# Orchestration partagee des points d'entree publics Asset Factory.
# Ce module ne modifie jamais le code des moteurs sous engines/.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ToolsRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$script:AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $script:ToolsRoot))
. (Join-Path $script:ToolsRoot "pipeline-common.ps1")

function Read-AFJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label = "JSON"
    )

    Assert-AFFile -Path $Path -Label $Label
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        throw "$Label invalide : $Path. $($_.Exception.Message)"
    }
}

function Join-AFPromptText {
    param([string[]]$Parts)

    $filtered = @(
        $Parts |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() }
    )
    return ($filtered -join ", ")
}

function Resolve-AFImageQualityPython {
    $candidates = @(
        (Join-Path $script:AssetFactoryRoot "engines\trellis\.venv-runtime\Scripts\python.exe"),
        (Join-Path $script:AssetFactoryRoot "engines\triposr\.venv\Scripts\python.exe"),
        (Join-Path $script:AssetFactoryRoot "engines\zero123plus\.venv\Scripts\python.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    foreach ($name in @("python.exe", "python")) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return $command.Path
        }
    }

    throw "Python introuvable pour scorer plusieurs images candidates. Installez un runtime Asset Factory ou Python avec Pillow."
}

function Get-AFReferencePreset {
    param([string]$Preset = "")

    $registryPath = Join-Path $script:AssetFactoryRoot "config\reference-presets.json"
    $registry = Read-AFJsonFile -Path $registryPath -Label "Registre des presets de reference"
    if ([int](Get-AFProperty $registry "schemaVersion" 0) -ne 1) {
        throw "Version du registre des presets de reference non prise en charge."
    }

    $resolvedName = $Preset
    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        $resolvedName = [string](Get-AFProperty $registry "defaultPreset" "")
    }

    if ([string]::IsNullOrWhiteSpace($resolvedName) -or $resolvedName -eq "none") {
        return [pscustomobject]@{
            Name = $null
            PositiveSuffix = ""
            NegativeSuffix = ""
        }
    }

    $presets = Get-AFProperty $registry "presets" $null
    $config = Get-AFProperty $presets $resolvedName $null
    if ($null -eq $config) {
        $available = @($presets.PSObject.Properties.Name) -join ", "
        throw "Preset de reference inconnu '$resolvedName'. Disponibles : $available"
    }

    return [pscustomobject]@{
        Name = $resolvedName
        PositiveSuffix = [string](Get-AFProperty $config "positiveSuffix" "")
        NegativeSuffix = [string](Get-AFProperty $config "negativeSuffix" "")
    }
}

