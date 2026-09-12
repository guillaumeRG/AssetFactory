param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath
)

# AssetFactory root = parent of tools\
$AssetFactoryRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
# Resolve input path
# ---------------------------------------------------------------------------

if (Test-Path -LiteralPath $InputPath) {
    $AbsInputPath = (Resolve-Path -LiteralPath $InputPath).Path
}
else {
    $CandidateInputPath = Join-Path -Path $AssetFactoryRoot -ChildPath $InputPath

    if (-not (Test-Path -LiteralPath $CandidateInputPath)) {
        Write-Output "[FAIL] Input file not found: $InputPath"
        exit 1
    }

    $AbsInputPath = (Resolve-Path -LiteralPath $CandidateInputPath).Path
}

# ---------------------------------------------------------------------------
# Validate TripoSR installation
# ---------------------------------------------------------------------------

$TripoSREngineDir = Join-Path -Path $AssetFactoryRoot -ChildPath "engines\triposr"
$PythonPath = Join-Path -Path $TripoSREngineDir -ChildPath ".venv\Scripts\python.exe"
$RunScriptPath = Join-Path -Path $TripoSREngineDir -ChildPath "run.py"

if (-not (Test-Path -LiteralPath $PythonPath)) {
    Write-Output "[FAIL] Python executable not found: $PythonPath"
    exit 1
}

if (-not (Test-Path -LiteralPath $RunScriptPath)) {
    Write-Output "[FAIL] TripoSR run script not found: $RunScriptPath"
    exit 1
}

# ---------------------------------------------------------------------------
# Create AssetFactory job
# ---------------------------------------------------------------------------

$JobId = Get-Date -Format "yyyyMMdd-HHmmss-fff"

$JobsRoot = Join-Path -Path $AssetFactoryRoot -ChildPath "outputs\jobs"
$JobDirectory = Join-Path -Path $JobsRoot -ChildPath $JobId

$InputDir = Join-Path -Path $JobDirectory -ChildPath "input"
$GeneratedDir = Join-Path -Path $JobDirectory -ChildPath "generated"
$MeshDir = Join-Path -Path $JobDirectory -ChildPath "mesh"
$LogsDir = Join-Path -Path $JobDirectory -ChildPath "logs"

New-Item -ItemType Directory -Force -Path $InputDir | Out-Null
New-Item -ItemType Directory -Force -Path $GeneratedDir | Out-Null
New-Item -ItemType Directory -Force -Path $MeshDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

# Copy source image into the job
$InputFileName = Split-Path -Path $AbsInputPath -Leaf
$JobInputPath = Join-Path -Path $InputDir -ChildPath $InputFileName

Copy-Item -LiteralPath $AbsInputPath -Destination $JobInputPath -Force

$JobInputPath = (Resolve-Path -LiteralPath $JobInputPath).Path

# TripoSR temporary/generated output stays inside the job
$TripoSROutputDir = Join-Path -Path $GeneratedDir -ChildPath "triposr"

New-Item -ItemType Directory -Force -Path $TripoSROutputDir | Out-Null

$FinalMeshPath = Join-Path -Path $MeshDir -ChildPath "mesh.obj"
$JobJsonPath = Join-Path -Path $JobDirectory -ChildPath "job.json"

$CreatedAt = (Get-Date).ToString("o")
$StartedAt = (Get-Date).ToString("o")

$JobData = [ordered]@{
    jobId = $JobId
    createdAt = $CreatedAt
    status = "running"

    input = [ordered]@{
        sourcePath = $AbsInputPath
        storedPath = $JobInputPath
    }

    steps = [ordered]@{
        triposr = [ordered]@{
            status = "running"
            startedAt = $StartedAt
            completedAt = $null
            meshPath = $null
            error = $null
        }
    }
}

$JobData |
    ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $JobJsonPath -Encoding UTF8

# ---------------------------------------------------------------------------
# Run TripoSR
# ---------------------------------------------------------------------------

$OriginalLocation = Get-Location
$ExitCode = 1
$FailureMessage = $null

try {
    Set-Location -LiteralPath $TripoSREngineDir

    & $PythonPath $RunScriptPath $JobInputPath --output-dir $TripoSROutputDir

    # Capture immediately after Python execution
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -ne 0) {
        $FailureMessage = "TripoSR failed with exit code: $ExitCode"
    }
    else {
        $GeneratedMeshPath = Join-Path -Path $TripoSROutputDir -ChildPath "0\mesh.obj"

        if (-not (Test-Path -LiteralPath $GeneratedMeshPath)) {
            $ExitCode = 1
            $FailureMessage = "TripoSR completed but mesh was not found: $GeneratedMeshPath"
        }
        else {
            Copy-Item -LiteralPath $GeneratedMeshPath -Destination $FinalMeshPath -Force

            if (-not (Test-Path -LiteralPath $FinalMeshPath)) {
                $ExitCode = 1
                $FailureMessage = "Final mesh could not be created: $FinalMeshPath"
            }
            else {
                $FinalMeshPath = (Resolve-Path -LiteralPath $FinalMeshPath).Path
                $ExitCode = 0
            }
        }
    }
}
catch {
    $ExitCode = 1
    $FailureMessage = $_.Exception.Message
}
finally {
    Set-Location -LiteralPath $OriginalLocation
}

# ---------------------------------------------------------------------------
# Finalize job metadata
# ---------------------------------------------------------------------------

$CompletedAt = (Get-Date).ToString("o")

if ($ExitCode -eq 0) {
    $JobData.status = "success"

    $JobData.steps.triposr.status = "success"
    $JobData.steps.triposr.completedAt = $CompletedAt
    $JobData.steps.triposr.meshPath = $FinalMeshPath
    $JobData.steps.triposr.error = $null
}
else {
    if ([string]::IsNullOrWhiteSpace($FailureMessage)) {
        $FailureMessage = "Unknown TripoSR failure."
    }

    $JobData.status = "failed"

    $JobData.steps.triposr.status = "failed"
    $JobData.steps.triposr.completedAt = $CompletedAt
    $JobData.steps.triposr.meshPath = $null
    $JobData.steps.triposr.error = $FailureMessage
}

$JobData |
    ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $JobJsonPath -Encoding UTF8

$JobJsonPath = (Resolve-Path -LiteralPath $JobJsonPath).Path

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if ($ExitCode -ne 0) {
    Write-Output "[FAIL] Asset Factory job failed"
    Write-Output "[FAIL] Job: $JobId"
    Write-Output "[FAIL] Error: $FailureMessage"
    Write-Output "[FAIL] Metadata: $JobJsonPath"
    exit $ExitCode
}

Write-Output "[OK] Asset Factory job completed"
Write-Output "[OK] Job: $JobId"
Write-Output "[OK] Mesh: $FinalMeshPath"
Write-Output "[OK] Metadata: $JobJsonPath"

exit 0