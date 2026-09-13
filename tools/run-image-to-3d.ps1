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

    # La sélection de référence est commune aux modes direct et multi-vues.
    [string]$MultiviewMethod = "",
    [string]$MultiviewProfile = "",
    [System.Nullable[int]]$MultiviewSteps = $null,
    [System.Nullable[double]]$MultiviewGuidanceScale = $null,
    [System.Nullable[bool]]$MultiviewKeepGrid = $null,
    [string]$MultiviewConditioningPrompt = "",
    [ValidateRange(1, 64)]
    [int]$ReferenceCandidates = 1,
    [string]$ReferencePreset = "",
    [string[]]$ReferenceExclude = @(),

    [string]$MultiviewGeometryMethod = "",
    [string]$MultiviewGeometryProfile = "",
    [string]$FusionMode = "",
    [System.Nullable[bool]]$IncludeReference = $null,
    [int[]]$ViewIndices = @(),
    [string]$ViewPolicy = "",
    [System.Nullable[int]]$MaxViews = $null,
    [System.Nullable[double]]$MinViewScore = $null,

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
    [string]$OutputDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")
Import-Module (Join-Path $PSScriptRoot "internal\AssetFactory.Pipeline.psm1") -Force

$ScriptBoundParameters = $PSBoundParameters

$Engine = $Engine.ToLowerInvariant()
$UseExistingImage = $PSCmdlet.ParameterSetName -eq "Image"
$GeometryRunner = Join-Path $PSScriptRoot "run-$Engine.ps1"
$MultiViewRunner = Join-Path $PSScriptRoot "run-multiview.ps1"
$MultiViewGeometryRunner = Join-Path $PSScriptRoot "run-multiview-to-3d.ps1"
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

