[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Prompt,

    [string]$NegativePrompt = "",

    [ValidateRange(0, [long]::MaxValue)]
    [long]$Seed = 0,

    [ValidateRange(0.001, 1000000.0)]
    [double]$TargetHeight = 1.0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath(
    (Split-Path -Parent $PSScriptRoot)
)

$ComfyRunner = Join-Path $AssetFactoryRoot "tools\run-comfyui.ps1"
$TripoRunner = Join-Path $AssetFactoryRoot "tools\run-triposr.ps1"
$BlenderScript = Join-Path $AssetFactoryRoot "blender\scripts\process-mesh.py"

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

function Save-PipelineMetadata {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Metadata |
        ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-BlenderExecutable {
    $cmd = Get-Command blender.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Path)) {
        return $cmd.Path
    }

    $patterns = @()

    if ($env:ProgramFiles) {
        $patterns += (Join-Path $env:ProgramFiles "Blender Foundation\Blender*\blender.exe")
    }

    if ($env:LOCALAPPDATA) {
        $patterns += (Join-Path $env:LOCALAPPDATA "Programs\Blender Foundation\Blender*\blender.exe")
    }

    $matches = @()

    foreach ($pattern in $patterns) {
        $matches += Get-Item -Path $pattern -ErrorAction SilentlyContinue
    }

    $match = $matches |
        Sort-Object { [System.Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName).FileVersion } -Descending |
        Select-Object -First 1

    if ($null -ne $match) {
        return $match.FullName
    }

    return $null
}

if (-not (Test-Path -LiteralPath $ComfyRunner -PathType Leaf)) {
    Write-Fail "ComfyUI runner not found: $ComfyRunner"
    exit 1
}

if (-not (Test-Path -LiteralPath $TripoRunner -PathType Leaf)) {
    Write-Fail "TripoSR runner not found: $TripoRunner"
    exit 1
}

if (-not (Test-Path -LiteralPath $BlenderScript -PathType Leaf)) {
    Write-Fail "Blender processing script not found: $BlenderScript"
    exit 1
}

$BlenderExe = Get-BlenderExecutable
if ([string]::IsNullOrWhiteSpace($BlenderExe)) {
    Write-Fail "Blender executable not found."
    exit 1
}

$PipelineId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$PipelinesRoot = Join-Path $AssetFactoryRoot "outputs\pipelines"
$PipelineRoot = Join-Path $PipelinesRoot $PipelineId
$PipelineProcessedDir = Join-Path $PipelineRoot "processed"
$PipelineMetadataPath = Join-Path $PipelineRoot "pipeline.json"

New-Item -ItemType Directory -Path $PipelineProcessedDir -Force | Out-Null

$PipelineMetadata = [ordered]@{
    pipelineId = $PipelineId
    createdAt = (Get-Date).ToString("o")
    completedAt = $null
    status = "running"
    prompt = $Prompt
    negativePrompt = $NegativePrompt
    seed = $Seed
    targetHeightMeters = $TargetHeight
    comfyui = [ordered]@{
        status = "pending"
        jobId = $null
        imagePath = $null
        error = $null
    }
    triposr = [ordered]@{
        status = "pending"
        jobId = $null
        meshPath = $null
        error = $null
    }
    blender = [ordered]@{
        status = "pending"
        inputMeshPath = $null
        processedMeshPath = $null
        fbxPath = $null
        requestedHeightMeters = $TargetHeight
        finalHeightMeters = $null
        finalWidthMeters = $null
        finalDepthMeters = $null
        scaleFactor = $null
        baseZ = $null
        error = $null
    }
}

Save-PipelineMetadata -Metadata $PipelineMetadata -Path $PipelineMetadataPath

Write-Ok "ComfyUI runner found"
Write-Ok "TripoSR runner found"
Write-Ok "Blender processing script found"
Write-Ok "Blender executable found: $BlenderExe"
Write-Info "PipelineId: $PipelineId"
Write-Info "Prompt: $Prompt"
Write-Info "Seed: $Seed"
Write-Info "Target height: $TargetHeight m"
Write-Info "Generating source image with ComfyUI..."

$PipelineMetadata.comfyui.status = "running"
Save-PipelineMetadata -Metadata $PipelineMetadata -Path $PipelineMetadataPath

