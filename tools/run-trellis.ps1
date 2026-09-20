[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputPath,

    [string[]]$InputPaths = @(),

    [ValidateSet("stochastic", "multidiffusion")]
    [string]$MultiImageMode = "stochastic",

    [string]$OutputDir,
    [string]$GenerationRoot = "",
    [string]$AssetVersion = "",
    [string]$ModelsDir,
    [ValidateRange(0, [long]::MaxValue)]
    [long]$Seed = 1,
    [double]$Simplify = 0.95,
    [int]$TextureSize = 1024,
    [switch]$GeometryOnly,
    [switch]$SavePly,
    [switch]$SelfTest,
    [switch]$CheckModels,

    [Alias("ProfilePath")]
    [string]$ProjectProfile = "",

    [string]$AssetId = "",
    [string]$Category = "",
    [System.Nullable[bool]]$AutoImport = $null,
    [switch]$PipelineManaged
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$AssetFactoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot "pipeline-common.ps1")
$TrellisRoot = Join-Path $AssetFactoryRoot "engines\trellis"
$TrellisPython = Join-Path $TrellisRoot ".venv-runtime\Scripts\python.exe"
$Adapter = Join-Path $PSScriptRoot "run_trellis.py"
$CompatRoot = Join-Path $PSScriptRoot "trellis_compat"
$UnrealImportRunner = Join-Path $PSScriptRoot "import-unreal.ps1"

function Get-TrellisVs2022Toolchain {
    $pf86 = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFilesX86)
    if ([string]::IsNullOrWhiteSpace($pf86)) {
        throw "Impossible de localiser Program Files (x86) pour detecter Visual Studio 2022."
    }

    $vs2022Root = Join-Path $pf86 "Microsoft Visual Studio\2022"
    if (-not (Test-Path -LiteralPath $vs2022Root -PathType Container)) {
        throw "Visual Studio 2022 avec les outils C++ est requis pour TRELLIS. Lancez '.\setup-asset-factory.ps1 trellis runtime-install'."
    }

    $roots = @(Get-ChildItem -LiteralPath $vs2022Root -Directory -ErrorAction SilentlyContinue)
    foreach ($root in $roots) {
        $vcvars = Join-Path $root.FullName "VC\Auxiliary\Build\vcvars64.bat"
        $msvcRoot = Join-Path $root.FullName "VC\Tools\MSVC"
        if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf) -or
            -not (Test-Path -LiteralPath $msvcRoot -PathType Container)) {
            continue
        }

        $toolsets = @(Get-ChildItem -LiteralPath $msvcRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($toolset in $toolsets) {
            $cl = Join-Path $toolset.FullName "bin\Hostx64\x64\cl.exe"
            if (Test-Path -LiteralPath $cl -PathType Leaf) {
                return [pscustomobject]@{
                    VsRoot = $root.FullName
                    Edition = $root.Name
                    Toolset = $toolset.Name
                    ClPath = $cl
                    VcVarsPath = $vcvars
                }
            }
        }
    }

    throw "Visual Studio 2022 C++ Build Tools (cl.exe) est introuvable. Lancez '.\setup-asset-factory.ps1 trellis runtime-install'."
}

