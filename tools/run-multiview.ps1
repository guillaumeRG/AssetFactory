[CmdletBinding()]
param(
    [string]$Prompt = "",
    [string]$NegativePrompt = "",
    [string]$ReferenceImage = "",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AssetId,

    [ValidateRange(0, [long]::MaxValue)]
    [long]$Seed = 0,
    [string]$AssetVersion = "",

    [string]$Method = "",
    [string]$MethodProfile = "",
    [System.Nullable[int]]$Steps = $null,
    [System.Nullable[double]]$GuidanceScale = $null,
    [System.Nullable[bool]]$KeepGrid = $null,
    [string]$ConditioningPrompt = "",
    [ValidateRange(1, 8)]
    [int]$ReferenceCandidates = 1,
    [string]$ReferencePreset = "",
    [string[]]$ReferenceExclude = @(),

    [string]$WorkflowPath = "workflows\comfyui-flux-schnell-base.json",
    [string]$ServerUrl = "http://127.0.0.1:8188",
    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 300,
    [bool]$ReleaseComfyMemory = $true,
    [string]$OutputDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")

$RegistryPath = Join-Path $AssetFactoryRoot "config\multiview-methods.json"
$ReferencePresetRegistryPath = Join-Path $AssetFactoryRoot "config\reference-presets.json"
$ComfyRunner = Join-Path $PSScriptRoot "run-comfyui.ps1"
$PythonRunner = Join-Path $PSScriptRoot "run_multiview.py"
$QualityRunner = Join-Path $PSScriptRoot "multiview_quality.py"
$LockHandle = $null
$Layout = $null
$Metadata = $null
$MetadataPath = $null
$Stage = "initialisation"

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Label = "JSON")
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label introuvable : $Path" }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    catch { throw "$Label invalide : $Path. $($_.Exception.Message)" }
}

function Get-OptionalSetting {
    param($Object, [string]$Name, $Default = $null)
    return Get-AFProperty -Object $Object -Name $Name -Default $Default
}

