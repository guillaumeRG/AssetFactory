[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BatchPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath(
    (Split-Path -Parent $PSScriptRoot)
)

if ([System.IO.Path]::IsPathRooted($BatchPath)) {
    $ResolvedBatchPath = [System.IO.Path]::GetFullPath($BatchPath)
} else {
    $ResolvedBatchPath = [System.IO.Path]::GetFullPath(
        (Join-Path $AssetFactoryRoot $BatchPath)
    )
}

if (-not (Test-Path -LiteralPath $ResolvedBatchPath -PathType Leaf)) {
    Write-Host "[FAIL] Batch manifest not found: $ResolvedBatchPath" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Batch manifest found: $ResolvedBatchPath" -ForegroundColor Green

try {
    $BatchJson = Get-Content -LiteralPath $ResolvedBatchPath -Raw
    $Batch = $BatchJson | ConvertFrom-Json
} catch {
    Write-Host "[FAIL] Could not load batch manifest JSON." -ForegroundColor Red
    Write-Host "[INFO] $($_.Exception.Message)"
    exit 1
}

if (-not ($Batch.PSObject.Properties.Name -contains "batchId")) {
    Write-Host "[FAIL] Batch manifest is missing 'batchId'." -ForegroundColor Red
    exit 1
}

if (-not ($Batch.PSObject.Properties.Name -contains "assets")) {
    Write-Host "[FAIL] Batch manifest is missing 'assets'." -ForegroundColor Red
    exit 1
}

$Assets = @($Batch.assets)

if ($Assets.Count -eq 0) {
    Write-Host "[FAIL] Batch contains no assets." -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Batch loaded: $($Batch.batchId)" -ForegroundColor Green
Write-Host "[INFO] Assets: $($Assets.Count)"

$SeenAssetIds = @{}

foreach ($Asset in $Assets) {
    if (-not ($Asset.PSObject.Properties.Name -contains "id")) {
        Write-Host "[FAIL] An asset is missing 'id'." -ForegroundColor Red
        exit 1
    }

    if (-not ($Asset.PSObject.Properties.Name -contains "prompt")) {
        Write-Host "[FAIL] Asset '$($Asset.id)' is missing 'prompt'." -ForegroundColor Red
        exit 1
    }

    $AssetId = [string]$Asset.id
    $AssetPrompt = [string]$Asset.prompt

    if ([string]::IsNullOrWhiteSpace($AssetId)) {
        Write-Host "[FAIL] Asset id cannot be empty." -ForegroundColor Red
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($AssetPrompt)) {
        Write-Host "[FAIL] Asset '$AssetId' has an empty prompt." -ForegroundColor Red
        exit 1
    }

    if ($SeenAssetIds.ContainsKey($AssetId)) {
        Write-Host "[FAIL] Duplicate asset id: $AssetId" -ForegroundColor Red
        exit 1
    }

    $SeenAssetIds[$AssetId] = $true

    Write-Host "[OK] Asset valid: $AssetId" -ForegroundColor Green
}

if ([string]::IsNullOrWhiteSpace([string]$Batch.batchId)) {
    Write-Host "[FAIL] batchId cannot be empty." -ForegroundColor Red
    exit 1
}

if ([string]$Batch.batchId -notmatch '^[A-Za-z0-9._-]+$') {
    Write-Host "[FAIL] batchId contains invalid characters." -ForegroundColor Red
    exit 1
}

$BatchRunId = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$($Batch.batchId)"
$BatchRoot = Join-Path $AssetFactoryRoot "outputs\batches\$BatchRunId"

New-Item -ItemType Directory -Path $BatchRoot -Force | Out-Null

$BatchMetadataPath = Join-Path $BatchRoot "batch.json"

$BatchMetadata = [ordered]@{
    batchRunId = $BatchRunId
    batchId = [string]$Batch.batchId
    createdAt = (Get-Date).ToString("o")
    status = "running"
    manifestPath = $ResolvedBatchPath
    assetCount = $Assets.Count
}

$BatchMetadata |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $BatchMetadataPath -Encoding UTF8

Write-Host "[OK] Batch run created: $BatchRunId" -ForegroundColor Green
Write-Host "[OK] Batch metadata: $BatchMetadataPath" -ForegroundColor Green

$BatchAssetRecords = @()

foreach ($Asset in $Assets) {
    $negativePrompt = ""
    if ($Asset.PSObject.Properties.Name -contains "negativePrompt") {
        $negativePrompt = [string]$Asset.negativePrompt
    }

    $seed = 0
    if ($Asset.PSObject.Properties.Name -contains "seed") {
        $seed = [long]$Asset.seed
    }

    $BatchAssetRecords += [ordered]@{
        id = [string]$Asset.id
        prompt = [string]$Asset.prompt
        negativePrompt = $negativePrompt
        seed = $seed
        status = "pending"
        jobId = $null
        imagePath = $null
        error = $null
    }
}

$BatchMetadata["assets"] = $BatchAssetRecords

$BatchMetadata |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $BatchMetadataPath -Encoding UTF8

Write-Host "[OK] Batch asset records initialized" -ForegroundColor Green

$ComfyRunner = Join-Path $AssetFactoryRoot "tools\run-comfyui.ps1"

if (-not (Test-Path -LiteralPath $ComfyRunner -PathType Leaf)) {
    Write-Host "[FAIL] ComfyUI runner not found: $ComfyRunner" -ForegroundColor Red
    exit 1
}

for ($i = 0; $i -lt $BatchAssetRecords.Count; $i++) {
    $record = $BatchAssetRecords[$i]

    Write-Host "[INFO] Generating asset $($record.id) ($($i + 1)/$($BatchAssetRecords.Count))"

    $record.status = "running"

    $BatchMetadata |
        ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $BatchMetadataPath -Encoding UTF8

    $runnerOutput = & $ComfyRunner `
        -Prompt $record.prompt `
        -NegativePrompt $record.negativePrompt `
        -Seed $record.seed 6>&1 2>&1

    $runnerExitCode = $LASTEXITCODE

    foreach ($line in $runnerOutput) {
        Write-Host $line
    }

    if ($runnerExitCode -ne 0) {
        $record.status = "failed"
        $record.error = "run-comfyui.ps1 failed with exit code $runnerExitCode"

        $BatchMetadata.status = "failed"

        $BatchMetadata |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $BatchMetadataPath -Encoding UTF8

        Write-Host "[FAIL] Asset failed: $($record.id)" -ForegroundColor Red
        exit 1
    }

    $jobLine = $runnerOutput |
        Where-Object { $_ -match '^\[OK\] Job: ' } |
        Select-Object -Last 1

    $imageLine = $runnerOutput |
        Where-Object { $_ -match '^\[OK\] Image: ' } |
        Select-Object -Last 1

    if (-not $jobLine -or -not $imageLine) {
        $record.status = "failed"
        $record.error = "Could not extract jobId or imagePath from runner output"

        $BatchMetadata.status = "failed"

        $BatchMetadata |
            ConvertTo-Json -Depth 20 |
            Set-Content -LiteralPath $BatchMetadataPath -Encoding UTF8

        Write-Host "[FAIL] Could not extract result for asset: $($record.id)" -ForegroundColor Red
        exit 1
    }

    $record.jobId = ($jobLine -replace '^\[OK\] Job:\s*', '').Trim()
    $record.imagePath = ($imageLine -replace '^\[OK\] Image:\s*', '').Trim()
    $record.status = "completed"

    $BatchMetadata |
        ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $BatchMetadataPath -Encoding UTF8
}

$BatchMetadata.status = "completed"
$BatchMetadata.completedAt = (Get-Date).ToString("o")

$BatchMetadata |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $BatchMetadataPath -Encoding UTF8

Write-Host "[OK] Batch completed: $BatchRunId" -ForegroundColor Green
Write-Host "[OK] Metadata: $BatchMetadataPath" -ForegroundColor Green