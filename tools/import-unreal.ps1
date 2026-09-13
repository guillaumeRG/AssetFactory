[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [Alias("FbxPath", "GlbPath")]
    [string]$SourcePath,

    [string]$AssetId = "",
    [string]$AssetVersion = "",
    [string]$Category = "",
    [string]$MetadataPath = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")
$ImportScript = Join-Path $AssetFactoryRoot "unreal\import_asset.py"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" }
function Write-Ok { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Host "[FAIL] $Message" -ForegroundColor Red }

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$BasePath = $AssetFactoryRoot)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Get-UnrealEditorCmd {
    param($Profile)

    if ($Profile.PSObject.Properties.Name -contains "unrealEditorCmd") {
        $configured = [string]$Profile.unrealEditorCmd
        if (-not [string]::IsNullOrWhiteSpace($configured)) {
            $resolved = Resolve-FullPath -Path $configured
            if (Test-Path -LiteralPath $resolved -PathType Leaf) { return $resolved }
            throw "Configured UnrealEditor-Cmd.exe does not exist: $resolved"
        }
    }

    $command = Get-Command "UnrealEditor-Cmd.exe" -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Path)) {
        return $command.Path
    }

    $patterns = @()
    if ($env:ProgramFiles) {
        $patterns += (Join-Path $env:ProgramFiles "Epic Games\UE_*\Engine\Binaries\Win64\UnrealEditor-Cmd.exe")
    }
    $matches = @()
    foreach ($pattern in $patterns) { $matches += Get-Item -Path $pattern -ErrorAction SilentlyContinue }
    $match = $matches | Sort-Object FullName -Descending | Select-Object -First 1
    if ($null -ne $match) { return $match.FullName }

    throw "UnrealEditor-Cmd.exe was not found. Set 'unrealEditorCmd' in the project profile."
}

function Invoke-UnrealImport {
    param(
        [Parameter(Mandatory = $true)][string]$UnrealEditorCmd,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$JobPath,
        [Parameter(Mandatory = $true)][string]$ResolvedLogPath
    )

    $oldJob = $env:ASSET_FACTORY_IMPORT_JOB
    try {
        $env:ASSET_FACTORY_IMPORT_JOB = $JobPath
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & $UnrealEditorCmd `
                $ProjectPath `
                "-ExecutePythonScript=$ImportScript" `
                "-unattended" `
                "-nop4" `
                "-nosplash" `
                "-NoSound" 6>&1 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        $output | ForEach-Object { $_.ToString() } |
            Set-Content -LiteralPath $ResolvedLogPath -Encoding UTF8
        foreach ($line in $output) { Write-Host $line }
        Write-Info "Unreal log: $ResolvedLogPath"
        return $exitCode
    }
    finally {
        if ($null -eq $oldJob) {
            Remove-Item Env:ASSET_FACTORY_IMPORT_JOB -ErrorAction SilentlyContinue
        } else {
            $env:ASSET_FACTORY_IMPORT_JOB = $oldJob
        }
    }
}

$ResolvedProfilePath = Resolve-FullPath -Path $ProfilePath
$ResolvedSourcePath = Resolve-FullPath -Path $SourcePath

if (-not (Test-Path -LiteralPath $ResolvedProfilePath -PathType Leaf)) {
    Write-Fail "Project profile not found: $ResolvedProfilePath"
    exit 1
}
if (-not (Test-Path -LiteralPath $ResolvedSourcePath -PathType Leaf)) {
    Write-Fail "Source model not found: $ResolvedSourcePath"
    exit 1
}
$SourceExtension = [System.IO.Path]::GetExtension($ResolvedSourcePath).ToLowerInvariant()
if ($SourceExtension -notin @(".fbx", ".glb")) {
    Write-Fail "Unsupported model format '$SourceExtension'. Expected .fbx or .glb."
    exit 1
}
if ((Get-Item -LiteralPath $ResolvedSourcePath).Length -le 0) {
    Write-Fail "Source model is empty: $ResolvedSourcePath"
    exit 1
}
if ([string]::IsNullOrWhiteSpace($AssetId)) {
    $AssetId = [System.IO.Path]::GetFileNameWithoutExtension($ResolvedSourcePath)
}
try {
    Assert-AFFileStem -Name $AssetId
    if (-not [string]::IsNullOrWhiteSpace($AssetVersion)) {
        Assert-AFAssetVersion -Version $AssetVersion
    }
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}
if (-not (Test-Path -LiteralPath $ImportScript -PathType Leaf)) {
    Write-Fail "Unreal import script not found: $ImportScript"
    exit 1
}