function Invoke-AFImageStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$NegativePrompt = "",
        [Parameter(Mandatory = $true)][string]$AssetId,
        [Parameter(Mandatory = $true)][string]$GenerationRoot,
        [string]$AssetVersion = "",
        [ValidateRange(0, [long]::MaxValue)][long]$Seed = 0,
        [ValidateRange(1, 64)][int]$Candidates = 1,
        [string]$Preset = "",
        [string[]]$Exclude = @(),
        [ValidateSet("source", "reference")][string]$Purpose = "source",
        [string]$WorkflowPath = "workflows\comfyui-flux-schnell-base.json",
        [string]$ServerUrl = "http://127.0.0.1:8188",
        [ValidateRange(10, 3600)][int]$TimeoutSeconds = 300,
        [bool]$ReleaseComfyMemory = $false
    )

    Assert-AFFileStem -Name $AssetId
    if (-not [string]::IsNullOrWhiteSpace($AssetVersion)) {
        Assert-AFAssetVersion -Version $AssetVersion
    }
    if ($Candidates -gt 16) {
        Write-AFInfo "Candidates=$Candidates : cette etape lancera autant de generations ComfyUI."
    }

    $layout = Resolve-AFGenerationLayout `
        -Root $script:AssetFactoryRoot `
        -AssetId $AssetId `
        -GenerationRoot $GenerationRoot `
        -Version $AssetVersion

    $comfyRunner = Join-Path $script:ToolsRoot "run-comfyui.ps1"
    $qualityRunner = Join-Path $script:ToolsRoot "multiview_quality.py"
    Assert-AFFile -Path $comfyRunner -Label "Runner ComfyUI"
    Assert-AFFile -Path (Resolve-AFPath -Path $WorkflowPath -BasePath $script:AssetFactoryRoot) -Label "Workflow ComfyUI"

    $presetConfig = Get-AFReferencePreset -Preset $Preset
    $excludeText = if (@($Exclude).Count -gt 0) { (@($Exclude) -join ", ") } else { "" }
    $promptUsed = Join-AFPromptText @($Prompt, $presetConfig.PositiveSuffix)
    $negativePromptUsed = Join-AFPromptText @($NegativePrompt, $presetConfig.NegativeSuffix, $excludeText)

    if ($Purpose -eq "reference") {
        $selectedDir = Join-Path $layout.SourceDir "reference"
        $candidateDir = Join-Path $selectedDir "candidates"
        $selectedStem = $AssetId + "_reference"
        $candidateStemPrefix = $AssetId + "_reference_candidate_"
        $metadataName = "reference-quality.json"
        $metadataPrefixBase = "reference-comfyui"
    } else {
        $selectedDir = $layout.SourceDir
        $candidateDir = Join-Path $layout.SourceDir "candidates"
        $selectedStem = $AssetId
        $candidateStemPrefix = $AssetId + "_candidate_"
        $metadataName = "image-selection.json"
        $metadataPrefixBase = "image-comfyui"
    }

    New-Item -ItemType Directory -Path $selectedDir -Force | Out-Null
    if ($Candidates -gt 1) {
        New-Item -ItemType Directory -Path $candidateDir -Force | Out-Null
    }

    $generated = New-Object System.Collections.Generic.List[string]
    for ($index = 1; $index -le $Candidates; $index++) {
        $candidateSeed = $Seed + ($index - 1)
        $single = $Candidates -eq 1
        $outputStem = if ($single) { $selectedStem } else { $candidateStemPrefix + ("{0:D2}" -f $index) }
        $sourceSubfolder = if ($single) {
            if ($Purpose -eq "reference") { "reference" } else { "" }
        } else {
            if ($Purpose -eq "reference") { "reference\candidates" } else { "candidates" }
        }
        $logPath = Join-Path $layout.LogsDir ("{0}-{1:D2}.log" -f $metadataPrefixBase, $index)
        $parameters = @{
            Prompt = $promptUsed
            NegativePrompt = $negativePromptUsed
            Seed = $candidateSeed
            WorkflowPath = $WorkflowPath
            ServerUrl = $ServerUrl
            TimeoutSeconds = $TimeoutSeconds
            AssetId = $AssetId
            GenerationRoot = $layout.Root
            AssetVersion = $layout.Version
            OutputFileStem = $outputStem
            SourceSubfolder = $sourceSubfolder
            MetadataPrefix = ("{0}-{1:D2}" -f $metadataPrefixBase, $index)
            PipelineManaged = $true
        }

        $result = Invoke-AFCommand -Executable $comfyRunner -Parameters $parameters -LogPath $logPath
        if ($result.ExitCode -ne 0) {
            throw "La generation de l'image candidate $index/$Candidates a echoue. Log : $logPath"
        }

        $searchRoot = if ($single) { $selectedDir } else { $candidateDir }
        $candidatePath = Get-ChildItem -LiteralPath $searchRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -eq $outputStem } |
            Select-Object -First 1 -ExpandProperty FullName
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            throw "ComfyUI n'a pas produit l'image attendue '$outputStem' dans $searchRoot."
        }
        $generated.Add($candidatePath)
    }

    $qualityPath = Join-Path $layout.MetadataDir $metadataName
    $selectedPath = $null
    $quality = $null

    if ($Candidates -eq 1) {
        $selectedPath = $generated[0]
        $quality = [ordered]@{
            schemaVersion = 1
            candidateCount = 1
            selectedReferencePath = $selectedPath
            selectedScore = $null
            selectionMethod = "single"
            candidates = @([ordered]@{
                path = $selectedPath
                score = $null
                warnings = @()
            })
        }
        Save-AFJson -Value $quality -Path $qualityPath
    } else {
        Assert-AFFile -Path $qualityRunner -Label "Scoring des images candidates"
        $qualityPython = Resolve-AFImageQualityPython
        $arguments = @("-B", $qualityRunner, "score-references", "--output", $qualityPath)
        foreach ($candidatePath in $generated) {
            $arguments += @("--image", $candidatePath)
        }
        $qualityLog = Join-Path $layout.LogsDir ($metadataPrefixBase + "-quality.log")
        $qualityResult = Invoke-AFCommand -Executable $qualityPython -Arguments $arguments -LogPath $qualityLog
        if ($qualityResult.ExitCode -ne 0) {
            throw "Le scoring des images candidates a echoue. Log : $qualityLog"
        }
        $quality = Read-AFJsonFile -Path $qualityPath -Label "Rapport de selection d'image"
        $selectedPath = [string](Get-AFProperty $quality "selectedReferencePath" "")
        if ([string]::IsNullOrWhiteSpace($selectedPath)) {
            throw "Le scoring n'a selectionne aucune image."
        }

        $extension = [System.IO.Path]::GetExtension($selectedPath).ToLowerInvariant()
        $finalPath = Join-Path $selectedDir ($selectedStem + $extension)
        if ([System.IO.Path]::GetFullPath($selectedPath) -ne [System.IO.Path]::GetFullPath($finalPath)) {
            Copy-Item -LiteralPath $selectedPath -Destination $finalPath -Force
        }
        $selectedPath = $finalPath
    }

    Assert-AFFile -Path $selectedPath -Label "Image selectionnee"

    if ($ReleaseComfyMemory) {
        Write-AFInfo "Liberation de la VRAM ComfyUI..."
        $release = Request-AFComfyMemoryRelease -ServerUrl $ServerUrl -TimeoutSeconds 90
        Write-AFOk $release.message
    }

    return [pscustomobject]@{
        GenerationRoot = $layout.Root
        AssetVersion = $layout.Version
        ImagePath = $selectedPath
        CandidatePaths = @($generated)
        CandidateCount = $Candidates
        QualityPath = $qualityPath
        Quality = $quality
        PromptUsed = $promptUsed
        NegativePromptUsed = $negativePromptUsed
        Preset = $presetConfig.Name
        Exclude = @($Exclude)
        Seed = $Seed
    }
}


