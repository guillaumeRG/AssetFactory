[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$FbxPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AssetId,

    [string]$Category = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath(
    (Split-Path -Parent $PSScriptRoot)
)

$ImportScript = Join-Path $AssetFactoryRoot "unreal\import_asset.py"
$ImportJobsRoot = Join-Path $AssetFactoryRoot "outputs\unreal-imports"

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$BasePath = $AssetFactoryRoot
    )

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
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                return $resolved
            }

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
    foreach ($pattern in $patterns) {
        $matches += Get-Item -Path $pattern -ErrorAction SilentlyContinue
    }

    $match = $matches |
        Sort-Object FullName -Descending |
        Select-Object -First 1

    if ($null -ne $match) {
        return $match.FullName
    }

    throw "UnrealEditor-Cmd.exe was not found. Set 'unrealEditorCmd' in the project profile."
}

function Invoke-UnrealImport {
    param(
        [Parameter(Mandatory = $true)][string]$UnrealEditorCmd,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$JobPath
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

        foreach ($line in $output) {
            Write-Host $line
        }

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
$ResolvedFbxPath = Resolve-FullPath -Path $FbxPath

if (-not (Test-Path -LiteralPath $ResolvedProfilePath -PathType Leaf)) {
    Write-Fail "Project profile not found: $ResolvedProfilePath"
    exit 1
}

if (-not (Test-Path -LiteralPath $ResolvedFbxPath -PathType Leaf)) {
    Write-Fail "FBX not found: $ResolvedFbxPath"
    exit 1
}

if (-not (Test-Path -LiteralPath $ImportScript -PathType Leaf)) {
    Write-Fail "Unreal import script not found: $ImportScript"
    exit 1
}

try {
    $Profile = Get-Content -LiteralPath $ResolvedProfilePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    Write-Fail "Could not read project profile: $($_.Exception.Message)"
    exit 1
}

if (-not ($Profile.PSObject.Properties.Name -contains "engine") -or
    [string]$Profile.engine -ne "unreal") {
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

$ProjectPath = Resolve-FullPath -Path ([string]$Profile.projectPath) -BasePath (Split-Path -Parent $ResolvedProfilePath)

if (-not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
    Write-Fail "Unreal project not found: $ProjectPath"
    exit 1
}

if ([System.IO.Path]::GetExtension($ProjectPath) -ne ".uproject") {
    Write-Fail "projectPath must point to a .uproject file: $ProjectPath"
    exit 1
}

try {
    $UnrealEditorCmd = Get-UnrealEditorCmd -Profile $Profile
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}

$ImportSettings = [ordered]@{
    replaceExisting = $true
    importMaterials = $false
    importTextures = $false
    combineMeshes = $true
    generateLightmapUVs = $true
    autoGenerateCollision = $true
}

if ($Profile.PSObject.Properties.Name -contains "import" -and $null -ne $Profile.import) {
    foreach ($property in $ImportSettings.Keys.Clone()) {
        if ($Profile.import.PSObject.Properties.Name -contains $property) {
            $ImportSettings[$property] = [bool]$Profile.import.$property
        }
    }
}

if (-not (Test-Path -LiteralPath $ImportJobsRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $ImportJobsRoot -Force | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$safeAssetId = ($AssetId -replace '[^A-Za-z0-9_-]', '_')
$JobPath = Join-Path $ImportJobsRoot "$stamp-$safeAssetId.json"

$Job = [ordered]@{
    jobId = "$stamp-$safeAssetId"
    createdAt = (Get-Date).ToString("o")
    status = "pending"
    error = $null
    profilePath = $ResolvedProfilePath
    projectPath = $ProjectPath
    fbxPath = $ResolvedFbxPath
    assetId = $AssetId
    category = $Category
    contentRoot = [string]$Profile.contentRoot
    destinationPath = $null
    assetName = $null
    importSettings = $ImportSettings
    importedObjectPaths = @()
}

$Job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JobPath -Encoding UTF8

Write-Ok "Project profile loaded: $ResolvedProfilePath"
Write-Ok "Unreal project found: $ProjectPath"
Write-Ok "UnrealEditor-Cmd found: $UnrealEditorCmd"
Write-Info "FBX: $ResolvedFbxPath"
Write-Info "AssetId: $AssetId"
Write-Info "Category: $Category"
Write-Info "Destination root: $($Profile.contentRoot)"
Write-Info "Importing asset into Unreal..."

$Job.status = "running"
$Job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JobPath -Encoding UTF8

$exitCode = Invoke-UnrealImport `
    -UnrealEditorCmd $UnrealEditorCmd `
    -ProjectPath $ProjectPath `
    -JobPath $JobPath

if (-not (Test-Path -LiteralPath $JobPath -PathType Leaf)) {
    Write-Fail "Unreal import job metadata disappeared: $JobPath"
    exit 1
}

$result = Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($exitCode -ne 0 -or [string]$result.status -ne "completed") {
    $message = if (-not [string]::IsNullOrWhiteSpace([string]$result.error)) {
        [string]$result.error
    } else {
        "Unreal import failed with exit code $exitCode."
    }

    Write-Fail $message
    Write-Fail "Import metadata: $JobPath"
    exit 1
}

Write-Ok "Unreal import completed"
foreach ($objectPath in @($result.importedObjectPaths)) {
    Write-Ok "Unreal asset: $objectPath"
}
Write-Ok "Import metadata: $JobPath"

exit 0