try {
    $Profile = Get-Content -LiteralPath $ResolvedProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Fail "Could not read project profile: $($_.Exception.Message)"
    exit 1
}

if (-not ($Profile.PSObject.Properties.Name -contains "engine") -or [string]$Profile.engine -ne "unreal") {
    Write-Fail "Profile engine must be 'unreal'."
    exit 1
}
if (-not ($Profile.PSObject.Properties.Name -contains "projectPath") -or
    [string]::IsNullOrWhiteSpace([string]$Profile.projectPath)) {
    Write-Fail "Profile is missing projectPath."
    exit 1
}
if (-not ($Profile.PSObject.Properties.Name -contains "contentRoot") -or
    [string]::IsNullOrWhiteSpace([string]$Profile.contentRoot)) {
    Write-Fail "Profile is missing contentRoot."
    exit 1
}
if ([string]$Profile.contentRoot -notmatch '^/Game(?:/[A-Za-z0-9_]+)*/?$') {
    Write-Fail "Profile contentRoot must be /Game or valid folders under /Game."
    exit 1
}

$ProjectPath = Resolve-FullPath -Path ([string]$Profile.projectPath) -BasePath (Split-Path -Parent $ResolvedProfilePath)
if (-not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
    Write-Fail "Unreal project not found: $ProjectPath"
    exit 1
}
if ([System.IO.Path]::GetExtension($ProjectPath) -ne ".uproject") {
    Write-Fail "projectPath must point to a .uproject file: $ProjectPath"
    exit 1
}

try { $UnrealEditorCmd = Get-UnrealEditorCmd -Profile $Profile }
catch {
    Write-Fail $_.Exception.Message
    exit 1
}

$IsGlb = $SourceExtension -eq ".glb"
$ImportSettings = [ordered]@{
    replaceExisting = $true
    importMaterials = $IsGlb
    importTextures = $IsGlb
    combineMeshes = $true
    generateLightmapUVs = $true
    autoGenerateCollision = $true
}

# Les réglages généraux restent compatibles avec les FBX ; importGlb ne surcharge que les GLB.
$settingsBlocks = @("import")
if ($IsGlb) { $settingsBlocks += "importGlb" }
foreach ($blockName in $settingsBlocks) {
    if ($Profile.PSObject.Properties.Name -contains $blockName -and $null -ne $Profile.$blockName) {
        $block = $Profile.$blockName
        foreach ($property in @($ImportSettings.Keys)) {
            if ($block.PSObject.Properties.Name -contains $property) {
                if ($block.$property -isnot [bool]) {
                    Write-Fail "Profile $blockName.$property must be a JSON boolean."
                    exit 1
                }
                $ImportSettings[$property] = [bool]$block.$property
            }
        }
    }
}

$OverwriteExistingVersion = $false
if ($Profile.PSObject.Properties.Name -contains "overwriteExistingVersion") {
    if ($Profile.overwriteExistingVersion -isnot [bool]) {
        Write-Fail "Profile overwriteExistingVersion must be a JSON boolean."
        exit 1
    }
    $OverwriteExistingVersion = [bool]$Profile.overwriteExistingVersion
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$safeAssetId = ($AssetId -replace '[^A-Za-z0-9_-]', '_')
if ([string]::IsNullOrWhiteSpace($MetadataPath)) {
    $recordRoot = Join-Path $AssetFactoryRoot "outputs\imports\$safeAssetId\$stamp"
    New-Item -ItemType Directory -Path $recordRoot -Force | Out-Null
    $JobPath = Join-Path $recordRoot "import.json"
} else {
    $JobPath = Resolve-FullPath -Path $MetadataPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $JobPath) -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $ResolvedLogPath = Join-Path (Split-Path -Parent $JobPath) "unreal.log"
} else {
    $ResolvedLogPath = Resolve-FullPath -Path $LogPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $ResolvedLogPath) -Force | Out-Null
}

