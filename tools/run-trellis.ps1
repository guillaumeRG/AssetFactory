[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputPath,

    [string]$OutputDir,
    [string]$ModelsDir,
    [ValidateRange(0, [long]::MaxValue)]
    [long]$Seed = 1,
    [double]$Simplify = 0.95,
    [int]$TextureSize = 1024,
    [switch]$SavePly,
    [switch]$SelfTest,
    [switch]$CheckModels,

    [Alias("ProfilePath")]
    [string]$ProjectProfile = "",

    [string]$AssetId = "",
    [string]$Category = "",
    [System.Nullable[bool]]$AutoImport = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$TrellisRoot = Join-Path $AssetFactoryRoot "engines\trellis"
$TrellisPython = Join-Path $TrellisRoot ".venv-runtime\Scripts\python.exe"
$Adapter = Join-Path $PSScriptRoot "run_trellis.py"
$CompatRoot = Join-Path $PSScriptRoot "trellis_compat"
$UnrealImportRunner = Join-Path $PSScriptRoot "import-unreal.ps1"

function Resolve-UnrealImportConfiguration {
    param([Parameter(Mandatory)][string]$ResolvedInput)

    $effectiveAssetId = $AssetId
    if ([string]::IsNullOrWhiteSpace($effectiveAssetId)) {
        $effectiveAssetId = [System.IO.Path]::GetFileNameWithoutExtension($ResolvedInput)
    }

    $result = [ordered]@{
        enabled = $false
        profilePath = $null
        autoImport = $false
        assetId = $effectiveAssetId
        category = $Category
    }

    if ([string]::IsNullOrWhiteSpace($ProjectProfile)) {
        if ($null -ne $AutoImport -and [bool]$AutoImport) {
            throw "-ProjectProfile is required when -AutoImport is true."
        }
        return $result
    }

    # Les profils de projet utilisent des chemins relatifs au projet, comme dans run-image-to-3d.ps1.
    $resolvedProfile = $ProjectProfile
    if (-not [System.IO.Path]::IsPathRooted($resolvedProfile)) {
        $resolvedProfile = Join-Path $AssetFactoryRoot $resolvedProfile
    }
    $resolvedProfile = [System.IO.Path]::GetFullPath($resolvedProfile)
    if (-not (Test-Path -LiteralPath $resolvedProfile -PathType Leaf)) {
        throw "Project profile not found: $resolvedProfile"
    }

    $profile = Get-Content -LiteralPath $resolvedProfile -Raw -Encoding UTF8 | ConvertFrom-Json
    $effectiveAutoImport = $false
    if ($profile.PSObject.Properties.Name -contains "autoImport") {
        if ($profile.autoImport -isnot [bool]) {
            throw "Profile autoImport must be a JSON boolean (true or false)."
        }
        $effectiveAutoImport = [bool]$profile.autoImport
    }
    if ($null -ne $AutoImport) {
        $effectiveAutoImport = [bool]$AutoImport
    }

    if ($effectiveAutoImport) {
        if (-not (Test-Path -LiteralPath $UnrealImportRunner -PathType Leaf)) {
            throw "Unreal import runner not found: $UnrealImportRunner"
        }
        # Valide la destination avant de consacrer du temps à la génération de l'asset.
        foreach ($property in @("engine", "projectPath", "contentRoot")) {
            if (-not ($profile.PSObject.Properties.Name -contains $property) -or
                [string]::IsNullOrWhiteSpace([string]$profile.$property)) {
                throw "Unreal profile is missing $property."
            }
        }
        if ([string]$profile.engine -ne "unreal") {
            throw "Profile engine must be 'unreal'."
        }
        if ([string]$profile.contentRoot -notmatch '^/Game(?:/|$)') {
            throw "Profile contentRoot must be /Game or a folder under /Game."
        }
        $projectPath = [string]$profile.projectPath
        if (-not [System.IO.Path]::IsPathRooted($projectPath)) {
            $projectPath = Join-Path (Split-Path -Parent $resolvedProfile) $projectPath
        }
        if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf) -or
            [System.IO.Path]::GetExtension($projectPath) -ne ".uproject") {
            throw "Unreal project not found or not a .uproject file: $projectPath"
        }
    }

    $result.enabled = $true
    $result.profilePath = $resolvedProfile
    $result.autoImport = $effectiveAutoImport
    return $result
}

function Resolve-AssetFactoryPath {
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

if (-not (Test-Path -LiteralPath $TrellisPython -PathType Leaf)) {
    throw "TRELLIS runtime Python is missing: $TrellisPython"
}
if (-not (Test-Path -LiteralPath $Adapter -PathType Leaf)) {
    throw "Asset Factory TRELLIS adapter is missing: $Adapter"
}
if (-not (Test-Path -LiteralPath $CompatRoot -PathType Container)) {
    throw "Asset Factory TRELLIS compatibility layer is missing: $CompatRoot"
}

# Résout les chemins dans le répertoire de l'appelant avant de changer de répertoire de travail.
if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
    $InputPath = Resolve-AssetFactoryPath -Path $InputPath
}
if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Resolve-AssetFactoryPath -Path $OutputDir
}
if ([string]::IsNullOrWhiteSpace($ModelsDir)) {
    $ModelsDir = Join-Path $AssetFactoryRoot "models\trellis"
} else {
    $ModelsDir = Resolve-AssetFactoryPath -Path $ModelsDir
}

