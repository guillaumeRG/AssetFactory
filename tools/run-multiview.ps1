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
    [ValidateRange(1, 64)]
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
Import-Module (Join-Path $PSScriptRoot "internal\AssetFactory.Pipeline.psm1") -Force

$RegistryPath = Join-Path $AssetFactoryRoot "config\multiview-methods.json"
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

try {
    Assert-AFFileStem -Name $AssetId
    if (-not [string]::IsNullOrWhiteSpace($AssetVersion)) { Assert-AFAssetVersion -Version $AssetVersion }
    Assert-AFFile -Path $PythonRunner -Label "Runner multi-vues Python"
    Assert-AFFile -Path $QualityRunner -Label "Runner qualité multi-vues"
    Assert-AFFile -Path $RegistryPath -Label "Registre des méthodes multi-vues"

    $useExistingReference = -not [string]::IsNullOrWhiteSpace($ReferenceImage)
    if (-not $useExistingReference -and [string]::IsNullOrWhiteSpace($Prompt)) {
        throw "Utilisez -Prompt pour créer l’image de référence ou -ReferenceImage pour fournir une image existante."
    }
    if ($useExistingReference -and $ReferenceCandidates -ne 1) {
        throw "ReferenceCandidates ne s’applique qu’aux références générées depuis un prompt."
    }

    $registry = Read-JsonFile -Path $RegistryPath -Label "Registre multi-vues"
    if ([int](Get-OptionalSetting $registry "schemaVersion" 0) -ne 1) { throw "Version du registre multi-vues non prise en charge." }

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
    $resolvedReferencePreset = if ($PSBoundParameters.ContainsKey("ReferencePreset")) { $ReferencePreset } elseif ($null -ne (Get-OptionalSetting $profileReference "preset" $null)) { [string](Get-OptionalSetting $profileReference "preset") } else { "" }
    $resolvedReferenceExclude = if ($PSBoundParameters.ContainsKey("ReferenceExclude")) { @($ReferenceExclude) } else { @(Get-OptionalSetting $profileReference "exclude" @()) }

    if ($resolvedSteps -lt 1 -or $resolvedSteps -gt 200) { throw "Steps doit être compris entre 1 et 200." }
    if ($resolvedGuidance -lt 0 -or $resolvedGuidance -gt 30) { throw "GuidanceScale doit être compris entre 0 et 30." }
    if ($resolvedReferenceCandidates -lt 1 -or $resolvedReferenceCandidates -gt 64) { throw "ReferenceCandidates doit être compris entre 1 et 64." }
    if ($resolvedReferenceCandidates -gt 16) { Write-AFInfo "ReferenceCandidates=$resolvedReferenceCandidates : cette étape lancera autant de générations ComfyUI." }

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
    $ViewsDir = Join-Path $Layout.SourceDir "views"
    New-Item -ItemType Directory -Path $ReferenceDir -Force | Out-Null
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
                promptUsed = $null
                negativePrompt = $(if ($useExistingReference) { $null } else { $NegativePrompt })
                negativePromptUsed = $null
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
        $referenceStage = Invoke-AFImageStage `
            -Prompt $Prompt `
            -NegativePrompt $NegativePrompt `
            -AssetId $AssetId `
            -GenerationRoot $Layout.Root `
            -AssetVersion $Layout.Version `
            -Seed $Seed `
            -Candidates $resolvedReferenceCandidates `
            -Preset $resolvedReferencePreset `
            -Exclude @($resolvedReferenceExclude) `
            -Purpose reference `
            -WorkflowPath $WorkflowPath `
            -ServerUrl $ServerUrl `
            -TimeoutSeconds $TimeoutSeconds `
            -ReleaseComfyMemory $ReleaseComfyMemory

        $ReferencePath = [string]$referenceStage.ImagePath
        $referenceQuality = $referenceStage.Quality
        $Metadata.methods.reference.promptUsed = $referenceStage.PromptUsed
        $Metadata.methods.reference.negativePromptUsed = $referenceStage.NegativePromptUsed
        $Metadata.methods.reference.preset = $referenceStage.Preset
        $Metadata.methods.reference.candidates = @()
        foreach ($candidate in @(Get-OptionalSetting $referenceQuality "candidates" @())) {
            $Metadata.methods.reference.candidates += [ordered]@{
                path = [string](Get-OptionalSetting $candidate "path" "")
                score = Get-OptionalSetting $candidate "score" $null
                warnings = @(Get-OptionalSetting $candidate "warnings" @())
            }
        }
        $Metadata.methods.reference.quality = $referenceQuality
        Write-AFOk ("Référence sélectionnée : {0}" -f $ReferencePath)
        Write-AFInfo ("Score de référence : {0}" -f (Get-OptionalSetting $referenceQuality "selectedScore" "n/a"))
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
    $result = [ordered]@{
        kind = "asset-factory-multiview-generation"
        status = "completed"
        generationId = $Metadata.generationId
        assetId = $AssetId
        assetVersion = $Layout.Version
        generationRoot = $Layout.Root
        referencePath = $ReferencePath
        viewsPath = $ViewsDir
        viewCount = $viewCount
        metadataPath = $MetadataPath
    }
    Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
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
