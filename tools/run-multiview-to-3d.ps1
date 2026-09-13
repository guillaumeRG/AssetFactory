[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GenerationRoot,

    [string]$Method = "",
    [string]$MethodProfile = "",
    [string]$FusionMode = "",
    [System.Nullable[bool]]$IncludeReference = $null,
    [int[]]$ViewIndices = @(),
    [string]$ViewPolicy = "",
    [System.Nullable[int]]$MaxViews = $null,
    [System.Nullable[double]]$MinViewScore = $null,
    [System.Nullable[long]]$Seed = $null,
    [System.Nullable[double]]$Simplify = $null,
    [System.Nullable[int]]$TextureSize = $null,

    [ValidateRange(0.001, 1000000.0)]
    [double]$TargetHeight = 1.0,

    [string]$ProjectProfile = "",
    [string]$Category = "",
    [System.Nullable[bool]]$AutoImport = $null,
    [string]$BlenderPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")

$RegistryPath = Join-Path $AssetFactoryRoot "config\geometry-methods.json"
$BlenderScript = Join-Path $AssetFactoryRoot "blender\scripts\process-mesh.py"
$UnrealImportRunner = Join-Path $PSScriptRoot "import-unreal.ps1"

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Label = "JSON")
    Assert-AFFile -Path $Path -Label $Label
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "$Label invalide : $Path. $($_.Exception.Message)" }
}

