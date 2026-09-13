[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BatchPath,

    [ValidateSet("images", "full")]
    [string]$Mode = "images",

    [ValidateSet("triposr", "trellis")]
    [string]$Engine = "trellis",

    [ValidateRange(1, 64)]
    [int]$Candidates = 1,
    [string]$Preset = "",
    [string[]]$Exclude = @(),
    [string]$MultiviewMethod = "none",

    [ValidateRange(0.001, 1000000.0)]
    [double]$TargetHeight = 1.0,
    [string]$ProjectProfile = "",
    [string]$Category = "",
    [System.Nullable[bool]]$AutoImport = $null,

    [string]$WorkflowPath = "workflows\comfyui-flux-schnell-base.json",
    [string]$ServerUrl = "http://127.0.0.1:8188",
    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 300,
    [bool]$ReleaseComfyMemory = $true,
    [string]$BlenderPath = "",

    [ValidateRange(0.0, 0.99)]
    [double]$TrellisSimplify = 0.95,
    [ValidateSet(512, 1024, 2048)]
    [int]$TrellisTextureSize = 1024
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")

$CommandOverrides = @{}
foreach ($key in $PSBoundParameters.Keys) { $CommandOverrides[$key] = $PSBoundParameters[$key] }

function Get-BatchSetting {
    param($Asset, $Batch, [string]$Property, [string]$Parameter, $Default)
    if ($CommandOverrides.ContainsKey($Parameter)) { return $CommandOverrides[$Parameter] }
    if ($null -ne $Asset -and $Asset.PSObject.Properties.Name -contains $Property) { return $Asset.$Property }
    return (Get-AFProperty $Batch $Property $Default)
}

$BatchMetadata = $null
$BatchMetadataPath = $null
$ActiveRecord = $null
$ExitCode = 1

try {
    $ResolvedBatchPath = Resolve-AFPath -Path $BatchPath -BasePath $AssetFactoryRoot
    Assert-AFFile -Path $ResolvedBatchPath -Label "Batch manifest"
    $Batch = Get-Content -LiteralPath $ResolvedBatchPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $BatchId = [string](Get-AFProperty $Batch "batchId" "")
    Assert-AFFileStem -Name $BatchId -Label "batchId"
    $Assets = @(Get-AFProperty $Batch "assets" @())
    if ($Assets.Count -eq 0) { throw "Batch contains no assets." }

    $EffectiveMode = [string](Get-BatchSetting $null $Batch "mode" "Mode" "images")
    $EffectiveMode = $EffectiveMode.ToLowerInvariant()
    if ($EffectiveMode -notin @("images", "full")) { throw "Batch mode must be 'images' or 'full'." }

    $ImageRunner = Join-Path $PSScriptRoot "generate-image.ps1"
    $AssetFromPromptRunner = Join-Path $PSScriptRoot "generate-asset-from-prompt.ps1"
    $AssetFromImageRunner = Join-Path $PSScriptRoot "generate-asset-from-image.ps1"
    Assert-AFFile -Path $ImageRunner -Label "Point d'entree generation d'image"
    if ($EffectiveMode -eq "full") {
        Assert-AFFile -Path $AssetFromPromptRunner -Label "Point d'entree asset depuis prompt"
        Assert-AFFile -Path $AssetFromImageRunner -Label "Point d'entree asset depuis image"
    }

    $SeenIds = @{}
    $Records = @()
    foreach ($Asset in $Assets) {
        $id = [string](Get-AFProperty $Asset "id" "")
        Assert-AFFileStem -Name $id
        if ($SeenIds.ContainsKey($id)) { throw "Duplicate asset id: $id" }
        $SeenIds[$id] = $true

        $prompt = [string](Get-AFProperty $Asset "prompt" "")
        $inputPath = [string](Get-AFProperty $Asset "inputPath" "")
        if ($EffectiveMode -eq "images" -or [string]::IsNullOrWhiteSpace($inputPath)) {
            if ([string]::IsNullOrWhiteSpace($prompt)) { throw "Asset '$id' is missing a non-empty prompt." }
        } else {
            $inputPath = Resolve-AFPath -Path $inputPath -BasePath $AssetFactoryRoot
            Assert-AFFile -Path $inputPath -Label "Batch input image"
        }

        $assetEngine = [string](Get-BatchSetting $Asset $Batch "engine" "Engine" "trellis")
        $assetEngine = $assetEngine.ToLowerInvariant()
        if ($assetEngine -notin @("triposr", "trellis")) {
            throw "Asset '$id': engine must be 'triposr' or 'trellis'."
        }

        $height = Get-BatchSetting $Asset $Batch "targetHeight" "TargetHeight" 1.0
        if ($height -is [string] -or $height -is [bool] -or $null -eq $height -or
            [double]$height -lt 0.001 -or [double]$height -gt 1000000.0 -or [double]::IsNaN([double]$height)) {
            throw "Asset '$id': targetHeight must be a JSON number between 0.001 and 1000000 metres."
        }
        $seed = Get-AFProperty $Asset "seed" 0
        if ($seed -is [string] -or $seed -is [bool] -or $null -eq $seed -or
            [decimal]$seed -lt 0 -or [decimal]$seed -gt [long]::MaxValue -or
            [decimal]$seed -ne [decimal]::Truncate([decimal]$seed)) {
            throw "Asset '$id': seed must be a non-negative 64-bit integer."
        }

        $candidates = Get-BatchSetting $Asset $Batch "candidates" "Candidates" 1
        if ($candidates -is [string] -or $candidates -is [bool] -or $null -eq $candidates -or
            [int]$candidates -lt 1 -or [int]$candidates -gt 64) {
            throw "Asset '$id': candidates must be an integer between 1 and 64."
        }
        $preset = [string](Get-BatchSetting $Asset $Batch "preset" "Preset" "")
        $exclude = @(Get-BatchSetting $Asset $Batch "exclude" "Exclude" @())
        $multiviewMethod = [string](Get-BatchSetting $Asset $Batch "multiviewMethod" "MultiviewMethod" "none")
        if ([string]::IsNullOrWhiteSpace($multiviewMethod)) { $multiviewMethod = "none" }

        $profile = [string](Get-BatchSetting $Asset $Batch "projectProfile" "ProjectProfile" "")
        $categoryValue = [string](Get-BatchSetting $Asset $Batch "category" "Category" "")
        $auto = Get-BatchSetting $Asset $Batch "autoImport" "AutoImport" $null
        if ($null -ne $auto -and $auto -isnot [bool]) { throw "Asset '$id': autoImport must be a JSON boolean." }
        $release = Get-BatchSetting $Asset $Batch "releaseComfyMemory" "ReleaseComfyMemory" $true
        if ($release -isnot [bool]) { throw "Asset '$id': releaseComfyMemory must be a JSON boolean." }
        $simplify = Get-BatchSetting $Asset $Batch "trellisSimplify" "TrellisSimplify" 0.95
        if ($simplify -is [string] -or $simplify -is [bool] -or $null -eq $simplify -or
            [double]$simplify -lt 0 -or [double]$simplify -gt 0.99 -or [double]::IsNaN([double]$simplify)) {
            throw "Asset '$id': trellisSimplify must be a JSON number between 0 and 0.99."
        }
        $textureSize = Get-BatchSetting $Asset $Batch "trellisTextureSize" "TrellisTextureSize" 1024
        if ($textureSize -is [string] -or $textureSize -is [bool] -or $textureSize -notin @(512, 1024, 2048)) {
            throw "Asset '$id': trellisTextureSize must be 512, 1024 or 2048."
        }

        if ($EffectiveMode -eq "full") {
            $null = Resolve-AFUnrealConfiguration -Root $AssetFactoryRoot `
                -ProjectProfile $profile -AutoImport $auto -AssetId $id -Category $categoryValue
            Assert-AFFile -Path (Join-Path $PSScriptRoot "run-$assetEngine.ps1") -Label "$assetEngine runner"
        }

        $Records += [ordered]@{
            id = $id
            prompt = $prompt
            inputPath = $inputPath
            negativePrompt = [string](Get-AFProperty $Asset "negativePrompt" "")
            seed = [long]$seed
            candidates = [int]$candidates
            preset = $preset
            exclude = @($exclude)
            multiviewMethod = $multiviewMethod
            engine = $assetEngine
            targetHeight = [double]$height
            projectProfile = $profile
            category = $categoryValue
            autoImport = $auto
            releaseComfyMemory = $release
            trellisSimplify = [double]$simplify
            trellisTextureSize = [int]$textureSize
            status = "pending"
            startedAt = $null
            completedAt = $null
            generationId = $null
            assetVersion = $null
            generationRoot = $null
            generationMetadataPath = $null
            imagePath = $null
            meshPath = $null
            sourceFormat = $null
            unrealStatus = $null
            unrealVersion = $null
            importedObjectPaths = @()
            failedStage = $null
            logPath = $null
            error = $null
        }
    }

    $BatchRunId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $BatchRoot = Join-Path $AssetFactoryRoot "outputs\batches\$BatchId\$BatchRunId"
    if (Test-Path -LiteralPath $BatchRoot) { throw "Batch output already exists: $BatchRoot" }
    $BatchLogsDir = Join-Path $BatchRoot "logs"
    New-Item -ItemType Directory -Path $BatchLogsDir -Force | Out-Null
    $BatchMetadataPath = Join-Path $BatchRoot "batch.json"

    $BatchMetadata = [ordered]@{
        schemaVersion = 3
        batchRunId = $BatchRunId
        batchId = $BatchId
        createdAt = (Get-Date).ToString("o")
        completedAt = $null
        status = "running"
        mode = $EffectiveMode
        manifestPath = $ResolvedBatchPath
        assetCount = $Records.Count
        assets = $Records
        error = $null
    }
    Save-AFJson $BatchMetadata $BatchMetadataPath
    Write-AFInfo "Batch: $BatchId / mode: $EffectiveMode / assets: $($Records.Count)"

    for ($index = 0; $index -lt $Records.Count; $index++) {
        $ActiveRecord = $Records[$index]
        $ActiveRecord.status = "running"
        $ActiveRecord.startedAt = (Get-Date).ToString("o")
        $ActiveRecord.logPath = Join-Path $BatchLogsDir ($ActiveRecord.id + ".log")
        Save-AFJson $BatchMetadata $BatchMetadataPath
        Write-AFInfo "Asset $($ActiveRecord.id) ($($index + 1)/$($Records.Count))"

        if ($EffectiveMode -eq "images") {
            $parameters = @{
                Prompt = $ActiveRecord.prompt
                NegativePrompt = $ActiveRecord.negativePrompt
                Seed = $ActiveRecord.seed
                AssetId = $ActiveRecord.id
                Candidates = $ActiveRecord.candidates
                Preset = $ActiveRecord.preset
                Exclude = @($ActiveRecord.exclude)
                WorkflowPath = $WorkflowPath
                ServerUrl = $ServerUrl
                TimeoutSeconds = $TimeoutSeconds
                ReleaseComfyMemory = $ActiveRecord.releaseComfyMemory
            }
            $result = Invoke-AFCommand -Executable $ImageRunner -LogPath $ActiveRecord.logPath -Parameters $parameters
            $resultJson = Get-AFOutputValue $result.Output "[RESULT_JSON] " -Optional
            if (-not [string]::IsNullOrWhiteSpace($resultJson)) {
                $summary = $resultJson | ConvertFrom-Json
                $ActiveRecord.generationId = $summary.generationId
                $ActiveRecord.assetVersion = $summary.assetVersion
                $ActiveRecord.generationRoot = $summary.generationRoot
                $ActiveRecord.generationMetadataPath = $summary.metadataPath
                $ActiveRecord.imagePath = $summary.imagePath
            }
            if ($result.ExitCode -ne 0) {
                $ActiveRecord.failedStage = "image"
                throw "Image generation failed for '$($ActiveRecord.id)'. See $($ActiveRecord.logPath)"
            }
            Assert-AFFile -Path $ActiveRecord.imagePath -Label "Batch image"
        } else {
            $commonParameters = @{
                AssetId = $ActiveRecord.id
                Seed = $ActiveRecord.seed
                GeometryMethod = $ActiveRecord.engine
                MultiviewMethod = $ActiveRecord.multiviewMethod
                TargetHeight = $ActiveRecord.targetHeight
                ProjectProfile = $ActiveRecord.projectProfile
                Category = $ActiveRecord.category
                TrellisSimplify = $ActiveRecord.trellisSimplify
                TrellisTextureSize = $ActiveRecord.trellisTextureSize
            }
            if ($null -ne $ActiveRecord.autoImport) { $commonParameters.AutoImport = [bool]$ActiveRecord.autoImport }
            if (-not [string]::IsNullOrWhiteSpace($BlenderPath)) { $commonParameters.BlenderPath = $BlenderPath }

            if ([string]::IsNullOrWhiteSpace($ActiveRecord.inputPath)) {
                $runner = $AssetFromPromptRunner
                $parameters = @{} + $commonParameters
                $parameters.Prompt = $ActiveRecord.prompt
                $parameters.NegativePrompt = $ActiveRecord.negativePrompt
                $parameters.Candidates = $ActiveRecord.candidates
                $parameters.Preset = $ActiveRecord.preset
                $parameters.Exclude = @($ActiveRecord.exclude)
                $parameters.WorkflowPath = $WorkflowPath
                $parameters.ServerUrl = $ServerUrl
                $parameters.TimeoutSeconds = $TimeoutSeconds
                $parameters.ReleaseComfyMemory = $ActiveRecord.releaseComfyMemory
            } else {
                $runner = $AssetFromImageRunner
                $parameters = @{} + $commonParameters
                $parameters.InputPath = $ActiveRecord.inputPath
            }

            $result = Invoke-AFCommand -Executable $runner -LogPath $ActiveRecord.logPath -Parameters $parameters
            $resultJson = Get-AFOutputValue $result.Output "[RESULT_JSON] " -Optional
            if (-not [string]::IsNullOrWhiteSpace($resultJson)) {
                $summary = $resultJson | ConvertFrom-Json
                $ActiveRecord.generationId = $summary.generationId
                $ActiveRecord.assetVersion = $summary.assetVersion
                $ActiveRecord.generationRoot = $summary.generationRoot
                $ActiveRecord.generationMetadataPath = $summary.metadataPath
                $ActiveRecord.imagePath = $summary.imagePath
                $ActiveRecord.meshPath = $summary.meshPath
                $ActiveRecord.failedStage = $summary.failedStage
            }

            if ($ActiveRecord.generationMetadataPath -and
                (Test-Path -LiteralPath $ActiveRecord.generationMetadataPath -PathType Leaf)) {
                $generation = Get-Content -LiteralPath $ActiveRecord.generationMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $ActiveRecord.sourceFormat = $generation.importSourceFormat
                $ActiveRecord.unrealStatus = $generation.unreal.status
                $ActiveRecord.unrealVersion = $generation.unreal.assetVersion
                $ActiveRecord.importedObjectPaths = @($generation.unreal.importedObjectPaths)
                $ActiveRecord.failedStage = $generation.failedStage
            }

            if ($result.ExitCode -ne 0) {
                throw "Generation failed for '$($ActiveRecord.id)'. See $($ActiveRecord.logPath)"
            }
            if ([string]::IsNullOrWhiteSpace($ActiveRecord.meshPath)) {
                throw "Generation returned no final model for '$($ActiveRecord.id)'."
            }
            Assert-AFFile -Path $ActiveRecord.meshPath -Label "Final batch model"
        }

        $ActiveRecord.status = "completed"
        $ActiveRecord.completedAt = (Get-Date).ToString("o")
        Save-AFJson $BatchMetadata $BatchMetadataPath
        $ActiveRecord = $null
    }

    $BatchMetadata.status = "completed"
    $ExitCode = 0
}
catch {
    $message = $_.Exception.Message
    if ($null -ne $ActiveRecord) {
        $ActiveRecord.status = "failed"
        $ActiveRecord.error = $message
        $ActiveRecord.completedAt = (Get-Date).ToString("o")
    }
    if ($null -ne $BatchMetadata) {
        $BatchMetadata.status = "failed"
        $BatchMetadata.error = $message
    }
    Write-AFFail $message
    $ExitCode = 1
}
finally {
    if ($null -ne $BatchMetadata) {
        $BatchMetadata.completedAt = (Get-Date).ToString("o")
        Save-AFJson $BatchMetadata $BatchMetadataPath
    }
}

if ($BatchMetadataPath) { Write-AFInfo "Batch metadata: $BatchMetadataPath" }
if ($ExitCode -eq 0) {
    Write-AFOk "Batch completed: $BatchId / $BatchRunId"
    Write-AFOk "Metadata: $BatchMetadataPath"
}
exit $ExitCode