function Invoke-AFMultiViewCycle {
    # Le mode multi-vues reste une orchestration : les deux runners spécialisés
    # conservent chacun la responsabilité de leur étape et restent appelables seuls.
    Assert-AFFile -Path $MultiViewRunner -Label "Runner multi-vues"
    Assert-AFFile -Path $MultiViewGeometryRunner -Label "Runner multi-vues-vers-3D"

    $resolvedSourceImage = $null
    if ($UseExistingImage) {
        $resolvedSourceImage = Resolve-AFPath -Path $InputPath -BasePath (Get-Location).Path
        Assert-AFFile -Path $resolvedSourceImage -Label "Input image"
        if ([System.IO.Path]::GetExtension($resolvedSourceImage).ToLowerInvariant() -notin @(".png", ".jpg", ".jpeg", ".webp")) {
            throw "InputPath doit être une image PNG, JPEG ou WebP."
        }
    }

    if ([string]::IsNullOrWhiteSpace($AssetId)) {
        $script:AssetId = if ($UseExistingImage) {
            [System.IO.Path]::GetFileNameWithoutExtension($resolvedSourceImage)
        } else {
            "Asset_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        }
    }
    Assert-AFFileStem -Name $AssetId
    if (-not [string]::IsNullOrWhiteSpace($AssetVersion)) { Assert-AFAssetVersion -Version $AssetVersion }

    $multiviewParameters = @{
        AssetId = $AssetId
        Seed = $Seed
        WorkflowPath = $WorkflowPath
        ServerUrl = $ServerUrl
        TimeoutSeconds = $TimeoutSeconds
        ReleaseComfyMemory = $ReleaseComfyMemory
    }
    if ($UseExistingImage) {
        $multiviewParameters.ReferenceImage = $resolvedSourceImage
    } else {
        $multiviewParameters.Prompt = $Prompt
        $multiviewParameters.NegativePrompt = $NegativePrompt
    }
    if (-not [string]::IsNullOrWhiteSpace($AssetVersion)) { $multiviewParameters.AssetVersion = $AssetVersion }
    if (-not [string]::IsNullOrWhiteSpace($MultiviewMethod)) { $multiviewParameters.Method = $MultiviewMethod }
    if (-not [string]::IsNullOrWhiteSpace($MultiviewProfile)) { $multiviewParameters.MethodProfile = $MultiviewProfile }
    if ($null -ne $MultiviewSteps) { $multiviewParameters.Steps = $MultiviewSteps }
    if ($null -ne $MultiviewGuidanceScale) { $multiviewParameters.GuidanceScale = $MultiviewGuidanceScale }
    if ($null -ne $MultiviewKeepGrid) { $multiviewParameters.KeepGrid = $MultiviewKeepGrid }
    if ($ScriptBoundParameters.ContainsKey("MultiviewConditioningPrompt")) { $multiviewParameters.ConditioningPrompt = $MultiviewConditioningPrompt }
    if ($ScriptBoundParameters.ContainsKey("ReferenceCandidates")) { $multiviewParameters.ReferenceCandidates = $ReferenceCandidates }
    if ($ScriptBoundParameters.ContainsKey("ReferencePreset")) { $multiviewParameters.ReferencePreset = $ReferencePreset }
    if ($ScriptBoundParameters.ContainsKey("ReferenceExclude")) { $multiviewParameters.ReferenceExclude = @($ReferenceExclude) }
    if (-not [string]::IsNullOrWhiteSpace($OutputDir)) { $multiviewParameters.OutputDir = $OutputDir }

    $diagnosticsRoot = Join-Path $AssetFactoryRoot "outputs\diagnostics\pipeline"
    New-Item -ItemType Directory -Path $diagnosticsRoot -Force | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $temporaryLog = Join-Path $diagnosticsRoot ("run-image-to-3d-{0}-{1}.log" -f $AssetId, $stamp)

    Write-AFInfo "Mode : multi-vues"
    Write-AFInfo "Asset : $AssetId"
    Write-AFInfo "Étape 1/2 : référence + vues multi-vues"
    $multiviewResult = Invoke-AFCommand -Executable $MultiViewRunner -Parameters $multiviewParameters -LogPath $temporaryLog
    Assert-StageSuccess $multiviewResult "Génération multi-vues"

    $multiviewSummaryJson = Get-AFOutputValue $multiviewResult.Output "[RESULT_JSON] "
    $multiviewSummary = $multiviewSummaryJson | ConvertFrom-Json
    $generationRoot = [string]$multiviewSummary.generationRoot
    if ([string]::IsNullOrWhiteSpace($generationRoot)) {
        throw "Le runner multi-vues n’a pas renvoyé de generationRoot."
    }
    $layout = Get-AFGenerationLayout -GenerationRoot $generationRoot
    $pipelineStageOneLog = Join-Path $layout.LogsDir "run-image-to-3d-multiview.log"
    try { Move-Item -LiteralPath $temporaryLog -Destination $pipelineStageOneLog -Force } catch { }

    $geometryParameters = @{
        GenerationRoot = $generationRoot
        TargetHeight = $TargetHeight
    }
    if ($ScriptBoundParameters.ContainsKey("FusionMode")) { $geometryParameters.FusionMode = $FusionMode }
    if ($ScriptBoundParameters.ContainsKey("ViewPolicy")) { $geometryParameters.ViewPolicy = $ViewPolicy }
    if ($null -ne $MaxViews) { $geometryParameters.MaxViews = $MaxViews }
    if ($null -ne $MinViewScore) { $geometryParameters.MinViewScore = $MinViewScore }
    if ($ScriptBoundParameters.ContainsKey("TrellisSimplify")) { $geometryParameters.Simplify = $TrellisSimplify }
    if ($ScriptBoundParameters.ContainsKey("TrellisTextureSize")) { $geometryParameters.TextureSize = $TrellisTextureSize }
    if (-not [string]::IsNullOrWhiteSpace($MultiviewGeometryMethod)) { $geometryParameters.Method = $MultiviewGeometryMethod }
    if (-not [string]::IsNullOrWhiteSpace($MultiviewGeometryProfile)) { $geometryParameters.MethodProfile = $MultiviewGeometryProfile }
    if ($null -ne $IncludeReference) { $geometryParameters.IncludeReference = $IncludeReference }
    if (@($ViewIndices).Count -gt 0) { $geometryParameters.ViewIndices = @($ViewIndices) }
    if ($ScriptBoundParameters.ContainsKey("Seed")) { $geometryParameters.Seed = $Seed }
    if (-not [string]::IsNullOrWhiteSpace($ProjectProfile)) { $geometryParameters.ProjectProfile = $ProjectProfile }
    if (-not [string]::IsNullOrWhiteSpace($Category)) { $geometryParameters.Category = $Category }
    if ($null -ne $AutoImport) { $geometryParameters.AutoImport = $AutoImport }
    if (-not [string]::IsNullOrWhiteSpace($BlenderPath)) { $geometryParameters.BlenderPath = $BlenderPath }

    Write-AFInfo "Étape 2/2 : TRELLIS multi-image + Blender + Unreal"
    $geometryLog = Join-Path $layout.LogsDir "run-image-to-3d-geometry.log"
    $geometryResult = Invoke-AFCommand -Executable $MultiViewGeometryRunner -Parameters $geometryParameters -LogPath $geometryLog
    Assert-StageSuccess $geometryResult "Reconstruction 3D multi-vues"

    $geometrySummaryJson = Get-AFOutputValue $geometryResult.Output "[RESULT_JSON] "
    $geometrySummary = $geometrySummaryJson | ConvertFrom-Json

    Write-AFOk "Pipeline multi-vues terminé"
    Write-AFOk "Asset : $AssetId"
    Write-AFOk "Version : $($multiviewSummary.assetVersion)"
    Write-AFOk "Génération : $generationRoot"
    Write-AFOk "Modèle final : $($geometrySummary.meshPath)"
    if ([string]$geometrySummary.unrealStatus -eq "completed") {
        Write-AFOk "Import Unreal : terminé"
    } elseif ([string]$geometrySummary.unrealStatus -eq "skipped") {
        Write-AFInfo "Import Unreal : désactivé"
    } elseif ([string]$geometrySummary.unrealStatus -eq "not-configured") {
        Write-AFInfo "Import Unreal : non configuré"
    }

    $result = [ordered]@{
        kind = "asset-factory-generation"
        status = "completed"
        mode = "multiview"
        generationId = $multiviewSummary.generationId
        assetId = $AssetId
        assetVersion = $multiviewSummary.assetVersion
        generationRoot = $generationRoot
        engine = "trellis"
        imagePath = $multiviewSummary.referencePath
        meshPath = $geometrySummary.meshPath
        metadataPath = $layout.GenerationMetadataPath
        unrealStatus = $geometrySummary.unrealStatus
        failedStage = $null
    }
    Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
    return 0
}

if ($Mode -eq "multiview") {
    try {
        if ($ScriptBoundParameters.ContainsKey("Engine") -and $Engine.ToLowerInvariant() -ne "trellis") {
            throw "Le mode multi-vues utilise TRELLIS. Supprimez -Engine ou utilisez -Engine trellis."
        }
        $Engine = "trellis"
        $multiViewExitCode = Invoke-AFMultiViewCycle
        exit $multiViewExitCode
    }
    catch {
        Write-AFFail $_.Exception.Message
        exit 1
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
        $geometryResult = Invoke-AFCommand -Executable $GeometryRunner `
            -LogPath $GeometryStage.logPath `
            -SuppressConsolePatterns @(
                '^\s*Remarque : inclusion du fichier :',
                '^\s*Note: including file:'
            ) `
            -Parameters @{
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
        $ProcessedMeshPath = Join-Path $Layout.FinalDir ($AssetId + ".glb")
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

    # 5. Import Unreal versionné. Une nouvelle génération ne remplace jamais la précédente par défaut.
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
        failedStage = $GenerationMetadata.failedStage
    }
    Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
}
exit $ExitCode
