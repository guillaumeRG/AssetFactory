[CmdletBinding(DefaultParameterSetName = "Prompt")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "Prompt")]
    [ValidateNotNullOrEmpty()]
    [string]$Prompt,

    [Parameter(Mandatory = $true, ParameterSetName = "Image")]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [string]$NegativePrompt = "",
    [ValidateRange(0, [long]::MaxValue)]
    [long]$Seed = 0,
    [ValidateRange(0.001, 1000000.0)]
    [double]$TargetHeight = 1.0,

    [ValidateSet("single", "multiview")]
    [string]$Mode = "single",

    [ValidateSet("triposr", "trellis")]
    [string]$Engine = "triposr",

    [string]$ProjectProfile = "",
    [string]$AssetId = "",
    [string]$AssetVersion = "",
    [string]$Category = "",
    [System.Nullable[bool]]$AutoImport = $null,

    [ValidateRange(1, 64)]
    [int]$ReferenceCandidates = 1,
    [string]$ReferencePreset = "",
    [string[]]$ReferenceExclude = @(),

    [ValidateRange(1, 100)]
    [int]$MultiviewCameras = 8,
    [ValidateRange(256, 8192)]
    [int]$TextureResolution = 2048,
    [string]$TextureCheckpoint = "RealVisXL_V5.0_fp16.safetensors",
    [string]$TexturePrompt = "",
    [string]$TextureNegativePrompt = "",
    [bool]$KeepProjectedBlend = $false,

    [string]$WorkflowPath = "workflows\comfyui-flux-schnell-base.json",
    [string]$ServerUrl = "http://127.0.0.1:8188",
    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 300,
    [bool]$ReleaseComfyMemory = $true,

    [ValidateRange(0.0, 0.99)]
    [double]$TrellisSimplify = 0.95,
    [ValidateSet(512, 1024, 2048)]
    [int]$TrellisTextureSize = 1024,

    [string]$BlenderPath = "",
    [ValidateSet("none", "qa")]
    [string]$Postprocess = "none",
    [string]$OutputDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")
Import-Module (Join-Path $PSScriptRoot "internal\AssetFactory.Pipeline.psm1") -Force

$ScriptBoundParameters = $PSBoundParameters

$Engine = $Engine.ToLowerInvariant()
if ($Mode -eq "multiview" -and $Engine -ne "trellis") { throw "Le mode multi-vues nécessite TRELLIS." }
$UseExistingImage = $PSCmdlet.ParameterSetName -eq "Image"
$GeometryRunner = Join-Path $PSScriptRoot "run-$Engine.ps1"
$BlenderScript = Join-Path $AssetFactoryRoot "blender\scripts\process-mesh.py"
$UnrealImportRunner = Join-Path $PSScriptRoot "import-unreal.ps1"

function Get-BlenderExecutable {
    if (-not [string]::IsNullOrWhiteSpace($BlenderPath)) {
        $resolved = Resolve-AFPath -Path $BlenderPath -BasePath $AssetFactoryRoot
        Assert-AFFile -Path $resolved -Label "Blender executable"
        return $resolved
    }
    foreach ($name in @("blender.exe", "blender")) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { return $command.Path }
    }
    $patterns = @()
    if ($env:ProgramFiles) {
        $patterns += (Join-Path $env:ProgramFiles "Blender Foundation\Blender*\blender.exe")
    }
    if ($env:LOCALAPPDATA) {
        $patterns += (Join-Path $env:LOCALAPPDATA "Programs\Blender Foundation\Blender*\blender.exe")
    }
    $candidates = @()
    foreach ($pattern in $patterns) { $candidates += Get-Item -Path $pattern -ErrorAction SilentlyContinue }
    $candidate = $candidates | Sort-Object {
        [System.Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName).FileVersion
    } -Descending | Select-Object -First 1
    if ($null -ne $candidate) { return $candidate.FullName }
    throw "Exécutable Blender introuvable. Utilisez -BlenderPath ou installez Blender."
}

function Assert-StageSuccess {
    param($Result, [string]$StageName)
    if ($Result.ExitCode -ne 0) {
        throw "$StageName a échoué avec le code $($Result.ExitCode). Log : $($Result.LogPath)"
    }
}


function Test-AFComfyServer {
    param([Parameter(Mandatory)][string]$BaseUrl)
    try {
        Invoke-RestMethod -Uri ($BaseUrl.TrimEnd("/") + "/queue") -Method Get -TimeoutSec 3 | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Wait-AFComfyServer {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [int]$TimeoutSeconds = 180
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-AFComfyServer -BaseUrl $BaseUrl) { return }
        Start-Sleep -Seconds 2
    }
    throw "ComfyUI n'est pas devenu disponible sur $BaseUrl."
}

