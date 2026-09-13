[CmdletBinding()]
param()

# Exécute l'orchestration réelle dans un projet temporaire isolé en remplaçant
# ComfyUI, les deux moteurs 3D, Blender et Unreal par de petites simulations PowerShell.
# Aucun calcul GPU, téléchargement, résultat existant ni projet Unreal n'est modifié.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$SourceRoot = Split-Path -Parent $PSScriptRoot
$Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("af-cycle-" + [guid]::NewGuid().ToString("N"))
$OldTestRoot = $env:AF_CYCLE_TEST_ROOT
$OldFailure = $env:AF_CYCLE_TEST_FAILURE
$OldBusy = $env:AF_CYCLE_TEST_BUSY
$script:Checks = 0

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:Checks++
    Write-Host "[PASS] $Message"
}

function Read-Calls {
    $path = Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl"
    if (Test-Path -LiteralPath $path) {
        Get-Content -LiteralPath $path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json }
    }
}

function Reset-Calls {
    Set-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl") -Value "" -Encoding UTF8
    $env:AF_CYCLE_TEST_FAILURE = ""
    $env:AF_CYCLE_TEST_BUSY = ""
}

function Invoke-RestMethod {
    param([string]$Uri, [string]$Method, [string]$ContentType, $Body, [int]$TimeoutSec)
    if ($Uri.EndsWith("/queue")) {
        $running = @()
        if ($env:AF_CYCLE_TEST_BUSY -eq "1") { $running = @(@("another-user-job")) }
        return [pscustomobject]@{ queue_running = $running; queue_pending = @() }
    }
    if ($Uri.EndsWith("/free")) {
        '{"name":"free"}' | Add-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl")
        return
    }
    if ($Uri.EndsWith("/system_stats")) {
        return [pscustomobject]@{ devices = @([pscustomobject]@{ type = "cuda"; torch_vram_total = 0 }) }
    }
    throw "Unexpected test HTTP request: $Uri"
}

function Invoke-TestPipeline {
    param([string]$Name, [hashtable]$Extra = @{})
    $parameters = @{
        Prompt = "test asset"; AssetId = "chair.v2"; TargetHeight = 1.5
        OutputDir = (Join-Path $Sandbox "case-$Name")
        BlenderPath = (Join-Path $Sandbox "tools\fake-blender.ps1")
        ReleaseComfyMemory = $false
    }
    foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
    if ($parameters.ContainsKey("InputPath")) { $parameters.Remove("Prompt") }
    $global:LASTEXITCODE = 0
    & (Join-Path $Sandbox "tools\run-image-to-3d.ps1") @parameters 6>&1 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $path = Join-Path $parameters.OutputDir "pipeline.json"
    $metadata = $null
    if (Test-Path -LiteralPath $path) { $metadata = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    return [pscustomobject]@{ Code = $code; Metadata = $metadata; Path = $path }
}

try {
    foreach ($path in @("tools\pipeline-common.ps1", "tools\run-image-to-3d.ps1", "tools\run-batch.ps1", "tools\run-trellis.ps1", "tools\import-unreal.ps1")) {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $path), [ref]$tokens, [ref]$parseErrors)
        Assert-Test (@($parseErrors).Count -eq 0) "PowerShell parses: $path $($parseErrors -join '; ')"
    }
    foreach ($directory in @("tools", "unreal", "blender\scripts", "workflows", "profiles", "batches")) {
        New-Item -ItemType Directory -Path (Join-Path $Sandbox $directory) -Force | Out-Null
    }
    foreach ($path in @("tools\pipeline-common.ps1", "tools\run-image-to-3d.ps1", "tools\run-batch.ps1")) {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $path) -Destination (Join-Path $Sandbox $path)
    }
    Set-Content -LiteralPath (Join-Path $Sandbox "unreal\import_asset.py") -Value "# fixture"
    Set-Content -LiteralPath (Join-Path $Sandbox "blender\scripts\process-mesh.py") -Value "# fixture"
    Set-Content -LiteralPath (Join-Path $Sandbox "workflows\comfyui-flux-schnell-base.json") -Value "{}"
    Set-Content -LiteralPath (Join-Path $Sandbox "Stub.uproject") -Value "{}"
    Set-Content -LiteralPath (Join-Path $Sandbox "source.png") -Value "mock PNG"
    $profile = @{
        engine = "unreal"; autoImport = $true; projectPath = (Join-Path $Sandbox "Stub.uproject")
        contentRoot = "/Game/Test"
    }
    $ProfilePath = Join-Path $Sandbox "profiles\auto.json"
    $profile | ConvertTo-Json | Set-Content -LiteralPath $ProfilePath -Encoding UTF8
    $env:AF_CYCLE_TEST_ROOT = $Sandbox

    @'
