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

    [ValidateSet("triposr", "trellis")]
    [string]$Engine = "triposr",

    [string]$ProjectProfile = "",
    [string]$AssetId = "",
    [string]$Category = "",
    [System.Nullable[bool]]$AutoImport = $null,

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

$ComfyRunner = Join-Path $PSScriptRoot "run-comfyui.ps1"
$GeometryRunner = Join-Path $PSScriptRoot "run-$($Engine.ToLowerInvariant()).ps1"
$BlenderScript = Join-Path $AssetFactoryRoot "blender\scripts\process-mesh.py"
$UnrealImportRunner = Join-Path $PSScriptRoot "import-unreal.ps1"
$Engine = $Engine.ToLowerInvariant()
$UseExistingImage = $PSCmdlet.ParameterSetName -eq "Image"

function Get-BlenderExecutable {
    if (-not [string]::IsNullOrWhiteSpace($BlenderPath)) {
        $resolved = Resolve-AFPath -Path $BlenderPath -BasePath $AssetFactoryRoot
        Assert-AFFile -Path $resolved -Label "Blender executable"
        return $resolved
    }
    foreach ($name in @("blender.exe", "blender")) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return $command.Path
        }
    }
    $patterns = @()
    if ($env:ProgramFiles) {
        $patterns += (Join-Path $env:ProgramFiles "Blender Foundation\Blender*\blender.exe")
    }
    if ($env:LOCALAPPDATA) {
        $patterns += (Join-Path $env:LOCALAPPDATA "Programs\Blender Foundation\Blender*\blender.exe")
    }
    $candidates = @()
    foreach ($pattern in $patterns) {
        $candidates += Get-Item -Path $pattern -ErrorAction SilentlyContinue
    }
    $candidate = $candidates | Sort-Object {
        [System.Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName).FileVersion
    } -Descending | Select-Object -First 1
    if ($null -ne $candidate) {
        return $candidate.FullName
    }
    throw "Blender executable not found. Use -BlenderPath or install Blender."
}

function Assert-StageSuccess {
    param($Result, [string]$StageName)
    if ($Result.ExitCode -ne 0) {
        throw "$StageName failed with exit code $($Result.ExitCode). Log: $($Result.LogPath)"
    }
}

$PipelineMetadata = $null
$PipelineMetadataPath = $null
$PipelineLock = $null
$Stage = $null
$ExitCode = 1