function Invoke-AFVisualQA {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ReferencePath,
        [Parameter(Mandatory = $true)][string]$MeshPath,
        [Parameter(Mandatory = $true)][string]$GenerationRoot,
        [Parameter(Mandatory = $true)][string]$BlenderExecutable,
        [ValidateSet("qa")][string]$Mode = "qa"
    )

    $layout = Get-AFGenerationLayout -GenerationRoot $GenerationRoot
    $qaRoot = Join-Path $layout.Root "qa"
    $qaReferenceDir = Join-Path $qaRoot "reference"
    $qaRendersDir = Join-Path $qaRoot "renders"
    $qaMapsDir = Join-Path $qaRoot "maps"
    foreach ($directory in @($qaRoot, $qaReferenceDir, $qaRendersDir, $qaMapsDir)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $configPath = Join-Path $script:AssetFactoryRoot "config\postprocess.json"
    $qaCore = Join-Path $script:ToolsRoot "internal\postprocess\qa_core.py"
    $blenderQa = Join-Path $script:ToolsRoot "internal\postprocess\blender_qa.py"
    Assert-AFFile -Path $ReferencePath -Label "Reference Visual QA"
    Assert-AFFile -Path $MeshPath -Label "Mesh Visual QA"
    Assert-AFFile -Path $BlenderExecutable -Label "Blender Visual QA"
    Assert-AFFile -Path $configPath -Label "Configuration Visual QA"
    Assert-AFFile -Path $qaCore -Label "Analyse Visual QA"
    Assert-AFFile -Path $blenderQa -Label "Rendu Blender Visual QA"

    $config = Read-AFJsonFile -Path $configPath -Label "Configuration Visual QA"
    if ([int](Get-AFProperty $config "schemaVersion" 0) -ne 1) {
        throw "Version de configuration Visual QA non prise en charge."
    }

    $python = Resolve-AFImageQualityPython
    $referenceLog = Join-Path $layout.LogsDir "visual-qa-reference.log"
    $prepareResult = Invoke-AFCommand -Executable $python -LogPath $referenceLog -Arguments @(
        "-B", $qaCore, "prepare-reference",
        "--reference", $ReferencePath,
        "--output-dir", $qaReferenceDir,
        "--config", $configPath
    )
    if ($prepareResult.ExitCode -ne 0) {
        throw "La preparation de la reference Visual QA a echoue. Log : $referenceLog"
    }

    $referenceMask = Join-Path $qaReferenceDir "reference-mask.png"
    $referenceSearchMask = Join-Path $qaReferenceDir "reference-mask-search.png"
    Assert-AFFile -Path $referenceMask -Label "Masque Visual QA"
    Assert-AFFile -Path $referenceSearchMask -Label "Masque de recherche camera Visual QA"

    $cameraPath = Join-Path $qaRoot "camera.json"
    $blenderLog = Join-Path $layout.LogsDir "visual-qa-blender.log"
    $blenderResult = Invoke-AFCommand -Executable $BlenderExecutable -LogPath $blenderLog -Arguments @(
        "--background", "--factory-startup", "--python-exit-code", "1",
        "--python", $blenderQa, "--",
        "--mesh", $MeshPath,
        "--reference-mask", $referenceSearchMask,
        "--output-dir", $qaRendersDir,
        "--camera-output", $cameraPath,
        "--config", $configPath
    )
    if ($blenderResult.ExitCode -ne 0) {
        throw "Le rendu Blender Visual QA a echoue. Log : $blenderLog"
    }
    Assert-AFFile -Path $cameraPath -Label "Camera Visual QA"

    $beautyPath = Join-Path $qaRendersDir "beauty.png"
    $silhouettePath = Join-Path $qaRendersDir "silhouette.png"
    $clayPath = Join-Path $qaRendersDir "clay.png"
    $albedoPath = Join-Path $qaRendersDir "albedo.png"
    foreach ($path in @($beautyPath, $silhouettePath, $clayPath, $albedoPath)) {
        Assert-AFFile -Path $path -Label "Passe Visual QA"
    }

    $reportPath = Join-Path $qaRoot "qa-report.json"
    $analysisLog = Join-Path $layout.LogsDir "visual-qa-analysis.log"
    $analysisResult = Invoke-AFCommand -Executable $python -LogPath $analysisLog -Arguments @(
        "-B", $qaCore, "analyze",
        "--reference", $ReferencePath,
        "--reference-mask", $referenceMask,
        "--beauty", $beautyPath,
        "--silhouette", $silhouettePath,
        "--clay", $clayPath,
        "--albedo", $albedoPath,
        "--camera", $cameraPath,
        "--output-dir", $qaMapsDir,
        "--report", $reportPath,
        "--config", $configPath
    )
    if ($analysisResult.ExitCode -ne 0) {
        throw "L'analyse Visual QA a echoue. Log : $analysisLog"
    }
    Assert-AFFile -Path $reportPath -Label "Rapport Visual QA"

    $report = Read-AFJsonFile -Path $reportPath -Label "Rapport Visual QA"
    $metrics = Get-AFProperty $report "metrics" $null
    return [pscustomobject]@{
        Mode = $Mode
        Status = [string](Get-AFProperty $report "status" "completed")
        Root = $qaRoot
        ReportPath = $reportPath
        AnomalyMapPath = Join-Path $qaMapsDir "anomaly-map.png"
        CameraPath = $cameraPath
        OverallScore = Get-AFProperty $metrics "overallScore" $null
        Warnings = @(Get-AFProperty $report "warnings" @())
    }
}

