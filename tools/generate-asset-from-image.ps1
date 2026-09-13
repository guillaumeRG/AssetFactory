[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [string]$AssetId = "",

    [ValidateSet("trellis", "triposr")]
    [string]$GeometryMethod = "trellis",

    [string]$MultiviewMethod = "none",

    [ValidateRange(0, [long]::MaxValue)]
    [long]$Seed = 0,

    [ValidateRange(0.001, 1000000.0)]
    [double]$TargetHeight = 1.0,

    [string]$ProjectProfile = "",
    [string]$Category = "",
    [System.Nullable[bool]]$AutoImport = $null,

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

    [string]$BlenderPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")
Import-Module (Join-Path $PSScriptRoot "internal\AssetFactory.Pipeline.psm1") -Force

try {
    $resolvedInput = Resolve-AFPath -Path $InputPath -BasePath (Get-Location).Path
    Assert-AFFile -Path $resolvedInput -Label "Image d'entree"
    if ([System.IO.Path]::GetExtension($resolvedInput).ToLowerInvariant() -notin @(".png", ".jpg", ".jpeg", ".webp")) {
        throw "InputPath doit etre une image PNG, JPEG ou WebP."
    }

    if ([string]::IsNullOrWhiteSpace($AssetId)) {
        $AssetId = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInput)
    }
    Assert-AFFileStem -Name $AssetId

    $result = Invoke-AFAssetPipeline `
        -InputKind Image `
        -InputPath $resolvedInput `
        -AssetId $AssetId `
        -Seed $Seed `
        -GeometryMethod $GeometryMethod `
        -MultiviewMethod $MultiviewMethod `
        -TargetHeight $TargetHeight `
        -ProjectProfile $ProjectProfile `
        -Category $Category `
        -AutoImport $AutoImport `
        -TrellisSimplify $TrellisSimplify `
        -TrellisTextureSize $TrellisTextureSize `
        -MultiviewProfile $MultiviewProfile `
        -FusionMode $FusionMode `
        -IncludeReference $IncludeReference `
        -ViewPolicy $ViewPolicy `
        -MaxViews $MaxViews `
        -MinViewScore $MinViewScore `
        -BlenderPath $BlenderPath

    Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
    exit 0
}
catch {
    Write-AFFail $_.Exception.Message
    exit 1
}