try {
    $ComfyOutput = & $ComfyRunner `
        -Prompt $Prompt `
        -NegativePrompt $NegativePrompt `
        -Seed $Seed 6>&1 2>&1

    $ComfyExitCode = $LASTEXITCODE

    foreach ($line in $ComfyOutput) {
        Write-Host $line
    }

    if ($ComfyExitCode -ne 0) {
        throw "ComfyUI generation failed with exit code $ComfyExitCode."
    }

    $ComfyJobLine = $ComfyOutput |
        Where-Object { $_ -match '^\[OK\] Job: ' } |
        Select-Object -Last 1

    $ImageLine = $ComfyOutput |
        Where-Object { $_ -match '^\[OK\] Image: ' } |
        Select-Object -Last 1

    if (-not $ComfyJobLine) {
        throw "Could not recover ComfyUI job ID from runner output."
    }

    if (-not $ImageLine) {
        throw "Could not recover generated image path from ComfyUI runner."
    }

    $ComfyJobId = ($ComfyJobLine -replace '^\[OK\] Job:\s*', '').Trim()
    $ImagePath = ($ImageLine -replace '^\[OK\] Image:\s*', '').Trim()

    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        throw "Generated image does not exist: $ImagePath"
    }

    $PipelineMetadata.comfyui.status = "completed"
    $PipelineMetadata.comfyui.jobId = $ComfyJobId
    $PipelineMetadata.comfyui.imagePath = $ImagePath
    $PipelineMetadata.comfyui.error = $null
    Save-PipelineMetadata -Metadata $PipelineMetadata -Path $PipelineMetadataPath

    Write-Ok "Source image ready: $ImagePath"
}
catch {
    $PipelineMetadata.status = "failed"
    $PipelineMetadata.completedAt = (Get-Date).ToString("o")
    $PipelineMetadata.comfyui.status = "failed"
    $PipelineMetadata.comfyui.error = $_.Exception.Message
    Save-PipelineMetadata -Metadata $PipelineMetadata -Path $PipelineMetadataPath

    Write-Fail $_.Exception.Message
    Write-Fail "Pipeline metadata: $PipelineMetadataPath"
    exit 1
}

Write-Info "Generating mesh with TripoSR..."

$PipelineMetadata.triposr.status = "running"
Save-PipelineMetadata -Metadata $PipelineMetadata -Path $PipelineMetadataPath

try {
    $PreviousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        $TripoOutput = & $TripoRunner `
            -InputPath $ImagePath 6>&1 2>&1

        $TripoExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    foreach ($line in $TripoOutput) {
        Write-Host $line
    }

    if ($TripoExitCode -ne 0) {
        throw "TripoSR generation failed with exit code $TripoExitCode."
    }

    $TripoJobLine = $TripoOutput |
        Where-Object { $_ -match '^\[OK\] Job: ' } |
        Select-Object -Last 1

    $MeshLine = $TripoOutput |
        Where-Object { $_ -match '^\[OK\] Mesh: ' } |
        Select-Object -Last 1

    if (-not $TripoJobLine) {
        throw "Could not recover TripoSR job ID from runner output."
    }

    if (-not $MeshLine) {
        throw "Could not recover generated mesh path from TripoSR runner."
    }

    $TripoJobId = ($TripoJobLine -replace '^\[OK\] Job:\s*', '').Trim()
    $MeshPath = ($MeshLine -replace '^\[OK\] Mesh:\s*', '').Trim()

    if (-not (Test-Path -LiteralPath $MeshPath -PathType Leaf)) {
        throw "Generated mesh does not exist: $MeshPath"
    }

    $PipelineMetadata.triposr.status = "completed"
    $PipelineMetadata.triposr.jobId = $TripoJobId
    $PipelineMetadata.triposr.meshPath = $MeshPath
    $PipelineMetadata.triposr.error = $null
    Save-PipelineMetadata -Metadata $PipelineMetadata -Path $PipelineMetadataPath
}
catch {
    $PipelineMetadata.status = "failed"
    $PipelineMetadata.completedAt = (Get-Date).ToString("o")
    $PipelineMetadata.triposr.status = "failed"
    $PipelineMetadata.triposr.error = $_.Exception.Message
    Save-PipelineMetadata -Metadata $PipelineMetadata -Path $PipelineMetadataPath

    Write-Fail $_.Exception.Message
    Write-Fail "Pipeline metadata: $PipelineMetadataPath"
    exit 1
}