function Invoke-AFAssetPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Prompt", "Image")][string]$InputKind,
        [string]$Prompt = "",
        [string]$NegativePrompt = "",
        [string]$InputPath = "",
        [string]$AssetId = "",
        [ValidateRange(0, [long]::MaxValue)][long]$Seed = 0,
        [ValidateRange(1, 64)][int]$Candidates = 1,
        [string]$Preset = "",
        [string[]]$Exclude = @(),
        [ValidateSet("trellis", "triposr")][string]$GeometryMethod = "trellis",

        [bool]$Multiview = $false,
        [ValidateRange(1, 100)][int]$MultiviewCameras = 8,
        [ValidateRange(256, 8192)][int]$TextureResolution = 2048,
        [string]$TextureCheckpoint = "RealVisXL_V5.0_fp16.safetensors",
        [string]$TexturePrompt = "",
        [string]$TextureNegativePrompt = "",
        [bool]$KeepProjectedBlend = $false,

        [ValidateRange(0.001, 1000000.0)][double]$TargetHeight = 1.0,
        [string]$ProjectProfile = "",
        [string]$Category = "",
        [System.Nullable[bool]]$AutoImport = $null,
        [ValidateRange(0.0, 0.99)][double]$TrellisSimplify = 0.95,
        [ValidateSet(512, 1024, 2048)][int]$TrellisTextureSize = 1024,
        [string]$WorkflowPath = "workflows\comfyui-flux-schnell-base.json",
        [string]$ServerUrl = "http://127.0.0.1:8188",
        [ValidateRange(10, 3600)][int]$TimeoutSeconds = 300,
        [bool]$ReleaseComfyMemory = $true,
        [string]$BlenderPath = "",
        [ValidateSet("none", "qa")][string]$Postprocess = "none"
    )

    if ($Multiview -and $GeometryMethod -ne "trellis") {
        throw "Le mode multi-vues nécessite GeometryMethod=trellis."
    }
    if ($Multiview -and [string]::IsNullOrWhiteSpace($TexturePrompt)) {
        throw "TexturePrompt est requis lorsque le mode multi-vues est activé."
    }

    $runner = Join-Path $script:ToolsRoot "run-image-to-3d.ps1"
    Assert-AFFile -Path $runner -Label "Pipeline image-vers-3D interne"

    $parameters = @{
        Mode = $(if ($Multiview) { "multiview" } else { "single" })
        Engine = $GeometryMethod
        AssetId = $AssetId
        Seed = $Seed
        TargetHeight = $TargetHeight
        ProjectProfile = $ProjectProfile
        Category = $Category
        WorkflowPath = $WorkflowPath
        ServerUrl = $ServerUrl
        TimeoutSeconds = $TimeoutSeconds
        ReleaseComfyMemory = $ReleaseComfyMemory
        TrellisSimplify = $TrellisSimplify
        TrellisTextureSize = $TrellisTextureSize
        MultiviewCameras = $MultiviewCameras
        TextureResolution = $TextureResolution
        TextureCheckpoint = $TextureCheckpoint
        TexturePrompt = $TexturePrompt
        TextureNegativePrompt = $TextureNegativePrompt
        KeepProjectedBlend = $KeepProjectedBlend
        Postprocess = $Postprocess
    }
    if (-not [string]::IsNullOrWhiteSpace($BlenderPath)) { $parameters.BlenderPath = $BlenderPath }
    if ($null -ne $AutoImport) { $parameters.AutoImport = [bool]$AutoImport }

    if ($InputKind -eq "Prompt") {
        $parameters.Prompt = $Prompt
        $parameters.NegativePrompt = $NegativePrompt
        $parameters.ReferenceCandidates = $Candidates
        $parameters.ReferencePreset = $Preset
        $parameters.ReferenceExclude = @($Exclude)
    } else {
        $parameters.InputPath = $InputPath
    }

    $diagnosticsRoot = Join-Path $script:AssetFactoryRoot "outputs\diagnostics\pipeline"
    New-Item -ItemType Directory -Path $diagnosticsRoot -Force | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $logPath = Join-Path $diagnosticsRoot ("asset-pipeline-{0}-{1}.log" -f $AssetId, $stamp)

    $result = Invoke-AFCommand -Executable $runner -Parameters $parameters -LogPath $logPath
    if ($result.ExitCode -ne 0) {
        throw "Pipeline AssetFactory échoué avec le code $($result.ExitCode). Log : $($result.LogPath)"
    }

    $summaryJson = Get-AFOutputValue $result.Output "[RESULT_JSON] "
    return ($summaryJson | ConvertFrom-Json)
}

Export-ModuleMember -Function Invoke-AFImageStage, Invoke-AFAssetPipeline, Invoke-AFVisualQA
