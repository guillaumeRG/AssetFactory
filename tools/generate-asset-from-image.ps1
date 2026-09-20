[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [string]$AssetId = "",

    [ValidateSet("trellis", "triposr")]
    [string]$GeometryMethod = "trellis",

    [ValidateRange(0, [long]::MaxValue)]
    [long]$Seed = 0,

    [bool]$Multiview = $false,
    [ValidateRange(1, 100)]
    [int]$MultiviewCameras = 8,
    [ValidateRange(256, 8192)]
    [int]$TextureResolution = 2048,
    [string]$TextureCheckpoint = "RealVisXL_V5.0_fp16.safetensors",
    [string]$TexturePrompt = "",
    [string]$TextureNegativePrompt = "",
    [bool]$KeepProjectedBlend = $false,

    [ValidateRange(0.001, 1000000.0)]
    [double]$TargetHeight = 1.0,

    [string]$ProjectProfile = "",
    [string]$Category = "",
    [System.Nullable[bool]]$AutoImport = $null,

    [ValidateRange(0.0, 0.99)]
    [double]$TrellisSimplify = 0.95,
    [ValidateSet(512, 1024, 2048)]
    [int]$TrellisTextureSize = 1024,

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
    $resolvedInput = Resolve-AFPath -Path $InputPath -BasePath (Get-Location).Path
    Assert-AFFile -Path $resolvedInput -Label "Image d'entree"
    if ([System.IO.Path]::GetExtension($resolvedInput).ToLowerInvariant() -notin @(".png", ".jpg", ".jpeg", ".webp")) {
        throw "InputPath doit etre une image PNG, JPEG ou WebP."
    }

    if ([string]::IsNullOrWhiteSpace($AssetId)) {
        $AssetId = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInput)
    }
    Assert-AFFileStem -Name $AssetId

    if ($Multiview -and [string]::IsNullOrWhiteSpace($TexturePrompt)) {
        throw "-TexturePrompt est requis avec -Multiview `$true pour une entrée image."
    }

    $result = Invoke-AFAssetPipeline `
        -InputKind Image `
        -InputPath $resolvedInput `
        -AssetId $AssetId `
        -Seed $Seed `
        -GeometryMethod $GeometryMethod `
        -Multiview $Multiview `
        -MultiviewCameras $MultiviewCameras `
        -TextureResolution $TextureResolution `
        -TextureCheckpoint $TextureCheckpoint `
        -TexturePrompt $TexturePrompt `
        -TextureNegativePrompt $TextureNegativePrompt `
        -KeepProjectedBlend $KeepProjectedBlend `
        -TargetHeight $TargetHeight `
        -ProjectProfile $ProjectProfile `
        -Category $Category `
        -AutoImport $AutoImport `
        -TrellisSimplify $TrellisSimplify `
        -TrellisTextureSize $TrellisTextureSize `
        -Postprocess $Postprocess `
        -BlenderPath $BlenderPath

    Write-Output ("[RESULT_JSON] " + ($result | ConvertTo-Json -Compress))
    exit 0
}
catch {
    Write-AFFail $_.Exception.Message
    exit 1
}