function Set-JsonProperty {
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Join-PromptText {
    param([string[]]$Parts)
    $filtered = @($Parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    return ($filtered -join ", ")
}

try {
    Assert-AFFileStem -Name $AssetId
    if (-not [string]::IsNullOrWhiteSpace($AssetVersion)) { Assert-AFAssetVersion -Version $AssetVersion }
    Assert-AFFile -Path $PythonRunner -Label "Runner multi-vues Python"
    Assert-AFFile -Path $QualityRunner -Label "Runner qualité multi-vues"
    Assert-AFFile -Path $RegistryPath -Label "Registre des méthodes multi-vues"
    Assert-AFFile -Path $ReferencePresetRegistryPath -Label "Registre des presets de référence"

    $useExistingReference = -not [string]::IsNullOrWhiteSpace($ReferenceImage)
    if (-not $useExistingReference -and [string]::IsNullOrWhiteSpace($Prompt)) {
        throw "Utilisez -Prompt pour créer l’image de référence ou -ReferenceImage pour fournir une image existante."
    }
    if ($useExistingReference -and $ReferenceCandidates -ne 1) {
        throw "ReferenceCandidates ne s’applique qu’aux références générées depuis un prompt."
    }
    if (-not $useExistingReference) {
        Assert-AFFile -Path $ComfyRunner -Label "Runner ComfyUI"
        Assert-AFFile -Path (Resolve-AFPath $WorkflowPath $AssetFactoryRoot) -Label "Workflow ComfyUI"
    }

    $registry = Read-JsonFile -Path $RegistryPath -Label "Registre multi-vues"
    if ([int](Get-OptionalSetting $registry "schemaVersion" 0) -ne 1) { throw "Version du registre multi-vues non prise en charge." }
    $presetRegistry = Read-JsonFile -Path $ReferencePresetRegistryPath -Label "Registre des presets de référence"
    if ([int](Get-OptionalSetting $presetRegistry "schemaVersion" 0) -ne 1) { throw "Version du registre des presets de référence non prise en charge." }

    $profile = $null
    if (-not [string]::IsNullOrWhiteSpace($MethodProfile)) {
        $resolvedProfile = Resolve-AFPath -Path $MethodProfile -BasePath $AssetFactoryRoot
        $profile = Read-JsonFile -Path $resolvedProfile -Label "Profil multi-vues"
        if ([int](Get-OptionalSetting $profile "schemaVersion" 0) -ne 1) { throw "Version du profil multi-vues non prise en charge." }
    }

    $selectedMethod = $Method
    if ([string]::IsNullOrWhiteSpace($selectedMethod) -and $null -ne $profile) {
        $selectedMethod = [string](Get-OptionalSetting $profile "method" "")
    }
    if ([string]::IsNullOrWhiteSpace($selectedMethod)) {
        $selectedMethod = [string](Get-OptionalSetting $registry "defaultMethod" "")
    }
    if ([string]::IsNullOrWhiteSpace($selectedMethod)) { throw "Aucune méthode multi-vues n’est configurée." }

    $methods = Get-OptionalSetting $registry "methods" $null
    $methodConfig = Get-OptionalSetting $methods $selectedMethod $null
    if ($null -eq $methodConfig) {
        $available = @($methods.PSObject.Properties.Name) -join ", "
        throw "Méthode multi-vues inconnue '$selectedMethod'. Disponibles : $available"
    }
    $defaults = Get-OptionalSetting $methodConfig "parameters" $null
    $profileParameters = if ($null -ne $profile) { Get-OptionalSetting $profile "parameters" $null } else { $null }
    $profileReference = if ($null -ne $profile) { Get-OptionalSetting $profile "reference" $null } else { $null }

    $resolvedSteps = if ($null -ne $Steps) { [int]$Steps } elseif ($null -ne (Get-OptionalSetting $profileParameters "steps" $null)) { [int](Get-OptionalSetting $profileParameters "steps") } else { [int](Get-OptionalSetting $defaults "steps" 28) }
    $resolvedGuidance = if ($null -ne $GuidanceScale) { [double]$GuidanceScale } elseif ($null -ne (Get-OptionalSetting $profileParameters "guidanceScale" $null)) { [double](Get-OptionalSetting $profileParameters "guidanceScale") } else { [double](Get-OptionalSetting $defaults "guidanceScale" 4.0) }
    $resolvedKeepGrid = if ($null -ne $KeepGrid) { [bool]$KeepGrid } elseif ($null -ne (Get-OptionalSetting $profileParameters "keepGrid" $null)) { [bool](Get-OptionalSetting $profileParameters "keepGrid") } else { [bool](Get-OptionalSetting $defaults "keepGrid" $true) }
    $resolvedConditioningPrompt = if ($PSBoundParameters.ContainsKey("ConditioningPrompt")) { $ConditioningPrompt } elseif ($null -ne (Get-OptionalSetting $profileParameters "conditioningPrompt" $null)) { [string](Get-OptionalSetting $profileParameters "conditioningPrompt") } else { [string](Get-OptionalSetting $defaults "conditioningPrompt" "") }
    $resolvedReferenceCandidates = if ($PSBoundParameters.ContainsKey("ReferenceCandidates")) { [int]$ReferenceCandidates } elseif ($null -ne (Get-OptionalSetting $profileReference "candidates" $null)) { [int](Get-OptionalSetting $profileReference "candidates") } else { 1 }
    $resolvedReferencePreset = if ($PSBoundParameters.ContainsKey("ReferencePreset")) { $ReferencePreset } elseif ($null -ne (Get-OptionalSetting $profileReference "preset" $null)) { [string](Get-OptionalSetting $profileReference "preset") } else { [string](Get-OptionalSetting $presetRegistry "defaultPreset" "") }
    $resolvedReferenceExclude = if ($PSBoundParameters.ContainsKey("ReferenceExclude")) { @($ReferenceExclude) } else { @(Get-OptionalSetting $profileReference "exclude" @()) }

    if ($resolvedSteps -lt 1 -or $resolvedSteps -gt 200) { throw "Steps doit être compris entre 1 et 200." }
    if ($resolvedGuidance -lt 0 -or $resolvedGuidance -gt 30) { throw "GuidanceScale doit être compris entre 0 et 30." }
    if ($resolvedReferenceCandidates -lt 1 -or $resolvedReferenceCandidates -gt 8) { throw "ReferenceCandidates doit être compris entre 1 et 8." }

    $resolvedPresetConfig = $null
    if (-not [string]::IsNullOrWhiteSpace($resolvedReferencePreset) -and $resolvedReferencePreset -ne "none") {
        $presetMap = Get-OptionalSetting $presetRegistry "presets" $null
        $resolvedPresetConfig = Get-OptionalSetting $presetMap $resolvedReferencePreset $null
        if ($null -eq $resolvedPresetConfig) {
            $availablePresets = @($presetMap.PSObject.Properties.Name) -join ", "
            throw "Preset de référence inconnu '$resolvedReferencePreset'. Disponibles : $availablePresets"
        }
    }

    $referencePositiveAugmentation = if ($null -ne $resolvedPresetConfig) { [string](Get-OptionalSetting $resolvedPresetConfig "positiveSuffix" "") } else { "" }
    $referenceNegativeAugmentation = if ($null -ne $resolvedPresetConfig) { [string](Get-OptionalSetting $resolvedPresetConfig "negativeSuffix" "") } else { "" }
    $resolvedReferencePrompt = if ($useExistingReference) { "" } else { Join-PromptText @($Prompt, $referencePositiveAugmentation) }
    $referenceExcludeText = if (@($resolvedReferenceExclude).Count -gt 0) { (@($resolvedReferenceExclude) -join ", ") } else { "" }
    $resolvedReferenceNegativePrompt = if ($useExistingReference) { "" } else { Join-PromptText @($NegativePrompt, $referenceNegativeAugmentation, $referenceExcludeText) }

    $methodEngineRoot = Resolve-AFPath -Path ([string](Get-OptionalSetting $methodConfig "engineRoot" "")) -BasePath $AssetFactoryRoot
    $methodModelRoot = Resolve-AFPath -Path ([string](Get-OptionalSetting $methodConfig "modelRoot" "")) -BasePath $AssetFactoryRoot
    $methodPython = Resolve-AFPath -Path ([string](Get-OptionalSetting $methodConfig "runtimePython" "")) -BasePath $AssetFactoryRoot
    Assert-AFFile -Path $methodPython -Label "Python de la méthode $selectedMethod"

    $locksRoot = Join-Path $AssetFactoryRoot "outputs\.locks"
    New-Item -ItemType Directory -Path $locksRoot -Force | Out-Null
    try {
        $LockHandle = [System.IO.File]::Open(
            (Join-Path $locksRoot "multiview.lock"),
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        throw "Une autre génération multi-vues est déjà en cours."
    }

    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $Layout = New-AFAssetGeneration -Root $AssetFactoryRoot -AssetId $AssetId -Version $AssetVersion
    } else {
        $resolvedOutput = Resolve-AFPath -Path $OutputDir -BasePath $AssetFactoryRoot
        if (Test-Path -LiteralPath $resolvedOutput -PathType Container) {
            if (@(Get-ChildItem -LiteralPath $resolvedOutput -Force -ErrorAction SilentlyContinue).Count -gt 0) {
                throw "Le dossier de sortie personnalisé n’est pas vide : $resolvedOutput"
            }
        }
        $Layout = Resolve-AFGenerationLayout -Root $AssetFactoryRoot -AssetId $AssetId -GenerationRoot $resolvedOutput -Version $AssetVersion
    }

    $MetadataPath = Join-Path $Layout.MetadataDir "multiview.json"
    $ReferenceDir = Join-Path $Layout.SourceDir "reference"
    $ReferenceCandidatesDir = Join-Path $ReferenceDir "candidates"
    $ViewsDir = Join-Path $Layout.SourceDir "views"
    New-Item -ItemType Directory -Path $ReferenceDir -Force | Out-Null
    New-Item -ItemType Directory -Path $ReferenceCandidatesDir -Force | Out-Null
    New-Item -ItemType Directory -Path $ViewsDir -Force | Out-Null

    $Metadata = [ordered]@{
        schemaVersion = 1
        generationId = "$AssetId-$($Layout.Version)"
        assetId = $AssetId
        assetVersion = $Layout.Version
        generationRoot = $Layout.Root
        type = "multiview-images"
        createdAt = (Get-Date).ToString("o")
        completedAt = $null
        status = "running"
        failedStage = $null
        error = $null
        methods = [ordered]@{
            reference = [ordered]@{
                method = $(if ($useExistingReference) { "provided-image" } else { "comfyui-flux-schnell" })
                prompt = $(if ($useExistingReference) { $null } else { $Prompt })
                promptUsed = $(if ($useExistingReference) { $null } else { $resolvedReferencePrompt })
                negativePrompt = $(if ($useExistingReference) { $null } else { $NegativePrompt })
                negativePromptUsed = $(if ($useExistingReference) { $null } else { $resolvedReferenceNegativePrompt })
                preset = $(if ($useExistingReference) { $null } else { $(if ([string]::IsNullOrWhiteSpace($resolvedReferencePreset)) { $null } else { $resolvedReferencePreset }) })
                candidateCount = $(if ($useExistingReference) { 1 } else { $resolvedReferenceCandidates })
                excludedDetails = @($resolvedReferenceExclude)
                seed = $Seed
                path = $null
                candidates = @()
                quality = $null
            }
            multiview = [ordered]@{
                method = $selectedMethod
                parameters = [ordered]@{
                    steps = $resolvedSteps
                    guidanceScale = $resolvedGuidance
                    keepGrid = $resolvedKeepGrid
                    conditioningPrompt = $resolvedConditioningPrompt
                    seed = $Seed
                }
                metadataPath = $MetadataPath
                qualityPath = $null
                quality = $null
            }
        }
    }
    Save-AFJson -Value $Metadata -Path $Layout.GenerationMetadataPath

    Write-AFInfo "Asset : $AssetId"
    Write-AFInfo "Version : $($Layout.Version)"
    Write-AFInfo "Méthode multi-vues : $selectedMethod"
    Write-AFInfo "Génération : $($Layout.Root)"
    if (-not $useExistingReference) {
        Write-AFInfo "Référence: $resolvedReferenceCandidates candidate(s) ; preset = $(if ([string]::IsNullOrWhiteSpace($resolvedReferencePreset)) { '(aucun)' } else { $resolvedReferencePreset })"
    }

    $Stage = "reference"
    if ($useExistingReference) {
        $resolvedReference = Resolve-AFPath -Path $ReferenceImage -BasePath (Get-Location).Path
        Assert-AFFile -Path $resolvedReference -Label "Image de référence"
        if ([System.IO.Path]::GetExtension($resolvedReference).ToLowerInvariant() -notin @(".png", ".jpg", ".jpeg", ".webp")) {
            throw "ReferenceImage doit être une image PNG, JPEG ou WebP."
        }
        $extension = [System.IO.Path]::GetExtension($resolvedReference).ToLowerInvariant()
        $ReferencePath = Join-Path $ReferenceDir ($AssetId + "_reference" + $extension)
        Copy-Item -LiteralPath $resolvedReference -Destination $ReferencePath
        Write-AFOk "Image de référence copiée : $ReferencePath"
    } else {
        $generatedReferencePaths = New-Object System.Collections.Generic.List[string]
        for ($candidateIndex = 1; $candidateIndex -le $resolvedReferenceCandidates; $candidateIndex++) {
            $candidateSeed = $Seed + ($candidateIndex - 1)
            $isSingleReference = $resolvedReferenceCandidates -eq 1
            $candidateStem = if ($isSingleReference) { ($AssetId + "_reference") } else { ("{0}_reference_candidate_{1:D2}" -f $AssetId, $candidateIndex) }
            $candidateSubfolder = if ($isSingleReference) { "reference" } else { "reference\candidates" }
            $referenceLog = Join-Path $Layout.LogsDir ("reference-comfyui-{0:D2}.log" -f $candidateIndex)
            $referenceParams = @{
                Prompt = $resolvedReferencePrompt
                NegativePrompt = $resolvedReferenceNegativePrompt
                Seed = $candidateSeed
                WorkflowPath = $WorkflowPath
                ServerUrl = $ServerUrl
                TimeoutSeconds = $TimeoutSeconds
                AssetId = $AssetId
                GenerationRoot = $Layout.Root
                AssetVersion = $Layout.Version
                OutputFileStem = $candidateStem
                SourceSubfolder = $candidateSubfolder
                MetadataPrefix = ("reference-comfyui-{0:D2}" -f $candidateIndex)
                PipelineManaged = $true
            }
            $referenceResult = Invoke-AFCommand -Executable $ComfyRunner -Parameters $referenceParams -LogPath $referenceLog
            if ($referenceResult.ExitCode -ne 0) { throw "La génération de l’image de référence a échoué. Log : $referenceLog" }

            $searchRoot = if ($isSingleReference) { $ReferenceDir } else { $ReferenceCandidatesDir }
            $candidatePath = Get-ChildItem -LiteralPath $searchRoot -File | Where-Object { $_.BaseName -eq $candidateStem } | Select-Object -First 1 -ExpandProperty FullName
            if ([string]::IsNullOrWhiteSpace($candidatePath)) { throw "ComfyUI n’a pas produit l’image de référence attendue dans $searchRoot" }
            $generatedReferencePaths.Add($candidatePath)
        }

        $referenceQualityPath = Join-Path $Layout.MetadataDir "reference-quality.json"
        $qualityArgs = @("-B", $QualityRunner, "score-references", "--output", $referenceQualityPath)
        foreach ($candidatePath in $generatedReferencePaths) {
            $qualityArgs += @("--image", $candidatePath)
        }
        $referenceQualityLog = Join-Path $Layout.LogsDir "reference-quality.log"
        $referenceQualityResult = Invoke-AFCommand -Executable $methodPython -Arguments $qualityArgs -LogPath $referenceQualityLog
        if ($referenceQualityResult.ExitCode -ne 0) { throw "Le scoring des références a échoué. Log : $referenceQualityLog" }
        $referenceQuality = Read-JsonFile -Path $referenceQualityPath -Label "Qualité des références"

        foreach ($candidate in @(Get-OptionalSetting $referenceQuality "candidates" @())) {
            $Metadata.methods.reference.candidates += [ordered]@{
                path = [string](Get-OptionalSetting $candidate "path" "")
                score = Get-OptionalSetting $candidate "score" $null
                warnings = @(Get-OptionalSetting $candidate "warnings" @())
            }
        }
        $selectedCandidatePath = [string](Get-OptionalSetting $referenceQuality "selectedReferencePath" "")
        if ([string]::IsNullOrWhiteSpace($selectedCandidatePath)) { throw "Aucune référence sélectionnée n’a été renvoyée par le scoring." }
        $selectedExtension = [System.IO.Path]::GetExtension($selectedCandidatePath).ToLowerInvariant()
        $ReferencePath = Join-Path $ReferenceDir ($AssetId + "_reference" + $selectedExtension)
        if ([System.IO.Path]::GetFullPath($selectedCandidatePath) -ne [System.IO.Path]::GetFullPath($ReferencePath)) {
            Copy-Item -LiteralPath $selectedCandidatePath -Destination $ReferencePath -Force
        }
        $Metadata.methods.reference.quality = $referenceQuality
        Write-AFOk ("Référence sélectionnée : {0}" -f $ReferencePath)
        Write-AFInfo ("Score de référence : {0}" -f (Get-OptionalSetting $referenceQuality "selectedScore" "n/a"))

        if ($ReleaseComfyMemory) {
            Write-AFInfo "Libération de la VRAM ComfyUI avant le moteur multi-vues..."
            $release = Request-AFComfyMemoryRelease -ServerUrl $ServerUrl -TimeoutSeconds 90
            Write-AFOk $release.message
        }
    }
    $Metadata.methods.reference.path = $ReferencePath
    Save-AFJson -Value $Metadata -Path $Layout.GenerationMetadataPath

    $Stage = "multiview"
    Write-AFInfo "Génération de vues cohérentes depuis une seule image de référence..."
    $multiviewLog = Join-Path $Layout.LogsDir "multiview.log"
    $arguments = @(
        "-B", $PythonRunner,
        "--method", $selectedMethod,
        "--reference", $ReferencePath,
        "--output-dir", $ViewsDir,
        "--metadata", $MetadataPath,
        "--asset-id", $AssetId,
        "--seed", $Seed.ToString(),
        "--steps", $resolvedSteps.ToString(),
        "--guidance-scale", $resolvedGuidance.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        ("--conditioning-prompt=" + $resolvedConditioningPrompt),
        "--keep-grid", $(if ($resolvedKeepGrid) { "true" } else { "false" }),
        "--registry", $RegistryPath
    )
    $multiviewResult = Invoke-AFCommand -Executable $methodPython -Arguments $arguments -LogPath $multiviewLog
    if ($multiviewResult.ExitCode -ne 0) { throw "La génération multi-vues a échoué. Log : $multiviewLog" }

    $providerMetadata = Read-JsonFile -Path $MetadataPath -Label "Métadonnées multi-vues"
    $viewCount = @($providerMetadata.views).Count
    if ($viewCount -lt 2) { throw "Le moteur multi-vues n’a produit que $viewCount vue(s)." }

    $qualityPath = Join-Path $Layout.MetadataDir "multiview-quality.json"
    $qualityArgs = @("-B", $QualityRunner, "report-views", "--output", $qualityPath)
    foreach ($view in @($providerMetadata.views)) {
        $qualityArgs += @("--image", [string](Get-OptionalSetting $view "path" ""))
    }
    $qualityLog = Join-Path $Layout.LogsDir "multiview-quality.log"
    $qualityResult = Invoke-AFCommand -Executable $methodPython -Arguments $qualityArgs -LogPath $qualityLog
    if ($qualityResult.ExitCode -ne 0) { throw "Le rapport qualité multi-vues a échoué. Log : $qualityLog" }
    $qualityReport = Read-JsonFile -Path $qualityPath -Label "Rapport qualité multi-vues"

    Set-JsonProperty -Object $providerMetadata -Name "quality" -Value $qualityReport
    Save-AFJson -Value $providerMetadata -Path $MetadataPath

    $Metadata.status = "completed"
    $Metadata.completedAt = (Get-Date).ToString("o")
    $Metadata.methods.multiview.viewCount = $viewCount
    $Metadata.methods.multiview.views = @($providerMetadata.views)
    $Metadata.methods.multiview.qualityPath = $qualityPath
    $Metadata.methods.multiview.quality = $qualityReport
    Save-AFJson -Value $Metadata -Path $Layout.GenerationMetadataPath

    Write-AFOk "Génération multi-vues terminée : $viewCount vues"
    Write-AFOk "Référence : $ReferencePath"
    Write-AFOk "Vues : $ViewsDir"
    Write-AFOk "Métadonnées : $MetadataPath"
    Write-AFInfo ("Score qualité multi-vues : {0}" -f (Get-OptionalSetting $qualityReport "score" "n/a"))
    if (@(Get-OptionalSetting $qualityReport "warnings" @()).Count -gt 0) {
        Write-AFInfo ("Avertissements qualité : " + (@(Get-OptionalSetting $qualityReport "warnings" @()) -join ", "))
    }
    exit 0
}
catch {
    $message = $_.Exception.Message
    if ($null -ne $Metadata -and $null -ne $Layout) {
        $Metadata.status = "failed"
        $Metadata.completedAt = (Get-Date).ToString("o")
        $Metadata.failedStage = $Stage
        $Metadata.error = $message
        try { Save-AFJson -Value $Metadata -Path $Layout.GenerationMetadataPath } catch { }
    }
    Write-AFFail $message
    if ($null -ne $Layout) { Write-AFInfo "Génération conservée : $($Layout.Root)" }
    exit 1
}
finally {
    if ($null -ne $LockHandle) { try { $LockHandle.Dispose() } catch { } }
}