function Import-TrellisVs2022Environment {
    param([Parameter(Mandatory)]$Toolchain)

    $cmd = Join-Path $env:SystemRoot "System32\cmd.exe"
    if (-not (Test-Path -LiteralPath $cmd -PathType Leaf)) {
        throw "cmd.exe est requis pour initialiser l'environnement de compilation Visual Studio 2022."
    }

    # vcvars64.bat doit etre execute dans un environnement enfant propre. Cela evite
    # d'heriter d'anciennes variables Visual Studio/CUDA susceptibles de depasser la
    # longueur maximale de ligne de cmd.exe ou de selectionner un autre toolset.
    $wrapper = Join-Path ([System.IO.Path]::GetTempPath()) ("asset-factory-vsenv-" + [guid]::NewGuid().ToString("N") + ".cmd")
    $wrapperLines = @(
        "@echo off",
        ("call `"{0}`" >nul" -f $Toolchain.VcVarsPath),
        "if errorlevel 1 exit /b %errorlevel%",
        "set"
    )
    [System.IO.File]::WriteAllLines($wrapper, $wrapperLines, [System.Text.Encoding]::ASCII)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd
    $psi.Arguments = "/d /c `"$wrapper`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables.Clear()

    $cleanVars = @(
        "SystemRoot", "WINDIR", "SystemDrive", "ComSpec",
        "TEMP", "TMP", "USERPROFILE", "HOMEDRIVE", "HOMEPATH",
        "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData",
        "LOCALAPPDATA", "APPDATA",
        "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER",
        "PROCESSOR_LEVEL", "PROCESSOR_REVISION", "NUMBER_OF_PROCESSORS",
        "OS", "PATHEXT"
    )

    foreach ($name in $cleanVars) {
        $value = [System.Environment]::GetEnvironmentVariable($name, "Process")
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $psi.EnvironmentVariables[$name] = $value
        }
    }

    $psi.EnvironmentVariables["PATH"] = @(
        (Join-Path $env:SystemRoot "System32"),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot "System32\Wbem"),
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0")
    ) -join ";"

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) {
            throw "Impossible de demarrer cmd.exe pour initialiser Visual Studio 2022."
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -ne 0) {
        $detail = (($stdout + [Environment]::NewLine + $stderr) -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " | "
        throw "Impossible d'initialiser l'environnement Visual Studio 2022 : $detail"
    }

    $allowed = @(
        "PATH", "INCLUDE", "LIB", "LIBPATH",
        "VCINSTALLDIR", "VCToolsInstallDir", "VCToolsRedistDir",
        "VSINSTALLDIR", "VisualStudioVersion",
        "WindowsSdkDir", "WindowsSDKVersion", "WindowsSDKLibVersion",
        "UniversalCRTSdkDir", "UCRTVersion",
        "FrameworkDir", "FrameworkDir64", "FrameworkVersion", "FrameworkVersion64"
    )

    foreach ($line in ($stdout -split "`r?`n")) {
        $separator = $line.IndexOf("=")
        if ($separator -le 0) { continue }
        $name = $line.Substring(0, $separator)
        if ($allowed -notcontains $name) { continue }
        [System.Environment]::SetEnvironmentVariable($name, $line.Substring($separator + 1), "Process")
    }
}