param($Prompt, $NegativePrompt, $Seed, $WorkflowPath, $ServerUrl, $TimeoutSeconds)
'{"name":"comfyui"}' | Add-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl")
Write-Host "[OK] Job: comfy-stub"
Write-Host "[OK] Image: $(Join-Path $env:AF_CYCLE_TEST_ROOT 'source.png')"
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\run-comfyui.ps1") -Encoding UTF8

    @'
param($InputPath, $OutputDir, $Seed, $Simplify, $TextureSize, $AutoImport)
@{ name = "trellis"; input = $InputPath; autoImport = $AutoImport; seed = $Seed } | ConvertTo-Json -Compress |
    Add-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl")
if ($env:AF_CYCLE_TEST_FAILURE -eq "trellis") { exit 7 }
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$mesh = Join-Path $OutputDir ([IO.Path]::GetFileNameWithoutExtension($InputPath) + ".glb")
Set-Content -LiteralPath $mesh -Value "mock GLB"
Write-Host "[OK] TRELLIS GLB generated: $mesh"
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\run-trellis.ps1") -Encoding UTF8

    @'
param($InputPath)
'{"name":"triposr"}' | Add-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl")
$mesh = Join-Path (Split-Path -Parent $InputPath) "mesh.obj"
Set-Content -LiteralPath $mesh -Value "mock OBJ"
Write-Host "[OK] Job: triposr-stub"
Write-Host "[OK] Mesh: $mesh"
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\run-triposr.ps1") -Encoding UTF8

    @'
# Les arguments non liés simulent volontairement une ligne de commande Blender native.
'{"name":"blender"}' | Add-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl")
if ($env:AF_CYCLE_TEST_FAILURE -eq "blender") { exit 8 }
$values = @{}
for ($i = 0; $i -lt $args.Count - 1; $i++) {
    if ($args[$i] -in @("--input", "--output", "--fbx-output", "--target-height")) {
        $values[$args[$i]] = $args[$i + 1]
    }
}
Set-Content -LiteralPath $values["--output"] -Value "normalized model"
if ($values.ContainsKey("--fbx-output")) { Set-Content -LiteralPath $values["--fbx-output"] -Value "normalized FBX" }
Write-Output ('[RESULT_JSON] ' + (@{ final_height_m = 1.5; final_width_m = 1; final_depth_m = 1; scale_factor = 1.5; base_z = 0 } | ConvertTo-Json -Compress))
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\fake-blender.ps1") -Encoding UTF8

    @'
param($ProfilePath, $SourcePath, $AssetId, $Category)
@{ name = "unreal"; source = $SourcePath; id = $AssetId } | ConvertTo-Json -Compress |
    Add-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl")