function Set-JsonProperty {
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-ViewAzimuth {
    param($View)
    $azimuth = Get-AFProperty $View "azimuth" $null
    if ($null -eq $azimuth) {
        return ([double]([int](Get-AFProperty $View "index" 1) - 1) * 60.0)
    }
    return [double]$azimuth
}

function Get-CircularDistance {
    param([double]$Left, [double]$Right)
    $delta = [math]::Abs($Left - $Right) % 360.0
    return [math]::Min($delta, 360.0 - $delta)
}

function Select-SpacedViews {
    param(
        [object[]]$Views,
        [int]$Limit,
        [hashtable]$Scores = @{},
        [switch]$PreferScore
    )
    $candidates = @($Views)
    if ($candidates.Count -le $Limit) { return @($candidates) }

    $selected = New-Object System.Collections.ArrayList
    if ($PreferScore) {
        $first = $candidates | Sort-Object -Property @{ Expression = {
            $path = [string](Get-AFProperty $_ "path" "")
            if ($Scores.ContainsKey($path)) { -[double]$Scores[$path] } else { 0.0 }
        } }, @{ Expression = { [int](Get-AFProperty $_ "index" 0) } } | Select-Object -First 1
    } else {
        $first = $candidates | Sort-Object { [int](Get-AFProperty $_ "index" 0) } | Select-Object -First 1
    }
    [void]$selected.Add($first)

    while ($selected.Count -lt $Limit) {
        $remaining = @($candidates | Where-Object {
            $candidatePath = [string](Get-AFProperty $_ "path" "")
            -not @($selected | Where-Object { [string](Get-AFProperty $_ "path" "") -eq $candidatePath }).Count
        })
        if ($remaining.Count -eq 0) { break }

        $best = $null
        $bestMetric = [double]::NegativeInfinity
        foreach ($candidate in $remaining) {
            $candidateAzimuth = Get-ViewAzimuth $candidate
            $minDistance = 360.0
            foreach ($chosen in $selected) {
                $distance = Get-CircularDistance -Left $candidateAzimuth -Right (Get-ViewAzimuth $chosen)
                if ($distance -lt $minDistance) { $minDistance = $distance }
            }
            $metric = $minDistance
            if ($PreferScore) {
                $path = [string](Get-AFProperty $candidate "path" "")
                $score = if ($Scores.ContainsKey($path)) { [double]$Scores[$path] } else { 50.0 }
                $metric += ($score * 0.45)
            }
            if ($metric -gt $bestMetric) {
                $bestMetric = $metric
                $best = $candidate
            }
        }
        if ($null -eq $best) { break }
        [void]$selected.Add($best)
    }
    return @($selected | Sort-Object { [int](Get-AFProperty $_ "index" 0) })
}

function Get-BlenderExecutable {
    if (-not [string]::IsNullOrWhiteSpace($BlenderPath)) {
        $resolved = Resolve-AFPath -Path $BlenderPath -BasePath $AssetFactoryRoot
        Assert-AFFile -Path $resolved -Label "Exécutable Blender"
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

$Layout = $null
$GenerationMetadata = $null
$GeometryMetadata = $null
$GeometryMetadataPath = $null
$Stage = "initialisation"
$ExitCode = 1

try {
    Assert-AFFile -Path $RegistryPath -Label "Registre des méthodes 3D"
    Assert-AFFile -Path $BlenderScript -Label "Script Blender"
    $BlenderExe = Get-BlenderExecutable

    $resolvedGenerationRoot = Resolve-AFPath -Path $GenerationRoot -BasePath (Get-Location).Path
    if (-not (Test-Path -LiteralPath $resolvedGenerationRoot -PathType Container)) {
        throw "Génération multi-vues introuvable : $resolvedGenerationRoot"
    }
    $Layout = Get-AFGenerationLayout -GenerationRoot $resolvedGenerationRoot
    Assert-AFFile -Path $Layout.GenerationMetadataPath -Label "Métadonnées de génération"
    $multiviewMetadataPath = Join-Path $Layout.MetadataDir "multiview.json"
    $GenerationMetadata = Read-JsonFile -Path $Layout.GenerationMetadataPath -Label "Métadonnées de génération"
    $MultiViewMetadata = Read-JsonFile -Path $multiviewMetadataPath -Label "Métadonnées multi-vues"

    if ([string](Get-AFProperty $MultiViewMetadata "status" "") -ne "completed") {
        throw "La génération multi-vues n'est pas terminée ; impossible de lancer la reconstruction 3D."
    }

    $AssetId = [string](Get-AFProperty $GenerationMetadata "assetId" "")
    $AssetVersion = [string](Get-AFProperty $GenerationMetadata "assetVersion" $Layout.Version)
    Assert-AFFileStem -Name $AssetId
    if (-not [string]::IsNullOrWhiteSpace($AssetVersion)) { Assert-AFAssetVersion -Version $AssetVersion }

    $registry = Read-JsonFile -Path $RegistryPath -Label "Registre des méthodes 3D"
    if ([int](Get-AFProperty $registry "schemaVersion" 0) -ne 1) {
        throw "Version du registre des méthodes 3D non prise en charge."
    }

    $profile = $null
    if (-not [string]::IsNullOrWhiteSpace($MethodProfile)) {
        $resolvedProfile = Resolve-AFPath -Path $MethodProfile -BasePath $AssetFactoryRoot
        $profile = Read-JsonFile -Path $resolvedProfile -Label "Profil de reconstruction 3D"
        if ([int](Get-AFProperty $profile "schemaVersion" 0) -ne 1) {
            throw "Version du profil de reconstruction 3D non prise en charge."
        }
    }

    $selectedMethod = $Method
    if ([string]::IsNullOrWhiteSpace($selectedMethod) -and $null -ne $profile) {
        $selectedMethod = [string](Get-AFProperty $profile "method" "")
    }
    if ([string]::IsNullOrWhiteSpace($selectedMethod)) {
        $selectedMethod = [string](Get-AFProperty $registry "defaultMethod" "")
    }
    if ([string]::IsNullOrWhiteSpace($selectedMethod)) { throw "Aucune méthode de reconstruction 3D n'est configurée." }

    $methods = Get-AFProperty $registry "methods" $null
    $methodConfig = Get-AFProperty $methods $selectedMethod $null
    if ($null -eq $methodConfig) {
        $available = @($methods.PSObject.Properties.Name) -join ", "
        throw "Méthode de reconstruction 3D inconnue '$selectedMethod'. Disponibles : $available"
    }
    if ([string](Get-AFProperty $methodConfig "type" "") -ne "multiview-to-3d") {
        throw "La méthode '$selectedMethod' n'est pas une méthode multi-vues-vers-3D."
    }
    if ([string](Get-AFProperty $methodConfig "provider" "") -ne "trellis") {
        throw "Fournisseur 3D non encore implémenté pour '$selectedMethod'."
    }

    $defaults = Get-AFProperty $methodConfig "parameters" $null
    $profileParameters = if ($null -ne $profile) { Get-AFProperty $profile "parameters" $null } else { $null }

    $resolvedFusionMode = if (-not [string]::IsNullOrWhiteSpace($FusionMode)) {
        $FusionMode
    } elseif ($null -ne (Get-AFProperty $profileParameters "fusionMode" $null)) {
        [string](Get-AFProperty $profileParameters "fusionMode")
    } else {
        [string](Get-AFProperty $defaults "fusionMode" "stochastic")
    }
    if ($resolvedFusionMode -notin @("stochastic", "multidiffusion")) {
        throw "FusionMode doit être 'stochastic' ou 'multidiffusion'."
    }

    $resolvedIncludeReference = if ($null -ne $IncludeReference) {
        [bool]$IncludeReference
    } elseif ($null -ne (Get-AFProperty $profileParameters "includeReference" $null)) {
        [bool](Get-AFProperty $profileParameters "includeReference")
    } else {
        [bool](Get-AFProperty $defaults "includeReference" $true)
    }
    $profileViewIndices = @(Get-AFProperty $profileParameters "viewIndices" @())
    if (@($ViewIndices).Count -gt 0) {
        $resolvedViewIndices = @($ViewIndices)
    } else {
        $resolvedViewIndices = @($profileViewIndices)
    }
    $resolvedViewPolicy = if (-not [string]::IsNullOrWhiteSpace($ViewPolicy)) { $ViewPolicy } elseif ($null -ne (Get-AFProperty $profileParameters "viewPolicy" $null)) { [string](Get-AFProperty $profileParameters "viewPolicy") } else { [string](Get-AFProperty $defaults "viewPolicy" "quality") }
    if ($resolvedViewPolicy -notin @("all", "balanced", "quality")) { throw "ViewPolicy doit être 'all', 'balanced' ou 'quality'." }
    $resolvedMaxViews = if ($null -ne $MaxViews) { [int]$MaxViews } elseif ($null -ne (Get-AFProperty $profileParameters "maxViews" $null)) { [int](Get-AFProperty $profileParameters "maxViews") } else { [int](Get-AFProperty $defaults "maxViews" 4) }
    $resolvedMinViewScore = if ($null -ne $MinViewScore) { [double]$MinViewScore } elseif ($null -ne (Get-AFProperty $profileParameters "minViewScore" $null)) { [double](Get-AFProperty $profileParameters "minViewScore") } else { [double](Get-AFProperty $defaults "minViewScore" 45.0) }
    if ($resolvedMaxViews -lt 2 -or $resolvedMaxViews -gt 12) { throw "MaxViews doit être compris entre 2 et 12." }
    if ($resolvedMinViewScore -lt 0 -or $resolvedMinViewScore -gt 100) { throw "MinViewScore doit être compris entre 0 et 100." }
    $resolvedSimplify = if ($null -ne $Simplify) { [double]$Simplify } elseif ($null -ne (Get-AFProperty $profileParameters "simplify" $null)) { [double](Get-AFProperty $profileParameters "simplify") } else { [double](Get-AFProperty $defaults "simplify" 0.95) }
    $resolvedTextureSize = if ($null -ne $TextureSize) { [int]$TextureSize } elseif ($null -ne (Get-AFProperty $profileParameters "textureSize" $null)) { [int](Get-AFProperty $profileParameters "textureSize") } else { [int](Get-AFProperty $defaults "textureSize" 1024) }
    if ($resolvedSimplify -lt 0 -or $resolvedSimplify -ge 1) { throw "Simplify doit être compris entre 0 inclus et 1 exclu." }
    if ($resolvedTextureSize -notin @(512, 1024, 2048)) { throw "TextureSize doit valoir 512, 1024 ou 2048." }

    $providerViews = @(Get-AFProperty $MultiViewMetadata "views" @())
    if ($providerViews.Count -lt 2) { throw "Les métadonnées multi-vues contiennent moins de deux vues." }
    $selectedViews = @()
    $selectionReason = "explicit"
    if ($resolvedViewIndices.Count -gt 0) {
        $duplicates = @($resolvedViewIndices | Group-Object | Where-Object { $_.Count -gt 1 })
        if ($duplicates.Count -gt 0) { throw "ViewIndices contient des doublons." }
        foreach ($wantedIndex in $resolvedViewIndices) {
            $match = @($providerViews | Where-Object { [int](Get-AFProperty $_ "index" -1) -eq [int]$wantedIndex })
            if ($match.Count -ne 1) { throw "Vue multi-vues introuvable pour l'index $wantedIndex." }
            $selectedViews += $match[0]
        }
    } elseif ($resolvedViewPolicy -eq "all") {
        $selectionReason = "all"
        $selectedViews = @($providerViews)
    } else {
        $viewScores = @{}
        $quality = Get-AFProperty $MultiViewMetadata "quality" $null
        foreach ($qualityView in @(Get-AFProperty $quality "views" @())) {
            $path = [string](Get-AFProperty $qualityView "path" "")
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                $viewScores[$path] = [double](Get-AFProperty $qualityView "score" 50.0)
            }
        }

        if ($resolvedViewPolicy -eq "quality" -and $viewScores.Count -gt 0) {
            $qualityCandidates = @($providerViews | Where-Object {
                $path = [string](Get-AFProperty $_ "path" "")
                (-not $viewScores.ContainsKey($path)) -or ([double]$viewScores[$path] -ge $resolvedMinViewScore)
            })
            if ($qualityCandidates.Count -lt 2) { $qualityCandidates = @($providerViews) }
            $selectedViews = @(Select-SpacedViews -Views $qualityCandidates -Limit ([math]::Min($resolvedMaxViews, $qualityCandidates.Count)) -Scores $viewScores -PreferScore)
            $selectionReason = "quality"
        } else {
            $selectedViews = @(Select-SpacedViews -Views $providerViews -Limit ([math]::Min($resolvedMaxViews, $providerViews.Count)))
            $selectionReason = $(if ($resolvedViewPolicy -eq "quality") { "quality-fallback-balanced" } else { "balanced" })
        }
    }
    if ($selectedViews.Count -lt 2) { throw "La politique de sélection n'a conservé que $($selectedViews.Count) vue(s)." }

    $inputPaths = @()
    $inputDescriptors = @()
    if ($resolvedIncludeReference) {
        $referencePath = [string](Get-AFProperty $MultiViewMetadata "referencePath" "")
        if ([string]::IsNullOrWhiteSpace($referencePath)) { throw "Chemin de référence absent des métadonnées multi-vues." }
        Assert-AFFile -Path $referencePath -Label "Image de référence"
        $inputPaths += $referencePath
        $inputDescriptors += [ordered]@{ kind = "reference"; index = 0; path = $referencePath }
    }
    foreach ($view in $selectedViews) {
        $viewPath = [string](Get-AFProperty $view "path" "")
        Assert-AFFile -Path $viewPath -Label "Vue multi-vues"
        $inputPaths += $viewPath
        $inputDescriptors += [ordered]@{
            kind = "view"
            index = [int](Get-AFProperty $view "index" 0)
            azimuth = Get-AFProperty $view "azimuth" $null
            elevation = Get-AFProperty $view "elevation" $null
            path = $viewPath
        }
    }
    if ($inputPaths.Count -lt 2) {
        throw "TRELLIS multi-image requiert au moins deux images de conditionnement."
    }

    $resolvedSeed = if ($null -ne $Seed) {
        [long]$Seed
    } else {
        $parameters = Get-AFProperty $MultiViewMetadata "parameters" $null
        [long](Get-AFProperty $parameters "seed" 0)
    }

    $runnerRelative = [string](Get-AFProperty $methodConfig "runner" "tools/run-trellis.ps1")
    $GeometryRunner = Resolve-AFPath -Path $runnerRelative -BasePath $AssetFactoryRoot
    Assert-AFFile -Path $GeometryRunner -Label "Runner de reconstruction 3D"

    $expectedRaw = Join-Path $Layout.RawDir ($AssetId + ".glb")
    $expectedFinal = Join-Path $Layout.FinalDir ($AssetId + ".glb")
    if (Test-Path -LiteralPath $expectedRaw -PathType Leaf) { throw "Le modèle brut existe déjà ; refus de l'écraser : $expectedRaw" }
    if (Test-Path -LiteralPath $expectedFinal -PathType Leaf) { throw "Le modèle final existe déjà ; refus de l'écraser : $expectedFinal" }

    $UnrealConfig = Resolve-AFUnrealConfiguration -Root $AssetFactoryRoot -ProjectProfile $ProjectProfile -AutoImport $AutoImport -AssetId $AssetId -Category $Category

    $GeometryMetadataPath = Join-Path $Layout.MetadataDir "geometry.json"
    $GeometryMetadata = [ordered]@{
        schemaVersion = 1
        status = "running"
        method = $selectedMethod
        provider = "trellis"
        generationRoot = $Layout.Root
        assetId = $AssetId
        assetVersion = $AssetVersion
        createdAt = (Get-Date).ToString("o")
        completedAt = $null
        failedStage = $null
        error = $null
        parameters = [ordered]@{
            fusionMode = $resolvedFusionMode
            includeReference = $resolvedIncludeReference
            viewPolicy = $resolvedViewPolicy
            selectionReason = $selectionReason
            maxViews = $resolvedMaxViews
            minViewScore = $resolvedMinViewScore
            viewIndices = @($selectedViews | ForEach-Object { [int](Get-AFProperty $_ "index" 0) })
            seed = $resolvedSeed
            simplify = $resolvedSimplify
            textureSize = $resolvedTextureSize
            targetHeightMeters = $TargetHeight
        }
        inputs = $inputDescriptors
        rawModelPath = $null
        finalModelPath = $null
        unreal = [ordered]@{
            status = $(if ($UnrealConfig.enabled) { "pending" } else { "not-configured" })
            metadataPath = Join-Path $Layout.MetadataDir "unreal.json"
            logPath = Join-Path $Layout.LogsDir "unreal.log"
            runnerLogPath = Join-Path $Layout.LogsDir "unreal-runner.log"
        }
    }
    Save-AFJson -Value $GeometryMetadata -Path $GeometryMetadataPath

    Set-JsonProperty -Object $GenerationMetadata -Name "status" -Value "running"
    Set-JsonProperty -Object $GenerationMetadata -Name "type" -Value "multiview-asset"
    Set-JsonProperty -Object $GenerationMetadata -Name "failedStage" -Value $null
    Set-JsonProperty -Object $GenerationMetadata -Name "error" -Value $null
    Set-JsonProperty -Object $GenerationMetadata -Name "geometryMetadataPath" -Value $GeometryMetadataPath
    Save-AFJson -Value $GenerationMetadata -Path $Layout.GenerationMetadataPath

    Write-AFInfo "Asset : $AssetId"
    Write-AFInfo "Version : $AssetVersion"
    Write-AFInfo "Méthode 3D : $selectedMethod"
    Write-AFInfo "Images de conditionnement : $($inputPaths.Count)"
    Write-AFInfo "Fusion TRELLIS : $resolvedFusionMode"
    Write-AFInfo "Référence incluse : $resolvedIncludeReference"
    Write-AFInfo "Sélection des vues : $selectionReason -> $(@($selectedViews | ForEach-Object { [int](Get-AFProperty $_ 'index' 0) }) -join ',')"

    $Stage = "geometry"
    $trellisRunnerLog = Join-Path $Layout.LogsDir "trellis-multiview-runner.log"
    $geometryResult = Invoke-AFCommand -Executable $GeometryRunner -LogPath $trellisRunnerLog -SuppressConsolePatterns @(
        '^\s*Remarque : inclusion du fichier :',
        '^\s*Note: including file:'
    ) -Parameters @{
        InputPaths = @($inputPaths)
        MultiImageMode = $resolvedFusionMode
        AssetId = $AssetId
        GenerationRoot = $Layout.Root
        AssetVersion = $AssetVersion
        Seed = $resolvedSeed
        Simplify = $resolvedSimplify
        TextureSize = $resolvedTextureSize
        AutoImport = $false
        PipelineManaged = $true
    }
    if ($geometryResult.ExitCode -ne 0) {
        throw "TRELLIS multi-image a échoué avec le code $($geometryResult.ExitCode). Log : $trellisRunnerLog"
    }
    Assert-AFFile -Path $expectedRaw -Label "Modèle TRELLIS multi-image"
    $GeometryMetadata.rawModelPath = $expectedRaw
    Save-AFJson -Value $GeometryMetadata -Path $GeometryMetadataPath

    $Stage = "blender"
    Write-AFInfo "Normalisation du modèle multi-vues avec Blender..."
    $heightArgument = $TargetHeight.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $blenderArguments = @(
        "--background", "--factory-startup", "--python-exit-code", "1",
        "--python", $BlenderScript, "--", "--input", $expectedRaw,
        "--target-height", $heightArgument,
        "--output", $expectedFinal
    )
    $blenderLog = Join-Path $Layout.LogsDir "blender.log"
    $blenderResult = Invoke-AFCommand -Executable $BlenderExe -Arguments $blenderArguments -LogPath $blenderLog
    if ($blenderResult.ExitCode -ne 0) { throw "Blender a échoué avec le code $($blenderResult.ExitCode). Log : $blenderLog" }
    Assert-AFFile -Path $expectedFinal -Label "Modèle final normalisé"
    $GeometryMetadata.finalModelPath = $expectedFinal
    Save-AFJson -Value $GeometryMetadata -Path $GeometryMetadataPath

    $Stage = "unreal"
    if ($UnrealConfig.autoImport) {
        Write-AFInfo "Import du modèle final dans Unreal Engine..."
        $importResult = Invoke-AFCommand -Executable $UnrealImportRunner -LogPath $GeometryMetadata.unreal.runnerLogPath -Parameters @{
            ProfilePath = $UnrealConfig.profilePath
            SourcePath = $expectedFinal
            AssetId = $AssetId
            AssetVersion = $AssetVersion
            Category = $Category
            MetadataPath = $GeometryMetadata.unreal.metadataPath
            LogPath = $GeometryMetadata.unreal.logPath
        }
        if ($importResult.ExitCode -ne 0) {
            throw "L'import Unreal a échoué. Le GLB final est conservé : $expectedFinal"
        }
        $GeometryMetadata.unreal.status = "completed"
    } elseif ($UnrealConfig.enabled) {
        $GeometryMetadata.unreal.status = "skipped"
    }

    $GeometryMetadata.status = "completed"
    $GeometryMetadata.completedAt = (Get-Date).ToString("o")
    Save-AFJson -Value $GeometryMetadata -Path $GeometryMetadataPath

    Set-JsonProperty -Object $GenerationMetadata -Name "status" -Value "completed"
    Set-JsonProperty -Object $GenerationMetadata -Name "completedAt" -Value ((Get-Date).ToString("o"))
    Set-JsonProperty -Object $GenerationMetadata -Name "rawModelPath" -Value $expectedRaw
    Set-JsonProperty -Object $GenerationMetadata -Name "finalModelPath" -Value $expectedFinal
    Save-AFJson -Value $GenerationMetadata -Path $Layout.GenerationMetadataPath

    Write-AFOk "Reconstruction 3D multi-vues terminée"
    Write-AFOk "Modèle brut : $expectedRaw"
    Write-AFOk "Modèle final : $expectedFinal"
    Write-AFOk "Métadonnées : $GeometryMetadataPath"
    $result = [ordered]@{
        kind = "asset-factory-multiview-3d"
        status = "completed"
        generationId = $(Get-AFProperty $GenerationMetadata "generationId" "$AssetId-$AssetVersion")
        assetId = $AssetId
        assetVersion = $AssetVersion
        generationRoot = $Layout.Root
        engine = "trellis"
        meshPath = $expectedFinal
        rawMeshPath = $expectedRaw
        metadataPath = $GeometryMetadataPath
        unrealStatus = $GeometryMetadata.unreal.status
    }
    Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
    $ExitCode = 0
}
catch {
    $message = $_.Exception.Message
    Write-AFFail $message
    if ($null -ne $GeometryMetadata -and $null -ne $GeometryMetadataPath) {
        $GeometryMetadata.status = "failed"
        $GeometryMetadata.completedAt = (Get-Date).ToString("o")
        $GeometryMetadata.failedStage = $Stage
        $GeometryMetadata.error = $message
        try { Save-AFJson -Value $GeometryMetadata -Path $GeometryMetadataPath } catch { }
    }
    if ($null -ne $GenerationMetadata -and $null -ne $Layout) {
        Set-JsonProperty -Object $GenerationMetadata -Name "status" -Value "failed"
        Set-JsonProperty -Object $GenerationMetadata -Name "failedStage" -Value $Stage
        Set-JsonProperty -Object $GenerationMetadata -Name "error" -Value $message
        try { Save-AFJson -Value $GenerationMetadata -Path $Layout.GenerationMetadataPath } catch { }
    }
    if ($null -ne $Layout) { Write-AFInfo "Génération conservée : $($Layout.Root)" }
    $ExitCode = 1
}

exit $ExitCode