function Initialize-TrellisNativeBuildEnvironment {
    param([Parameter(Mandatory)][string]$RuntimeScripts)

    $toolchain = Get-TrellisVs2022Toolchain
    Import-TrellisVs2022Environment -Toolchain $toolchain

    $cudaRoot = Join-Path $env:ProgramFiles "NVIDIA GPU Computing Toolkit\CUDA\v13.4"
    $cudaBin = Join-Path $cudaRoot "bin"
    $nvcc = Join-Path $cudaBin "nvcc.exe"
    if (-not (Test-Path -LiteralPath $nvcc -PathType Leaf)) {
        throw "CUDA Toolkit 13.4 (nvcc.exe) est requis pour TRELLIS. Lancez '.\setup-asset-factory.ps1 trellis runtime-install'."
    }

    # Place les outils du venv, CUDA et MSVC en tete du PATH afin que les builds JIT
    # de cumm/spconv retrouvent ninja, nvcc et cl.exe dans un nouveau terminal.
    $prefixes = @((Split-Path -Parent $toolchain.ClPath), $cudaBin, $RuntimeScripts)
    foreach ($entry in $prefixes) {
        if ($env:Path -notlike "$entry;*") {
            $env:Path = "$entry;$env:Path"
        }
    }

    $env:CUDA_HOME = $cudaRoot
    $env:CUDA_PATH = $cudaRoot
    $env:CUDACXX = $nvcc
    $env:CUDAHOSTCXX = $toolchain.ClPath
    $env:CC = $toolchain.ClPath
    $env:CXX = $toolchain.ClPath
    $env:DISTUTILS_USE_SDK = "1"
    $env:MSSdk = "1"
    $env:TORCH_CUDA_ARCH_LIST = "12.0"
    $env:CUMM_CUDA_ARCH_LIST = "12.0"
    $env:MAX_JOBS = "1"

    if ([string]::IsNullOrWhiteSpace($env:CL)) {
        $env:CL = "/Zc:preprocessor"
    } elseif ($env:CL -notmatch '(^|\s)/Zc:preprocessor($|\s)') {
        $env:CL = "$env:CL /Zc:preprocessor"
    }

    $resolvedCl = Get-Command cl.exe -CommandType Application -ErrorAction SilentlyContinue
    $resolvedNvcc = Get-Command nvcc.exe -CommandType Application -ErrorAction SilentlyContinue
    $resolvedNinja = Get-Command ninja.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $resolvedCl) { throw "cl.exe reste introuvable apres l'initialisation de Visual Studio 2022." }
    if ($null -eq $resolvedNvcc) { throw "nvcc.exe reste introuvable apres l'initialisation de CUDA 13.4." }
    if ($null -eq $resolvedNinja) { throw "ninja.exe reste introuvable dans le runtime TRELLIS." }

    Write-Host "[OK] Compilateur MSVC : $($resolvedCl.Path)"
    Write-Host "[OK] Compilateur CUDA : $($resolvedNvcc.Path)"
    Write-Host "[OK] Outil de build Ninja : $($resolvedNinja.Path)"
}

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
if (-not [string]::IsNullOrWhiteSpace($InputPath) -and @($InputPaths).Count -gt 0) {
    throw "Utilisez -InputPath pour une image ou -InputPaths pour plusieurs images, pas les deux."
}
if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
    $InputPath = Resolve-AssetFactoryPath -Path $InputPath
}
if (@($InputPaths).Count -gt 0) {
    $resolvedInputPaths = @()
    foreach ($candidate in @($InputPaths)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            throw "InputPaths contient un chemin vide."
        }
        $resolvedInputPaths += Resolve-AssetFactoryPath -Path $candidate
    }
    $InputPaths = @($resolvedInputPaths)
}
if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Resolve-AssetFactoryPath -Path $OutputDir
}
if (-not [string]::IsNullOrWhiteSpace($GenerationRoot)) {
    $GenerationRoot = Resolve-AssetFactoryPath -Path $GenerationRoot
}
if (-not [string]::IsNullOrWhiteSpace($OutputDir) -and -not [string]::IsNullOrWhiteSpace($GenerationRoot)) {
    throw "Use either -GenerationRoot (recommended) or legacy -OutputDir, not both."
}
$OwnsGeneration = [string]::IsNullOrWhiteSpace($OutputDir) -and [string]::IsNullOrWhiteSpace($GenerationRoot)
if ([string]::IsNullOrWhiteSpace($ModelsDir)) {
    $ModelsDir = Join-Path $AssetFactoryRoot "models\trellis"
} else {
    $ModelsDir = Resolve-AssetFactoryPath -Path $ModelsDir
}

$nativeEnvironmentNames = @(
    "Path", "INCLUDE", "LIB", "LIBPATH",
    "VCINSTALLDIR", "VCToolsInstallDir", "VCToolsRedistDir",
    "VSINSTALLDIR", "VisualStudioVersion",
    "WindowsSdkDir", "WindowsSDKVersion", "WindowsSDKLibVersion",
    "UniversalCRTSdkDir", "UCRTVersion",
    "FrameworkDir", "FrameworkDir64", "FrameworkVersion", "FrameworkVersion64",
    "CUDA_HOME", "CUDA_PATH", "CUDACXX", "CUDAHOSTCXX",
    "CC", "CXX", "DISTUTILS_USE_SDK", "MSSdk", "CL",
    "TORCH_CUDA_ARCH_LIST", "CUMM_CUDA_ARCH_LIST", "MAX_JOBS",
    "PYTHONNOUSERSITE", "SPARSE_ATTN_BACKEND", "ATTN_BACKEND", "SPCONV_ALGO"
)
$oldNativeEnvironment = @{}
foreach ($name in $nativeEnvironmentNames) {
    $oldNativeEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, "Process")
}

$TrellisScripts = Split-Path -Parent $TrellisPython
$env:PYTHONNOUSERSITE = "1"
$env:ATTN_BACKEND = "sdpa"
$env:SPARSE_ATTN_BACKEND = "xformers"
$env:SPCONV_ALGO = "native"

