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
        Get-Content -LiteralPath $path |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    }
}

function Reset-Calls {
    Set-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl") -Value "" -Encoding UTF8
    $env:AF_CYCLE_TEST_FAILURE = ""
    $env:AF_CYCLE_TEST_BUSY = ""
}

# Simulation des trois points d'accès ComfyUI utilisés pour libérer proprement la VRAM.
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
        Prompt = "test asset"
        AssetId = ("asset_" + ($Name -replace '[^A-Za-z0-9_]', '_'))
        TargetHeight = 1.5
        BlenderPath = (Join-Path $Sandbox "tools\fake-blender.ps1")
        ReleaseComfyMemory = $false
    }
    foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
    if ($parameters.ContainsKey("InputPath")) { $parameters.Remove("Prompt") }

    $global:LASTEXITCODE = 0
    $output = @(& (Join-Path $Sandbox "tools\run-image-to-3d.ps1") @parameters 6>&1 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    $jsonLine = @($output | Where-Object { $_.StartsWith("[RESULT_JSON] ") } | Select-Object -Last 1)
    $summary = $null
    $metadata = $null
    $path = $null
    if ($jsonLine.Count -gt 0) {
        $summary = $jsonLine[0].Substring("[RESULT_JSON] ".Length) | ConvertFrom-Json
        $path = [string]$summary.metadataPath
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $metadata = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        }
    }
    return [pscustomobject]@{ Code = $code; Metadata = $metadata; Summary = $summary; Path = $path; Output = $output }
}

try {
    # Vérifie d'abord que les scripts livrés sont syntaxiquement valides pour PowerShell.
    foreach ($path in @(
        "tools\pipeline-common.ps1", "tools\run-comfyui.ps1", "tools\run-triposr.ps1",
        "tools\run-image-to-3d.ps1", "tools\run-batch.ps1", "tools\run-trellis.ps1",
        "tools\import-unreal.ps1", "setup-asset-factory.ps1"
    )) {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $SourceRoot $path), [ref]$tokens, [ref]$parseErrors
        )
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
        engine = "unreal"
        autoImport = $true
        projectPath = (Join-Path $Sandbox "Stub.uproject")
        contentRoot = "/Game/AssetFactory"
        overwriteExistingVersion = $false
    }
    $ProfilePath = Join-Path $Sandbox "profiles\auto.json"
    $profile | ConvertTo-Json | Set-Content -LiteralPath $ProfilePath -Encoding UTF8
    $env:AF_CYCLE_TEST_ROOT = $Sandbox

    @'