try {
    # Valide les prérequis avant de soumettre une image ou de démarrer un modèle GPU.
    Assert-AFFile -Path $GeometryRunner -Label "$Engine runner"
    Assert-AFFile -Path $BlenderScript -Label "Blender processing script"
    $BlenderExe = Get-BlenderExecutable
    $SourceImage = $null
    if ($UseExistingImage) {
        $SourceImage = Resolve-AFPath -Path $InputPath -BasePath (Get-Location).Path
        Assert-AFFile -Path $SourceImage -Label "Input image"
        if ([System.IO.Path]::GetExtension($SourceImage).ToLowerInvariant() -notin @(".png", ".jpg", ".jpeg", ".webp")) {
            throw "InputPath must be a PNG, JPEG or WebP image."
        }
    } else {
        Assert-AFFile -Path $ComfyRunner -Label "ComfyUI runner"
        Assert-AFFile -Path (Resolve-AFPath $WorkflowPath $AssetFactoryRoot) -Label "ComfyUI workflow"
    }

    $PipelineId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    if ([string]::IsNullOrWhiteSpace($AssetId)) {
        $AssetId = if ($UseExistingImage) {
            [System.IO.Path]::GetFileNameWithoutExtension($SourceImage)
        } else {
            "asset_$PipelineId"
        }
    }
    Assert-AFFileStem -Name $AssetId
    $UnrealConfig = Resolve-AFUnrealConfiguration `
        -Root $AssetFactoryRoot -ProjectProfile $ProjectProfile `
        -AutoImport $AutoImport -AssetId $AssetId -Category $Category

    # Un second pipeline complet ne doit pas démarrer simultanément une autre charge GPU.
    $OutputsRoot = Join-Path $AssetFactoryRoot "outputs"
    New-Item -ItemType Directory -Path $OutputsRoot -Force | Out-Null
    try {
        $PipelineLock = [System.IO.File]::Open(
            (Join-Path $OutputsRoot ".image-to-3d.lock"),
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        throw "Another image-to-3D pipeline holds the project lock. Nothing was interrupted."
    }

    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $PipelineRoot = Join-Path $OutputsRoot "pipelines\$PipelineId"
    } else {
        $PipelineRoot = Resolve-AFPath -Path $OutputDir -BasePath $AssetFactoryRoot
    }
    if (Test-Path -LiteralPath $PipelineRoot) {
        throw "Output directory already exists; refusing to reuse old artifacts: $PipelineRoot"
    }
    $PipelineProcessedDir = Join-Path $PipelineRoot "processed"
    $PipelineInputDir = Join-Path $PipelineRoot "input"
    $PipelineLogsDir = Join-Path $PipelineRoot "logs"
    foreach ($directory in @($PipelineProcessedDir, $PipelineInputDir, $PipelineLogsDir)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $PipelineMetadataPath = Join-Path $PipelineRoot "pipeline.json"
    $GeometryStage = [ordered]@{
        status = "pending"
        engine = $Engine
        jobId = $null
        meshPath = $null
        sourceFormat = $null
        logPath = $null
        error = $null
    }
    $PipelineMetadata = [ordered]@{
        schemaVersion = 2
        pipelineId = $PipelineId
        assetId = $AssetId
        engine = $Engine
        createdAt = (Get-Date).ToString("o")
        completedAt = $null
        status = "running"
        failedStage = $null
        error = $null
        prompt = $Prompt
        negativePrompt = $NegativePrompt
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
            sourceImagePath = $null
            metadataPath = $null
            logPath = $null
            error = $null
        }
        gpuHandoff = [ordered]@{
            status = "pending"
            serverUrl = $ServerUrl
            reservedBytes = $null
            error = $null
        }
        geometry = $GeometryStage
        triposr = $(if ($Engine -eq "triposr") { $GeometryStage } else { @{ status = "not-selected" } })
        trellis = $(if ($Engine -eq "trellis") { $GeometryStage } else { @{ status = "not-selected" } })
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
            logPath = $null
            error = $null
        }
        unreal = [ordered]@{
            configured = $UnrealConfig.enabled
            profilePath = $UnrealConfig.profilePath
            autoImport = $UnrealConfig.autoImport
            assetId = $AssetId
            category = $Category
            status = "pending"
            sourcePath = $null
            importedObjectPaths = @()
            metadataPath = $null
            logPath = $null
            error = $null
        }
    }
    Save-AFJson $PipelineMetadata $PipelineMetadataPath
    Write-AFInfo "Pipeline: $PipelineId / engine: $Engine / asset: $AssetId"
    Write-AFInfo "Metadata: $PipelineMetadataPath"

    # 1. Obtient une image puis la copie sous le nom stable de l'asset.
    $Stage = "comfyui"
    if (-not $UseExistingImage) {
        $PipelineMetadata.comfyui.status = "running"
        Save-AFJson $PipelineMetadata $PipelineMetadataPath
        $comfyLog = Join-Path $PipelineLogsDir "comfyui.log"
        $PipelineMetadata.comfyui.logPath = $comfyLog
        $comfyResult = Invoke-AFCommand -Executable $ComfyRunner -LogPath $comfyLog -Parameters @{
            Prompt = $Prompt
            NegativePrompt = $NegativePrompt
            Seed = $Seed
            WorkflowPath = $WorkflowPath
            ServerUrl = $ServerUrl
            TimeoutSeconds = $TimeoutSeconds
        }
        Assert-StageSuccess $comfyResult "ComfyUI"
        $SourceImage = Get-AFOutputValue $comfyResult.Output "[OK] Image: "
        $PipelineMetadata.comfyui.jobId = Get-AFOutputValue $comfyResult.Output "[OK] Job: "
        $PipelineMetadata.comfyui.metadataPath = Get-AFOutputValue $comfyResult.Output "[OK] Metadata: " -Optional
        Assert-AFFile -Path $SourceImage -Label "Generated image"
    }
    $imageExtension = [System.IO.Path]::GetExtension($SourceImage).ToLowerInvariant()
    $ImagePath = Join-Path $PipelineInputDir ($AssetId + $imageExtension)
    Copy-Item -LiteralPath $SourceImage -Destination $ImagePath
    Assert-AFFile -Path $ImagePath -Label "Named input image"
    $PipelineMetadata.imagePath = $ImagePath
    $PipelineMetadata.comfyui.imagePath = $ImagePath
    $PipelineMetadata.comfyui.sourceImagePath = $SourceImage
    $PipelineMetadata.comfyui.status = if ($UseExistingImage) { "skipped-existing-image" } else { "completed" }
    Save-AFJson $PipelineMetadata $PipelineMetadataPath
    Write-AFOk "Image: $ImagePath"

    # 2. Libère la mémoire des modèles ComfyUI avant le démarrage de l'un des moteurs 3D.
    $Stage = "gpuHandoff"
    if (-not $UseExistingImage -and $ReleaseComfyMemory) {
        $PipelineMetadata.gpuHandoff.status = "running"
        Save-AFJson $PipelineMetadata $PipelineMetadataPath
        Write-AFInfo "Requesting ComfyUI model unloading before $Engine..."
        $release = Request-AFComfyMemoryRelease -ServerUrl $ServerUrl
        $PipelineMetadata.gpuHandoff.reservedBytes = $release.reservedBytes
        $PipelineMetadata.gpuHandoff.status = "completed"
        Write-AFOk $release.message
    } else {
        $PipelineMetadata.gpuHandoff.status = "skipped"
    }
    Save-AFJson $PipelineMetadata $PipelineMetadataPath

    # 3. Génère avec un seul moteur sélectionné. Aucun basculement silencieux vers l'autre moteur.
    $Stage = "geometry"
    $GeometryStage.status = "running"
    $GeometryStage.logPath = Join-Path $PipelineLogsDir "$Engine.log"
    Save-AFJson $PipelineMetadata $PipelineMetadataPath
    Write-AFInfo "Generating 3D with $Engine..."
    if ($Engine -eq "trellis") {
        $rawOutputDir = Join-Path $PipelineRoot "generated\trellis"
        $geometryResult = Invoke-AFCommand -Executable $GeometryRunner -LogPath $GeometryStage.logPath -Parameters @{
            InputPath = $ImagePath
            OutputDir = $rawOutputDir
            Seed = $Seed
            Simplify = $TrellisSimplify
            TextureSize = $TrellisTextureSize
            AutoImport = $false
        }
        Assert-StageSuccess $geometryResult "TRELLIS"
        $MeshPath = Join-Path $rawOutputDir ($AssetId + ".glb")
        $GeometryStage.jobId = $PipelineId
        $GeometryStage.sourceFormat = "glb"
    } else {
        $geometryResult = Invoke-AFCommand -Executable $GeometryRunner -LogPath $GeometryStage.logPath -Parameters @{
            InputPath = $ImagePath
        }
        Assert-StageSuccess $geometryResult "TripoSR"
        $MeshPath = Get-AFOutputValue $geometryResult.Output "[OK] Mesh: "
        $GeometryStage.jobId = Get-AFOutputValue $geometryResult.Output "[OK] Job: "
        $GeometryStage.sourceFormat = "obj"
    }
    Assert-AFFile -Path $MeshPath -Label "Generated 3D model"
    $GeometryStage.meshPath = $MeshPath
    $GeometryStage.status = "completed"
    Save-AFJson $PipelineMetadata $PipelineMetadataPath

    # 4. Conserve le GLB texturé pour TRELLIS ; conserve OBJ + FBX pour TripoSR.
    $Stage = "blender"
    $PipelineMetadata.blender.status = "running"
    $PipelineMetadata.blender.inputMeshPath = $MeshPath
    $PipelineMetadata.blender.logPath = Join-Path $PipelineLogsDir "blender.log"
    Save-AFJson $PipelineMetadata $PipelineMetadataPath
    $heightArgument = $TargetHeight.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $blenderArguments = @(
        "--background", "--factory-startup", "--python-exit-code", "1",
        "--python", $BlenderScript, "--", "--input", $MeshPath,
        "--target-height", $heightArgument
    )
    if ($Engine -eq "trellis") {
        $ProcessedMeshPath = Join-Path $PipelineProcessedDir ($AssetId + ".glb")
        $ImportSourcePath = $ProcessedMeshPath
        $blenderArguments += @("--output", $ProcessedMeshPath)
        $PipelineMetadata.blender.glbPath = $ProcessedMeshPath
        $PipelineMetadata.importSourceFormat = "glb"
    } else {
        $ProcessedMeshPath = Join-Path $PipelineProcessedDir "mesh.obj"
        $ImportSourcePath = Join-Path $PipelineProcessedDir "mesh.fbx"
        $blenderArguments += @("--output", $ProcessedMeshPath, "--fbx-output", $ImportSourcePath)
        $PipelineMetadata.blender.fbxPath = $ImportSourcePath
        $PipelineMetadata.importSourceFormat = "fbx"
    }
    $blenderResult = Invoke-AFCommand -Executable $BlenderExe `
        -Arguments $blenderArguments -LogPath $PipelineMetadata.blender.logPath
    Assert-StageSuccess $blenderResult "Blender"
    Assert-AFFile -Path $ProcessedMeshPath -Label "Normalized model"
    Assert-AFFile -Path $ImportSourcePath -Label "Unreal import source"
    $normalizationJson = Get-AFOutputValue $blenderResult.Output "[RESULT_JSON] "
    $normalization = $normalizationJson | ConvertFrom-Json
    $PipelineMetadata.blender.processedMeshPath = $ProcessedMeshPath
    $PipelineMetadata.blender.finalHeightMeters = [double]$normalization.final_height_m
    $PipelineMetadata.blender.finalWidthMeters = [double]$normalization.final_width_m
    $PipelineMetadata.blender.finalDepthMeters = [double]$normalization.final_depth_m
    $PipelineMetadata.blender.scaleFactor = [double]$normalization.scale_factor
    $PipelineMetadata.blender.baseZ = [double]$normalization.base_z
    $PipelineMetadata.blender.status = "completed"
    $PipelineMetadata.importSourcePath = $ImportSourcePath
    Save-AFJson $PipelineMetadata $PipelineMetadataPath

    # 5. Importe une seule fois, après la normalisation et après l'arrêt du processus GPU.
    $Stage = "unreal"
    $PipelineMetadata.unreal.sourcePath = $ImportSourcePath
    if ($UnrealConfig.autoImport) {
        $PipelineMetadata.unreal.status = "running"
        $PipelineMetadata.unreal.logPath = Join-Path $PipelineLogsDir "unreal.log"
        Save-AFJson $PipelineMetadata $PipelineMetadataPath
        $importResult = Invoke-AFCommand -Executable $UnrealImportRunner `
            -LogPath $PipelineMetadata.unreal.logPath -Parameters @{
                ProfilePath = $UnrealConfig.profilePath
                SourcePath = $ImportSourcePath
                AssetId = $AssetId
                Category = $Category
            }
        $PipelineMetadata.unreal.metadataPath = Get-AFOutputValue $importResult.Output "[OK] Import metadata: " -Optional
        if (-not $PipelineMetadata.unreal.metadataPath) {
            $PipelineMetadata.unreal.metadataPath = Get-AFOutputValue $importResult.Output "[FAIL] Import metadata: " -Optional
        }
        Assert-StageSuccess $importResult "Unreal import (generated model is preserved)"
        $importedPaths = @($importResult.Output | Where-Object { $_.StartsWith("[OK] Unreal asset: ") } | ForEach-Object {
            $_.Substring("[OK] Unreal asset: ".Length).Trim()
        })
        if ($importedPaths.Count -eq 0) {
            throw "Unreal importer returned success without an imported asset path."
        }
        $PipelineMetadata.unreal.importedObjectPaths = $importedPaths
        $PipelineMetadata.unreal.status = "completed"
    } else {
        $PipelineMetadata.unreal.status = if ($UnrealConfig.enabled) { "skipped" } else { "not-configured" }
    }
    $PipelineMetadata.status = "completed"
    $ExitCode = 0
}
catch {
    $message = $_.Exception.Message
    Write-AFFail $message
    if ($null -ne $PipelineMetadata) {
        $PipelineMetadata.status = "failed"
        $PipelineMetadata.failedStage = $Stage
        $PipelineMetadata.error = $message
        if ($Stage -and $PipelineMetadata.Contains($Stage)) {
            $PipelineMetadata[$Stage].status = "failed"
            $PipelineMetadata[$Stage].error = $message
        }
    }
    $ExitCode = 1
}
finally {
    try {
        if ($null -ne $PipelineMetadata) {
            $PipelineMetadata.completedAt = (Get-Date).ToString("o")
            Save-AFJson $PipelineMetadata $PipelineMetadataPath
        }
    } finally {
        if ($null -ne $PipelineLock) {
            $PipelineLock.Dispose()
        }
    }
}