$oldNoUserSite = $env:PYTHONNOUSERSITE
$oldSparseBackend = $env:SPARSE_ATTN_BACKEND
$oldAttentionBackend = $env:ATTN_BACKEND
$oldSpconvAlgo = $env:SPCONV_ALGO

$env:PYTHONNOUSERSITE = "1"
$env:ATTN_BACKEND = "sdpa"
$env:SPARSE_ATTN_BACKEND = "xformers"
$env:SPCONV_ALGO = "native"

$previousLocation = Get-Location
try {
    Set-Location -LiteralPath $AssetFactoryRoot

    if ($SelfTest) {
        Write-Host "[INFO] Testing Asset Factory TRELLIS SDPA compatibility layer..."
        $nativePreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $TrellisPython -B -s -u $Adapter --self-test
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $nativePreference
        }
        if ($exitCode -ne 0) {
            throw "TRELLIS SDPA compatibility self-test failed with exit code $exitCode."
        }
        Write-Host "[OK] TRELLIS SDPA compatibility self-test passed."
        return
    }

    if ($CheckModels) {
        $nativePreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $TrellisPython -B -s -u $Adapter --check-models --models-dir $ModelsDir
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $nativePreference
        }
        if ($exitCode -ne 0) {
            throw "TRELLIS offline model check failed. Run 'trellis model-install'."
        }
        return
    }

    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        throw "-InputPath is required unless -SelfTest or -CheckModels is used."
    }

    $resolvedInput = Resolve-AssetFactoryPath -Path $InputPath
    if (-not (Test-Path -LiteralPath $resolvedInput -PathType Leaf)) {
        throw "Input image does not exist: $resolvedInput"
    }

    $unrealConfig = Resolve-UnrealImportConfiguration -ResolvedInput $resolvedInput

    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $resolvedOutput = Join-Path $AssetFactoryRoot "outputs\trellis\$stamp"
    } else {
        $resolvedOutput = Resolve-AssetFactoryPath -Path $OutputDir
    }

    New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null

    Write-Host "[INFO] Running TRELLIS through the Asset Factory SDPA adapter..."
    Write-Host "[INFO] Input: $resolvedInput"
    Write-Host "[INFO] Output: $resolvedOutput"
    Write-Host "[INFO] Models: $ModelsDir (offline mode)"
    Write-Host "[INFO] Automatic Unreal import: $($unrealConfig.autoImport)"

    $arguments = @(
        "-B", "-s", "-u",
        $Adapter,
        "--models-dir", $ModelsDir,
        "--input", $resolvedInput,
        "--output-dir", $resolvedOutput,
        "--seed", $Seed.ToString(),
        "--simplify", $Simplify.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        "--texture-size", $TextureSize.ToString()
    )
    if ($SavePly) {
        $arguments += "--save-ply"
    }

    # Les pipelines externes capturent stderr. Sous Windows PowerShell 5.1, les avertissements Python
    # sans gravité ne doivent pas devenir des enregistrements NativeCommandError fatals.
    $nativePreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $TrellisPython @arguments
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $nativePreference
    }

    if ($exitCode -ne 0) {
        throw "TRELLIS inference failed with exit code $exitCode."
    }

    $assetName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInput)
    $glb = Join-Path $resolvedOutput ($assetName + ".glb")
    if (-not (Test-Path -LiteralPath $glb -PathType Leaf)) {
        throw "TRELLIS returned success but the expected GLB was not produced: $glb"
    }
    if ((Get-Item -LiteralPath $glb).Length -le 0) {
        throw "TRELLIS produced an empty GLB: $glb"
    }

    Write-Host "[OK] TRELLIS GLB generated: $glb"

    # Python s'est arrêté ; TRELLIS n'occupe donc plus la mémoire GPU au démarrage d'Unreal.
    if ($unrealConfig.autoImport) {
        Write-Host "[INFO] Importing the generated GLB into Unreal..."
        $global:LASTEXITCODE = 0
        & $UnrealImportRunner `
            -ProfilePath $unrealConfig.profilePath `
            -SourcePath $glb `
            -AssetId $unrealConfig.assetId `
            -Category $unrealConfig.category
        $importExitCode = $LASTEXITCODE

        if ($importExitCode -ne 0) {
            throw "Unreal import failed. The generated GLB is preserved: $glb. Retry with tools\import-unreal.ps1; no generation is needed."
        }
        Write-Host "[OK] Automatic Unreal import completed."
    } elseif ($unrealConfig.enabled) {
        Write-Host "[INFO] Automatic Unreal import disabled by profile/argument. GLB kept for manual import."
    } else {
        Write-Host "[INFO] No Unreal profile selected. Use -ProjectProfile to enable the existing import workflow."
    }
} finally {
    Set-Location -LiteralPath $previousLocation

    if ($null -eq $oldNoUserSite) { Remove-Item Env:\PYTHONNOUSERSITE -ErrorAction SilentlyContinue } else { $env:PYTHONNOUSERSITE = $oldNoUserSite }
    if ($null -eq $oldSparseBackend) { Remove-Item Env:\SPARSE_ATTN_BACKEND -ErrorAction SilentlyContinue } else { $env:SPARSE_ATTN_BACKEND = $oldSparseBackend }
    if ($null -eq $oldAttentionBackend) { Remove-Item Env:\ATTN_BACKEND -ErrorAction SilentlyContinue } else { $env:ATTN_BACKEND = $oldAttentionBackend }
    if ($null -eq $oldSpconvAlgo) { Remove-Item Env:\SPCONV_ALGO -ErrorAction SilentlyContinue } else { $env:SPCONV_ALGO = $oldSpconvAlgo }
}
