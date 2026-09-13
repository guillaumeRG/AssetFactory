[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Prompt,

    [string]$NegativePrompt = "",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$AssetId,

    [ValidateRange(0, [long]::MaxValue)]
    [long]$Seed = 0,

    [ValidateRange(1, 64)]
    [int]$Candidates = 1,

    [string]$Preset = "",
    [string[]]$Exclude = @(),
    [string]$AssetVersion = "",

    [string]$WorkflowPath = "workflows\comfyui-flux-schnell-base.json",
    [string]$ServerUrl = "http://127.0.0.1:8188",
    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 300,
    [bool]$ReleaseComfyMemory = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")
Import-Module (Join-Path $PSScriptRoot "internal\AssetFactory.Pipeline.psm1") -Force

$layout = $null
$metadata = $null

try {
    Assert-AFFileStem -Name $AssetId
    if (-not [string]::IsNullOrWhiteSpace($AssetVersion)) {
        Assert-AFAssetVersion -Version $AssetVersion
    }

    $layout = New-AFAssetGeneration -Root $AssetFactoryRoot -AssetId $AssetId -Version $AssetVersion
    $metadata = [ordered]@{
        schemaVersion = 4
        generationId = "$AssetId-$($layout.Version)"
        assetId = $AssetId
        assetVersion = $layout.Version
        generationRoot = $layout.Root
        type = "image"
        createdAt = (Get-Date).ToString("o")
        completedAt = $null
        status = "running"
        failedStage = $null
        error = $null
        image = [ordered]@{
            method = "comfyui"
            prompt = $Prompt
            negativePrompt = $NegativePrompt
            candidateCount = $Candidates
            preset = $(if ([string]::IsNullOrWhiteSpace($Preset)) { $null } else { $Preset })
            excludedDetails = @($Exclude)
            seed = $Seed
            path = $null
            selectionReportPath = $null
            candidates = @()
        }
    }
    Save-AFJson -Value $metadata -Path $layout.GenerationMetadataPath

    Write-AFInfo "Generation d'image : $AssetId / $($layout.Version)"
    Write-AFInfo "Candidats : $Candidates"

    $result = Invoke-AFImageStage `
        -Prompt $Prompt `
        -NegativePrompt $NegativePrompt `
        -AssetId $AssetId `
        -GenerationRoot $layout.Root `
        -AssetVersion $layout.Version `
        -Seed $Seed `
        -Candidates $Candidates `
        -Preset $Preset `
        -Exclude @($Exclude) `
        -Purpose source `
        -WorkflowPath $WorkflowPath `
        -ServerUrl $ServerUrl `
        -TimeoutSeconds $TimeoutSeconds `
        -ReleaseComfyMemory $ReleaseComfyMemory

    $metadata.status = "completed"
    $metadata.completedAt = (Get-Date).ToString("o")
    $metadata.image.promptUsed = $result.PromptUsed
    $metadata.image.negativePromptUsed = $result.NegativePromptUsed
    $metadata.image.preset = $result.Preset
    $metadata.image.path = $result.ImagePath
    $metadata.image.selectionReportPath = $result.QualityPath
    $metadata.image.candidates = @($result.CandidatePaths)
    Save-AFJson -Value $metadata -Path $layout.GenerationMetadataPath

    Write-AFOk "Image selectionnee : $($result.ImagePath)"
    Write-AFOk "Generation : $($layout.Root)"
    Write-AFOk "Rapport : $($result.QualityPath)"

    $summary = [ordered]@{
        kind = "asset-factory-image"
        status = "completed"
        generationId = $metadata.generationId
        assetId = $AssetId
        assetVersion = $layout.Version
        generationRoot = $layout.Root
        imagePath = $result.ImagePath
        candidateCount = $Candidates
        selectionReportPath = $result.QualityPath
        metadataPath = $layout.GenerationMetadataPath
    }
    Write-Output ("[RESULT_JSON] " + ($summary | ConvertTo-Json -Compress))
    exit 0
}
catch {
    $message = $_.Exception.Message
    if ($null -ne $metadata -and $null -ne $layout) {
        $metadata.status = "failed"
        $metadata.completedAt = (Get-Date).ToString("o")
        $metadata.failedStage = "image"
        $metadata.error = $message
        try { Save-AFJson -Value $metadata -Path $layout.GenerationMetadataPath } catch { }
    }
    Write-AFFail $message
    if ($null -ne $layout) { Write-AFInfo "Generation conservee : $($layout.Root)" }
    exit 1
}
