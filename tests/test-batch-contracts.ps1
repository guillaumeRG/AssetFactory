[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$SourceRoot = Split-Path -Parent $PSScriptRoot
$Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("af-batch-v1-" + [guid]::NewGuid().ToString("N"))
$OldRoot = $env:AF_BATCH_TEST_ROOT
$OldFailId = $env:AF_BATCH_TEST_FAIL_ID
$script:Checks = 0

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:Checks++
    Write-Host "[PASS] $Message"
}

function Reset-Calls {
    Set-Content -LiteralPath (Join-Path $Sandbox "calls.jsonl") -Value "" -Encoding UTF8
    $env:AF_BATCH_TEST_FAIL_ID = ""
}

function Read-Calls {
    $path = Join-Path $Sandbox "calls.jsonl"
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Write-Manifest {
    param([string]$RelativePath, $Value)
    $path = Join-Path $Sandbox $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Invoke-Batch {
    param([string]$ManifestPath, [switch]$Resume, [switch]$ValidateOnly)
    $global:LASTEXITCODE = 0
    $output = @(& (Join-Path $Sandbox "tools\run-batch.ps1") -ManifestPath $ManifestPath -Resume:$Resume -ValidateOnly:$ValidateOnly 6>&1 2>&1 | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
}

function New-BaseManifest {
    param([string]$BatchId, [string]$EntryPoint)
    return [ordered]@{
        kind = "asset-factory-batch"
        schemaVersion = 1
        batchId = $BatchId
        entryPoint = $EntryPoint
        execution = [ordered]@{ continueOnError = $false; maxParallelism = 1 }
        items = @()
    }
}

function Assert-RejectedWithoutCalls {
    param([string]$Name, $Manifest)
    Reset-Calls
    $path = Write-Manifest -RelativePath ("batches\reject-" + $Name + ".json") -Value $Manifest
    $result = Invoke-Batch -ManifestPath $path
    Assert-Test ($result.Code -ne 0) "$Name is rejected"
    Assert-Test (@(Read-Calls).Count -eq 0) "$Name is rejected before any public entry point call"
}

try {
    New-Item -ItemType Directory -Path (Join-Path $Sandbox "tools\internal") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Sandbox "workflows") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Sandbox "inputs") -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceRoot "tools\pipeline-common.ps1") -Destination (Join-Path $Sandbox "tools\pipeline-common.ps1")
    Copy-Item -LiteralPath (Join-Path $SourceRoot "tools\run-batch.ps1") -Destination (Join-Path $Sandbox "tools\run-batch.ps1")
    Copy-Item -LiteralPath (Join-Path $SourceRoot "tools\internal\AssetFactory.Batch.psm1") -Destination (Join-Path $Sandbox "tools\internal\AssetFactory.Batch.psm1")
    Set-Content -LiteralPath (Join-Path $Sandbox "workflows\test.json") -Value "{}" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Sandbox "inputs\source.png") -Value "fake" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Sandbox "fake-blender.exe") -Value "fake" -Encoding UTF8

    @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Prompt,
    [string]$NegativePrompt = "",
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$AssetId,
    [ValidateRange(0, [long]::MaxValue)][long]$Seed = 0,
    [ValidateRange(1, 64)][int]$Candidates = 1,
    [string]$Preset = "",
    [string[]]$Exclude = @(),
    [string]$AssetVersion = "",
    [string]$WorkflowPath = "workflows\test.json",
    [string]$ServerUrl = "http://127.0.0.1:8188",
    [ValidateRange(10, 3600)][int]$TimeoutSeconds = 300,
    [bool]$ReleaseComfyMemory = $true
)
$call = [ordered]@{ entryPoint = "generate-image"; prompt = $Prompt; negativePrompt = $NegativePrompt; assetId = $AssetId; seed = $Seed; candidates = $Candidates; preset = $Preset; exclude = @($Exclude); assetVersion = $AssetVersion; workflowPath = $WorkflowPath; serverUrl = $ServerUrl; timeoutSeconds = $TimeoutSeconds; releaseComfyMemory = $ReleaseComfyMemory }
$call | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $env:AF_BATCH_TEST_ROOT "calls.jsonl")
if ($env:AF_BATCH_TEST_FAIL_ID -eq $AssetId) { exit 1 }
$result = [ordered]@{ kind = "stub"; status = "completed"; assetId = $AssetId; generationRoot = (Join-Path $env:AF_BATCH_TEST_ROOT ("generated\" + $AssetId)) }
Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\generate-image.ps1") -Encoding UTF8

    @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$InputPath,
    [string]$AssetId = "",
    [ValidateSet("trellis", "triposr")][string]$GeometryMethod = "trellis",
    [ValidateRange(0, [long]::MaxValue)][long]$Seed = 0,
    [bool]$Multiview = $false,
    [ValidateRange(1, 100)][int]$MultiviewCameras = 8,
    [ValidateRange(256, 8192)][int]$TextureResolution = 2048,
    [string]$TextureCheckpoint = "checkpoint.safetensors",
    [string]$TexturePrompt = "",
    [string]$TextureNegativePrompt = "",
    [bool]$KeepProjectedBlend = $false,
    [ValidateRange(0.001, 1000000.0)][double]$TargetHeight = 1.0,
    [string]$ProjectProfile = "",
    [string]$Category = "",
    [System.Nullable[bool]]$AutoImport = $null,
    [ValidateRange(0.0, 0.99)][double]$TrellisSimplify = 0.95,
    [ValidateSet(512, 1024, 2048)][int]$TrellisTextureSize = 1024,
    [ValidateSet("none", "qa")][string]$Postprocess = "none",
    [string]$BlenderPath = ""
)
$call = [ordered]@{ entryPoint = "generate-asset-from-image"; inputPath = $InputPath; assetId = $AssetId; seed = $Seed; geometryMethod = $GeometryMethod; multiview = $Multiview; multiviewCameras = $MultiviewCameras; textureResolution = $TextureResolution; textureCheckpoint = $TextureCheckpoint; texturePrompt = $TexturePrompt; textureNegativePrompt = $TextureNegativePrompt; keepProjectedBlend = $KeepProjectedBlend; targetHeight = $TargetHeight; projectProfile = $ProjectProfile; category = $Category; autoImport = $AutoImport; trellisSimplify = $TrellisSimplify; trellisTextureSize = $TrellisTextureSize; postprocess = $Postprocess; blenderPath = $BlenderPath }
$call | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $env:AF_BATCH_TEST_ROOT "calls.jsonl")
if ($env:AF_BATCH_TEST_FAIL_ID -eq $AssetId) { exit 1 }
$result = [ordered]@{ kind = "stub"; status = "completed"; assetId = $AssetId; generationRoot = (Join-Path $env:AF_BATCH_TEST_ROOT ("generated\" + $AssetId)) }
Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\generate-asset-from-image.ps1") -Encoding UTF8

    @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Prompt,
    [string]$NegativePrompt = "",
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$AssetId,
    [ValidateRange(0, [long]::MaxValue)][long]$Seed = 0,
    [ValidateRange(1, 64)][int]$Candidates = 1,
    [string]$Preset = "",
    [string[]]$Exclude = @(),
    [ValidateSet("trellis", "triposr")][string]$GeometryMethod = "trellis",
    [bool]$Multiview = $false,
    [ValidateRange(1, 100)][int]$MultiviewCameras = 8,
    [ValidateRange(256, 8192)][int]$TextureResolution = 2048,
    [string]$TextureCheckpoint = "checkpoint.safetensors",
    [string]$TexturePrompt = "",
    [string]$TextureNegativePrompt = "",
    [bool]$KeepProjectedBlend = $false,
    [ValidateRange(0.001, 1000000.0)][double]$TargetHeight = 1.0,
    [string]$ProjectProfile = "",
    [string]$Category = "",
    [System.Nullable[bool]]$AutoImport = $null,
    [string]$WorkflowPath = "workflows\test.json",
    [string]$ServerUrl = "http://127.0.0.1:8188",
    [ValidateRange(10, 3600)][int]$TimeoutSeconds = 300,
    [bool]$ReleaseComfyMemory = $true,
    [ValidateRange(0.0, 0.99)][double]$TrellisSimplify = 0.95,
    [ValidateSet(512, 1024, 2048)][int]$TrellisTextureSize = 1024,
    [ValidateSet("none", "qa")][string]$Postprocess = "none",
    [string]$BlenderPath = ""
)
$call = [ordered]@{ entryPoint = "generate-asset-from-prompt"; prompt = $Prompt; negativePrompt = $NegativePrompt; assetId = $AssetId; seed = $Seed; candidates = $Candidates; preset = $Preset; exclude = @($Exclude); geometryMethod = $GeometryMethod; multiview = $Multiview; multiviewCameras = $MultiviewCameras; textureResolution = $TextureResolution; textureCheckpoint = $TextureCheckpoint; texturePrompt = $TexturePrompt; textureNegativePrompt = $TextureNegativePrompt; keepProjectedBlend = $KeepProjectedBlend; targetHeight = $TargetHeight; projectProfile = $ProjectProfile; category = $Category; autoImport = $AutoImport; workflowPath = $WorkflowPath; serverUrl = $ServerUrl; timeoutSeconds = $TimeoutSeconds; releaseComfyMemory = $ReleaseComfyMemory; trellisSimplify = $TrellisSimplify; trellisTextureSize = $TrellisTextureSize; postprocess = $Postprocess; blenderPath = $BlenderPath }
$call | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $env:AF_BATCH_TEST_ROOT "calls.jsonl")
if ($env:AF_BATCH_TEST_FAIL_ID -eq $AssetId) { exit 1 }
$result = [ordered]@{ kind = "stub"; status = "completed"; assetId = $AssetId; generationRoot = (Join-Path $env:AF_BATCH_TEST_ROOT ("generated\" + $AssetId)) }
Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\generate-asset-from-prompt.ps1") -Encoding UTF8

    $env:AF_BATCH_TEST_ROOT = $Sandbox
    Reset-Calls

    foreach ($path in @("tools\run-batch.ps1", "tools\internal\AssetFactory.Batch.psm1", "tests\test-batch-contracts.ps1")) {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $path), [ref]$tokens, [ref]$parseErrors)
        Assert-Test (@($parseErrors).Count -eq 0) "PowerShell parses: $path"
    }

    $manifest = New-BaseManifest -BatchId "expand" -EntryPoint "generate-image"
    $manifest["defaults"] = [ordered]@{ candidates = 4; releaseComfyMemory = $false }
    $manifest.items = @([ordered]@{
        id = "rock"
        prompt = "rock prompt"
        outputs = [ordered]@{ count = 3; seedStart = 100; seedStep = 10 }
    })
    $path = Write-Manifest -RelativePath "batches\expand.json" -Value $manifest
    $result = Invoke-Batch -ManifestPath $path
    $calls = Read-Calls
    if ($result.Code -ne 0) {
        Write-Host "[DIAG] valid image batch output:" -ForegroundColor Yellow
        foreach ($line in @($result.Output)) { Write-Host ("[DIAG] " + $line) -ForegroundColor Yellow }
    }
    Assert-Test ($result.Code -eq 0) "valid image batch succeeds"
    Assert-Test ($calls.Count -eq 3) "outputs.count=3 creates exactly three public calls"
    Assert-Test (($calls.assetId -join ",") -eq "rock__01,rock__02,rock__03") "variant AssetIds are deterministic"
    Assert-Test (($calls.seed -join ",") -eq "100,110,120") "seedStart and seedStep expand deterministically"
    Assert-Test (@($calls | Where-Object { $_.candidates -eq 4 }).Count -eq 3) "candidates remains per-call and does not multiply output count"
    Assert-Test (@($calls | Where-Object { $_.releaseComfyMemory -eq $false }).Count -eq 3) "JSON false remains false"

    $runRoot = Get-ChildItem -LiteralPath (Join-Path $Sandbox "outputs\batches\expand") -Directory | Sort-Object Name -Descending | Select-Object -First 1
    foreach ($name in @("manifest.original.json", "manifest.resolved.json", "batch-run.json", "items.json", "results.json")) {
        Assert-Test (Test-Path -LiteralPath (Join-Path $runRoot.FullName $name) -PathType Leaf) "report contains $name"
    }

    Reset-Calls
    $seedManifest = New-BaseManifest -BatchId "seeds" -EntryPoint "generate-image"
    $seedManifest.items = @([ordered]@{ id = "seeded"; prompt = "x"; outputs = [ordered]@{ seeds = @(42, 128, 999) } })
    $seedPath = Write-Manifest -RelativePath "batches\seeds.json" -Value $seedManifest
    $result = Invoke-Batch -ManifestPath $seedPath
    $calls = Read-Calls
    Assert-Test ($result.Code -eq 0 -and ($calls.seed -join ",") -eq "42,128,999") "explicit seed lists are supported"

    Reset-Calls
    $baseSeedManifest = New-BaseManifest -BatchId "base-seed" -EntryPoint "generate-image"
    $baseSeedManifest["defaults"] = [ordered]@{ seed = 500 }
    $baseSeedManifest.items = @([ordered]@{ id = "base"; prompt = "x"; outputs = [ordered]@{ count = 3 } })
    $baseSeedPath = Write-Manifest -RelativePath "batches\base-seed.json" -Value $baseSeedManifest
    $result = Invoke-Batch -ManifestPath $baseSeedPath
    $calls = Read-Calls
    Assert-Test ($result.Code -eq 0 -and ($calls.seed -join ",") -eq "500,501,502") "multiple outputs increment the effective base seed by default"

    Reset-Calls
    $override = New-BaseManifest -BatchId "override" -EntryPoint "generate-asset-from-prompt"
    $override["defaults"] = [ordered]@{ geometryMethod = "trellis"; targetHeight = 1.0; candidates = 2 }
    $override.items = @([ordered]@{ id = "tree"; prompt = "tree"; params = [ordered]@{ targetHeight = 8.0 } })
    $overridePath = Write-Manifest -RelativePath "batches\override.json" -Value $override
    $result = Invoke-Batch -ManifestPath $overridePath
    $call = @(Read-Calls)[0]
    Assert-Test ($result.Code -eq 0 -and $call.geometryMethod -eq "trellis" -and [double]$call.targetHeight -eq 8.0) "item params override manifest defaults"
    Assert-Test ($call.assetId -eq "tree") "outputs.count=1 keeps the item id without a variant suffix"

    Reset-Calls
    $pathDir = Join-Path $Sandbox "batches\relative\inputs"
    New-Item -ItemType Directory -Path $pathDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pathDir "source.png") -Value "fake" -Encoding UTF8
    $imageManifest = New-BaseManifest -BatchId "imagepath" -EntryPoint "generate-asset-from-image"
    $imageManifest.items = @([ordered]@{ id = "source_asset"; inputPath = "inputs/source.png" })
    $imagePath = Write-Manifest -RelativePath "batches\relative\batch.json" -Value $imageManifest
    $result = Invoke-Batch -ManifestPath $imagePath
    $call = @(Read-Calls)[0]
    Assert-Test ($result.Code -eq 0 -and [System.IO.Path]::IsPathRooted([string]$call.inputPath)) "inputPath is resolved relative to the manifest directory"
    Assert-Test ([System.IO.Path]::GetFullPath([string]$call.inputPath) -eq [System.IO.Path]::GetFullPath((Join-Path $pathDir "source.png"))) "resolved inputPath points to the expected file"

    Reset-Calls
    $profilePath = Join-Path $Sandbox "profiles\stub.json"
    New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
    Set-Content -LiteralPath $profilePath -Value '{"autoImport":false}' -Encoding UTF8
    $mapping = New-BaseManifest -BatchId "mapping-prompt" -EntryPoint "generate-asset-from-prompt"
    $mapping["defaults"] = [ordered]@{
        negativePrompt = "environment"
        candidates = 2
        preset = "hero"
        exclude = @("text", "logo")
        geometryMethod = "trellis"
        multiview = $true
        multiviewCameras = 6
        textureResolution = 1024
        textureCheckpoint = "checkpoint.safetensors"
        texturePrompt = "painted metal"
        textureNegativePrompt = "rust"
        keepProjectedBlend = $true
        targetHeight = 2.5
        projectProfile = "../../profiles/stub.json"
        category = "Props"
        autoImport = $false
        workflowPath = "../../workflows/test.json"
        serverUrl = "http://127.0.0.1:8188"
        timeoutSeconds = 123
        releaseComfyMemory = $false
        trellisSimplify = 0.75
        trellisTextureSize = 512
        postprocess = "qa"
        blenderPath = "../../fake-blender.exe"
    }
    $mapping.items = @([ordered]@{ id = "mapped"; prompt = "mapped prompt"; outputs = [ordered]@{ count = 2; seedStart = 9000 } })
    $mappingPath = Write-Manifest -RelativePath "batches\mapping\batch.json" -Value $mapping
    $result = Invoke-Batch -ManifestPath $mappingPath
    $calls = Read-Calls
    Assert-Test ($result.Code -eq 0 -and $calls.Count -eq 2) "prompt mapping batch produces two final executions"
    Assert-Test (@($calls | Where-Object { $_.candidates -eq 2 }).Count -eq 2) "candidates stays internal to each final execution"
    Assert-Test (@($calls | Where-Object { $_.multiview -eq $true -and $_.multiviewCameras -eq 6 -and $_.textureResolution -eq 1024 }).Count -eq 2) "multiview parameters are mapped to prompt entry point"
    Assert-Test (@($calls | Where-Object { $_.keepProjectedBlend -eq $true -and $_.releaseComfyMemory -eq $false }).Count -eq 2) "boolean parameters preserve true and false values"
    Assert-Test (@($calls | Where-Object { $_.autoImport -eq $false -and $_.category -eq "Props" }).Count -eq 2) "nullable AutoImport=false and Unreal category are mapped"
    Assert-Test (@($calls | Where-Object { @($_.exclude).Count -eq 2 -and $_.exclude[0] -eq "text" -and $_.exclude[1] -eq "logo" }).Count -eq 2) "string array parameters are preserved"
    Assert-Test (@($calls | Where-Object { [System.IO.Path]::IsPathRooted([string]$_.workflowPath) -and [System.IO.Path]::IsPathRooted([string]$_.projectProfile) -and [System.IO.Path]::IsPathRooted([string]$_.blenderPath) }).Count -eq 2) "path parameters are resolved before invocation"

    $mappingRun = Get-ChildItem -LiteralPath (Join-Path $Sandbox "outputs\batches\mapping-prompt") -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $mappingResults = @(Get-Content -LiteralPath (Join-Path $mappingRun.FullName "results.json") -Raw | ConvertFrom-Json)
    Assert-Test (@($mappingResults | Where-Object { $_.status -eq "completed" -and -not [string]::IsNullOrWhiteSpace([string]$_.generationRoot) }).Count -eq 2) "RESULT_JSON generationRoot is captured in batch results"

    Reset-Calls
    $imageMapping = New-BaseManifest -BatchId "mapping-image" -EntryPoint "generate-asset-from-image"
    $imageMapping["defaults"] = [ordered]@{
        geometryMethod = "trellis"
        multiview = $true
        multiviewCameras = 4
        textureResolution = 512
        textureCheckpoint = "checkpoint.safetensors"
        texturePrompt = "industrial crate"
        textureNegativePrompt = "text"
        keepProjectedBlend = $true
        autoImport = $false
        postprocess = "none"
    }
    $imageMapping.items = @(
        [ordered]@{ id = "image_a"; inputPath = "../../inputs/source.png"; outputs = [ordered]@{ count = 2; seedStart = 9100 } },
        [ordered]@{ id = "image_b"; inputPath = "../../inputs/source.png"; outputs = [ordered]@{ count = 2; seedStart = 9200 } }
    )
    $imageMappingPath = Write-Manifest -RelativePath "batches\mapping-image\batch.json" -Value $imageMapping
    $result = Invoke-Batch -ManifestPath $imageMappingPath
    $calls = Read-Calls
    Assert-Test ($result.Code -eq 0 -and $calls.Count -eq 4) "asset-from-image mapping supports multiple items and outputs"
    Assert-Test (@($calls | Where-Object { $_.entryPoint -eq "generate-asset-from-image" -and $_.multiview -eq $true -and $_.texturePrompt -eq "industrial crate" }).Count -eq 4) "multiview parameters are mapped to image entry point"
    Assert-Test (($calls.assetId -join ",") -eq "image_a__01,image_a__02,image_b__01,image_b__02") "asset-from-image variants remain isolated and deterministic"

    Reset-Calls
    $validate = New-BaseManifest -BatchId "validate" -EntryPoint "generate-image"
    $validate.items = @([ordered]@{ id = "validate_only"; prompt = "x"; outputs = [ordered]@{ count = 2 } })
    $validatePath = Write-Manifest -RelativePath "batches\validate.json" -Value $validate
    $result = Invoke-Batch -ManifestPath $validatePath -ValidateOnly
    Assert-Test ($result.Code -eq 0) "ValidateOnly accepts a valid manifest"
    Assert-Test (@(Read-Calls).Count -eq 0) "ValidateOnly calls no public entry point"
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $Sandbox "outputs\batches\validate"))) "ValidateOnly creates no batch run directory"

    Reset-Calls
    $invalidJsonPath = Join-Path $Sandbox "batches\invalid-json.json"
    Set-Content -LiteralPath $invalidJsonPath -Value '{"kind":' -Encoding UTF8
    $invalidJsonResult = Invoke-Batch -ManifestPath $invalidJsonPath
    Assert-Test ($invalidJsonResult.Code -ne 0) "invalid JSON is rejected"
    Assert-Test (@(Read-Calls).Count -eq 0) "invalid JSON is rejected before any public entry point call"

    $bad = New-BaseManifest -BatchId "bad-kind" -EntryPoint "generate-image"
    $bad.kind = "legacy-batch"
    $bad.items = @([ordered]@{ id = "a"; prompt = "x" })
    Assert-RejectedWithoutCalls -Name "bad-kind" -Manifest $bad

    $bad = New-BaseManifest -BatchId "bad-version" -EntryPoint "generate-image"
    $bad.schemaVersion = 2
    $bad.items = @([ordered]@{ id = "a"; prompt = "x" })
    Assert-RejectedWithoutCalls -Name "bad-version" -Manifest $bad

    $bad = New-BaseManifest -BatchId "bad-entry" -EntryPoint "generate-image"
    $bad.entryPoint = "other"
    $bad.items = @([ordered]@{ id = "a"; prompt = "x" })
    Assert-RejectedWithoutCalls -Name "bad-entry" -Manifest $bad

    $bad = New-BaseManifest -BatchId "empty" -EntryPoint "generate-image"
    Assert-RejectedWithoutCalls -Name "empty-items" -Manifest $bad

    $bad = New-BaseManifest -BatchId "duplicate" -EntryPoint "generate-image"
    $bad.items = @([ordered]@{ id = "dup"; prompt = "a" }, [ordered]@{ id = "dup"; prompt = "b" })
    Assert-RejectedWithoutCalls -Name "duplicate-id" -Manifest $bad

    $bad = New-BaseManifest -BatchId "unknown" -EntryPoint "generate-image"
    $bad["defaults"] = [ordered]@{ geomtryMethod = "trellis" }
    $bad.items = @([ordered]@{ id = "a"; prompt = "x" })
    Assert-RejectedWithoutCalls -Name "unknown-param" -Manifest $bad

    $bad = New-BaseManifest -BatchId "wrong-param" -EntryPoint "generate-image"
    $bad["defaults"] = [ordered]@{ geometryMethod = "trellis" }
    $bad.items = @([ordered]@{ id = "a"; prompt = "x" })
    Assert-RejectedWithoutCalls -Name "wrong-entrypoint-param" -Manifest $bad

    $legacy = [ordered]@{ batchId = "legacy"; assets = @([ordered]@{ id = "a"; prompt = "x" }) }
    Assert-RejectedWithoutCalls -Name "legacy-format" -Manifest $legacy

    Reset-Calls
    $continue = New-BaseManifest -BatchId "continue" -EntryPoint "generate-image"
    $continue.execution.continueOnError = $true
    $continue.items = @(
        [ordered]@{ id = "A"; prompt = "a" },
        [ordered]@{ id = "B"; prompt = "b" },
        [ordered]@{ id = "C"; prompt = "c" }
    )
    $continuePath = Write-Manifest -RelativePath "batches\continue.json" -Value $continue
    $env:AF_BATCH_TEST_FAIL_ID = "B"
    $result = Invoke-Batch -ManifestPath $continuePath
    Assert-Test ($result.Code -ne 0 -and @(Read-Calls).Count -eq 3) "continueOnError=true attempts executions after a failure"
    $continueRun = Get-ChildItem -LiteralPath (Join-Path $Sandbox "outputs\batches\continue") -Directory | Sort-Object Name -Descending | Select-Object -First 1
    $continueMeta = Get-Content -LiteralPath (Join-Path $continueRun.FullName "batch-run.json") -Raw | ConvertFrom-Json
    Assert-Test ($continueMeta.status -eq "completed-with-errors") "continueOnError=true reports completed-with-errors"

    Reset-Calls
    $resume = New-BaseManifest -BatchId "resume" -EntryPoint "generate-image"
    $resume.items = @(
        [ordered]@{ id = "A"; prompt = "a" },
        [ordered]@{ id = "B"; prompt = "b" },
        [ordered]@{ id = "C"; prompt = "c" }
    )
    $resumePath = Write-Manifest -RelativePath "batches\resume.json" -Value $resume
    $env:AF_BATCH_TEST_FAIL_ID = "B"
    $first = Invoke-Batch -ManifestPath $resumePath
    Assert-Test ($first.Code -ne 0 -and @(Read-Calls).Count -eq 2) "continueOnError=false stops after the first failure"
    $env:AF_BATCH_TEST_FAIL_ID = ""
    $second = Invoke-Batch -ManifestPath $resumePath -Resume
    $calls = Read-Calls
    if ($second.Code -ne 0) {
        Write-Host "[DIAG] Resume output:" -ForegroundColor Yellow
        foreach ($line in @($second.Output)) { Write-Host ("[DIAG] " + $line) -ForegroundColor Yellow }
        $resumeRoot = Get-ChildItem -LiteralPath (Join-Path $Sandbox "outputs\batches\resume") -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($null -ne $resumeRoot) {
            foreach ($name in @("batch-run.json", "results.json")) {
                $diagPath = Join-Path $resumeRoot.FullName $name
                if (Test-Path -LiteralPath $diagPath -PathType Leaf) {
                    Write-Host ("[DIAG] " + $name + ":") -ForegroundColor Yellow
                    foreach ($line in @(Get-Content -LiteralPath $diagPath)) { Write-Host ("[DIAG] " + $line) -ForegroundColor Yellow }
                }
            }
        }
    }
    Assert-Test ($second.Code -eq 0) "Resume completes an incomplete compatible run"
    Assert-Test (@($calls | Where-Object assetId -eq "A").Count -eq 1) "Resume does not rerun completed execution A"
    Assert-Test (@($calls | Where-Object assetId -eq "B").Count -eq 2) "Resume retries failed execution B"
    Assert-Test (@($calls | Where-Object assetId -eq "C").Count -eq 1) "Resume runs pending execution C"

    Reset-Calls
    $changed = New-BaseManifest -BatchId "changed" -EntryPoint "generate-image"
    $changed.items = @([ordered]@{ id = "A"; prompt = "a" }, [ordered]@{ id = "B"; prompt = "b" })
    $changedPath = Write-Manifest -RelativePath "batches\changed.json" -Value $changed
    $env:AF_BATCH_TEST_FAIL_ID = "A"
    $first = Invoke-Batch -ManifestPath $changedPath
    Assert-Test ($first.Code -ne 0) "fixture creates an incomplete run for manifest hash test"
    $changed.items[0].prompt = "modified"
    $null = Write-Manifest -RelativePath "batches\changed.json" -Value $changed
    $env:AF_BATCH_TEST_FAIL_ID = ""
    $before = @(Read-Calls).Count
    $second = Invoke-Batch -ManifestPath $changedPath -Resume
    Assert-Test ($second.Code -ne 0) "Resume rejects a changed manifest"
    Assert-Test (@(Read-Calls).Count -eq $before) "changed manifest is rejected before retrying any execution"

    Write-Host "[OK] $script:Checks Batch V1 PowerShell contract checks passed with public entry point stubs only."
}
finally {
    [System.Environment]::SetEnvironmentVariable("AF_BATCH_TEST_ROOT", $OldRoot, "Process")
    [System.Environment]::SetEnvironmentVariable("AF_BATCH_TEST_FAIL_ID", $OldFailId, "Process")
    if (Test-Path -LiteralPath $Sandbox) { Remove-Item -LiteralPath $Sandbox -Recurse -Force }
}