$Job = [ordered]@{
    schemaVersion = 3
    jobId = "$stamp-$safeAssetId"
    logPath = $ResolvedLogPath
    createdAt = (Get-Date).ToString("o")
    status = "pending"
    error = $null
    profilePath = $ResolvedProfilePath
    projectPath = $ProjectPath
    sourcePath = $ResolvedSourcePath
    sourceFormat = $SourceExtension.TrimStart(".")
    fbxPath = $(if (-not $IsGlb) { $ResolvedSourcePath } else { $null })
    assetId = $AssetId
    requestedAssetVersion = $(if ([string]::IsNullOrWhiteSpace($AssetVersion)) { $null } else { $AssetVersion })
    assetVersion = $null
    overwriteExistingVersion = $OverwriteExistingVersion
    category = $Category
    contentRoot = ([string]$Profile.contentRoot).TrimEnd("/")
    destinationPath = $null
    assetName = $null
    importSettings = $ImportSettings
    importedObjectPaths = @()
}
$Job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JobPath -Encoding UTF8

Write-Ok "Project profile loaded: $ResolvedProfilePath"
Write-Ok "Unreal project found: $ProjectPath"
Write-Ok "UnrealEditor-Cmd found: $UnrealEditorCmd"
Write-Info "Source: $ResolvedSourcePath"
Write-Info "Format: $($SourceExtension.TrimStart('.'))"
Write-Info "Materials: $($ImportSettings.importMaterials) / Textures: $($ImportSettings.importTextures)"
Write-Info "AssetId: $AssetId"
if (-not [string]::IsNullOrWhiteSpace($AssetVersion)) { Write-Info "Requested version: $AssetVersion" }
Write-Info "Category: $Category"
Write-Info "Destination root: $($Profile.contentRoot)"
Write-Info "Existing versions are preserved by default."
Write-Info "Importing asset into Unreal..."

$Job.status = "running"
$Job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JobPath -Encoding UTF8

try {
    $exitCode = Invoke-UnrealImport `
        -UnrealEditorCmd $UnrealEditorCmd `
        -ProjectPath $ProjectPath `
        -JobPath $JobPath `
        -ResolvedLogPath $ResolvedLogPath
}
catch {
    $Job.status = "failed"
    $Job.error = $_.Exception.Message
    $Job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JobPath -Encoding UTF8
    Write-Fail $Job.error
    Write-Fail "Import metadata: $JobPath"
    exit 1
}

if (-not (Test-Path -LiteralPath $JobPath -PathType Leaf)) {
    Write-Fail "Unreal import metadata disappeared: $JobPath"
    exit 1
}
$result = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($exitCode -ne 0 -or [string]$result.status -ne "completed") {
    $message = if (-not [string]::IsNullOrWhiteSpace([string]$result.error)) {
        [string]$result.error
    } else {
        "Unreal import failed with exit code $exitCode."
    }
    $result.status = "failed"
    $result.error = $message
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JobPath -Encoding UTF8
    Write-Fail $message
    Write-Fail "Import metadata: $JobPath"
    exit 1
}

Write-Ok "Unreal import completed"
Write-Ok "Unreal version: $($result.assetVersion)"
Write-Ok "Unreal destination: $($result.destinationPath)"
foreach ($objectPath in @($result.importedObjectPaths)) { Write-Ok "Unreal asset: $objectPath" }
Write-Ok "Import metadata: $JobPath"
exit 0
