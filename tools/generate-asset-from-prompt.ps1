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

    [ValidateSet("trellis", "triposr")]
    [string]$GeometryMethod = "trellis",

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

    [ValidateRange(0.0, 0.99)]
    [double]$TrellisSimplify = 0.95,
    [ValidateSet(512, 1024, 2048)]
    [int]$TrellisTextureSize = 1024,

    [string]$MultiviewProfile = "",
    [string]$FusionMode = "",
    [System.Nullable[bool]]$IncludeReference = $null,
    [string]$ViewPolicy = "",
    [System.Nullable[int]]$MaxViews = $null,
    [System.Nullable[double]]$MinViewScore = $null,

    [ValidateSet("none", "qa")]
    [string]$Postprocess = "none",
    [string]$BlenderPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")
Import-Module (Join-Path $PSScriptRoot "internal\AssetFactory.Pipeline.psm1") -Force

try {
    Assert-AFFileStem -Name $AssetId

    $result = Invoke-AFAssetPipeline `
        -InputKind Prompt `
        -Prompt $Prompt `
        -NegativePrompt $NegativePrompt `
        -AssetId $AssetId `
        -Seed $Seed `
        -Candidates $Candidates `
        -Preset $Preset `
        -Exclude @($Exclude) `
        -GeometryMethod $GeometryMethod `
        -MultiviewMethod $MultiviewMethod `
        -TargetHeight $TargetHeight `
        -ProjectProfile $ProjectProfile `
        -Category $Category `
        -AutoImport $AutoImport `
        -TrellisSimplify $TrellisSimplify `
        -TrellisTextureSize $TrellisTextureSize `
        -WorkflowPath $WorkflowPath `
        -ServerUrl $ServerUrl `
        -TimeoutSeconds $TimeoutSeconds `
        -ReleaseComfyMemory $ReleaseComfyMemory `
        -MultiviewProfile $MultiviewProfile `
        -FusionMode $FusionMode `
        -IncludeReference $IncludeReference `
        -ViewPolicy $ViewPolicy `
        -MaxViews $MaxViews `
        -MinViewScore $MinViewScore `
        -Postprocess $Postprocess `
        -BlenderPath $BlenderPath

    Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
    exit 0
}
catch {
    Write-AFFail $_.Exception.Message
    exit 1
}