if ($env:AF_CYCLE_TEST_FAILURE -eq "unreal") { exit 9 }
Write-Host "[OK] Unreal asset: /Game/Test/$AssetId.$AssetId"
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\import-unreal.ps1") -Encoding UTF8

    Reset-Calls
    $r = Invoke-TestPipeline "default"
    Assert-Test ($r.Code -eq 0 -and $r.Metadata.engine -eq "triposr") "Old default is TripoSR"
    Assert-Test ($r.Metadata.blender.fbxPath.EndsWith("mesh.fbx")) "TripoSR still exports FBX"
    Assert-Test ($r.Metadata.triposr.status -eq "completed") "Legacy TripoSR metadata retained"

    Reset-Calls
    $r = Invoke-TestPipeline "trellis" @{ Engine = "trellis"; ProjectProfile = $ProfilePath; ReleaseComfyMemory = $true; Seed = [long]4000000000 }
    Assert-Test ($r.Code -eq 0) "TRELLIS full pipeline succeeds with fixtures"
    $calls = @(Read-Calls)
    Assert-Test (($calls.name -join ",") -eq "comfyui,free,trellis,blender,unreal") "Sequential handoff; one import after Blender"
    $trellis = @($calls | Where-Object name -eq "trellis")[0]
    Assert-Test ($trellis.autoImport -eq $false) "Pipeline suppresses TRELLIS direct auto-import"
    Assert-Test ($trellis.seed -eq 4000000000) "64-bit seed passed to TRELLIS"
    Assert-Test ($r.Metadata.imagePath.EndsWith("chair.v2.png")) "PNG receives the asset name"
    Assert-Test ($r.Metadata.importSourcePath.EndsWith("chair.v2.glb")) "Normalized GLB retains PNG stem"
    $import = @($calls | Where-Object name -eq "unreal")[0]
    Assert-Test ($import.source -eq $r.Metadata.blender.glbPath) "Unreal receives normalized GLB, not raw GLB"

    Reset-Calls
    $r = Invoke-TestPipeline "no-import" @{ Engine = "trellis"; ProjectProfile = $ProfilePath; AutoImport = $false }
    Assert-Test ($r.Code -eq 0 -and @(Read-Calls | Where-Object name -eq "unreal").Count -eq 0) "Explicit false overrides autoImport=true profile"

    Reset-Calls
    $r = Invoke-TestPipeline "existing-image" @{ Engine = "trellis"; InputPath = (Join-Path $Sandbox "source.png") }
    Assert-Test ($r.Code -eq 0 -and @(Read-Calls | Where-Object name -eq "comfyui").Count -eq 0) "Existing PNG skips ComfyUI"

    Reset-Calls
    $env:AF_CYCLE_TEST_FAILURE = "trellis"
    $r = Invoke-TestPipeline "engine-failure" @{ Engine = "trellis" }
    Assert-Test ($r.Code -ne 0 -and $r.Metadata.failedStage -eq "geometry") "Native/script failure propagates to pipeline"
    Assert-Test (@(Read-Calls | Where-Object { $_.name -in @("triposr", "blender", "unreal") }).Count -eq 0) "No fallback or later stages after engine failure"

    Reset-Calls
    $env:AF_CYCLE_TEST_FAILURE = "unreal"
    $r = Invoke-TestPipeline "import-failure" @{ Engine = "trellis"; ProjectProfile = $ProfilePath }
    Assert-Test ($r.Code -ne 0 -and $r.Metadata.failedStage -eq "unreal") "Import failure has its own stage"
    Assert-Test ((Test-Path -LiteralPath $r.Metadata.importSourcePath) -and $r.Metadata.blender.status -eq "completed") "Model preserved after import failure"

    Reset-Calls
    $env:AF_CYCLE_TEST_BUSY = "1"
    $r = Invoke-TestPipeline "busy" @{ Engine = "trellis"; ReleaseComfyMemory = $true }
    Assert-Test ($r.Code -ne 0 -and $r.Metadata.failedStage -eq "gpuHandoff") "Busy ComfyUI is not interrupted"
    Assert-Test (@(Read-Calls | Where-Object { $_.name -in @("free", "trellis") }).Count -eq 0) "Busy server prevents unloading and GPU overlap"

    Reset-Calls
    $batchPath = Join-Path $Sandbox "batches\legacy.json"
    @{ batchId = "legacy"; assets = @(@{ id = "crate_a"; prompt = "crate" }, @{ id = "crate_b"; prompt = "crate" }) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $batchPath -Encoding UTF8
    & (Join-Path $Sandbox "tools\run-batch.ps1") -BatchPath $batchPath 6>&1 2>&1 | Out-Null
    Assert-Test ($LASTEXITCODE -eq 0 -and ((@(Read-Calls).name -join ",") -eq "comfyui,comfyui")) "Unchanged batch remains images only"

    Reset-Calls
    $batchPath = Join-Path $Sandbox "batches\mixed.json"
    @{ batchId = "mixed"; mode = "full"; engine = "trellis"; releaseComfyMemory = $false; assets = @(
        @{ id = "crate_a"; prompt = "crate" }, @{ id = "crate_b"; prompt = "crate"; engine = "triposr" }
    ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $batchPath -Encoding UTF8
    & (Join-Path $Sandbox "tools\run-batch.ps1") -BatchPath $batchPath -BlenderPath (Join-Path $Sandbox "tools\fake-blender.ps1") 6>&1 2>&1 | Out-Null
    Assert-Test ($LASTEXITCODE -eq 0) "Mixed-engine batch succeeds with fixtures"
    $engines = @(Read-Calls | Where-Object { $_.name -in @("trellis", "triposr") })
    Assert-Test (($engines.name -join ",") -eq "trellis,triposr") "Asset engine overrides batch engine"

    Reset-Calls
    & (Join-Path $Sandbox "tools\run-batch.ps1") -BatchPath $batchPath -Engine trellis -BlenderPath (Join-Path $Sandbox "tools\fake-blender.ps1") 6>&1 2>&1 | Out-Null
    Assert-Test ($LASTEXITCODE -eq 0) "Batch CLI engine override succeeds"
    $engines = @(Read-Calls | Where-Object { $_.name -in @("trellis", "triposr") })
    Assert-Test (($engines.name -join ",") -eq "trellis,trellis") "CLI engine overrides both asset and manifest"

    Write-Host "[OK] $script:Checks PowerShell checks passed. All external engines were simulated."
}
finally {
    foreach ($pair in @(@("AF_CYCLE_TEST_ROOT", $OldTestRoot), @("AF_CYCLE_TEST_FAILURE", $OldFailure), @("AF_CYCLE_TEST_BUSY", $OldBusy))) {
        [System.Environment]::SetEnvironmentVariable($pair[0], $pair[1], "Process")
    }
    if (Test-Path -LiteralPath $Sandbox) {
        Remove-Item -LiteralPath $Sandbox -Recurse -Force
    }
}