param($Prompt, $NegativePrompt, $Seed, $WorkflowPath, $ServerUrl, $TimeoutSeconds, $AssetId, $GenerationRoot, $AssetVersion, $PipelineManaged)
'{"name":"comfyui"}' | Add-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl")
if ([string]::IsNullOrWhiteSpace($GenerationRoot)) {
    $assetRoot = Join-Path $env:AF_CYCLE_TEST_ROOT ("outputs\assets\" + $AssetId)
    New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
    $number = 1
    do {
        $AssetVersion = 'v{0:D3}' -f $number
        $GenerationRoot = Join-Path $assetRoot $AssetVersion
        $number++
    } while (Test-Path -LiteralPath $GenerationRoot)
}
$sourceDir = Join-Path $GenerationRoot "source"
$metadataDir = Join-Path $GenerationRoot "metadata"
New-Item -ItemType Directory -Path $sourceDir, $metadataDir -Force | Out-Null
$image = Join-Path $sourceDir ($AssetId + ".png")
Set-Content -LiteralPath $image -Value "mock PNG"
$meta = Join-Path $metadataDir "comfyui.json"
@{ status = "completed"; imagePath = $image } | ConvertTo-Json | Set-Content -LiteralPath $meta
Write-Host "[OK] Job: comfy-stub"
Write-Host "[OK] Generation: $GenerationRoot"
if ($AssetVersion) { Write-Host "[OK] Version: $AssetVersion" }
Write-Host "[OK] Image: $image"
Write-Host "[OK] Metadata: $meta"
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\run-comfyui.ps1") -Encoding UTF8

    @'
param($InputPath, $AssetId, $GenerationRoot, $AssetVersion, $Seed, $Simplify, $TextureSize, $AutoImport, $PipelineManaged)
@{ name = "trellis"; input = $InputPath; autoImport = $AutoImport; seed = $Seed } | ConvertTo-Json -Compress |
    Add-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl")
if ($env:AF_CYCLE_TEST_FAILURE -eq "trellis") { exit 7 }
$rawDir = Join-Path $GenerationRoot "raw"
New-Item -ItemType Directory -Path $rawDir -Force | Out-Null
$mesh = Join-Path $rawDir ($AssetId + ".glb")
Set-Content -LiteralPath $mesh -Value "mock GLB"
Write-Host "[OK] TRELLIS GLB generated: $mesh"
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\run-trellis.ps1") -Encoding UTF8

    @'
param($InputPath, $AssetId, $GenerationRoot, $AssetVersion)
'{"name":"triposr"}' | Add-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl")
$rawDir = Join-Path $GenerationRoot "raw"
New-Item -ItemType Directory -Path $rawDir -Force | Out-Null
$mesh = Join-Path $rawDir ($AssetId + ".obj")
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
param($ProfilePath, $SourcePath, $AssetId, $AssetVersion, $Category, $MetadataPath, $LogPath)
@{ name = "unreal"; source = $SourcePath; id = $AssetId; version = $AssetVersion } | ConvertTo-Json -Compress |
    Add-Content -LiteralPath (Join-Path $env:AF_CYCLE_TEST_ROOT "calls.jsonl")
if ($env:AF_CYCLE_TEST_FAILURE -eq "unreal") { exit 9 }
Write-Host "[OK] Unreal version: $AssetVersion"
Write-Host "[OK] Unreal destination: /Game/AssetFactory/$AssetId/$AssetVersion"
Write-Host "[OK] Unreal asset: /Game/AssetFactory/$AssetId/$AssetVersion/$AssetId.$AssetId"
exit 0
'@ | Set-Content -LiteralPath (Join-Path $Sandbox "tools\import-unreal.ps1") -Encoding UTF8

    Reset-Calls
    $r = Invoke-TestPipeline "default"
    Assert-Test ($r.Code -eq 0 -and $r.Metadata.engine -eq "triposr") "Le moteur par défaut reste TripoSR"
    Assert-Test ($r.Metadata.importSourcePath.EndsWith("asset_default.fbx")) "TripoSR produit un FBX final nommé d'après l'asset"
    Assert-Test ($r.Metadata.geometry.status -eq "completed") "L'étape géométrique est enregistrée"
    Assert-Test ($r.Summary.generationRoot -match 'outputs[\\/]assets[\\/]asset_default[\\/]v001$') "La génération utilise outputs/assets/<AssetId>/v001"

    Reset-Calls
    $r = Invoke-TestPipeline "trellis" @{ Engine = "trellis"; ProjectProfile = $ProfilePath; ReleaseComfyMemory = $true; Seed = [long]4000000000 }
    Assert-Test ($r.Code -eq 0) "Le cycle TRELLIS complet réussit avec les simulations"
    $calls = @(Read-Calls)
    Assert-Test (($calls.name -join ",") -eq "comfyui,free,trellis,blender,unreal") "Enchaînement séquentiel et import unique après Blender"
    $trellis = @($calls | Where-Object name -eq "trellis")[0]
    Assert-Test ($trellis.autoImport -eq $false) "Le pipeline désactive l'import direct de TRELLIS"
    Assert-Test ($trellis.seed -eq 4000000000) "La seed 64 bits est transmise à TRELLIS"
    Assert-Test ($r.Metadata.imagePath.EndsWith("asset_trellis.png")) "Le PNG porte le nom de l'asset"
    Assert-Test ($r.Metadata.importSourcePath.EndsWith("asset_trellis.glb")) "Le GLB normalisé conserve le nom de l'asset"
    $import = @($calls | Where-Object name -eq "unreal")[0]
    Assert-Test ($import.source -eq $r.Metadata.blender.glbPath) "Unreal reçoit le GLB normalisé"
    Assert-Test ($import.version -eq "v001") "La version de génération est transmise à Unreal"

    Reset-Calls
    $first = Invoke-TestPipeline "versions-a" @{ Engine = "trellis"; AssetId = "versioned_asset" }
    $second = Invoke-TestPipeline "versions-b" @{ Engine = "trellis"; AssetId = "versioned_asset" }
    Assert-Test ($first.Summary.assetVersion -eq "v001" -and $second.Summary.assetVersion -eq "v002") "Deux générations du même asset créent v001 puis v002"
    Assert-Test ($first.Summary.generationRoot -ne $second.Summary.generationRoot) "Aucune génération précédente n'est écrasée"

    Reset-Calls
    $r = Invoke-TestPipeline "no-import" @{ Engine = "trellis"; ProjectProfile = $ProfilePath; AutoImport = $false }
    Assert-Test ($r.Code -eq 0 -and @(Read-Calls | Where-Object name -eq "unreal").Count -eq 0) "AutoImport=false surcharge le profil"

    Reset-Calls
    $r = Invoke-TestPipeline "existing-image" @{ Engine = "trellis"; InputPath = (Join-Path $Sandbox "source.png") }
    Assert-Test ($r.Code -eq 0 -and @(Read-Calls | Where-Object name -eq "comfyui").Count -eq 0) "Une image existante saute ComfyUI"

    Reset-Calls
    $env:AF_CYCLE_TEST_FAILURE = "trellis"
    $r = Invoke-TestPipeline "engine-failure" @{ Engine = "trellis" }
    Assert-Test ($r.Code -ne 0 -and $r.Metadata.failedStage -eq "geometry") "L'échec du moteur remonte à l'étape geometry"
    Assert-Test (@(Read-Calls | Where-Object { $_.name -in @("triposr", "blender", "unreal") }).Count -eq 0) "Aucun fallback ni étape ultérieure après l'échec moteur"

    Reset-Calls
    $env:AF_CYCLE_TEST_FAILURE = "unreal"
    $r = Invoke-TestPipeline "import-failure" @{ Engine = "trellis"; ProjectProfile = $ProfilePath }
    Assert-Test ($r.Code -ne 0 -and $r.Metadata.failedStage -eq "unreal") "L'échec d'import possède sa propre étape"
    Assert-Test ((Test-Path -LiteralPath $r.Metadata.importSourcePath) -and $r.Metadata.blender.status -eq "completed") "Le modèle final est conservé après un échec d'import"

    Reset-Calls
    $env:AF_CYCLE_TEST_BUSY = "1"
    $r = Invoke-TestPipeline "busy" @{ Engine = "trellis"; ReleaseComfyMemory = $true }
    Assert-Test ($r.Code -ne 0 -and $r.Metadata.failedStage -eq "gpuHandoff") "Un ComfyUI occupé n'est pas interrompu"
    Assert-Test (@(Read-Calls | Where-Object { $_.name -in @("free", "trellis") }).Count -eq 0) "Un serveur occupé empêche le déchargement et le chevauchement GPU"

    Reset-Calls
    $batchPath = Join-Path $Sandbox "batches\images.json"
    @{ batchId = "images"; assets = @(@{ id = "crate_a"; prompt = "crate" }, @{ id = "crate_b"; prompt = "crate" }) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $batchPath -Encoding UTF8
    & (Join-Path $Sandbox "tools\run-batch.ps1") -BatchPath $batchPath 6>&1 2>&1 | Out-Null
    Assert-Test ($LASTEXITCODE -eq 0 -and ((@(Read-Calls).name -join ",") -eq "comfyui,comfyui")) "Un batch historique reste en mode images"

    Reset-Calls
    $batchPath = Join-Path $Sandbox "batches\mixed.json"
    @{ batchId = "mixed"; mode = "full"; engine = "trellis"; releaseComfyMemory = $false; assets = @(
        @{ id = "crate_c"; prompt = "crate" }, @{ id = "crate_d"; prompt = "crate"; engine = "triposr" }
    ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $batchPath -Encoding UTF8
    & (Join-Path $Sandbox "tools\run-batch.ps1") -BatchPath $batchPath -BlenderPath (Join-Path $Sandbox "tools\fake-blender.ps1") 6>&1 2>&1 | Out-Null
    Assert-Test ($LASTEXITCODE -eq 0) "Un batch multi-moteurs réussit avec les simulations"
    $engines = @(Read-Calls | Where-Object { $_.name -in @("trellis", "triposr") })
    Assert-Test (($engines.name -join ",") -eq "trellis,triposr") "Le moteur de l'asset surcharge celui du batch"

    Reset-Calls
    & (Join-Path $Sandbox "tools\run-batch.ps1") -BatchPath $batchPath -Engine trellis -BlenderPath (Join-Path $Sandbox "tools\fake-blender.ps1") 6>&1 2>&1 | Out-Null
    Assert-Test ($LASTEXITCODE -eq 0) "La surcharge du moteur en ligne de commande fonctionne"
    $engines = @(Read-Calls | Where-Object { $_.name -in @("trellis", "triposr") })
    Assert-Test (($engines.name -join ",") -eq "trellis,trellis") "La ligne de commande surcharge le manifeste et l'asset"

    Write-Host "[OK] $script:Checks vérifications PowerShell réussies. Tous les moteurs externes étaient simulés."
}
finally {
    foreach ($pair in @(
        @("AF_CYCLE_TEST_ROOT", $OldTestRoot),
        @("AF_CYCLE_TEST_FAILURE", $OldFailure),
        @("AF_CYCLE_TEST_BUSY", $OldBusy)
    )) {
        [System.Environment]::SetEnvironmentVariable($pair[0], $pair[1], "Process")
    }
    if (Test-Path -LiteralPath $Sandbox) {
        Remove-Item -LiteralPath $Sandbox -Recurse -Force
    }
}