if ($null -ne $PipelineMetadata) {
    if ($ExitCode -eq 0) {
        Write-AFOk "Image-to-3D pipeline completed"
        Write-AFOk "Pipeline: $PipelineId"
        Write-AFOk "Engine: $Engine"
        if ($PipelineMetadata.comfyui.jobId) {
            Write-AFOk "ComfyUI job: $($PipelineMetadata.comfyui.jobId)"
        }
        Write-AFOk "Image: $($PipelineMetadata.imagePath)"
        Write-AFOk "Mesh: $($PipelineMetadata.geometry.meshPath)"
        if ($Engine -eq "trellis") {
            Write-AFOk "GLB: $($PipelineMetadata.blender.glbPath)"
        } else {
            Write-AFOk "TripoSR job: $($PipelineMetadata.geometry.jobId)"
            Write-AFOk "Processed OBJ: $($PipelineMetadata.blender.processedMeshPath)"
            Write-AFOk "FBX: $($PipelineMetadata.blender.fbxPath)"
        }
        Write-AFOk "Final size: $($PipelineMetadata.blender.finalWidthMeters) x $($PipelineMetadata.blender.finalDepthMeters) x $($PipelineMetadata.blender.finalHeightMeters) m"
        Write-AFOk "Metadata: $PipelineMetadataPath"
    } else {
        Write-AFFail "Pipeline metadata: $PipelineMetadataPath"
        if ($PipelineMetadata.importSourcePath) {
            Write-AFInfo "Import can be retried without regeneration: $($PipelineMetadata.importSourcePath)"
        }
    }
    $result = [ordered]@{
        kind = "asset-factory-pipeline"
        status = $PipelineMetadata.status
        pipelineId = $PipelineId
        engine = $Engine
        imagePath = $PipelineMetadata.imagePath
        meshPath = $PipelineMetadata.importSourcePath
        metadataPath = $PipelineMetadataPath
        failedStage = $PipelineMetadata.failedStage
    }
    Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
}
exit $ExitCode