Write-Info "Processing mesh with Blender..."

$ProcessedMeshPath = Join-Path $PipelineProcessedDir "mesh.obj"
$FbxPath = Join-Path $PipelineProcessedDir "mesh.fbx"

$PipelineMetadata.blender.status = "running"
$PipelineMetadata.blender.inputMeshPath = $MeshPath
Save-PipelineMetadata -Metadata $PipelineMetadata -Path $PipelineMetadataPath

try {
    $PreviousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        $TargetHeightInvariant = [string]::Format(
            [System.Globalization.CultureInfo]::InvariantCulture,
            "{0}",
            $TargetHeight
        )

        $BlenderOutput = & $BlenderExe `
            --background `
            --factory-startup `
            --python $BlenderScript `
            -- `
            --input $MeshPath `
            --output $ProcessedMeshPath `
            --fbx-output $FbxPath `
            --target-height $TargetHeightInvariant 6>&1 2>&1

        $BlenderExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }

    foreach ($line in $BlenderOutput) {
        Write-Host $line
    }

    if ($BlenderExitCode -ne 0) {
        throw "Blender processing failed with exit code $BlenderExitCode."
    }

    if (-not (Test-Path -LiteralPath $ProcessedMeshPath -PathType Leaf)) {
        throw "Blender completed but processed OBJ was not created: $ProcessedMeshPath"
    }

    if (-not (Test-Path -LiteralPath $FbxPath -PathType Leaf)) {
        throw "Blender completed but FBX was not created: $FbxPath"
    }

    $ResultLine = $BlenderOutput |
        Where-Object { $_ -match '^\[RESULT_JSON\]\s+' } |
        Select-Object -Last 1

    if (-not $ResultLine) {
        throw "Blender completed but did not return normalization metadata."
    }

    $ResultJson = ($ResultLine -replace '^\[RESULT_JSON\]\s*', '').Trim()
    $BlenderResult = $ResultJson | ConvertFrom-Json

    $ProcessedMeshPath = (Resolve-Path -LiteralPath $ProcessedMeshPath).Path
    $FbxPath = (Resolve-Path -LiteralPath $FbxPath).Path

    $PipelineMetadata.blender.status = "completed"
    $PipelineMetadata.blender.processedMeshPath = $ProcessedMeshPath
    $PipelineMetadata.blender.fbxPath = $FbxPath
    $PipelineMetadata.blender.finalHeightMeters = [double]$BlenderResult.final_height_m
    $PipelineMetadata.blender.finalWidthMeters = [double]$BlenderResult.final_width_m
    $PipelineMetadata.blender.finalDepthMeters = [double]$BlenderResult.final_depth_m
    $PipelineMetadata.blender.scaleFactor = [double]$BlenderResult.scale_factor
    $PipelineMetadata.blender.baseZ = [double]$BlenderResult.base_z
    $PipelineMetadata.blender.error = $null

    $PipelineMetadata.status = "completed"
    $PipelineMetadata.completedAt = (Get-Date).ToString("o")

    Save-PipelineMetadata -Metadata $PipelineMetadata -Path $PipelineMetadataPath
}
catch {
    $PipelineMetadata.status = "failed"
    $PipelineMetadata.completedAt = (Get-Date).ToString("o")
    $PipelineMetadata.blender.status = "failed"
    $PipelineMetadata.blender.error = $_.Exception.Message
    Save-PipelineMetadata -Metadata $PipelineMetadata -Path $PipelineMetadataPath

    Write-Fail $_.Exception.Message
    Write-Fail "Pipeline metadata: $PipelineMetadataPath"
    exit 1
}

Write-Ok "Image-to-3D pipeline completed"
Write-Ok "Pipeline: $PipelineId"
Write-Ok "ComfyUI job: $ComfyJobId"
Write-Ok "Image: $ImagePath"
Write-Ok "TripoSR job: $TripoJobId"
Write-Ok "Mesh: $MeshPath"
Write-Ok "Processed OBJ: $ProcessedMeshPath"
Write-Ok "FBX: $FbxPath"
Write-Ok "Final size: $($PipelineMetadata.blender.finalWidthMeters) x $($PipelineMetadata.blender.finalDepthMeters) x $($PipelineMetadata.blender.finalHeightMeters) m"
Write-Ok "Metadata: $PipelineMetadataPath"

exit 0