$metadata = $null
$metadataPath = $null
$layout = $null
$StandaloneGeneration = $null
$StandaloneGenerationPath = $null
$previousLocation = Get-Location
try {
    Set-Location -LiteralPath $AssetFactoryRoot

    if ($SelfTest) {
        Write-Host "[INFO] Test de la couche de compatibilité SDPA TRELLIS..."
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
        Write-Host "[OK] Test de compatibilité SDPA TRELLIS réussi."
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

    $resolvedInputs = @()
    if (@($InputPaths).Count -gt 0) {
        $resolvedInputs = @($InputPaths)
    } elseif (-not [string]::IsNullOrWhiteSpace($InputPath)) {
        $resolvedInputs = @($InputPath)
    }
    if ($resolvedInputs.Count -eq 0) {
        throw "-InputPath ou -InputPaths est requis sauf avec -SelfTest ou -CheckModels."
    }
    foreach ($resolvedInput in $resolvedInputs) {
        if (-not (Test-Path -LiteralPath $resolvedInput -PathType Leaf)) {
            throw "Image d'entrée introuvable : $resolvedInput"
        }
        if ([System.IO.Path]::GetExtension($resolvedInput).ToLowerInvariant() -notin @(".png", ".jpg", ".jpeg", ".webp")) {
            throw "Les entrées TRELLIS doivent être des images PNG, JPEG ou WebP : $resolvedInput"
        }
    }
    $isMultiImage = $resolvedInputs.Count -gt 1

    $effectiveAssetId = $AssetId
    if ([string]::IsNullOrWhiteSpace($effectiveAssetId)) {
        $effectiveAssetId = [System.IO.Path]::GetFileNameWithoutExtension($resolvedInputs[0])
    }
    Assert-AFFileStem -Name $effectiveAssetId

    $layout = $null
    $metadataPath = $null
    $metadata = $null
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        $layout = Resolve-AFGenerationLayout `
            -Root $AssetFactoryRoot `
            -AssetId $effectiveAssetId `
            -GenerationRoot $GenerationRoot `
            -Version $AssetVersion
        $resolvedOutput = $layout.RawDir
        if ($isMultiImage) {
            # Dans un pipeline multi-vues, les images sont déjà versionnées sous source/views.
            # Un lancement TRELLIS direct conserve en revanche une copie des entrées dans sa génération.
            if ($OwnsGeneration) {
                $trellisInputsDir = Join-Path $layout.SourceDir "trellis-inputs"
                New-Item -ItemType Directory -Path $trellisInputsDir -Force | Out-Null
                $storedInputs = @()
                for ($index = 0; $index -lt $resolvedInputs.Count; $index++) {
                    $source = $resolvedInputs[$index]
                    $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
                    $stored = Join-Path $trellisInputsDir ("{0}_view_{1:D2}{2}" -f $effectiveAssetId, ($index + 1), $extension)
                    if (Test-Path -LiteralPath $stored) {
                        throw "Une entrée TRELLIS existe déjà dans la génération : $stored"
                    }
                    Copy-Item -LiteralPath $source -Destination $stored
                    $storedInputs += $stored
                }
                $resolvedInputs = @($storedInputs)
            }
        } else {
            $resolvedInput = $resolvedInputs[0]
            $extension = [System.IO.Path]::GetExtension($resolvedInput).ToLowerInvariant()
            $storedInput = Join-Path $layout.SourceDir ($effectiveAssetId + $extension)
            if ([System.IO.Path]::GetFullPath($resolvedInput) -ne [System.IO.Path]::GetFullPath($storedInput)) {
                if (Test-Path -LiteralPath $storedInput) {
                    throw "L'image source de la génération existe déjà ; refus de l'écraser : $storedInput"
                }
                Copy-Item -LiteralPath $resolvedInput -Destination $storedInput
            }
            $resolvedInputs = @($storedInput)
        }
        $metadataPath = Join-Path $layout.MetadataDir "trellis.json"
        $metadata = [ordered]@{
            schemaVersion = 4
            assetId = $effectiveAssetId
            assetVersion = $layout.Version
            generationRoot = $layout.Root
            createdAt = (Get-Date).ToString("o")
            completedAt = $null
            status = "running"
            inputMode = $(if ($isMultiImage) { "multi-image" } else { "single-image" })
            inputPath = $(if ($isMultiImage) { $null } else { $resolvedInputs[0] })
            inputPaths = @($resolvedInputs)
            multiImageMode = $(if ($isMultiImage) { $MultiImageMode } else { $null })
            glbPath = $null
            plyPath = $null
            seed = $Seed
            simplify = $Simplify
            textureSize = $TextureSize
            error = $null
        }
        Save-AFJson -Value $metadata -Path $metadataPath
        if ($OwnsGeneration) {
            $StandaloneGenerationPath = $layout.GenerationMetadataPath
            $StandaloneGeneration = [ordered]@{
                schemaVersion = 3
                generationId = "$effectiveAssetId-$($layout.Version)"
                assetId = $effectiveAssetId
                assetVersion = $layout.Version
                generationRoot = $layout.Root
                type = "engine-only"
                engine = "trellis"
                createdAt = $metadata.createdAt
                completedAt = $null
                status = "running"
                imagePath = $(if ($isMultiImage) { $null } else { $resolvedInputs[0] })
                inputPaths = @($resolvedInputs)
                rawModelPath = $null
                metadataPath = $metadataPath
                unreal = [ordered]@{ status = "pending"; assetVersion = $null; destinationPath = $null }
                error = $null
            }
            Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath
        }
    } else {
        # Compatibilité avec les anciens appels explicites : -OutputDir désigne directement
        # le dossier brut. Les nouveaux pipelines utilisent -GenerationRoot.
        $resolvedOutput = Resolve-AssetFactoryPath -Path $OutputDir
    }

    New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
    $assetName = $(if ($isMultiImage) { $effectiveAssetId } else { [System.IO.Path]::GetFileNameWithoutExtension($resolvedInputs[0]) })
    $expectedGlb = Join-Path $resolvedOutput ($assetName + ".glb")
    if (Test-Path -LiteralPath $expectedGlb) {
        throw "TRELLIS output already exists; refusing to overwrite it: $expectedGlb"
    }
    if ($SavePly) {
        $expectedPly = Join-Path $resolvedOutput ($assetName + ".ply")
        if (Test-Path -LiteralPath $expectedPly) {
            throw "TRELLIS PLY output already exists; refusing to overwrite it: $expectedPly"
        }
    }
    $unrealConfig = Resolve-UnrealImportConfiguration -ResolvedInput $resolvedInputs[0]

    Write-Host "[INFO] Exécution de TRELLIS via l’adaptateur SDPA Asset Factory..."
    if ($isMultiImage) {
        Write-Host "[INFO] Entrées multi-vues : $($resolvedInputs.Count) images"
        Write-Host "[INFO] Fusion TRELLIS : $MultiImageMode"
    } else {
        Write-Host "[INFO] Entrée : $($resolvedInputs[0])"
    }
    Write-Host "[INFO] Sortie : $resolvedOutput"
    if ($null -ne $layout) { Write-Host "[INFO] Génération : $($layout.Root)" }
    Write-Host "[INFO] Modèles : $ModelsDir (mode hors ligne)"
    if (-not $PipelineManaged) {
        if ($unrealConfig.autoImport) {
            Write-Host "[INFO] Import Unreal direct : activé"
        } elseif ($unrealConfig.enabled) {
            Write-Host "[INFO] Import Unreal direct : désactivé"
        }
    }

    $arguments = @(
        "-B", "-s", "-u",
        $Adapter,
        "--models-dir", $ModelsDir,
        "--output-dir", $resolvedOutput,
        "--seed", $Seed.ToString(),
        "--simplify", $Simplify.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        "--texture-size", $TextureSize.ToString(),
        "--multi-image-mode", $MultiImageMode
    )
    if ($isMultiImage) {
        $arguments += @("--asset-id", $effectiveAssetId)
    }
    foreach ($resolvedInput in $resolvedInputs) {
        $arguments += @("--input", $resolvedInput)
    }
    if ($GeometryOnly) {
        $arguments += "--geometry-only"
        Write-Host "[INFO] Mode géométrie seule : la texture sera produite par le pipeline multi-vues Blender."
    }
    if ($SavePly) {
        $arguments += "--save-ply"
    }

    Initialize-TrellisNativeBuildEnvironment -RuntimeScripts $TrellisScripts
    Write-Host "[INFO] Backend natif cumm/spconv : réutilisation du cache si valide ; recompilation uniquement si le cache est absent ou invalidé."

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

    $glb = $expectedGlb
    if (-not (Test-Path -LiteralPath $glb -PathType Leaf)) {
        throw "TRELLIS returned success but the expected GLB was not produced: $glb"
    }
    if ((Get-Item -LiteralPath $glb).Length -le 0) {
        throw "TRELLIS produced an empty GLB: $glb"
    }

    if ($null -ne $metadata) {
        $metadata.status = "completed"
        $metadata.completedAt = (Get-Date).ToString("o")
        $metadata.glbPath = $glb
        if ($SavePly) {
            $plyPath = Join-Path $resolvedOutput ($assetName + ".ply")
            if (Test-Path -LiteralPath $plyPath -PathType Leaf) { $metadata.plyPath = $plyPath }
        }
        Save-AFJson -Value $metadata -Path $metadataPath
    }
    if ($null -ne $StandaloneGeneration) {
        $StandaloneGeneration.rawModelPath = $glb
        Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath
    }

    Write-Host "[OK] GLB TRELLIS généré : $glb"
    if ($null -ne $layout) {
        Write-Host "[OK] Génération : $($layout.Root)"
        if (-not [string]::IsNullOrWhiteSpace($layout.Version)) { Write-Host "[OK] Version : $($layout.Version)" }
        Write-Host "[OK] Métadonnées : $metadataPath"
    }

    # Python s'est arrêté ; TRELLIS n'occupe donc plus la mémoire GPU au démarrage d'Unreal.
    if ($unrealConfig.autoImport) {
        Write-Host "[INFO] Import du GLB généré dans Unreal Engine..."
        $global:LASTEXITCODE = 0
        $importParameters = @{
            ProfilePath = $unrealConfig.profilePath
            SourcePath = $glb
            AssetId = $unrealConfig.assetId
            Category = $unrealConfig.category
        }
        if ($null -ne $layout -and -not [string]::IsNullOrWhiteSpace($layout.Version)) {
            $importParameters.AssetVersion = $layout.Version
            $importParameters.MetadataPath = (Join-Path $layout.MetadataDir "unreal.json")
            $importParameters.LogPath = (Join-Path $layout.LogsDir "unreal.log")
        }
        & $UnrealImportRunner @importParameters
        $importExitCode = $LASTEXITCODE

        if ($importExitCode -ne 0) {
            throw "Unreal import failed. The generated GLB is preserved: $glb. Retry with tools\import-unreal.ps1; no generation is needed."
        }
        if ($null -ne $StandaloneGeneration) {
            $StandaloneGeneration.unreal.status = "completed"
            $unrealMetadataPath = Join-Path $layout.MetadataDir "unreal.json"
            if (Test-Path -LiteralPath $unrealMetadataPath -PathType Leaf) {
                $unrealMetadata = Get-Content -LiteralPath $unrealMetadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $StandaloneGeneration.unreal.assetVersion = $unrealMetadata.assetVersion
                $StandaloneGeneration.unreal.destinationPath = $unrealMetadata.destinationPath
            }
        }
        Write-Host "[OK] Import Unreal automatique terminé."
    } elseif ($unrealConfig.enabled) {
        if (-not $PipelineManaged) {
            Write-Host "[INFO] Import Unreal automatique désactivé. Le GLB est conservé pour un import manuel."
        }
    } else {
        if (-not $PipelineManaged) {
            Write-Host "[INFO] Aucun profil Unreal sélectionné. Utilisez -ProjectProfile pour activer l’import."
        }
        if ($null -ne $StandaloneGeneration) { $StandaloneGeneration.unreal.status = "not-configured" }
    }

    if ($null -ne $StandaloneGeneration) {
        if ($StandaloneGeneration.unreal.status -eq "pending") { $StandaloneGeneration.unreal.status = "skipped" }
        $StandaloneGeneration.status = "completed"
        $StandaloneGeneration.completedAt = (Get-Date).ToString("o")
        Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath
        Write-Host "[OK] Métadonnées de génération : $StandaloneGenerationPath"
    }
} catch {
    if ($null -ne $metadata -and $null -ne $metadataPath) {
        $metadata.status = "failed"
        $metadata.completedAt = (Get-Date).ToString("o")
        $metadata.error = $_.Exception.Message
        try { Save-AFJson -Value $metadata -Path $metadataPath } catch { }
    }
    if ($null -ne $StandaloneGeneration -and $null -ne $StandaloneGenerationPath) {
        $StandaloneGeneration.status = "failed"
        $StandaloneGeneration.completedAt = (Get-Date).ToString("o")
        $StandaloneGeneration.error = $_.Exception.Message
        if ($StandaloneGeneration.unreal.status -eq "pending") { $StandaloneGeneration.unreal.status = "failed" }
        try { Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath } catch { }
    }
    throw
} finally {
    Set-Location -LiteralPath $previousLocation

    foreach ($name in $nativeEnvironmentNames) {
        [System.Environment]::SetEnvironmentVariable($name, $oldNativeEnvironment[$name], "Process")
    }
}