function Invoke-AFIntegratedMultiview {
    param(
        [Parameter(Mandatory)][string]$MeshPath,
        [Parameter(Mandatory)][string]$PromptText,
        [string]$NegativePromptText = "",
        [Parameter(Mandatory)][string]$BlenderExecutable,
        [Parameter(Mandatory)]$Layout,
        [Parameter(Mandatory)][string]$AssetName
    )

    $vendorAddon = Join-Path $AssetFactoryRoot "vendor\StableGen\stablegen"
    $driver = Join-Path $PSScriptRoot "internal\multiview_texture_driver.py"
    $depsRoot = Join-Path $AssetFactoryRoot "cache\multiview\blender-python"
    $comfyRoot = Join-Path $AssetFactoryRoot "engines\comfyui"
    $comfyPython = Join-Path $comfyRoot ".venv\Scripts\python.exe"
    $comfyMain = Join-Path $comfyRoot "main.py"

    Assert-AFFile -Path $driver -Label "Driver Blender multi-vues"
    Assert-AFFile -Path $comfyPython -Label "Python ComfyUI"
    Assert-AFFile -Path $comfyMain -Label "ComfyUI main.py"
    if (-not (Test-Path -LiteralPath $vendorAddon -PathType Container)) {
        throw "Module Blender multi-vues absent : $vendorAddon. Lancez '.\setup-asset-factory.ps1 multiview install'."
    }
    if (-not (Test-Path -LiteralPath $depsRoot -PathType Container)) {
        throw "Dépendances Blender multi-vues absentes. Lancez '.\setup-asset-factory.ps1 multiview install'."
    }

    $uri = [Uri]$ServerUrl
    $baseUrl = "{0}://{1}:{2}" -f $uri.Scheme, $uri.Host, $uri.Port
    $serverAddress = "{0}:{1}" -f $uri.Host, $uri.Port
    $startedComfy = $false
    $comfyProcess = $null

    $runtimeRoot = Join-Path $Layout.Root "runtime\multiview"
    $runtimeScripts = Join-Path $runtimeRoot "scripts"
    $runtimeConfig = Join-Path $runtimeRoot "config"
    $runtimeAddonParent = Join-Path $runtimeScripts "addons"
    $runtimeAddon = Join-Path $runtimeAddonParent "stablegen"
    $legacyRuntimeAddon = Join-Path $runtimeAddonParent "assettexturing"
    New-Item -ItemType Directory -Path $runtimeAddonParent -Force | Out-Null
    if (Test-Path -LiteralPath $legacyRuntimeAddon) { Remove-Item -LiteralPath $legacyRuntimeAddon -Recurse -Force }
    if (Test-Path -LiteralPath $runtimeAddon) { Remove-Item -LiteralPath $runtimeAddon -Recurse -Force }
    Copy-Item -LiteralPath $vendorAddon -Destination $runtimeAddon -Recurse -Force

    $runRoot = Join-Path $Layout.Root "multiview"
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $resultPath = Join-Path $runRoot "multiview-result.json"
    $configPath = Join-Path $runRoot "launch-config.json"
    $finalBlend = Join-Path $Layout.FinalDir ($AssetName + ".blend")
    $finalGlb = Join-Path $Layout.FinalDir ($AssetName + ".glb")

    [ordered]@{
        mesh = $MeshPath
        asset_name = $AssetName
        run_root = $runRoot
        python_deps = $depsRoot
        server = $serverAddress
        checkpoint = $TextureCheckpoint
        prompt = $PromptText
        negative_prompt = $NegativePromptText
        seed = $Seed
        num_cameras = $MultiviewCameras
        texture_resolution = $TextureResolution
        mesh_regex = ".*"
        exclude_mesh_names = @()
        final_blend = $finalBlend
        final_glb = $finalGlb
        keep_projected_blend = $KeepProjectedBlend
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

    $oldUserScripts = $env:BLENDER_USER_SCRIPTS
    $oldUserConfig = $env:BLENDER_USER_CONFIG
    $oldPythonPath = $env:PYTHONPATH
    try {
        if (-not (Test-AFComfyServer -BaseUrl $baseUrl)) {
            if ($uri.Host -notin @("127.0.0.1", "localhost")) {
                throw "Le démarrage automatique de ComfyUI est limité à localhost."
            }
            $comfyOut = Join-Path $Layout.LogsDir "multiview-comfyui.stdout.log"
            $comfyErr = Join-Path $Layout.LogsDir "multiview-comfyui.stderr.log"
            Write-AFInfo "Démarrage de ComfyUI pour le texturage multi-vues..."
            $comfyProcess = Start-Process -FilePath $comfyPython `
                -ArgumentList @("`"$comfyMain`"", "--lowvram", "--listen", $uri.Host, "--port", $uri.Port) `
                -WorkingDirectory $comfyRoot `
                -RedirectStandardOutput $comfyOut `
                -RedirectStandardError $comfyErr `
                -PassThru
            $startedComfy = $true
            Wait-AFComfyServer -BaseUrl $baseUrl -TimeoutSeconds 180
        } else {
            Write-AFInfo "Réutilisation de ComfyUI : $baseUrl"
        }

        New-Item -ItemType Directory -Path $runtimeConfig -Force | Out-Null
        $env:BLENDER_USER_SCRIPTS = $runtimeScripts
        $env:BLENDER_USER_CONFIG = $runtimeConfig
        $env:PYTHONPATH = if ($oldPythonPath) {
            "$depsRoot$([IO.Path]::PathSeparator)$oldPythonPath"
        } else {
            $depsRoot
        }

        $blenderOut = Join-Path $Layout.LogsDir "multiview-blender.stdout.log"
        $blenderErr = Join-Path $Layout.LogsDir "multiview-blender.stderr.log"
        Write-AFInfo "Multi-vues Blender : $MultiviewCameras caméra(s), projection séquentielle puis bake final."

        $arguments = @(
            "--factory-startup",
            "--online-mode",
            "--python-use-system-env",
            "--python-exit-code", "1",
            "--python", "`"$driver`"",
            "--",
            "--config", "`"$configPath`""
        )
        $process = Start-Process -FilePath $BlenderExecutable `
            -ArgumentList $arguments `
            -RedirectStandardOutput $blenderOut `
            -RedirectStandardError $blenderErr `
            -PassThru `
            -Wait

        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "Le texturage multi-vues n'a pas produit son résultat. Logs : $blenderOut / $blenderErr"
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ($result.status -ne "success") {
            $failure = [string]$result.error
            if (-not [string]::IsNullOrWhiteSpace([string]$result.exception)) {
                $failure += " | exception: $($result.exception)"
            }
            throw "Le texturage multi-vues a échoué : $failure. Détails : $resultPath. Logs : $blenderOut / $blenderErr"
        }
        if ($process.ExitCode -ne 0) {
            throw "Blender a terminé avec le code $($process.ExitCode)."
        }
        return $result
    }
    finally {
        $env:BLENDER_USER_SCRIPTS = $oldUserScripts
        $env:BLENDER_USER_CONFIG = $oldUserConfig
        $env:PYTHONPATH = $oldPythonPath
        if ($startedComfy -and $ReleaseComfyMemory -and $null -ne $comfyProcess -and -not $comfyProcess.HasExited) {
            Stop-Process -Id $comfyProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

$GenerationMetadata = $null
$GenerationMetadataPath = $null
$PipelineLock = $null
$Layout = $null
$Stage = $null
$ExitCode = 1

try {
    Assert-AFFile -Path $GeometryRunner -Label "$Engine runner"
    Assert-AFFile -Path $BlenderScript -Label "Blender processing script"
    $BlenderExe = Get-BlenderExecutable

    $SourceImage = $null
    if ($UseExistingImage) {
        $SourceImage = Resolve-AFPath -Path $InputPath -BasePath (Get-Location).Path
        Assert-AFFile -Path $SourceImage -Label "Input image"
        if ([System.IO.Path]::GetExtension($SourceImage).ToLowerInvariant() -notin @(".png", ".jpg", ".jpeg", ".webp")) {
            throw "InputPath doit être une image PNG, JPEG ou WebP."
        }
    }

    if ([string]::IsNullOrWhiteSpace($AssetId)) {
        $AssetId = if ($UseExistingImage) {
            [System.IO.Path]::GetFileNameWithoutExtension($SourceImage)
        } else {
            "Asset_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        }
    }
    Assert-AFFileStem -Name $AssetId
    if (-not [string]::IsNullOrWhiteSpace($AssetVersion)) { Assert-AFAssetVersion -Version $AssetVersion }

    $UnrealConfig = Resolve-AFUnrealConfiguration `
        -Root $AssetFactoryRoot -ProjectProfile $ProjectProfile `
        -AutoImport $AutoImport -AssetId $AssetId -Category $Category

    # Un seul cycle GPU complet à la fois ; les runners directs restent indépendants.
    $OutputsRoot = Join-Path $AssetFactoryRoot "outputs"
    $LocksRoot = Join-Path $OutputsRoot ".locks"
    New-Item -ItemType Directory -Path $LocksRoot -Force | Out-Null
    try {
        $PipelineLock = [System.IO.File]::Open(
            (Join-Path $LocksRoot "image-to-3d.lock"),
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        throw "Un autre pipeline image-vers-3D utilise déjà le verrou du projet. Aucun traitement n’a été interrompu."
    }

    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $Layout = New-AFAssetGeneration -Root $AssetFactoryRoot -AssetId $AssetId -Version $AssetVersion
    } else {
        $resolvedCustomOutput = Resolve-AFPath -Path $OutputDir -BasePath $AssetFactoryRoot
        if (Test-Path -LiteralPath $resolvedCustomOutput -PathType Container) {
            $existingEntries = @(Get-ChildItem -LiteralPath $resolvedCustomOutput -Force -ErrorAction SilentlyContinue)
            if ($existingEntries.Count -gt 0) {
                throw "Le dossier de sortie personnalisé n’est pas vide ; refus d’écraser les artefacts existants : $resolvedCustomOutput"
            }
        }
        $Layout = Resolve-AFGenerationLayout `
            -Root $AssetFactoryRoot -AssetId $AssetId `
            -GenerationRoot $resolvedCustomOutput -Version $AssetVersion
    }

    $GenerationMetadataPath = $Layout.GenerationMetadataPath
    $GenerationId = if ([string]::IsNullOrWhiteSpace($Layout.Version)) {
        "$AssetId-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')"
    } else {
        "$AssetId-$($Layout.Version)"
    }

    $GeometryStage = [ordered]@{
        status = "pending"
        engine = $Engine
        jobId = $null
        meshPath = $null
        sourceFormat = $null
        metadataPath = $null
        logPath = $null
        error = $null
    }
    $GenerationMetadata = [ordered]@{
        schemaVersion = 3
        generationId = $GenerationId
        assetId = $AssetId
        assetVersion = $Layout.Version
        generationRoot = $Layout.Root
        engine = $Engine
        createdAt = (Get-Date).ToString("o")
        completedAt = $null
        status = "running"
        failedStage = $null
        error = $null
        prompt = $(if ($UseExistingImage) { $null } else { $Prompt })
        negativePrompt = $(if ($UseExistingImage) { $null } else { $NegativePrompt })
        seed = $Seed
        targetHeightMeters = $TargetHeight
        inputMode = $(if ($UseExistingImage) { "image" } else { "prompt" })
        imagePath = $null
        importSourcePath = $null
        importSourceFormat = $null
        trellisSettings = @{
            simplify = $TrellisSimplify
            textureSize = $TrellisTextureSize
        }
        comfyui = [ordered]@{
            status = "pending"
            jobId = $null
            imagePath = $null
            metadataPath = (Join-Path $Layout.MetadataDir "comfyui.json")
            logPath = (Join-Path $Layout.LogsDir "comfyui.log")
            candidateCount = $(if ($UseExistingImage) { 1 } else { $ReferenceCandidates })
            candidatePaths = @()
            selectionReportPath = $null
            promptUsed = $null
            negativePromptUsed = $null
            preset = $null
            error = $null
        }
        gpuHandoff = [ordered]@{
            status = "pending"
            serverUrl = $ServerUrl
            reservedBytes = $null
            error = $null
        }
        geometry = $GeometryStage
        blender = [ordered]@{
            status = "pending"
            inputMeshPath = $null
            processedMeshPath = $null
            fbxPath = $null
            glbPath = $null
            requestedHeightMeters = $TargetHeight
            finalHeightMeters = $null
            finalWidthMeters = $null
            finalDepthMeters = $null
            scaleFactor = $null
            baseZ = $null
            logPath = (Join-Path $Layout.LogsDir "blender.log")
            error = $null
        }
        multiview = [ordered]@{
            enabled = ($Mode -eq "multiview")
            status = $(if ($Mode -eq "multiview") { "pending" } else { "skipped" })
            cameraCount = $MultiviewCameras
            textureResolution = $TextureResolution
            checkpoint = $TextureCheckpoint
            finalBlendPath = $null
            finalGlbPath = $null
            projectedBlendPath = $null
            bakedDir = $null
            generatedImages = @()
            error = $null
        }
        postprocess = [ordered]@{
            mode = $Postprocess
            status = $(if ($Postprocess -eq "none") { "skipped" } else { "pending" })
            reportPath = $null
            anomalyMapPath = $null
            overallScore = $null
            warnings = @()
            error = $null
        }
        unreal = [ordered]@{
            configured = $UnrealConfig.enabled
            profilePath = $UnrealConfig.profilePath
            autoImport = $UnrealConfig.autoImport
            assetId = $AssetId
            requestedAssetVersion = $Layout.Version
            assetVersion = $null
            category = $Category
            status = "pending"
            sourcePath = $null
            metadataPath = (Join-Path $Layout.MetadataDir "unreal.json")
            # Le runner PowerShell et UnrealEditor-Cmd ne doivent jamais écrire dans le même fichier.
            # unreal.log contient la sortie native d'Unreal ; unreal-runner.log contient l'orchestration.
            logPath = (Join-Path $Layout.LogsDir "unreal.log")
            runnerLogPath = (Join-Path $Layout.LogsDir "unreal-runner.log")
            importedObjectPaths = @()
            error = $null
        }
    }
    Save-AFJson $GenerationMetadata $GenerationMetadataPath

    Write-AFInfo "Asset : $AssetId"
    if (-not [string]::IsNullOrWhiteSpace($Layout.Version)) { Write-AFInfo "Version : $($Layout.Version)" }
    Write-AFInfo "Moteur 3D : $($Engine.ToUpperInvariant())"
    Write-AFInfo "Hauteur cible : $TargetHeight m"
    if (-not $UseExistingImage) {
        Write-AFInfo "Prompt : $Prompt"
        if ([string]::IsNullOrWhiteSpace($NegativePrompt)) {
            Write-AFInfo "Prompt négatif : (vide)"
        } else {
            Write-AFInfo "Prompt négatif : $NegativePrompt"
        }
        Write-AFInfo "Graine : $Seed"
    }
    if ($UnrealConfig.autoImport) {
        Write-AFInfo "Import Unreal final : activé après la normalisation Blender"
    } else {
        Write-AFInfo "Import Unreal final : désactivé"
    }

    # 1. Produit ou copie l'image de référence dans source/.
    $Stage = "comfyui"
    if ($UseExistingImage) {
        $imageExtension = [System.IO.Path]::GetExtension($SourceImage).ToLowerInvariant()
        $ImagePath = Join-Path $Layout.SourceDir ($AssetId + $imageExtension)
        if (Test-Path -LiteralPath $ImagePath) {
            throw "Generation source image already exists; refusing to overwrite it: $ImagePath"
        }
        Copy-Item -LiteralPath $SourceImage -Destination $ImagePath
        Assert-AFFile -Path $ImagePath -Label "Stored input image"
        $GenerationMetadata.comfyui.status = "skipped-existing-image"
        $GenerationMetadata.comfyui.imagePath = $ImagePath
        $GenerationMetadata.comfyui.metadataPath = $null
        $GenerationMetadata.comfyui.logPath = $null
    } else {
        $GenerationMetadata.comfyui.status = "running"
        Save-AFJson $GenerationMetadata $GenerationMetadataPath

        # La generation et la selection best-of-N sont factorisees avec le mode multi-vues
        # et avec le point d'entree generate-image.ps1.
        $imageStage = Invoke-AFImageStage `
            -Prompt $Prompt `
            -NegativePrompt $NegativePrompt `
            -AssetId $AssetId `
            -GenerationRoot $Layout.Root `
            -AssetVersion $Layout.Version `
            -Seed $Seed `
            -Candidates $ReferenceCandidates `
            -Preset $ReferencePreset `
            -Exclude @($ReferenceExclude) `
            -Purpose source `
            -WorkflowPath $WorkflowPath `
            -ServerUrl $ServerUrl `
            -TimeoutSeconds $TimeoutSeconds `
            -ReleaseComfyMemory $false

        $ImagePath = [string]$imageStage.ImagePath
        Assert-AFFile -Path $ImagePath -Label "Image generee"
        $GenerationMetadata.comfyui.status = "completed"
        $GenerationMetadata.comfyui.imagePath = $ImagePath
        $GenerationMetadata.comfyui.metadataPath = $imageStage.QualityPath
        $GenerationMetadata.comfyui.logPath = $null
        $GenerationMetadata.comfyui.candidateCount = $ReferenceCandidates
        $GenerationMetadata.comfyui.candidatePaths = @($imageStage.CandidatePaths)
        $GenerationMetadata.comfyui.selectionReportPath = $imageStage.QualityPath
        $GenerationMetadata.comfyui.promptUsed = $imageStage.PromptUsed
        $GenerationMetadata.comfyui.negativePromptUsed = $imageStage.NegativePromptUsed
        $GenerationMetadata.comfyui.preset = $imageStage.Preset
    }
    $GenerationMetadata.imagePath = $ImagePath
    Save-AFJson $GenerationMetadata $GenerationMetadataPath

    # 2. Libère la VRAM ComfyUI avant le moteur 3D.
    $Stage = "gpuHandoff"
    if (-not $UseExistingImage -and $ReleaseComfyMemory) {
        $GenerationMetadata.gpuHandoff.status = "running"
        Save-AFJson $GenerationMetadata $GenerationMetadataPath
        Write-AFInfo "Libération des modèles ComfyUI avant $($Engine.ToUpperInvariant())..."
        $release = Request-AFComfyMemoryRelease -ServerUrl $ServerUrl
        $GenerationMetadata.gpuHandoff.reservedBytes = $release.reservedBytes
        $GenerationMetadata.gpuHandoff.status = "completed"
        Write-AFOk $release.message
    } else {
        $GenerationMetadata.gpuHandoff.status = "skipped"
    }
    Save-AFJson $GenerationMetadata $GenerationMetadataPath

    # 3. Génération brute dans raw/ avec un seul moteur sélectionné.
    $Stage = "geometry"
    $GeometryStage.status = "running"
    $GeometryStage.logPath = Join-Path $Layout.LogsDir "$Engine.log"
    $GeometryStage.metadataPath = Join-Path $Layout.MetadataDir "$Engine.json"
    Save-AFJson $GenerationMetadata $GenerationMetadataPath
    Write-AFInfo "Génération 3D avec $($Engine.ToUpperInvariant())..."

    if ($Engine -eq "trellis") {
        $trellisParameters = @{
            InputPath = $ImagePath
            AssetId = $AssetId
            GenerationRoot = $Layout.Root
            AssetVersion = $Layout.Version
            Seed = $Seed
            Simplify = $TrellisSimplify
            TextureSize = $TrellisTextureSize
            AutoImport = $false
            PipelineManaged = $true
        }
        if ($Mode -eq "multiview") {
            $trellisParameters.GeometryOnly = $true
            Write-AFInfo "TRELLIS : géométrie seule (aucune UV/texture/bake TRELLIS)."
        }

        $geometryResult = Invoke-AFCommand -Executable $GeometryRunner `
            -LogPath $GeometryStage.logPath `
            -SuppressConsolePatterns @(
                '^\s*Remarque : inclusion du fichier :',
                '^\s*Note: including file:'
            ) `
            -Parameters $trellisParameters
        Assert-StageSuccess $geometryResult "TRELLIS"
        $MeshPath = Join-Path $Layout.RawDir ($AssetId + ".glb")
        $GeometryStage.jobId = $GenerationId
        $GeometryStage.sourceFormat = "glb"
    } else {
        $geometryResult = Invoke-AFCommand -Executable $GeometryRunner -LogPath $GeometryStage.logPath -Parameters @{
            InputPath = $ImagePath
            AssetId = $AssetId
            GenerationRoot = $Layout.Root
            AssetVersion = $Layout.Version
        }
        Assert-StageSuccess $geometryResult "TripoSR"
        $MeshPath = Join-Path $Layout.RawDir ($AssetId + ".obj")
        $GeometryStage.jobId = Get-AFOutputValue $geometryResult.Output "[OK] Job: " -Optional
        $GeometryStage.sourceFormat = "obj"
    }
    Assert-AFFile -Path $MeshPath -Label "Generated 3D model"
    $GeometryStage.meshPath = $MeshPath
    $GeometryStage.status = "completed"
    Save-AFJson $GenerationMetadata $GenerationMetadataPath

    # 4. Normalisation Blender dans final/.
    $Stage = "blender"
    $GenerationMetadata.blender.status = "running"
    $GenerationMetadata.blender.inputMeshPath = $MeshPath
    Save-AFJson $GenerationMetadata $GenerationMetadataPath

    $heightArgument = $TargetHeight.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $blenderArguments = @(
        "--background", "--factory-startup", "--python-exit-code", "1",
        "--python", $BlenderScript, "--", "--input", $MeshPath,
        "--target-height", $heightArgument
    )
    if ($Engine -eq "trellis") {
        $ProcessedMeshPath = if ($Mode -eq "multiview") {
            Join-Path $Layout.FinalDir ($AssetId + ".geometry.glb")
        } else {
            Join-Path $Layout.FinalDir ($AssetId + ".glb")
        }
        $ImportSourcePath = $ProcessedMeshPath
        $blenderArguments += @("--output", $ProcessedMeshPath)
        $GenerationMetadata.blender.glbPath = $ProcessedMeshPath
        $GenerationMetadata.importSourceFormat = "glb"
    } else {
        $ProcessedMeshPath = Join-Path $Layout.FinalDir ($AssetId + ".obj")
        $ImportSourcePath = Join-Path $Layout.FinalDir ($AssetId + ".fbx")
        $blenderArguments += @("--output", $ProcessedMeshPath, "--fbx-output", $ImportSourcePath)
        $GenerationMetadata.blender.fbxPath = $ImportSourcePath
        $GenerationMetadata.importSourceFormat = "fbx"
    }

    Write-AFInfo "Normalisation du modèle avec Blender..."

    $blenderResult = Invoke-AFCommand -Executable $BlenderExe `
        -Arguments $blenderArguments -LogPath $GenerationMetadata.blender.logPath
    Assert-StageSuccess $blenderResult "Blender"
    Assert-AFFile -Path $ProcessedMeshPath -Label "Normalized model"
    Assert-AFFile -Path $ImportSourcePath -Label "Unreal import source"
    $normalizationJson = Get-AFOutputValue $blenderResult.Output "[RESULT_JSON] "
    $normalization = $normalizationJson | ConvertFrom-Json
    $GenerationMetadata.blender.processedMeshPath = $ProcessedMeshPath
    $GenerationMetadata.blender.finalHeightMeters = [double]$normalization.final_height_m
    $GenerationMetadata.blender.finalWidthMeters = [double]$normalization.final_width_m
    $GenerationMetadata.blender.finalDepthMeters = [double]$normalization.final_depth_m
    $GenerationMetadata.blender.scaleFactor = [double]$normalization.scale_factor
    $GenerationMetadata.blender.baseZ = [double]$normalization.base_z
    $GenerationMetadata.blender.status = "completed"
    $GenerationMetadata.importSourcePath = $ImportSourcePath
    Save-AFJson $GenerationMetadata $GenerationMetadataPath

    if ($Mode -eq "multiview") {
        $Stage = "multiview"
        $GenerationMetadata.multiview.status = "running"
        Save-AFJson $GenerationMetadata $GenerationMetadataPath

        try {
            $textureText = $TexturePrompt
            if ([string]::IsNullOrWhiteSpace($textureText) -and -not $UseExistingImage) {
                $textureText = $Prompt
            }
            if ([string]::IsNullOrWhiteSpace($textureText)) {
                throw "TexturePrompt est requis pour le mode multi-vues."
            }

            $multiviewResult = Invoke-AFIntegratedMultiview `
                -MeshPath $ProcessedMeshPath `
                -PromptText $textureText `
                -NegativePromptText $TextureNegativePrompt `
                -BlenderExecutable $BlenderExe `
                -Layout $Layout `
                -AssetName $AssetId

            $previousGeometryPath = $ProcessedMeshPath
            $ProcessedMeshPath = [string]$multiviewResult.final_glb
            $ImportSourcePath = $ProcessedMeshPath

            Assert-AFFile -Path $ProcessedMeshPath -Label "Final textured GLB"
            Assert-AFFile -Path ([string]$multiviewResult.final_blend) -Label "Final Blender asset"

            $GenerationMetadata.multiview.status = "completed"
            $GenerationMetadata.multiview.finalBlendPath = [string]$multiviewResult.final_blend
            $GenerationMetadata.multiview.finalGlbPath = [string]$multiviewResult.final_glb
            $GenerationMetadata.multiview.projectedBlendPath = $multiviewResult.projected_blend
            $GenerationMetadata.multiview.bakedDir = [string]$multiviewResult.baked_dir
            $GenerationMetadata.multiview.generatedImages = @($multiviewResult.generated_images)
            $GenerationMetadata.blender.processedMeshPath = $ProcessedMeshPath
            $GenerationMetadata.blender.glbPath = $ProcessedMeshPath
            $GenerationMetadata.importSourcePath = $ProcessedMeshPath

            # The normalized geometry intermediate is only a handoff file.
            # raw/<AssetId>.glb remains the persistent geometry checkpoint.
            if ($previousGeometryPath -ne $ProcessedMeshPath -and
                (Test-Path -LiteralPath $previousGeometryPath -PathType Leaf)) {
                Remove-Item -LiteralPath $previousGeometryPath -Force -ErrorAction SilentlyContinue
            }

            Save-AFJson $GenerationMetadata $GenerationMetadataPath
            Write-AFOk "Texturage multi-vues Blender terminé : $ProcessedMeshPath"
        }
        catch {
            $GenerationMetadata.multiview.status = "failed"
            $GenerationMetadata.multiview.error = $_.Exception.Message
            Save-AFJson $GenerationMetadata $GenerationMetadataPath
            throw
        }
    }

    # 5. Controle qualite visuel optionnel. Une erreur QA ne detruit jamais l'asset valide.
    $Stage = "postprocess"
    if ($Postprocess -eq "qa") {
        $GenerationMetadata.postprocess.status = "running"
        Save-AFJson $GenerationMetadata $GenerationMetadataPath
        Write-AFInfo "Visual QA : comparaison de la reference et du modele final..."
        try {
            $qaResult = Invoke-AFVisualQA `
                -ReferencePath $ImagePath `
                -MeshPath $ProcessedMeshPath `
                -GenerationRoot $Layout.Root `
                -BlenderExecutable $BlenderExe `
                -Mode qa
            $GenerationMetadata.postprocess.status = $qaResult.Status
            $GenerationMetadata.postprocess.reportPath = $qaResult.ReportPath
            $GenerationMetadata.postprocess.anomalyMapPath = $qaResult.AnomalyMapPath
            $GenerationMetadata.postprocess.overallScore = $qaResult.OverallScore
            $GenerationMetadata.postprocess.warnings = @($qaResult.Warnings)
            Write-AFOk "Visual QA termine : $($qaResult.ReportPath)"
        }
        catch {
            $GenerationMetadata.postprocess.status = "failed"
            $GenerationMetadata.postprocess.error = $_.Exception.Message
            Write-AFFail "Visual QA non bloquant : $($_.Exception.Message)"
        }
        Save-AFJson $GenerationMetadata $GenerationMetadataPath
    }

    # 6. Import Unreal versionné. Une nouvelle génération ne remplace jamais la précédente par défaut.
    $Stage = "unreal"
    $GenerationMetadata.unreal.sourcePath = $ImportSourcePath
    if ($UnrealConfig.autoImport) {
        $GenerationMetadata.unreal.status = "running"
        Save-AFJson $GenerationMetadata $GenerationMetadataPath
        Write-AFInfo "Import du modèle final dans Unreal Engine..."
        $importResult = Invoke-AFCommand -Executable $UnrealImportRunner `
            -LogPath $GenerationMetadata.unreal.runnerLogPath -Parameters @{
                ProfilePath = $UnrealConfig.profilePath
                SourcePath = $ImportSourcePath
                AssetId = $AssetId
                AssetVersion = $Layout.Version
                Category = $Category
                MetadataPath = $GenerationMetadata.unreal.metadataPath
                LogPath = $GenerationMetadata.unreal.logPath
            }
        Assert-StageSuccess $importResult "Unreal import (generated model is preserved)"
        $importedPaths = @($importResult.Output | Where-Object { $_.StartsWith("[OK] Unreal asset: ") } | ForEach-Object {
            $_.Substring("[OK] Unreal asset: ".Length).Trim()
        })
        if ($importedPaths.Count -eq 0) {
            throw "Unreal importer returned success without an imported asset path."
        }
        $GenerationMetadata.unreal.assetVersion = Get-AFOutputValue $importResult.Output "[OK] Unreal version: " -Optional
        $GenerationMetadata.unreal.importedObjectPaths = $importedPaths
        $GenerationMetadata.unreal.status = "completed"
    } else {
        $GenerationMetadata.unreal.status = if ($UnrealConfig.enabled) { "skipped" } else { "not-configured" }
    }

    $GenerationMetadata.status = "completed"
    $ExitCode = 0
}
catch {
    $message = $_.Exception.Message
    Write-AFFail $message
    if ($null -ne $GenerationMetadata) {
        $GenerationMetadata.status = "failed"
        $GenerationMetadata.failedStage = $Stage
        $GenerationMetadata.error = $message
        if ($Stage -and $GenerationMetadata.Contains($Stage)) {
            $GenerationMetadata[$Stage].status = "failed"
            $GenerationMetadata[$Stage].error = $message
        }
    }
    $ExitCode = 1
}
finally {
    try {
        if ($null -ne $GenerationMetadata) {
            $GenerationMetadata.completedAt = (Get-Date).ToString("o")
            Save-AFJson $GenerationMetadata $GenerationMetadataPath
        }
    } finally {
        if ($null -ne $PipelineLock) { $PipelineLock.Dispose() }
    }
}

if ($null -ne $GenerationMetadata) {
    if ($ExitCode -eq 0) {
        Write-AFOk "Génération image-vers-3D terminée"
        Write-AFOk "Asset : $AssetId"
        if (-not [string]::IsNullOrWhiteSpace($Layout.Version)) { Write-AFOk "Version : $($Layout.Version)" }
        Write-AFOk "Moteur : $Engine"
        Write-AFOk "Génération : $($Layout.Root)"
        Write-AFOk "Image : $($GenerationMetadata.imagePath)"
        Write-AFOk "Modèle brut : $($GenerationMetadata.geometry.meshPath)"
        Write-AFOk "Modèle final : $($GenerationMetadata.importSourcePath)"
        if ($Mode -eq "multiview") {
            Write-AFOk "Blend final : $($GenerationMetadata.multiview.finalBlendPath)"
        }
        Write-AFOk "Dimensions finales : $($GenerationMetadata.blender.finalWidthMeters) x $($GenerationMetadata.blender.finalDepthMeters) x $($GenerationMetadata.blender.finalHeightMeters) m"
        if ($GenerationMetadata.unreal.status -eq "completed") {
            Write-AFOk "Version Unreal : $($GenerationMetadata.unreal.assetVersion)"
        }
        Write-AFOk "Métadonnées : $GenerationMetadataPath"
    } else {
        Write-AFFail "Métadonnées de génération : $GenerationMetadataPath"
        if ($GenerationMetadata.importSourcePath) {
            Write-AFInfo "L’import peut être relancé sans régénérer le modèle : $($GenerationMetadata.importSourcePath)"
        }
    }

    $result = [ordered]@{
        kind = "asset-factory-generation"
        status = $GenerationMetadata.status
        generationId = $GenerationMetadata.generationId
        assetId = $AssetId
        assetVersion = $Layout.Version
        generationRoot = $Layout.Root
        engine = $Engine
        imagePath = $GenerationMetadata.imagePath
        meshPath = $GenerationMetadata.importSourcePath
        metadataPath = $GenerationMetadataPath
        postprocessStatus = $GenerationMetadata.postprocess.status
        postprocessReportPath = $GenerationMetadata.postprocess.reportPath
        failedStage = $GenerationMetadata.failedStage
    }
    Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
}
exit $ExitCode


