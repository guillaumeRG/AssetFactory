[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [string]$AssetId = "",
    [string]$GenerationRoot = "",
    [string]$AssetVersion = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")

$TripoSREngineDir = Join-Path $AssetFactoryRoot "engines\triposr"
$PythonPath = Join-Path $TripoSREngineDir ".venv\Scripts\python.exe"
$RunScriptPath = Join-Path $TripoSREngineDir "run.py"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" }
function Write-Ok { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Host "[FAIL] $Message" -ForegroundColor Red }

$Metadata = $null
$MetadataPath = $null
$TempOutputDir = $null
$ExitCode = 1
$FailureMessage = $null
$Layout = $null
$OwnsGeneration = [string]::IsNullOrWhiteSpace($GenerationRoot)
$StandaloneGeneration = $null
$StandaloneGenerationPath = $null

try {
    $ResolvedInput = Resolve-AFPath -Path $InputPath -BasePath (Get-Location).Path
    Assert-AFFile -Path $ResolvedInput -Label "Input image"

    if ([string]::IsNullOrWhiteSpace($AssetId)) {
        $AssetId = [System.IO.Path]::GetFileNameWithoutExtension($ResolvedInput)
    }
    Assert-AFFileStem -Name $AssetId

    Assert-AFFile -Path $PythonPath -Label "TripoSR Python executable"
    Assert-AFFile -Path $RunScriptPath -Label "TripoSR run script"

    $Layout = Resolve-AFGenerationLayout `
        -Root $AssetFactoryRoot `
        -AssetId $AssetId `
        -GenerationRoot $GenerationRoot `
        -Version $AssetVersion

    $extension = [System.IO.Path]::GetExtension($ResolvedInput).ToLowerInvariant()
    if ($extension -notin @(".png", ".jpg", ".jpeg", ".webp")) {
        throw "InputPath must be a PNG, JPEG or WebP image."
    }

    $StoredInput = Join-Path $Layout.SourceDir ($AssetId + $extension)
    if ([System.IO.Path]::GetFullPath($ResolvedInput) -ne [System.IO.Path]::GetFullPath($StoredInput)) {
        if (Test-Path -LiteralPath $StoredInput) {
            $existing = Get-Item -LiteralPath $StoredInput
            $source = Get-Item -LiteralPath $ResolvedInput
            if ($existing.Length -ne $source.Length) {
                throw "Generation source image already exists with different content: $StoredInput"
            }
        } else {
            Copy-Item -LiteralPath $ResolvedInput -Destination $StoredInput
        }
    }
    Assert-AFFile -Path $StoredInput -Label "Stored input image"

    $RawMeshPath = Join-Path $Layout.RawDir ($AssetId + ".obj")
    if (Test-Path -LiteralPath $RawMeshPath) {
        throw "Raw TripoSR mesh already exists; refusing to overwrite it: $RawMeshPath"
    }

    $MetadataPath = Join-Path $Layout.MetadataDir "triposr.json"
    $JobId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $Metadata = [ordered]@{
        schemaVersion = 3
        jobId = $JobId
        assetId = $AssetId
        assetVersion = $Layout.Version
        generationRoot = $Layout.Root
        createdAt = (Get-Date).ToString("o")
        completedAt = $null
        status = "running"
        sourcePath = $ResolvedInput
        storedInputPath = $StoredInput
        meshPath = $null
        error = $null
    }
    Save-AFJson -Value $Metadata -Path $MetadataPath
    if ($OwnsGeneration) {
        $StandaloneGenerationPath = $Layout.GenerationMetadataPath
        $StandaloneGeneration = [ordered]@{
            schemaVersion = 3
            generationId = "$AssetId-$($Layout.Version)"
            assetId = $AssetId
            assetVersion = $Layout.Version
            generationRoot = $Layout.Root
            type = "engine-only"
            engine = "triposr"
            createdAt = $Metadata.createdAt
            completedAt = $null
            status = "running"
            imagePath = $StoredInput
            rawModelPath = $null
            metadataPath = $MetadataPath
            error = $null
        }
        Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath
    }

    $TempOutputDir = Join-Path ([System.IO.Path]::GetTempPath()) ("assetfactory-triposr-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $TempOutputDir | Out-Null

    Write-Info "AssetId: $AssetId"
    Write-Info "Generation: $($Layout.Root)"
    Write-Info "Input: $StoredInput"
    Write-Info "Raw output: $RawMeshPath"

    $OriginalLocation = Get-Location
    try {
        Set-Location -LiteralPath $TripoSREngineDir
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $PythonPath $RunScriptPath $StoredInput --output-dir $TempOutputDir
            $nativeExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldPreference
        }
    } finally {
        Set-Location -LiteralPath $OriginalLocation
    }

    if ($nativeExitCode -ne 0) {
        throw "TripoSR failed with exit code: $nativeExitCode"
    }

    $GeneratedMeshPath = Join-Path $TempOutputDir "0\mesh.obj"
    Assert-AFFile -Path $GeneratedMeshPath -Label "TripoSR generated mesh"
    Copy-Item -LiteralPath $GeneratedMeshPath -Destination $RawMeshPath
    Assert-AFFile -Path $RawMeshPath -Label "Raw TripoSR mesh"

    $Metadata.status = "completed"
    $Metadata.completedAt = (Get-Date).ToString("o")
    $Metadata.meshPath = $RawMeshPath
    Save-AFJson -Value $Metadata -Path $MetadataPath
    if ($null -ne $StandaloneGeneration) {
        $StandaloneGeneration.status = "completed"
        $StandaloneGeneration.completedAt = $Metadata.completedAt
        $StandaloneGeneration.rawModelPath = $RawMeshPath
        Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath
    }
    $ExitCode = 0
}
catch {
    $FailureMessage = $_.Exception.Message
    if ($null -ne $Metadata -and $null -ne $MetadataPath) {
        $Metadata.status = "failed"
        $Metadata.completedAt = (Get-Date).ToString("o")
        $Metadata.error = $FailureMessage
        try { Save-AFJson -Value $Metadata -Path $MetadataPath } catch { }
    }
    if ($null -ne $StandaloneGeneration -and $null -ne $StandaloneGenerationPath) {
        $StandaloneGeneration.status = "failed"
        $StandaloneGeneration.completedAt = (Get-Date).ToString("o")
        $StandaloneGeneration.error = $FailureMessage
        try { Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath } catch { }
    }
    Write-Fail $FailureMessage
    $ExitCode = 1
}
finally {
    if ($TempOutputDir -and (Test-Path -LiteralPath $TempOutputDir -PathType Container)) {
        Remove-Item -LiteralPath $TempOutputDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($ExitCode -eq 0) {
    Write-Ok "TripoSR generation completed"
    Write-Ok "Job: $JobId"
    Write-Ok "Generation: $($Layout.Root)"
    if (-not [string]::IsNullOrWhiteSpace($Layout.Version)) { Write-Ok "Version: $($Layout.Version)" }
    Write-Ok "Mesh: $RawMeshPath"
    Write-Ok "Metadata: $MetadataPath"
    if ($null -ne $StandaloneGenerationPath) { Write-Ok "Generation metadata: $StandaloneGenerationPath" }
}
exit $ExitCode
