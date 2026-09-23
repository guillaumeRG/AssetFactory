[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "status", "doctor", "triposr", "comfyui", "trellis", "multiview", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [Alias("TriposrCommand", "ComfyUiCommand", "TrellisCommand", "MultiViewCommand")]
    [ValidateSet("install", "status", "doctor", "repair", "smoke", "model-install", "model-status", "runtime-install", "runtime-status", "runtime-doctor", "native-install", "native-status", "native-doctor")]
    [string]$EngineCommand = "status",

    [string]$Method = "projection",

    [switch]$NoInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.7.1"
$ProjectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$MinimumPowerShellVersion = [version]"5.1"
$Script:HadWarnings = $false
$Script:TrellisVsEnvironmentLoaded = $false

$RequiredDirs = @(
    "engines",
    "blender\scripts",
    "outputs",
    "outputs\assets",
    "outputs\batches",
    "outputs\imports",
    "outputs\tests",
    "outputs\diagnostics",
    "outputs\.locks",
    "tools",
    "workflows",
    "batches",
    "docs",
    "config",
    "profiles",
    "unreal"
)

# Configuration du moteur TripoSR. Le moteur est installé localement sous engines/triposr
# et est volontairement isolé du Python de bootstrap partagé.
$TripoSrRepoUrl = "https://github.com/VAST-AI-Research/TripoSR"
$TripoSrRoot = Join-Path $ProjectRoot "engines\triposr"
$TripoSrVenv = Join-Path $TripoSrRoot ".venv"
$TripoSrVenvPython = Join-Path $TripoSrVenv "Scripts\python.exe"
$TripoSrRequirements = Join-Path $TripoSrRoot "requirements.txt"
$TripoSrPreferredPythonVersions = @("3.11", "3.10")


# Configuration de TRELLIS v1.
#
# AF-08A conserve un checkout officiel de TRELLIS isolé sous engines/trellis.
# AF-08B ajoute un second environnement virtuel d'exécution Python 3.12 afin que les essais avec les versions modernes
# de PyTorch/CUDA ne modifient ni ComfyUI, ni TripoSR, ni le Python global, ni
# l'environnement virtuel de bootstrap initial.
$TrellisRepoUrl = "https://github.com/microsoft/TRELLIS.git"
$TrellisPinnedCommit = "442aa1e"
$TrellisPinnedFlexiCubesCommit = "815e075a2a400d06c48d94c347674344ed6ae5c5"
$TrellisRoot = Join-Path $ProjectRoot "engines\trellis"

$TrellisBootstrapVenv = Join-Path $TrellisRoot ".venv"
$TrellisBootstrapVenvPython = Join-Path $TrellisBootstrapVenv "Scripts\python.exe"
$TrellisBootstrapPythonVersion = "3.10"

$TrellisRuntimeVenv = Join-Path $TrellisRoot ".venv-runtime"
$TrellisRuntimeVenvPython = Join-Path $TrellisRuntimeVenv "Scripts\python.exe"
$TrellisRuntimePythonVersion = "3.12"

# Wheels PyTorch officiels. Les bibliothèques d'exécution CUDA 13 sont fournies par le wheel ;
# l'installation globale d'un CUDA Toolkit 13 n'est volontairement PAS requise ici.
# Le CUDA Toolkit 12.8 local reste inchangé pour les moteurs existants.
$TrellisTorchVersion = "2.13.0"
$TrellisTorchIndexUrl = "https://download.pytorch.org/whl/cu130"
$TrellisExpectedTorchCuda = "13.0"

$TrellisAttentionBackend = "sdpa"


# Sources des extensions natives de l'étape 2 d'AF-08C. Elles restent dans l'arborescence
# d'exécution TRELLIS ignorée afin qu'aucun checkout de source tiers ne soit versionné.
$TrellisNativeExtensionsRoot = Join-Path $TrellisRoot ".asset-factory-extensions"
$TrellisCummRepoUrl = "https://github.com/FindDefinition/cumm.git"
$TrellisSpconvRepoUrl = "https://github.com/traveller59/spconv.git"
$TrellisNvdiffrastRepoUrl = "https://github.com/NVlabs/nvdiffrast.git"
$TrellisNvdiffrastRef = "253ac4fcea7de5f396371124af597e6cc957bfae"
$TrellisDiffOctreeRepoUrl = "https://github.com/JeffreyXiang/diffoctreerast.git"
$TrellisMipSplattingRepoUrl = "https://github.com/autonomousvision/mip-splatting.git"
$TrellisKaolinRepoUrl = "https://github.com/NVIDIAGameWorks/kaolin.git"
$TrellisKaolinRef = "v0.18.0"



# Les extensions CUDA natives de TRELLIS ne sont volontairement pas installées dans la v0.6.1.
# Le setup.sh amont ne prend pas en charge la matrice moderne Windows/PyTorch/CUDA
# que nous ciblons. Nous validons d'abord la base d'exécution, puis ajoutons un à un
# les composants natifs open source/précompilés épinglés dans AF-08C.
$TrellisBasicPackages = @(
    "pillow",
    "imageio",
    "imageio-ffmpeg",
    "tqdm",
    "easydict",
    "opencv-python-headless",
    "scipy",
    "ninja",
    "rembg",
    "onnxruntime",
    "trimesh",
    "xatlas",
    "pyvista",
    "open3d",
    "pymeshfix",
    "igraph",
    "transformers",
    "huggingface_hub"
)

# Configuration du moteur ComfyUI. Le dépôt d'exécution, l'environnement virtuel et les modèles restent locaux.
$ComfyUiRepoUrl = "https://github.com/Comfy-Org/ComfyUI.git"
$ComfyUiPinnedRef = "v0.35.0"
$ComfyUiExpectedVersion = "0.35.0"
$ComfyUiRoot = Join-Path $ProjectRoot "engines\comfyui"
$ComfyUiVenv = Join-Path $ComfyUiRoot ".venv"
$ComfyUiVenvPython = Join-Path $ComfyUiVenv "Scripts\python.exe"
$ComfyUiRequirements = Join-Path $ComfyUiRoot "requirements.txt"
$ComfyUiMain = Join-Path $ComfyUiRoot "main.py"
$ComfyUiPreferredPythonVersion = "3.11"
$ComfyUiTorchIndexUrl = "https://download.pytorch.org/whl/cu130"
$ComfyUiExpectedTorchCuda = "13.0"
$ComfyUiSmokeHost = "127.0.0.1"
$ComfyUiSmokeTimeoutSeconds = 180

# Checkpoint FLUX Schnell utilisé par le workflow d'image Asset Factory validé.
# Le modèle n'est volontairement pas stocké dans Git car il s'agit d'une donnée d'exécution volumineuse.
$ComfyUiFluxRepoId = "Comfy-Org/flux1-schnell"
$ComfyUiFluxFileName = "flux1-schnell-fp8.safetensors"
$ComfyUiFluxModelsDir = Join-Path $ComfyUiRoot "models\checkpoints"
$ComfyUiFluxModelPath = Join-Path $ComfyUiFluxModelsDir $ComfyUiFluxFileName

# Configuration des méthodes image-vers-multi-vues. La première implémentation

# Le mode multi-vues réutilise ComfyUI et Blender déjà gérés par Asset Factory.
# Aucun runtime de génération de vues 2D séparé n'est installé.
$MultiViewDepsRoot = Join-Path $ProjectRoot "cache\multiview\blender-python"
$MultiViewVendorRoot = Join-Path $ProjectRoot "vendor\StableGen\stablegen"
$MultiViewDriver = Join-Path $ProjectRoot "tools\internal\multiview_texture_driver.py"
$MultiViewCheckpoint = Join-Path $ComfyUiRoot "models\checkpoints\RealVisXL_V5.0_fp16.safetensors"
$MultiViewDepthModel = Join-Path $ComfyUiRoot "models\controlnet\controlnet_depth_sdxl.safetensors"
$MultiViewLightningLora = Join-Path $ComfyUiRoot "models\loras\sdxl_lightning_8step_lora.safetensors"

function Write-Header {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ""
    Write-Host "=== Asset Factory $Title ===" -ForegroundColor Cyan
}

function Write-Result {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("OK", "WARN", "MISSING", "FAIL", "INFO")]
        [string]$State,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $prefix = "[$State]"
    switch ($State) {
        "OK"      { Write-Host "$prefix $Message" -ForegroundColor Green }
        "WARN"    { $Script:HadWarnings = $true; Write-Host "$prefix $Message" -ForegroundColor Yellow }
        "MISSING" { $Script:HadWarnings = $true; Write-Host "$prefix $Message" -ForegroundColor Yellow }
        "FAIL"    { Write-Host "$prefix $Message" -ForegroundColor Red }
        default   { Write-Host "$prefix $Message" }
    }
}

function Test-IsWindows {
    # $IsWindows n'existe que dans PowerShell Core. Cette méthode prend aussi en charge Windows PowerShell 5.1.
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Refresh-ProcessPath {
    if (-not (Test-IsWindows)) {
        return
    }

    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")

    # Conserve aussi les entrées PATH locales au processus ; le setup a pu être lancé depuis un
    # shell ayant injecté des chemins utiles non persistés aux niveaux Utilisateur/Machine.
    $allEntries = New-Object System.Collections.Generic.List[string]
    foreach ($rawPath in @($env:Path, $machinePath, $userPath)) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) {
            continue
        }

        foreach ($entry in $rawPath.Split(";")) {
            $trimmed = $entry.Trim()
            if (-not $trimmed) {
                continue
            }

            $exists = $false
            foreach ($known in $allEntries) {
                if ([string]::Equals($known, $trimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $exists = $true
                    break
                }
            }

            if (-not $exists) {
                $allEntries.Add($trimmed)
            }
        }
    }

    $env:Path = $allEntries -join ";"
}

function Assert-BootstrapHost {
    if (-not (Test-IsWindows)) {
        throw "This bootstrap currently supports Windows only."
    }

    if ($PSVersionTable.PSVersion -lt $MinimumPowerShellVersion) {
        throw "PowerShell $MinimumPowerShellVersion or newer is required. Detected: $($PSVersionTable.PSVersion)."
    }
}

function Get-ExecutablePath {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Path)) {
            return $cmd.Path
        }
    }

    return $null
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $null
    )

    # Ne pas utiliser `2>&1` de PowerShell ici. Sous Windows PowerShell 5.1,
    # stderr d'un exécutable natif peut devenir une NativeCommandError
    # fatale lorsque $ErrorActionPreference = "Stop".
    #
    # Un code de sortie natif non nul est une donnée que l'appelant doit examiner,
    # pas une exception PowerShell. System.Diagnostics.Process fournit une capture
    # déterministe de stdout/stderr aussi bien sous Windows PowerShell 5.1
    # que sous PowerShell 7+.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
            throw "Working directory does not exist: $WorkingDirectory"
        }
        $psi.WorkingDirectory = $WorkingDirectory
    }

    # ProcessStartInfo.ArgumentList n'est pas disponible dans le .NET Framework utilisé
    # par Windows PowerShell 5.1 ; on construit donc une chaîne d'arguments correctement échappée.
    $quotedArgs = foreach ($arg in $Arguments) {
        if ($null -eq $arg) {
            '""'
            continue
        }

        $text = [string]$arg
        if ($text -notmatch '[\s"]') {
            $text
            continue
        }

        # Échappement de ligne de commande Windows compatible avec CommandLineToArgvW :
        # échappe les antislashs précédant un guillemet, échappe les guillemets et double
        # les antislashs finaux avant le guillemet fermant.
        $escaped = [regex]::Replace($text, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }

    $psi.Arguments = ($quotedArgs -join ' ')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            throw "Could not start native executable: $Executable"
        }

        # Lit les deux flux redirigés de façon suffisamment asynchrone pour éviter
        # le blocage classique dû à un tampon plein, puis attend la fin du processus.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }

    $stdoutLines = @()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $stdoutLines = @($stdout -split "\r?\n" | Where-Object { $_ -ne "" })
    }

    $stderrLines = @()
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $stderrLines = @($stderr -split "\r?\n" | Where-Object { $_ -ne "" })
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($stdoutLines + $stderrLines)
        StdOut = @($stdoutLines)
        StdErr = @($stderrLines)
    }
}

function Test-Winget {
    return $null -ne (Get-ExecutablePath @("winget.exe", "winget"))
}

function Get-GitInfo {
    $path = Get-ExecutablePath @("git.exe", "git")

    # La configuration de l'environnement de compilation natif peut réécrire temporairement PATH. Git pour
    # Windows est normalement installé dans l'un de ces emplacements stables ; on les teste donc
    # directement au lieu de considérer PATH comme l'unique source de vérité.
    if (-not $path) {
        $candidates = @()

        if ($env:ProgramFiles) {
            $candidates += (Join-Path $env:ProgramFiles "Git\cmd\git.exe")
            $candidates += (Join-Path $env:ProgramFiles "Git\bin\git.exe")
        }

        $programFilesX86 = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFilesX86)
        if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
            $candidates += (Join-Path $programFilesX86 "Git\cmd\git.exe")
            $candidates += (Join-Path $programFilesX86 "Git\bin\git.exe")
        }

        if ($env:LOCALAPPDATA) {
            $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe")
            $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Git\bin\git.exe")
        }

        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $path = $candidate
                break
            }
        }
    }

    if (-not $path) {
        return [pscustomobject]@{ Installed = $false; Path = $null; Version = $null }
    }

    try {
        $result = Invoke-NativeCapture -Executable $path -Arguments @("--version")
        if ($result.ExitCode -ne 0) {
            throw "git --version returned exit code $($result.ExitCode)"
        }

        return [pscustomobject]@{
            Installed = $true
            Path = $path
            Version = ($result.Output | Select-Object -First 1).ToString().Trim()
        }
    } catch {
        return [pscustomobject]@{ Installed = $false; Path = $path; Version = $null }
    }
}

function Get-PythonInfo {
    $candidates = New-Object System.Collections.Generic.List[object]

    $pyLauncher = Get-ExecutablePath @("py.exe", "py")
    if ($pyLauncher) {
        try {
            $exeResult = Invoke-NativeCapture -Executable $pyLauncher -Arguments @("-3", "-c", "import sys; print(sys.executable)")
            $versionResult = Invoke-NativeCapture -Executable $pyLauncher -Arguments @("-3", "--version")
            if ($exeResult.ExitCode -eq 0 -and $versionResult.ExitCode -eq 0) {
                $exe = ($exeResult.Output | Select-Object -First 1).ToString().Trim()
                if ($exe -and (Test-Path -LiteralPath $exe)) {
                    $candidates.Add([pscustomobject]@{
                        Installed = $true
                        Path = $exe
                        Version = ($versionResult.Output | Select-Object -First 1).ToString().Trim()
                        Launcher = $pyLauncher
                    })
                }
            }
        } catch {}
    }

    foreach ($name in @("python.exe", "python3.exe", "python", "python3")) {
        $path = Get-ExecutablePath @($name)
        if (-not $path) {
            continue
        }

        # Ignore les alias du Windows Store qui peuvent exister sans véritable installation de Python.
        if ($path -match "WindowsApps") {
            continue
        }

        try {
            $exeResult = Invoke-NativeCapture -Executable $path -Arguments @("-c", "import sys; print(sys.executable)")
            $versionResult = Invoke-NativeCapture -Executable $path -Arguments @("--version")
            if ($exeResult.ExitCode -eq 0 -and $versionResult.ExitCode -eq 0) {
                $resolved = ($exeResult.Output | Select-Object -First 1).ToString().Trim()
                if ($resolved -and (Test-Path -LiteralPath $resolved)) {
                    $alreadyKnown = $false
                    foreach ($candidate in $candidates) {
                        if ($candidate.Path -eq $resolved) {
                            $alreadyKnown = $true
                            break
                        }
                    }
                    if (-not $alreadyKnown) {
                        $candidates.Add([pscustomobject]@{
                            Installed = $true
                            Path = $resolved
                            Version = ($versionResult.Output | Select-Object -First 1).ToString().Trim()
                            Launcher = $null
                        })
                    }
                }
            }
        } catch {}
    }

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    return [pscustomobject]@{ Installed = $false; Path = $null; Version = $null; Launcher = $null }
}

function Get-BlenderInfo {
    $path = Get-ExecutablePath @("blender.exe", "blender")

    if (-not $path) {
        $patterns = @()
        if ($env:ProgramFiles) {
            $patterns += (Join-Path $env:ProgramFiles "Blender Foundation\Blender*\blender.exe")
        }
        if ($env:LOCALAPPDATA) {
            $patterns += (Join-Path $env:LOCALAPPDATA "Programs\Blender Foundation\Blender*\blender.exe")
        }

        $matches = @()
        foreach ($pattern in $patterns) {
            $matches += Get-Item -Path $pattern -ErrorAction SilentlyContinue
        }

        $path = $matches |
            Sort-Object { [System.Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName).FileVersion } -Descending |
            Select-Object -First 1 |
            ForEach-Object { $_.FullName }
    }

    if (-not $path) {
        return [pscustomobject]@{ Installed = $false; Path = $null; Version = $null }
    }

    try {
        $result = Invoke-NativeCapture -Executable $path -Arguments @("--version")
        $version = if ($result.ExitCode -eq 0) { ($result.Output | Select-Object -First 1).ToString().Trim() } else { $null }
        return [pscustomobject]@{ Installed = $true; Path = $path; Version = $version }
    } catch {
        return [pscustomobject]@{ Installed = $false; Path = $path; Version = $null }
    }
}

function Get-NvidiaInfo {
    $path = Get-ExecutablePath @("nvidia-smi.exe", "nvidia-smi")

    if (-not $path -and $env:ProgramFiles) {
        $fallback = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"
        if (Test-Path -LiteralPath $fallback) {
            $path = $fallback
        }
    }

    if (-not $path) {
        return [pscustomobject]@{ Available = $false; Name = $null; DriverVersion = $null; VramMiB = $null }
    }

    try {
        $result = Invoke-NativeCapture -Executable $path -Arguments @(
            "--query-gpu=name,driver_version,memory.total",
            "--format=csv,noheader,nounits"
        )

        if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) {
            throw "nvidia-smi query failed"
        }

        $row = ($result.Output | Select-Object -First 1).ToString()
        $parts = @($row.Split(",") | ForEach-Object { $_.Trim() })
        if ($parts.Count -lt 3) {
            throw "Unexpected nvidia-smi output: $row"
        }

        $vram = 0
        if (-not [int]::TryParse($parts[2], [ref]$vram)) {
            throw "Could not parse NVIDIA VRAM value '$($parts[2])'"
        }

        return [pscustomobject]@{
            Available = $true
            Name = $parts[0]
            DriverVersion = $parts[1]
            VramMiB = $vram
        }
    } catch {
        return [pscustomobject]@{ Available = $false; Name = $null; DriverVersion = $null; VramMiB = $null }
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $winget = Get-ExecutablePath @("winget.exe", "winget")
    if (-not $winget) {
        throw "winget is not available. Install App Installer or install $DisplayName manually."
    }

    Write-Result "INFO" "Installing $DisplayName via winget..."

    $result = Invoke-NativeCapture -Executable $winget -Arguments @(
        "install",
        "--id", $Id,
        "--exact",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent",
        "--disable-interactivity"
    )

    if ($result.ExitCode -ne 0) {
        $details = ($result.Output | Select-Object -Last 8) -join [Environment]::NewLine
        throw "winget failed while installing $DisplayName (exit code $($result.ExitCode)).`n$details"
    }

    Refresh-ProcessPath
    Write-Result "OK" "$DisplayName installation completed"
}

function Assert-DetectedAfterInstall {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][scriptblock]$Detector
    )

    Refresh-ProcessPath
    $detected = & $Detector
    if (-not $detected) {
        throw "$DisplayName installation completed, but the executable is still not detectable. Open a new terminal and rerun 'status'."
    }
}

function Ensure-Directories {
    foreach ($relativePath in $RequiredDirs) {
        $fullPath = Join-Path $ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath)) {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
            Write-Result "OK" "Created $relativePath"
        } else {
            Write-Result "OK" "$relativePath already exists"
        }
    }
}

function Ensure-GitIgnore {
    $gitignorePath = Join-Path $ProjectRoot ".gitignore"
    $requiredLines = @(
        ".venv/",
        "**/.venv/",
        "__pycache__/",
        "*.pyc",
        ".pytest_cache/",
        ".mypy_cache/",
        ".ruff_cache/",
        ".vs/",
        ".vscode/settings.json",
        ".vscode/*.log",
        "outputs/**",
        "!outputs/.gitkeep",
        "models/",
        "cache/",
        "engines/triposr/",
        "engines/comfyui/",
        "engines/trellis/",
        "profiles/*.json",
        "!profiles/unreal.example.json",
        "*.log",
        "*.tmp"
    )

    $existing = @()
    if (Test-Path -LiteralPath $gitignorePath) {
        $existing = @(Get-Content -LiteralPath $gitignorePath)
    }

    $toAdd = @($requiredLines | Where-Object { $_ -notin $existing })
    if ($toAdd.Count -gt 0) {
        if ((Test-Path -LiteralPath $gitignorePath) -and (Get-Item -LiteralPath $gitignorePath).Length -gt 0) {
            Add-Content -LiteralPath $gitignorePath -Value ""
        }
        Add-Content -LiteralPath $gitignorePath -Value $toAdd
        Write-Result "OK" "Updated .gitignore"
    } else {
        Write-Result "OK" ".gitignore already contains required entries"
    }

    $keep = Join-Path $ProjectRoot "outputs\.gitkeep"
    if (-not (Test-Path -LiteralPath $keep)) {
        New-Item -ItemType File -Path $keep -Force | Out-Null
    }
}

function Ensure-DocumentationSkeleton {
    $docs = @{
        "PROJECT_OVERVIEW.md" = "# Asset Factory - Vue d'ensemble du projet`r`n`r`nContexte canonique du projet. Compléter et faire évoluer ce document à mesure que les décisions sont validées.`r`n"
        "ARCHITECTURE.md" = "# Asset Factory - Architecture`r`n`r`nConserver une architecture simple, testable, reproductible, modulaire et remplaçable.`r`n"
        "V0_FUELTANK_T1.md" = "# V0 - FuelTank_T1`r`n`r`nSpécification de preuve de concept pour le premier pipeline Asset Factory.`r`n"
        "DEVELOPMENT_POLICY.md" = "# Politique de développement`r`n`r`nPrivilégier les modifications petites et réversibles. Ne pas ajouter d'infrastructure en dehors du jalon actif.`r`n"
        "DEXTER_POLICY.md" = "# Politique Dexter`r`n`r`nDexter reçoit des tâches petites, explicites et testables, avec un périmètre de fichiers limité.`r`n"
        "ENVIRONMENT.md" = "# Environnement`r`n`r`nConsigner ici les outils hôtes validés et les environnements propres à chaque moteur.`r`n"
        "QA_POLICY.md" = "# Politique QA`r`n`r`nLa QA technique est déterministe. La validation artistique reste humaine.`r`n"
    }

    foreach ($name in $docs.Keys) {
        $path = Join-Path (Join-Path $ProjectRoot "docs") $name
        if (-not (Test-Path -LiteralPath $path)) {
            Set-Content -LiteralPath $path -Value $docs[$name] -Encoding UTF8
            Write-Result "OK" "Created docs\$name"
        }
    }
}

function Ensure-Readme {
    $readmePath = Join-Path $ProjectRoot "README.md"
    if (Test-Path -LiteralPath $readmePath) {
        return
    }

    $content = @"
# Asset Factory

Chaîne locale, modulaire et reproductible de génération et de préparation d'assets.

Les moteurs IA sont isolés, remplaçables et validés indépendamment avant leur
intégration dans le pipeline de production.

Voir `docs/PROJECT_OVERVIEW.md`, `docs/ARCHITECTURE.md` et `docs/QA_POLICY.md`.
"@
    Set-Content -LiteralPath $readmePath -Value $content -Encoding UTF8
    Write-Result "OK" "Created README.md"
}

function Ensure-GitRepository {
    $git = Get-GitInfo
    if (-not $git.Installed) {
        return
    }

    $probe = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $ProjectRoot, "rev-parse", "--is-inside-work-tree")
    if ($probe.ExitCode -eq 0) {
        Write-Result "OK" "Git repository already initialized"
        return
    }

    $result = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $ProjectRoot, "init")
    if ($result.ExitCode -ne 0) {
        $details = ($result.Output -join " | ")
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = "Git returned exit code $($result.ExitCode)."
        }
        throw "Could not initialize Git repository: $details"
    }

    # Vérifie le résultat au lieu de supposer que `git init` a réellement réussi.
    $verify = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $ProjectRoot, "rev-parse", "--is-inside-work-tree")
    if ($verify.ExitCode -ne 0) {
        throw "Git init returned success, but repository verification failed."
    }

    Write-Result "OK" "Initialized Git repository"
}


function Get-PythonPathForVersion {
    param([Parameter(Mandatory)][string]$Version)

    $pyLauncher = Get-ExecutablePath @("py.exe", "py")
    if ($pyLauncher) {
        try {
            $result = Invoke-NativeCapture -Executable $pyLauncher -Arguments @("-$Version", "-c", "import sys; print(sys.executable)")
            if ($result.ExitCode -eq 0 -and $result.Output.Count -gt 0) {
                $candidate = ($result.Output | Select-Object -First 1).ToString().Trim()
                if ($candidate -and (Test-Path -LiteralPath $candidate)) {
                    return $candidate
                }
            }
        } catch {}
    }

    $digits = $Version.Replace(".", "")
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\\Python\\Python$digits\\python.exe")
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "Python$digits\\python.exe")
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }

        try {
            $result = Invoke-NativeCapture -Executable $candidate -Arguments @("-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
            if ($result.ExitCode -eq 0 -and $result.Output.Count -gt 0) {
                $detected = ($result.Output | Select-Object -First 1).ToString().Trim()
                if ($detected -eq $Version) {
                    return $candidate
                }
            }
        } catch {}
    }

    return $null
}

function Get-TripoSrPythonInfo {
    foreach ($version in $TripoSrPreferredPythonVersions) {
        $path = Get-PythonPathForVersion -Version $version
        if ($path) {
            return [pscustomobject]@{
                Installed = $true
                Version = $version
                Path = $path
            }
        }
    }

    return [pscustomobject]@{
        Installed = $false
        Version = $null
        Path = $null
    }
}

function Ensure-TripoSrPython {
    $python = Get-TripoSrPythonInfo
    if ($python.Installed) {
        Write-Result "OK" "TripoSR Python $($python.Version) available - $($python.Path)"
        return $python
    }

    if ($NoInstall) {
        throw "TripoSR requires Python 3.11 or 3.10, but neither is installed. -NoInstall prevents automatic installation."
    }

    Install-WingetPackage -Id "Python.Python.3.11" -DisplayName "Python 3.11 for TripoSR"
    Refresh-ProcessPath

    $python = Get-TripoSrPythonInfo
    if (-not $python.Installed) {
        throw "Python 3.11 installation completed, but TripoSR-compatible Python is still not detectable. Open a new terminal and rerun 'triposr install'."
    }

    return $python
}

function Get-CudaToolkitInfo {
    $nvcc = Get-ExecutablePath @("nvcc.exe", "nvcc")

    if (-not $nvcc -and $env:ProgramFiles) {
        $cudaRoot = Join-Path $env:ProgramFiles "NVIDIA GPU Computing Toolkit\\CUDA"
        if (Test-Path -LiteralPath $cudaRoot) {
            $matches = @(Get-ChildItem -LiteralPath $cudaRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
            foreach ($match in $matches) {
                $candidate = Join-Path $match.FullName "bin\\nvcc.exe"
                if (Test-Path -LiteralPath $candidate) {
                    $nvcc = $candidate
                    break
                }
            }
        }
    }

    if (-not $nvcc) {
        return [pscustomobject]@{
            Installed = $false
            Path = $null
            Version = $null
            Major = $null
            Minor = $null
        }
    }

    try {
        $result = Invoke-NativeCapture -Executable $nvcc -Arguments @("--version")
        if ($result.ExitCode -ne 0) {
            throw "nvcc returned exit code $($result.ExitCode)"
        }

        $text = ($result.Output -join "`n")
        $match = [regex]::Match($text, 'release\s+(\d+)\.(\d+)')
        if (-not $match.Success) {
            throw "Could not parse nvcc version."
        }

        return [pscustomobject]@{
            Installed = $true
            Path = $nvcc
            Version = "$($match.Groups[1].Value).$($match.Groups[2].Value)"
            Major = [int]$match.Groups[1].Value
            Minor = [int]$match.Groups[2].Value
        }
    } catch {
        return [pscustomobject]@{
            Installed = $false
            Path = $nvcc
            Version = $null
            Major = $null
            Minor = $null
        }
    }
}

function Get-Vs2022CppToolchainInfo {
    $roots = @()
    $pf86 = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFilesX86)
    if (-not [string]::IsNullOrWhiteSpace($pf86)) {
        $vs2022Root = Join-Path $pf86 "Microsoft Visual Studio\2022"
        if (Test-Path -LiteralPath $vs2022Root -PathType Container) {
            $roots = @(Get-ChildItem -LiteralPath $vs2022Root -Directory -ErrorAction SilentlyContinue)
        }
    }

    foreach ($root in $roots) {
        $msvcRoot = Join-Path $root.FullName "VC\Tools\MSVC"
        if (-not (Test-Path -LiteralPath $msvcRoot -PathType Container)) {
            continue
        }

        $toolsets = @(Get-ChildItem -LiteralPath $msvcRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($toolset in $toolsets) {
            $cl = Join-Path $toolset.FullName "bin\Hostx64\x64\cl.exe"
            if (Test-Path -LiteralPath $cl -PathType Leaf) {
                return [pscustomobject]@{
                    Installed = $true
                    Root = $root.FullName
                    Edition = $root.Name
                    Toolset = $toolset.Name
                    ClPath = $cl
                }
            }
        }
    }

    return [pscustomobject]@{
        Installed = $false
        Root = $null
        Edition = $null
        Toolset = $null
        ClPath = $null
    }
}

function Test-TripoSrCudaVsIntegration {
    param([Parameter(Mandatory)]$CudaToolkit)

    $vs = Get-Vs2022CppToolchainInfo
    if (-not $vs.Installed) {
        return [pscustomobject]@{
            Valid = $false
            Message = "Visual Studio 2022 C++ Build Tools were not found. TripoSR torchmcubes requires the VS2022 C++ toolchain."
            Vs = $vs
        }
    }

    $buildCustomizations = Join-Path $vs.Root "MSBuild\Microsoft\VC\v170\BuildCustomizations"
    $props = Join-Path $buildCustomizations "CUDA $($CudaToolkit.Version).props"
    $targets = Join-Path $buildCustomizations "CUDA $($CudaToolkit.Version).targets"

    if (-not (Test-Path -LiteralPath $props -PathType Leaf) -or -not (Test-Path -LiteralPath $targets -PathType Leaf)) {
        $cudaRoot = Split-Path -Parent (Split-Path -Parent $CudaToolkit.Path)
        $source = Join-Path $cudaRoot "extras\visual_studio_integration\MSBuildExtensions"
        return [pscustomobject]@{
            Valid = $false
            Message = "CUDA $($CudaToolkit.Version) Visual Studio integration is missing from '$buildCustomizations'. Expected CUDA .props/.targets files. Source files are normally under '$source'."
            Vs = $vs
        }
    }

    return [pscustomobject]@{
        Valid = $true
        Message = "VS2022 $($vs.Edition) / MSVC $($vs.Toolset) with CUDA $($CudaToolkit.Version) MSBuild integration"
        Vs = $vs
    }
}

function Assert-TripoSrNativeBuildEnvironment {
    $cuda = Get-CudaToolkitInfo
    if (-not $cuda.Installed) {
        throw "CUDA Toolkit with nvcc is required for TripoSR torchmcubes. Install a supported CUDA Toolkit first."
    }

    $integration = Test-TripoSrCudaVsIntegration -CudaToolkit $cuda
    if (-not $integration.Valid) {
        throw $integration.Message
    }

    Write-Result "OK" $integration.Message
}

function Get-TripoSrTorchProfile {
    param([Parameter(Mandatory)]$CudaToolkit)

    if (-not $CudaToolkit.Installed) {
        throw "CUDA Toolkit with nvcc is required because TripoSR installs torchmcubes from source. Install CUDA Toolkit 12.8+ or 13.x, then rerun."
    }

    if ($CudaToolkit.Major -eq 12) {
        if ($CudaToolkit.Minor -lt 8) {
            throw "CUDA Toolkit $($CudaToolkit.Version) detected. RTX 5060 Ti / Blackwell requires CUDA Toolkit 12.8 or newer for this setup."
        }

        return [pscustomobject]@{
            Torch = "2.11.0"
            TorchVision = "0.26.0"
            IndexUrl = "https://download.pytorch.org/whl/cu128"
            ExpectedCudaMajor = 12
            Label = "PyTorch 2.11.0 + CUDA 12.8"
        }
    }

    if ($CudaToolkit.Major -eq 13) {
        return [pscustomobject]@{
            Torch = "2.12.0"
            TorchVision = "0.27.0"
            IndexUrl = "https://download.pytorch.org/whl/cu130"
            ExpectedCudaMajor = 13
            Label = "PyTorch 2.12.0 + CUDA 13.0"
        }
    }

    throw "Unsupported CUDA Toolkit major version $($CudaToolkit.Major). TripoSR torchmcubes requires the local CUDA major version to match PyTorch."
}

function Normalize-GitRemoteUrl {
    param([Parameter(Mandatory)][string]$Url)

    $normalized = $Url.Trim()
    if ($normalized.EndsWith(".git")) {
        $normalized = $normalized.Substring(0, $normalized.Length - 4)
    }
    return $normalized.TrimEnd("/")
}

function Test-TripoSrRepository {
    if (-not (Test-Path -LiteralPath $TripoSrRoot)) {
        return [pscustomobject]@{ Valid = $false; State = "missing"; Origin = $null; Message = "engines\\triposr does not exist" }
    }

    $gitDir = Join-Path $TripoSrRoot ".git"
    if (-not (Test-Path -LiteralPath $gitDir)) {
        return [pscustomobject]@{ Valid = $false; State = "partial"; Origin = $null; Message = "engines\\triposr exists but is not a Git repository" }
    }

    $git = Get-GitInfo
    if (-not $git.Installed) {
        return [pscustomobject]@{ Valid = $false; State = "blocked"; Origin = $null; Message = "Git is unavailable" }
    }

    $originResult = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $TripoSrRoot, "remote", "get-url", "origin")
    if ($originResult.ExitCode -ne 0 -or $originResult.Output.Count -eq 0) {
        return [pscustomobject]@{ Valid = $false; State = "blocked"; Origin = $null; Message = "Could not read TripoSR origin" }
    }

    $origin = ($originResult.Output | Select-Object -First 1).ToString().Trim()
    if ((Normalize-GitRemoteUrl $origin) -ne (Normalize-GitRemoteUrl $TripoSrRepoUrl)) {
        return [pscustomobject]@{ Valid = $false; State = "wrong-origin"; Origin = $origin; Message = "Unexpected TripoSR origin" }
    }

    if (-not (Test-Path -LiteralPath $TripoSrRequirements)) {
        return [pscustomobject]@{ Valid = $false; State = "incomplete"; Origin = $origin; Message = "requirements.txt is missing" }
    }

    return [pscustomobject]@{ Valid = $true; State = "ready"; Origin = $origin; Message = "Official TripoSR repository present" }
}

function Ensure-TripoSrRepository {
    $git = Get-GitInfo
    if (-not $git.Installed) {
        throw "Git is required before installing TripoSR."
    }

    $enginesDir = Join-Path $ProjectRoot "engines"
    if (-not (Test-Path -LiteralPath $enginesDir)) {
        New-Item -ItemType Directory -Path $enginesDir -Force | Out-Null
    }

    $state = Test-TripoSrRepository
    if ($state.Valid) {
        Write-Result "OK" "Official TripoSR repository already present"
        return
    }

    if ($state.State -eq "missing") {
        $clone = Invoke-NativeCapture -Executable $git.Path -Arguments @("clone", $TripoSrRepoUrl, $TripoSrRoot)
        if ($clone.ExitCode -ne 0) {
            throw "Could not clone TripoSR: $($clone.Output -join ' | ')"
        }

        Write-Result "OK" "Cloned official TripoSR repository"
        return
    }

    if ($state.State -eq "partial") {
        $entries = @(Get-ChildItem -LiteralPath $TripoSrRoot -Force)
        $allowedNames = @("test_cuda.py")
        $unexpected = @($entries | Where-Object { $_.Name -notin $allowedNames })

        if ($unexpected.Count -gt 0) {
            $names = ($unexpected | Select-Object -ExpandProperty Name) -join ", "
            throw "engines\\triposr is not a Git repository and contains unexpected files: $names. Nothing was deleted."
        }

        $tempDir = Join-Path $enginesDir "triposr_clone_tmp"
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force
        }

        $clone = Invoke-NativeCapture -Executable $git.Path -Arguments @("clone", $TripoSrRepoUrl, $tempDir)
        if ($clone.ExitCode -ne 0) {
            throw "Could not clone temporary TripoSR repository: $($clone.Output -join ' | ')"
        }

        try {
            Get-ChildItem -LiteralPath $tempDir -Force | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $TripoSrRoot -Recurse -Force
            }
        } finally {
            if (Test-Path -LiteralPath $tempDir) {
                Remove-Item -LiteralPath $tempDir -Recurse -Force
            }
        }

        $verify = Test-TripoSrRepository
        if (-not $verify.Valid) {
            throw "TripoSR bootstrap merge completed but repository verification failed: $($verify.Message)"
        }

        Write-Result "OK" "Installed official TripoSR repository and preserved existing helper files"
        return
    }

    if ($state.State -eq "wrong-origin") {
        throw "engines\\triposr is a Git repository with unexpected origin '$($state.Origin)'. Nothing was modified."
    }

    throw "TripoSR repository is incomplete or invalid: $($state.Message). Nothing was deleted."
}

function Ensure-TripoSrVenv {
    # Réutilise un environnement virtuel moteur valide avant de rechercher un Python de base.
    # Cela évite de réinstaller Python simplement parce que l'interpréteur d'origine
    # n'est plus dans PATH alors que l'environnement virtuel a déjà été créé.
    if (Test-Path -LiteralPath $TripoSrVenvPython -PathType Leaf) {
        $versionResult = Invoke-NativeCapture -Executable $TripoSrVenvPython -Arguments @(
            "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        )
        if ($versionResult.ExitCode -eq 0 -and $versionResult.Output.Count -gt 0) {
            $version = ($versionResult.Output | Select-Object -First 1).ToString().Trim()
            if ($version -in $TripoSrPreferredPythonVersions) {
                Write-Result "OK" "Reusing TripoSR venv with Python $version"
                return
            }
        }

        if ($NoInstall) {
            throw "TripoSR venv exists but is broken or unsupported. -NoInstall prevents recreation."
        }

        Write-Result "WARN" "TripoSR venv exists with unsupported/broken Python; recreating only .venv"
        Remove-Item -LiteralPath $TripoSrVenv -Recurse -Force
    } elseif (Test-Path -LiteralPath $TripoSrVenv) {
        if ($NoInstall) {
            throw "Incomplete TripoSR venv detected. -NoInstall prevents recreation."
        }

        Write-Result "WARN" "Incomplete TripoSR venv detected; recreating only .venv"
        Remove-Item -LiteralPath $TripoSrVenv -Recurse -Force
    }

    $python = Ensure-TripoSrPython
    $result = Invoke-NativeCapture -Executable $python.Path -Arguments @("-m", "venv", $TripoSrVenv)
    if ($result.ExitCode -ne 0) {
        throw "Could not create TripoSR venv: $($result.Output -join ' | ')"
    }

    if (-not (Test-Path -LiteralPath $TripoSrVenvPython -PathType Leaf)) {
        throw "TripoSR venv creation returned success but python.exe is missing."
    }

    $verify = Invoke-NativeCapture -Executable $TripoSrVenvPython -Arguments @(
        "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
    )
    if ($verify.ExitCode -ne 0 -or $verify.Output.Count -eq 0 -or $verify.Output[0].ToString().Trim() -notin $TripoSrPreferredPythonVersions) {
        throw "TripoSR venv was created but Python version validation failed."
    }

    Write-Result "OK" "Created isolated TripoSR venv"
}

function Invoke-TripoSrPython {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if (-not (Test-Path -LiteralPath $TripoSrVenvPython)) {
        throw "TripoSR venv is missing. Run '.\\setup-asset-factory.ps1 triposr install'."
    }

    # TripoSR n'est pas installé comme site-package (le dépôt officiel ne contient ni
    # setup.py ni pyproject.toml). Python doit donc s'exécuter avec la racine du dépôt
    # comme répertoire de travail afin que `import tsr` résolve le package local `tsr`.
    return Invoke-NativeCapture -Executable $TripoSrVenvPython -Arguments $Arguments -WorkingDirectory $TripoSrRoot
}

function Ensure-TripoSrPackagingTools {
    $result = Invoke-TripoSrPython -Arguments @("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel")
    if ($result.ExitCode -ne 0) {
        throw "Could not upgrade TripoSR packaging tools: $($result.Output -join ' | ')"
    }
    Write-Result "OK" "TripoSR pip/setuptools/wheel ready"
}

function Ensure-TripoSrPyTorch {
    $cudaToolkit = Get-CudaToolkitInfo
    $profile = Get-TripoSrTorchProfile -CudaToolkit $cudaToolkit
    Write-Result "OK" "CUDA Toolkit $($cudaToolkit.Version) detected - $($cudaToolkit.Path)"

    $existing = Invoke-TripoSrPython -Arguments @("-c", "import torch; print(torch.__version__); print(torch.version.cuda or '')")
    if ($existing.ExitCode -eq 0 -and $existing.Output.Count -ge 2) {
        $cudaText = $existing.Output[1].ToString().Trim()
        $cudaMajor = $null
        if ($cudaText -match '^(\d+)\.') {
            $cudaMajor = [int]$matches[1]
        }

        if ($cudaMajor -eq $profile.ExpectedCudaMajor) {
            Write-Result "OK" "Reusing compatible PyTorch $($existing.Output[0]) / CUDA $cudaText"
            return
        }

        Write-Result "WARN" "Existing TripoSR PyTorch CUDA '$cudaText' does not match CUDA Toolkit major $($profile.ExpectedCudaMajor); reinstalling inside .venv"
    }

    Write-Result "INFO" "Installing $($profile.Label) in TripoSR venv..."
    $install = Invoke-TripoSrPython -Arguments @(
        "-m", "pip", "install", "--upgrade", "--force-reinstall",
        "torch==$($profile.Torch)",
        "torchvision==$($profile.TorchVision)",
        "--index-url", $profile.IndexUrl
    )

    if ($install.ExitCode -ne 0) {
        throw "PyTorch installation failed: $($install.Output -join ' | ')"
    }

    Write-Result "OK" "$($profile.Label) installed"
}

function Test-TripoSrCuda {
    $code = @'
import torch
import sys

print("python=" + sys.version.split()[0])
print("torch=" + torch.__version__)
print("torch_cuda=" + str(torch.version.cuda))
print("cuda_available=" + str(torch.cuda.is_available()))

if not torch.cuda.is_available():
    raise SystemExit("CUDA is unavailable")

name = torch.cuda.get_device_name(0)
arch = torch.cuda.get_arch_list()
print("gpu=" + name)
print("arch=" + ",".join(arch))

if "RTX 5060 Ti" in name and "sm_120" not in arch:
    raise SystemExit("RTX 5060 Ti detected but PyTorch build does not expose sm_120")

x = torch.randn((1024, 1024), device="cuda")
y = x @ x
torch.cuda.synchronize()
print("tensor_cuda=OK")
'@

    $result = Invoke-TripoSrPython -Arguments @("-c", $code)
    foreach ($line in $result.Output) {
        Write-Result "INFO" $line.ToString()
    }

    if ($result.ExitCode -ne 0) {
        throw "TripoSR CUDA validation failed: $($result.Output -join ' | ')"
    }

    Write-Result "OK" "TripoSR CUDA tensor test passed"
}

function Ensure-TripoSrBuildDependencies {
    # torchmcubes doit être compilé avec le PyTorch déjà installé dans cet environnement virtuel.
    # Ses instructions d'installation amont exigent de désactiver l'isolation de compilation PEP 517
    # et de rendre les outils de compilation disponibles dans l'environnement actif.
    $result = Invoke-TripoSrPython -Arguments @(
        "-m", "pip", "install",
        "scikit-build-core",
        "pybind11",
        "cmake",
        "ninja"
    )

    if ($result.ExitCode -ne 0) {
        throw "TripoSR native build dependencies installation failed: $($result.Output -join ' | ')"
    }

    Write-Result "OK" "TripoSR native build dependencies ready"
}

function Ensure-TripoSrRequirements {
    if (-not (Test-Path -LiteralPath $TripoSrRequirements)) {
        throw "TripoSR requirements.txt is missing."
    }

    Ensure-TripoSrBuildDependencies

    # Le requirements.txt de TripoSR contient torchmcubes directement depuis GitHub.
    # torchmcubes inspecte dynamiquement la version de PyTorch installée lors de
    # la génération de ses métadonnées ; l'isolation de compilation normale de pip ne peut donc pas fonctionner.
    # --no-build-isolation est par conséquent requis pour installer les dépendances.
    $result = Invoke-TripoSrPython -Arguments @(
        "-m", "pip", "install",
        "--no-build-isolation",
        "-r", $TripoSrRequirements
    )

    if ($result.ExitCode -ne 0) {
        throw "TripoSR requirements installation failed: $($result.Output -join ' | ')"
    }

    Write-Result "OK" "TripoSR official requirements installed"
}

function Ensure-TripoSrRembgBackend {
    $probe = Invoke-TripoSrPython -Arguments @("-c", "import onnxruntime; print(onnxruntime.__version__)")
    if ($probe.ExitCode -eq 0) {
        Write-Result "OK" "TripoSR rembg CPU backend ready (onnxruntime $($probe.Output[0]))"
        return
    }

    if ($NoInstall) {
        throw "rembg backend is missing (onnxruntime). -NoInstall prevents automatic installation."
    }

    Write-Result "INFO" "Installing rembg CPU backend (onnxruntime) in TripoSR venv..."
    $install = Invoke-TripoSrPython -Arguments @(
        "-m", "pip", "install",
        "rembg[cpu]"
    )

    if ($install.ExitCode -ne 0) {
        throw "TripoSR rembg CPU backend installation failed: $($install.Output -join ' | ')"
    }

    $verify = Invoke-TripoSrPython -Arguments @("-c", "import rembg, onnxruntime; print(onnxruntime.__version__)")
    if ($verify.ExitCode -ne 0) {
        throw "TripoSR rembg CPU backend validation failed: $($verify.Output -join ' | ')"
    }

    Write-Result "OK" "TripoSR rembg CPU backend ready (onnxruntime $($verify.Output[0]))"
}

function Repair-TripoSrTorchMcubes {
    $cudaToolkit = Get-CudaToolkitInfo
    $null = Get-TripoSrTorchProfile -CudaToolkit $cudaToolkit

    Ensure-TripoSrBuildDependencies

    $uninstall = Invoke-TripoSrPython -Arguments @("-m", "pip", "uninstall", "-y", "torchmcubes")
    if ($uninstall.ExitCode -ne 0) {
        Write-Result "WARN" "torchmcubes uninstall returned exit code $($uninstall.ExitCode); continuing with reinstall"
    }

    $install = Invoke-TripoSrPython -Arguments @("-m", "pip", "install", "--no-build-isolation", "git+https://github.com/tatsy/torchmcubes.git")
    if ($install.ExitCode -ne 0) {
        throw "torchmcubes repair failed: $($install.Output -join ' | ')"
    }

    Write-Result "OK" "torchmcubes reinstalled"
}

function Test-TripoSrImports {
    $importTsr = Invoke-TripoSrPython -Arguments @("-c", "import tsr; print('tsr import OK')")
    if ($importTsr.ExitCode -ne 0) {
        throw "TripoSR import failed: $($importTsr.Output -join ' | ')"
    }
    Write-Result "OK" "TripoSR package import works"

    $importMain = Invoke-TripoSrPython -Arguments @("-c", "from tsr.system import TSR; print('TSR import OK')")
    if ($importMain.ExitCode -ne 0) {
        throw "TSR class import failed: $($importMain.Output -join ' | ')"
    }
    Write-Result "OK" "TSR main class import works"
}

function Test-TripoSrCli {
    $runPy = Join-Path $TripoSrRoot "run.py"
    if (-not (Test-Path -LiteralPath $runPy)) {
        throw "TripoSR run.py is missing."
    }

    $result = Invoke-TripoSrPython -Arguments @($runPy, "--help")
    if ($result.ExitCode -ne 0) {
        throw "TripoSR run.py --help failed: $($result.Output -join ' | ')"
    }

    Write-Result "OK" "TripoSR CLI starts"
}

function Invoke-TripoSrSmokeTest {
    Write-Header "TripoSR Smoke Test"

    if (-not (Test-Path -LiteralPath $TripoSrVenvPython -PathType Leaf)) {
        throw "TripoSR venv is missing. Run '.\setup-asset-factory.ps1 triposr install' first."
    }

    $example = Join-Path $TripoSrRoot "examples\chair.png"
    if (-not (Test-Path -LiteralPath $example -PathType Leaf)) {
        throw "Official TripoSR example image is missing: $example"
    }

    Test-TripoSrCuda

    # Les smoke tests valident l'installation ; ils ne réparent pas silencieusement les dépendances.
    $onnx = Invoke-TripoSrPython -Arguments @("-c", "import rembg, onnxruntime; print(onnxruntime.__version__)")
    if ($onnx.ExitCode -ne 0) {
        throw "TripoSR rembg CPU backend is not ready. Run 'triposr install' or 'triposr repair'. Details: $($onnx.Output -join ' | ')"
    }
    Write-Result "OK" "TripoSR rembg CPU backend ready (onnxruntime $($onnx.Output[0]))"

    Test-TripoSrImports

    # Utilise toujours un répertoire de test unique afin qu'un ancien maillage ne puisse
    # pas faire passer à tort une inférence défaillante pour un succès.
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $outputDir = Join-Path $ProjectRoot "outputs\tests\triposr\$stamp"
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

    $runPy = Join-Path $TripoSrRoot "run.py"
    Write-Result "INFO" "Running official chair.png inference..."
    $result = Invoke-TripoSrPython -Arguments @(
        $runPy,
        $example,
        "--output-dir", $outputDir
    )

    if ($result.ExitCode -ne 0) {
        throw "TripoSR smoke inference failed: $($result.Output -join ' | ')"
    }

    $models = @(Get-ChildItem -LiteralPath $outputDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.obj', '.glb', '.ply') })
    if ($models.Count -eq 0) {
        throw "TripoSR inference returned success but no new 3D model was found in $outputDir"
    }

    Write-Result "OK" "TripoSR image-to-3D smoke test passed"
    foreach ($model in $models) {
        Write-Result "INFO" "Output: $($model.FullName)"
    }
}

function Show-TripoSrStatus {
    Write-Header "TripoSR Status"

    $repo = Test-TripoSrRepository
    if ($repo.Valid) {
        Write-Result "OK" "Repository: $($repo.Origin)"
    } elseif ($repo.State -eq "missing") {
        Write-Result "MISSING" "TripoSR repository not installed"
    } else {
        Write-Result "WARN" "TripoSR repository state: $($repo.Message)"
    }

    $python = Get-TripoSrPythonInfo
    if ($python.Installed) {
        Write-Result "OK" "Compatible engine Python $($python.Version) - $($python.Path)"
    } else {
        Write-Result "MISSING" "Python 3.11/3.10 for TripoSR"
    }

    if (Test-Path -LiteralPath $TripoSrVenvPython) {
        $version = Invoke-NativeCapture -Executable $TripoSrVenvPython -Arguments @("--version")
        if ($version.ExitCode -eq 0) {
            Write-Result "OK" "Venv: $(($version.Output | Select-Object -First 1).ToString().Trim())"
        } else {
            Write-Result "WARN" "TripoSR venv exists but Python does not run"
        }
    } else {
        Write-Result "MISSING" "TripoSR isolated venv"
    }

    $cuda = Get-CudaToolkitInfo
    if ($cuda.Installed) {
        Write-Result "OK" "CUDA Toolkit $($cuda.Version) - $($cuda.Path)"
    } else {
        Write-Result "MISSING" "CUDA Toolkit / nvcc required for torchmcubes"
    }

    if (Test-Path -LiteralPath $TripoSrVenvPython) {
        $torch = Invoke-TripoSrPython -Arguments @("-c", "import torch; print(torch.__version__); print(torch.version.cuda or 'none'); print(torch.cuda.is_available())")
        if ($torch.ExitCode -eq 0 -and $torch.Output.Count -ge 3) {
            Write-Result "OK" "PyTorch $($torch.Output[0]) / CUDA $($torch.Output[1]) / cuda_available=$($torch.Output[2])"
        } else {
            Write-Result "MISSING" "PyTorch/CUDA not ready in TripoSR venv"
        }
    }
}

function Invoke-TripoSrInstall {
    Write-Header "TripoSR Install"
    Assert-BootstrapHost

    if ($NoInstall) {
        Write-Result "INFO" "-NoInstall: validation only; no repository/package changes will be made."
        $doctorExit = Invoke-TripoSrDoctor
        if ($doctorExit -ne 0) {
            throw "TripoSR validation failed while -NoInstall was active."
        }
        return
    }

    $git = Get-GitInfo
    if (-not $git.Installed) {
        if ($NoInstall) {
            throw "Git is missing and -NoInstall was specified."
        }
        Install-WingetPackage -Id "Git.Git" -DisplayName "Git"
    }

    $gpu = Get-NvidiaInfo
    if (-not $gpu.Available) {
        throw "NVIDIA GPU is not detectable with nvidia-smi."
    }
    Write-Result "OK" "NVIDIA GPU: $($gpu.Name), $($gpu.VramMiB) MiB VRAM"

    Ensure-TripoSrRepository
    Ensure-TripoSrVenv
    Ensure-TripoSrPackagingTools
    Ensure-TripoSrPyTorch
    Test-TripoSrCuda
    Assert-TripoSrNativeBuildEnvironment
    Ensure-TripoSrRequirements
    Ensure-TripoSrRembgBackend
    Test-TripoSrImports
    Test-TripoSrCli

    Write-Result "OK" "TripoSR installation validated"
}

function Invoke-TripoSrDoctor {
    Write-Header "TripoSR Doctor"
    $failures = 0

    $repo = Test-TripoSrRepository
    if ($repo.Valid) {
        Write-Result "OK" "Official TripoSR repository valid"
    } else {
        Write-Result "FAIL" "Repository: $($repo.Message)"
        $failures++
    }

    if (Test-Path -LiteralPath $TripoSrVenvPython) {
        Write-Result "OK" "Isolated TripoSR venv present"
    } else {
        Write-Result "FAIL" "TripoSR venv missing"
        $failures++
    }

    $cuda = Get-CudaToolkitInfo
    if ($cuda.Installed) {
        try {
            $profile = Get-TripoSrTorchProfile -CudaToolkit $cuda
            Write-Result "OK" "CUDA Toolkit $($cuda.Version), profile $($profile.Label)"
        } catch {
            Write-Result "FAIL" $_.Exception.Message
            $failures++
        }
    } else {
        Write-Result "FAIL" "CUDA Toolkit/nvcc missing"
        $failures++
    }

    if ($failures -eq 0) {
        try {
            Assert-TripoSrNativeBuildEnvironment
        } catch {
            Write-Result "FAIL" $_.Exception.Message
            $failures++
        }
    }

    if ($failures -eq 0) {
        try { Test-TripoSrCuda } catch { Write-Result "FAIL" $_.Exception.Message; $failures++ }
        try {
            $onnx = Invoke-TripoSrPython -Arguments @("-c", "import onnxruntime; print(onnxruntime.__version__)")
            if ($onnx.ExitCode -ne 0) { throw "onnxruntime/rembg CPU backend missing" }
            Write-Result "OK" "rembg CPU backend available (onnxruntime $($onnx.Output[0]))"
        } catch { Write-Result "FAIL" $_.Exception.Message; $failures++ }
        try { Test-TripoSrImports } catch { Write-Result "FAIL" $_.Exception.Message; $failures++ }
        try { Test-TripoSrCli } catch { Write-Result "FAIL" $_.Exception.Message; $failures++ }
    }

    if ($failures -gt 0) {
        Write-Result "FAIL" "TripoSR doctor found $failures blocking issue(s)."
        return 1
    }

    Write-Result "OK" "TripoSR doctor found no blocking issue."
    return 0
}

function Invoke-TripoSrRepair {
    Write-Header "TripoSR Repair"
    Assert-BootstrapHost

    Ensure-TripoSrRepository
    Ensure-TripoSrVenv
    Ensure-TripoSrPackagingTools
    Ensure-TripoSrPyTorch
    Test-TripoSrCuda
    Assert-TripoSrNativeBuildEnvironment
    Repair-TripoSrTorchMcubes
    Ensure-TripoSrRequirements
    Ensure-TripoSrRembgBackend
    Test-TripoSrImports
    Test-TripoSrCli

    Write-Result "OK" "TripoSR repair completed and validated"
}

function Invoke-TripoSrCommand {
    switch ($EngineCommand) {
        "install" { Invoke-TripoSrInstall }
        "status"  { Show-TripoSrStatus }
        "doctor"  {
            $exitCode = Invoke-TripoSrDoctor
            if ($exitCode -ne 0) { exit $exitCode }
        }
        "repair"  { Invoke-TripoSrRepair }
        "smoke"   { Invoke-TripoSrSmokeTest }
    }
}



function Get-TrellisPythonInfo {
    param(
        [Parameter(Mandatory)][string]$Version
    )

    $path = Get-PythonPathForVersion -Version $Version
    if ($path) {
        return [pscustomobject]@{
            Installed = $true
            Version = $Version
            Path = $path
        }
    }

    return [pscustomobject]@{
        Installed = $false
        Version = $null
        Path = $null
    }
}

function Ensure-TrellisPython {
    param(
        [Parameter(Mandatory)][string]$Version
    )

    $python = Get-TrellisPythonInfo -Version $Version
    if ($python.Installed) {
        Write-Result "OK" "TRELLIS Python $Version available - $($python.Path)"
        return $python
    }

    if ($NoInstall) {
        throw "TRELLIS requires Python $Version for this stage. -NoInstall prevents automatic installation."
    }

    Install-WingetPackage -Id "Python.Python.$Version" -DisplayName "Python $Version for TRELLIS"
    Refresh-ProcessPath

    $python = Get-TrellisPythonInfo -Version $Version
    if (-not $python.Installed) {
        throw "Python $Version installation completed, but it is still not detectable. Open a new terminal and rerun the TRELLIS command."
    }

    return $python
}

function Test-TrellisRepository {
    if (-not (Test-Path -LiteralPath $TrellisRoot -PathType Container)) {
        return [pscustomobject]@{ Valid = $false; State = "missing"; Origin = $null; Message = "engines\\trellis does not exist" }
    }

    $gitDir = Join-Path $TrellisRoot ".git"
    if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) {
        return [pscustomobject]@{ Valid = $false; State = "partial"; Origin = $null; Message = "engines\\trellis exists but is not a Git repository" }
    }

    $git = Get-GitInfo
    if (-not $git.Installed) {
        return [pscustomobject]@{ Valid = $false; State = "blocked"; Origin = $null; Message = "Git is unavailable" }
    }

    $originResult = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $TrellisRoot, "remote", "get-url", "origin")
    if ($originResult.ExitCode -ne 0 -or $originResult.Output.Count -eq 0) {
        return [pscustomobject]@{ Valid = $false; State = "blocked"; Origin = $null; Message = "Could not read TRELLIS origin" }
    }

    $origin = ($originResult.Output | Select-Object -First 1).ToString().Trim()
    if ((Normalize-GitRemoteUrl $origin) -ne (Normalize-GitRemoteUrl $TrellisRepoUrl)) {
        return [pscustomobject]@{ Valid = $false; State = "wrong-origin"; Origin = $origin; Message = "Unexpected TRELLIS origin" }
    }

    $pipelineFile = Join-Path $TrellisRoot "trellis\pipelines\trellis_image_to_3d.py"
    $setupFile = Join-Path $TrellisRoot "setup.sh"

    if (-not (Test-Path -LiteralPath $pipelineFile -PathType Leaf)) {
        return [pscustomobject]@{ Valid = $false; State = "incomplete"; Origin = $origin; Message = "TRELLIS image-to-3D pipeline source is missing" }
    }

    if (-not (Test-Path -LiteralPath $setupFile -PathType Leaf)) {
        return [pscustomobject]@{ Valid = $false; State = "incomplete"; Origin = $origin; Message = "TRELLIS setup.sh is missing" }
    }

    return [pscustomobject]@{ Valid = $true; State = "ready"; Origin = $origin; Message = "Official TRELLIS repository present" }
}

function Get-TrellisGitState {
    $git = Get-GitInfo
    if (-not $git.Installed -or -not (Test-Path -LiteralPath (Join-Path $TrellisRoot ".git") -PathType Container)) {
        return $null
    }

    $head = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $TrellisRoot, "rev-parse", "--short=7", "HEAD")
    $dirty = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $TrellisRoot, "status", "--porcelain", "--untracked-files=no")
    $submodule = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $TrellisRoot, "submodule", "status", "trellis/representations/mesh/flexicubes")

    return [pscustomobject]@{
        Head = if ($head.ExitCode -eq 0 -and $head.Output.Count -gt 0) { $head.Output[0].ToString().Trim() } else { $null }
        Dirty = ($dirty.ExitCode -ne 0 -or $dirty.Output.Count -gt 0)
        FlexiCubes = if ($submodule.ExitCode -eq 0 -and $submodule.Output.Count -gt 0) { $submodule.Output[0].ToString().Trim() } else { $null }
    }
}

function Ensure-TrellisRepository {
    $git = Get-GitInfo
    if (-not $git.Installed) {
        throw "Git is required before preparing TRELLIS."
    }

    $enginesDir = Join-Path $ProjectRoot "engines"
    if (-not (Test-Path -LiteralPath $enginesDir -PathType Container)) {
        New-Item -ItemType Directory -Path $enginesDir -Force | Out-Null
    }

    $state = Test-TrellisRepository

    if ($state.State -eq "missing") {
        Write-Result "INFO" "Cloning official TRELLIS repository with submodules..."
        $clone = Invoke-NativeCapture -Executable $git.Path -Arguments @(
            "clone", "--recurse-submodules", $TrellisRepoUrl, $TrellisRoot
        )
        if ($clone.ExitCode -ne 0) {
            throw "Could not clone TRELLIS: $($clone.Output -join ' | ')"
        }
        $state = Test-TrellisRepository
    } elseif ($state.State -eq "partial") {
        $entries = @(Get-ChildItem -LiteralPath $TrellisRoot -Force -ErrorAction SilentlyContinue)
        if ($entries.Count -eq 0) {
            Remove-Item -LiteralPath $TrellisRoot -Force
            Write-Result "INFO" "Removed empty engines\\trellis placeholder before clone"

            $clone = Invoke-NativeCapture -Executable $git.Path -Arguments @(
                "clone", "--recurse-submodules", $TrellisRepoUrl, $TrellisRoot
            )
            if ($clone.ExitCode -ne 0) {
                throw "Could not clone TRELLIS: $($clone.Output -join ' | ')"
            }
            $state = Test-TrellisRepository
        } else {
            $names = ($entries | Select-Object -ExpandProperty Name) -join ", "
            throw "engines\\trellis is not a Git repository and contains files: $names. Nothing was deleted."
        }
    }

    if (-not $state.Valid) {
        if ($state.State -eq "wrong-origin") {
            throw "engines\\trellis is a Git repository with unexpected origin '$($state.Origin)'. Nothing was modified."
        }
        throw "TRELLIS repository is incomplete or invalid: $($state.Message)"
    }

    $gitState = Get-TrellisGitState
    if ($null -eq $gitState) {
        throw "Could not inspect TRELLIS Git state."
    }

    if ($gitState.Dirty) {
        throw "TRELLIS tracked files contain local changes. Refusing to pin the repository automatically."
    }

    if ($gitState.Head -ne $TrellisPinnedCommit) {
        Write-Result "INFO" "Pinning TRELLIS to validated commit $TrellisPinnedCommit..."
        $fetch = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $TrellisRoot, "fetch", "origin")
        if ($fetch.ExitCode -ne 0) {
            throw "Could not fetch TRELLIS before pinning: $($fetch.Output -join ' | ')"
        }

        $checkout = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $TrellisRoot, "checkout", "--detach", $TrellisPinnedCommit)
        if ($checkout.ExitCode -ne 0) {
            throw "Could not checkout TRELLIS commit $TrellisPinnedCommit`: $($checkout.Output -join ' | ')"
        }
    }

    $subUpdate = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $TrellisRoot, "submodule", "update", "--init", "--recursive")
    if ($subUpdate.ExitCode -ne 0) {
        throw "Could not synchronize TRELLIS submodules: $($subUpdate.Output -join ' | ')"
    }

    $finalState = Get-TrellisGitState
    if ($finalState.Head -ne $TrellisPinnedCommit) {
        throw "TRELLIS pin verification failed. Expected $TrellisPinnedCommit, got '$($finalState.Head)'."
    }
    if ([string]::IsNullOrWhiteSpace($finalState.FlexiCubes) -or $finalState.FlexiCubes -notmatch $TrellisPinnedFlexiCubesCommit) {
        throw "TRELLIS flexicubes submodule does not match expected commit $TrellisPinnedFlexiCubesCommit."
    }

    Write-Result "OK" "Official TRELLIS repository pinned at $TrellisPinnedCommit"
}

function Ensure-TrellisVenv {
    param(
        [Parameter(Mandatory)][string]$VenvPath,
        [Parameter(Mandatory)][string]$VenvPython,
        [Parameter(Mandatory)][string]$PythonVersion,
        [Parameter(Mandatory)][string]$Label
    )

    if (Test-Path -LiteralPath $VenvPython -PathType Leaf) {
        $versionResult = Invoke-NativeCapture -Executable $VenvPython -Arguments @(
            "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        )
        if ($versionResult.ExitCode -eq 0 -and $versionResult.Output.Count -gt 0) {
            $version = ($versionResult.Output | Select-Object -First 1).ToString().Trim()
            if ($version -eq $PythonVersion) {
                Write-Result "OK" "Reusing $Label venv with Python $version"
                return
            }
        }

        if ($NoInstall) {
            throw "$Label venv exists but is broken or unsupported. -NoInstall prevents recreation."
        }

        Write-Result "WARN" "$Label venv exists with unsupported/broken Python; recreating only that venv"
        Remove-Item -LiteralPath $VenvPath -Recurse -Force
    } elseif (Test-Path -LiteralPath $VenvPath) {
        if ($NoInstall) {
            throw "Incomplete $Label venv detected. -NoInstall prevents recreation."
        }
        Remove-Item -LiteralPath $VenvPath -Recurse -Force
    }

    $python = Ensure-TrellisPython -Version $PythonVersion
    $create = Invoke-NativeCapture -Executable $python.Path -Arguments @("-m", "venv", $VenvPath)
    if ($create.ExitCode -ne 0) {
        throw "Could not create $Label venv: $($create.Output -join ' | ')"
    }

    if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
        throw "$Label venv creation returned success but python.exe is missing."
    }

    Write-Result "OK" "Created isolated $Label venv"
}

function Invoke-TrellisPython {
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
        throw "Requested TRELLIS Python environment is missing: $PythonPath"
    }

    return Invoke-NativeCapture -Executable $PythonPath -Arguments $Arguments -WorkingDirectory $TrellisRoot
}

function Ensure-TrellisPackagingTools {
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$Label
    )

    $result = Invoke-TrellisPython -PythonPath $PythonPath -Arguments @(
        "-m", "pip", "install", "--upgrade", "pip", "wheel", "setuptools==80.10.2"
    )
    if ($result.ExitCode -ne 0) {
        throw "Could not prepare $Label packaging tools: $($result.Output -join ' | ')"
    }

    Write-Result "OK" "$Label pip/setuptools/wheel ready"
}

function Get-TrellisRuntimeTorchInfo {
    if (-not (Test-Path -LiteralPath $TrellisRuntimeVenvPython -PathType Leaf)) {
        return [pscustomobject]@{
            Available = $false
            Torch = $null
            Cuda = $null
            CudaAvailable = $false
            Gpu = $null
            Arch = $null
        }
    }

    $code = @'
import torch
print(torch.__version__)
print(torch.version.cuda or "")
print(str(torch.cuda.is_available()))
print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else "")
print(",".join(torch.cuda.get_arch_list()) if torch.cuda.is_available() else "")
'@

    $result = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @("-c", $code)
    if ($result.ExitCode -ne 0 -or $result.Output.Count -lt 5) {
        return [pscustomobject]@{
            Available = $false
            Torch = $null
            Cuda = $null
            CudaAvailable = $false
            Gpu = $null
            Arch = $null
        }
    }

    return [pscustomobject]@{
        Available = $true
        Torch = $result.Output[0].ToString().Trim()
        Cuda = $result.Output[1].ToString().Trim()
        CudaAvailable = ($result.Output[2].ToString().Trim() -eq "True")
        Gpu = $result.Output[3].ToString().Trim()
        Arch = $result.Output[4].ToString().Trim()
    }
}

function Ensure-TrellisRuntimePyTorch {
    $current = Get-TrellisRuntimeTorchInfo
    if ($current.Available -and
        $current.Torch -like "$TrellisTorchVersion*" -and
        $current.Cuda -eq $TrellisExpectedTorchCuda -and
        $current.CudaAvailable) {
        Write-Result "OK" "Reusing TRELLIS runtime PyTorch $($current.Torch) / CUDA $($current.Cuda)"
        return
    }

    if ($NoInstall) {
        throw "TRELLIS runtime PyTorch $TrellisTorchVersion / CUDA $TrellisExpectedTorchCuda is not ready. -NoInstall prevents installation."
    }

    Write-Result "INFO" "Installing official PyTorch $TrellisTorchVersion CUDA $TrellisExpectedTorchCuda wheels in TRELLIS runtime venv..."
    $install = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @(
        "-m", "pip", "install", "--upgrade",
        "torch==$TrellisTorchVersion",
        "torchvision",
        "--index-url", $TrellisTorchIndexUrl
    )

    if ($install.ExitCode -ne 0) {
        throw "TRELLIS runtime PyTorch installation failed: $($install.Output -join ' | ')"
    }

    $verify = Get-TrellisRuntimeTorchInfo
    if (-not $verify.Available -or -not $verify.CudaAvailable) {
        throw "TRELLIS runtime PyTorch installed but CUDA execution is unavailable."
    }
    if ($verify.Cuda -ne $TrellisExpectedTorchCuda) {
        throw "TRELLIS runtime PyTorch reports CUDA '$($verify.Cuda)' instead of expected '$TrellisExpectedTorchCuda'."
    }
    if ($verify.Arch -notmatch "sm_120") {
        throw "TRELLIS runtime PyTorch does not expose sm_120 required by the detected Blackwell GPU. Reported arch list: $($verify.Arch)"
    }

    Write-Result "OK" "TRELLIS runtime PyTorch $($verify.Torch) / CUDA $($verify.Cuda) / sm_120 validated"
}

function Ensure-TrellisRuntimeBasicPackages {
    if ($NoInstall) {
        Write-Result "INFO" "-NoInstall: skipping TRELLIS runtime package installation."
        return
    }

    Write-Result "INFO" "Installing TRELLIS pure-Python/basic runtime dependencies..."
    $arguments = @("-m", "pip", "install", "--upgrade") + $TrellisBasicPackages
    $install = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments $arguments
    if ($install.ExitCode -ne 0) {
        throw "TRELLIS basic dependency installation failed: $($install.Output -join ' | ')"
    }

    $utils3d = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @(
        "-m", "pip", "install",
        "git+https://github.com/EasternJournalist/utils3d.git@9a4eb15e4021b67b12c460c7057d642626897ec8"
    )
    if ($utils3d.ExitCode -ne 0) {
        throw "TRELLIS utils3d installation failed: $($utils3d.Output -join ' | ')"
    }

    Write-Result "OK" "TRELLIS basic runtime dependencies ready"
}

function Test-TrellisRuntimeBasicImports {
    $code = @'
import importlib
modules = [
    "PIL",
    "imageio",
    "tqdm",
    "easydict",
    "cv2",
    "scipy",
    "rembg",
    "onnxruntime",
    "trimesh",
    "xatlas",
    "open3d",
    "transformers",
    "huggingface_hub",
    "utils3d",
]
failed = []
for name in modules:
    try:
        importlib.import_module(name)
    except Exception as exc:
        failed.append(f"{name}: {exc}")
if failed:
    print(" | ".join(failed))
    raise SystemExit(1)
print("OK")
'@

    $probe = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @("-c", $code)
    if ($probe.ExitCode -ne 0) {
        throw "TRELLIS basic runtime import probe failed: $($probe.Output -join ' | ')"
    }

    Write-Result "OK" "TRELLIS basic runtime imports passed"
}


function Get-TrellisSdpaInfo {
    if (-not (Test-Path -LiteralPath $TrellisRuntimeVenvPython -PathType Leaf)) {
        return [pscustomobject]@{
            Available = $false
            Message = "TRELLIS runtime venv missing"
        }
    }

    $code = @'
import torch
import torch.nn.functional as F

if not torch.cuda.is_available():
    raise RuntimeError("CUDA unavailable")

q = torch.randn((1, 8, 128, 64), device="cuda", dtype=torch.float16)
k = torch.randn((1, 8, 128, 64), device="cuda", dtype=torch.float16)
v = torch.randn((1, 8, 128, 64), device="cuda", dtype=torch.float16)

with torch.backends.cuda.sdp_kernel(
    enable_flash=True,
    enable_math=True,
    enable_mem_efficient=True,
    enable_cudnn=True,
):
    out = F.scaled_dot_product_attention(q, k, v)

torch.cuda.synchronize()

print(torch.__version__)
print(torch.version.cuda or "")
print(torch.cuda.get_device_name(0))
print(",".join(torch.cuda.get_arch_list()))
print(str(out.shape))
print("SDPA_CUDA_OK")
'@

    $probe = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @("-c", $code)

    if ($probe.ExitCode -ne 0) {
        return [pscustomobject]@{
            Available = $false
            Message = ($probe.Output -join " | ")
        }
    }

    return [pscustomobject]@{
        Available = ($probe.Output -contains "SDPA_CUDA_OK")
        Message = ($probe.Output -join " | ")
    }
}

function Test-TrellisSdpa {
    $sdpa = Get-TrellisSdpaInfo
    if (-not $sdpa.Available) {
        throw "PyTorch SDPA CUDA validation failed: $($sdpa.Message)"
    }

    Write-Result "OK" "PyTorch SDPA CUDA attention passed on the TRELLIS runtime"
}

function Get-TrellisXFormersInfo {
    if (-not (Test-Path -LiteralPath $TrellisRuntimeVenvPython -PathType Leaf)) {
        return [pscustomobject]@{
            Installed = $false
            Version = $null
            CudaKernel = $false
            Message = "TRELLIS runtime venv missing"
        }
    }

    $code = @'
try:
    import xformers
    version = getattr(xformers, "__version__", "unknown")
    print(version)
except Exception as exc:
    print(type(exc).__name__ + ": " + str(exc))
    raise SystemExit(2)

try:
    import torch
    import xformers.ops as xops

    q = torch.randn((1, 32, 4, 64), device="cuda", dtype=torch.float16)
    k = torch.randn((1, 32, 4, 64), device="cuda", dtype=torch.float16)
    v = torch.randn((1, 32, 4, 64), device="cuda", dtype=torch.float16)
    out = xops.memory_efficient_attention(q, k, v)
    torch.cuda.synchronize()
    print("XFORMERS_CUDA_OK")
except Exception as exc:
    print(type(exc).__name__ + ": " + str(exc))
    raise SystemExit(1)
'@

    $probe = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @("-c", $code)

    if ($probe.ExitCode -eq 2) {
        return [pscustomobject]@{
            Installed = $false
            Version = $null
            CudaKernel = $false
            Message = ($probe.Output -join " | ")
        }
    }

    $version = if ($probe.Output.Count -gt 0) { $probe.Output[0].ToString().Trim() } else { $null }

    return [pscustomobject]@{
        Installed = $true
        Version = $version
        CudaKernel = ($probe.ExitCode -eq 0 -and ($probe.Output -contains "XFORMERS_CUDA_OK"))
        Message = ($probe.Output -join " | ")
    }
}

function Remove-TrellisBrokenXFormers {
    $info = Get-TrellisXFormersInfo
    if (-not $info.Installed) {
        return
    }

    if ($info.CudaKernel) {
        Write-Result "INFO" "xformers $($info.Version) works, but Asset Factory still prefers PyTorch SDPA on this Blackwell runtime."
        return
    }

    if ($NoInstall) {
        Write-Result "WARN" "xformers $($info.Version) is installed but incompatible with the current Blackwell runtime; -NoInstall prevents removing it."
        return
    }

    Write-Result "WARN" "xformers $($info.Version) is incompatible with this Blackwell stack; removing it to avoid accidental backend selection."
    $uninstall = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @(
        "-m", "pip", "uninstall", "-y", "xformers"
    )
    if ($uninstall.ExitCode -ne 0) {
        throw "Could not remove incompatible xformers: $($uninstall.Output -join ' | ')"
    }

    Write-Result "OK" "Incompatible xformers removed"
}

function Get-TrellisNativeToolchainInfo {
    $vs = Get-Vs2022CppToolchainInfo

    $cudaRoot = Join-Path $env:ProgramFiles "NVIDIA GPU Computing Toolkit\CUDA\v13.4"
    $nvcc = Join-Path $cudaRoot "bin\nvcc.exe"

    $cudaPresent = Test-Path -LiteralPath $nvcc -PathType Leaf
    $nvccVersion = $null

    if ($cudaPresent) {
        try {
            $probe = Invoke-NativeCapture -Executable $nvcc -Arguments @("--version")
            if ($probe.ExitCode -eq 0) {
                $joined = $probe.Output -join "`n"
                $m = [regex]::Match($joined, 'release\s+(\d+\.\d+)')
                if ($m.Success) {
                    $nvccVersion = $m.Groups[1].Value
                }
            }
        } catch {}
    }

    $props = $null
    $targets = $null
    $integrationValid = $false

    if ($vs.Installed) {
        $buildCustomizations = Join-Path $vs.Root "MSBuild\Microsoft\VC\v170\BuildCustomizations"
        $props = Join-Path $buildCustomizations "CUDA 13.4.props"
        $targets = Join-Path $buildCustomizations "CUDA 13.4.targets"
        $integrationValid = (
            (Test-Path -LiteralPath $props -PathType Leaf) -and
            (Test-Path -LiteralPath $targets -PathType Leaf)
        )
    }

    return [pscustomobject]@{
        CudaPresent = $cudaPresent
        CudaRoot = $cudaRoot
        NvccPath = $nvcc
        NvccVersion = $nvccVersion
        VsInstalled = $vs.Installed
        VsRoot = $vs.Root
        MsvcToolset = $vs.Toolset
        ClPath = $vs.ClPath
        PropsPath = $props
        TargetsPath = $targets
        IntegrationValid = $integrationValid
    }
}

function Assert-TrellisNativeToolchain {
    $info = Get-TrellisNativeToolchainInfo

    if (-not $info.CudaPresent) {
        throw "CUDA Toolkit 13.4 is required for TRELLIS native extensions."
    }

    if ($info.NvccVersion -ne "13.4") {
        throw "TRELLIS native nvcc version mismatch. Expected 13.4, detected '$($info.NvccVersion)'."
    }

    if (-not $info.VsInstalled) {
        throw "Visual Studio 2022 C++ Build Tools are required for TRELLIS native extensions."
    }

    if (-not $info.IntegrationValid) {
        throw "CUDA 13.4 Visual Studio integration is incomplete."
    }

    Write-Result "OK" "CUDA Toolkit $($info.NvccVersion) - $($info.NvccPath)"
    Write-Result "OK" "VS2022 C++ / MSVC $($info.MsvcToolset) - $($info.ClPath)"
    Write-Result "OK" "CUDA 13.4 MSBuild integration present"

    return $info
}

function Invoke-TrellisNativeCompileTest {
    param([switch]$Quiet)

    $toolchain = Assert-TrellisNativeToolchain

    $testDir = Join-Path $ProjectRoot "outputs\diagnostics\trellis\native-toolchain"
    if (-not (Test-Path -LiteralPath $testDir -PathType Container)) {
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    }

    $sourcePath = Join-Path $testDir "sm120-test.cu"
    $objectPath = Join-Path $testDir "sm120-test.obj"

    @'
__global__ void asset_factory_trellis_test_kernel() {}

int main()
{
    asset_factory_trellis_test_kernel<<<1, 1>>>();
    return 0;
}
'@ | Set-Content -LiteralPath $sourcePath -Encoding ASCII

    if (Test-Path -LiteralPath $objectPath -PathType Leaf) {
        Remove-Item -LiteralPath $objectPath -Force
    }

    $clDir = Split-Path -Parent $toolchain.ClPath
    $compile = Invoke-NativeCapture -Executable $toolchain.NvccPath -Arguments @(
        "-arch=sm_120",
        "-ccbin", $clDir,
        "-c", $sourcePath,
        "-o", $objectPath
    )

    if ($compile.ExitCode -ne 0) {
        throw "CUDA/MSVC sm_120 compile test failed: $($compile.Output -join ' | ')"
    }

    if (-not (Test-Path -LiteralPath $objectPath -PathType Leaf)) {
        throw "CUDA/MSVC compile returned success but did not produce $objectPath"
    }

    if (-not $Quiet) {
        Write-Result "OK" "CUDA/MSVC compile test passed for sm_120"
        Write-Result "INFO" "Toolchain test object: $objectPath"
    }

    return $objectPath
}



function Import-TrellisVs2022BuildEnvironment {
    param([Parameter(Mandatory)]$Toolchain)

    if ($Script:TrellisVsEnvironmentLoaded) {
        Write-Result "OK" "VS2022 Build Tools environment already loaded for this TRELLIS run"
        return
    }

    $vcvars = Join-Path $Toolchain.VsRoot "VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) {
        throw "VS2022 x64 developer environment script is missing: $vcvars"
    }

    $cmd = Join-Path $env:SystemRoot "System32\cmd.exe"
    if (-not (Test-Path -LiteralPath $cmd -PathType Leaf)) {
        throw "cmd.exe is required to initialize the VS2022 native build environment."
    }

    $originalPath = $env:Path

    $tempDir = Join-Path $ProjectRoot "outputs\diagnostics\trellis\native-toolchain"
    if (-not (Test-Path -LiteralPath $tempDir -PathType Container)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    $wrapper = Join-Path $tempDir "load-vs2022-env.cmd"
    @"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b %errorlevel%
set
"@ | Set-Content -LiteralPath $wrapper -Encoding ASCII

    # IMPORTANT :
    # L'exécution d'un fichier .ps1 partage l'environnement du processus PowerShell parent.
    # Des exécutions précédentes du bootstrap peuvent donc laisser de volumineuses variables VS/CUDA.
    # Démarrer vcvars64.bat avec l'environnement hérité n'est pas déterministe
    # et finit par faire échouer cmd.exe avec "input line is too long".
    #
    # Lance plutôt vcvars dans un environnement enfant réellement propre. Seules les
    # variables Windows requises par cmd/vcvars sont transmises.
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

    $systemPath = @(
        (Join-Path $env:SystemRoot "System32"),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot "System32\Wbem"),
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0")
    ) -join ";"
    $psi.EnvironmentVariables["PATH"] = $systemPath

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        if (-not $process.Start()) {
            throw "Could not start clean cmd.exe process for vcvars64.bat."
        }

        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    } finally {
        if ($process) {
            $process.Dispose()
        }
        if (Test-Path -LiteralPath $wrapper -PathType Leaf) {
            Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue
        }
    }

    if ($exitCode -ne 0) {
        $detail = (($stdout + [Environment]::NewLine + $stderr) -split "`r?`n" |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " | "
        throw "Could not initialize VS2022 x64 developer environment: $detail"
    }

    # Importe uniquement les variables de compilation native réellement nécessaires. Importer toutes les
    # variables produites par `set` modifierait inutilement le shell de l'appelant.
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
        if ($separator -le 0) {
            continue
        }

        $name = $line.Substring(0, $separator)
        if ($allowed -notcontains $name) {
            continue
        }

        $data = $line.Substring($separator + 1)
        [System.Environment]::SetEnvironmentVariable($name, $data, "Process")
    }

    # Restaure les entrées PATH d'origine de l'appelant après celles de la chaîne d'outils VS.
    # Cela garde Git/Python/winget accessibles sans permettre à une ancienne installation VS
    # de prendre la priorité sur les VS2022 Build Tools épinglés.
    $mergedPathEntries = New-Object System.Collections.Generic.List[string]
    foreach ($rawPath in @($env:Path, $originalPath)) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) {
            continue
        }

        foreach ($entry in $rawPath.Split(";")) {
            $trimmed = $entry.Trim()
            if (-not $trimmed) {
                continue
            }

            $duplicate = $false
            foreach ($known in $mergedPathEntries) {
                if ([string]::Equals($known, $trimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $duplicate = $true
                    break
                }
            }

            if (-not $duplicate) {
                $mergedPathEntries.Add($trimmed)
            }
        }
    }
    $env:Path = $mergedPathEntries -join ";"

    $env:DISTUTILS_USE_SDK = "1"
    $env:MSSdk = "1"
    $env:CC = $Toolchain.ClPath
    $env:CXX = $Toolchain.ClPath
    $env:CUDAHOSTCXX = $Toolchain.ClPath

    $whereExe = Join-Path $env:SystemRoot "System32\where.exe"
    if (Test-Path -LiteralPath $whereExe -PathType Leaf) {
        $clProbe = Invoke-NativeCapture -Executable $whereExe -Arguments @("cl.exe")
        if ($clProbe.ExitCode -eq 0 -and $clProbe.StdOut.Count -gt 0) {
            $selectedCl = $clProbe.StdOut[0].ToString().Trim()
            if (-not [string]::Equals(
                [System.IO.Path]::GetFullPath($selectedCl),
                [System.IO.Path]::GetFullPath($Toolchain.ClPath),
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                throw "VS2022 environment initialization selected unexpected cl.exe '$selectedCl'; expected '$($Toolchain.ClPath)'."
            }
        }
    }

    $Script:TrellisVsEnvironmentLoaded = $true
    Write-Result "OK" "VS2022 Build Tools environment pinned to MSVC $($Toolchain.MsvcToolset) from a clean child environment"
}

function Set-TrellisNativeBuildEnvironment {
    $toolchain = Assert-TrellisNativeToolchain
    Import-TrellisVs2022BuildEnvironment -Toolchain $toolchain

    $cudaBin = Join-Path $toolchain.CudaRoot "bin"
    $runtimeScripts = Split-Path -Parent $TrellisRuntimeVenvPython
    $env:CUDA_HOME = $toolchain.CudaRoot
    $env:CUDA_PATH = $toolchain.CudaRoot
    $env:CUDACXX = $toolchain.NvccPath

    # Utilise exactement le même ninja.exe pendant l'installation native et pendant
    # les générations. Mélanger un Ninja système avec celui du venv peut invalider
    # .ninja_log et provoquer une recompilation JIT complète au lancement suivant.
    $clBin = Split-Path -Parent $toolchain.ClPath
    $env:Path = "$runtimeScripts;$cudaBin;$clBin;$env:Path"

    $runtimeNinja = Join-Path $runtimeScripts "ninja.exe"
    if (-not (Test-Path -LiteralPath $runtimeNinja -PathType Leaf)) {
        throw "ninja.exe est absent du runtime TRELLIS : $runtimeNinja. Relancez 'trellis runtime-install'."
    }

    # Les RTX 50 Blackwell utilisent la capacité de calcul 12.0.
    $env:TORCH_CUDA_ARCH_LIST = "12.0"
    $env:CUMM_CUDA_ARCH_LIST = "12.0"
    $env:SPCONV_ALGO = "native"
    $env:ATTN_BACKEND = $TrellisAttentionBackend
    $env:PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True"
    $env:MAX_JOBS = "1"

    # Maintient l'environnement d'exécution TRELLIS hermétique. Sous Windows, les packages Python du site utilisateur
    # peuvent sinon masquer les packages éditables cumm/spconv/pccm/ccimport de
    # .venv-runtime et réintroduire silencieusement d'anciens réglages de compilation CUDA/C++14.
    $env:PYTHONNOUSERSITE = "1"

    # CCCL de CUDA 13.4 rejette le préprocesseur traditionnel de MSVC. Force le
    # préprocesseur conforme aux standards pour toutes les compilations d'extensions natives.
    $existingCl = $env:CL
    if ([string]::IsNullOrWhiteSpace($existingCl)) {
        $env:CL = "/Zc:preprocessor"
    } elseif ($existingCl -notmatch '(^|\s)/Zc:preprocessor($|\s)') {
        $env:CL = "$existingCl /Zc:preprocessor"
    }

    Write-Result "OK" "TRELLIS native build environment configured for CUDA 13.4 / sm_120"
    Write-Result "OK" "Ninja TRELLIS pinned to runtime venv: $runtimeNinja"
    Write-Result "OK" "MSVC standards-conforming preprocessor enabled (/Zc:preprocessor)"
}

function Ensure-TrellisNativeBuildPackages {
    if ($NoInstall) {
        return
    }

    $install = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @(
        "-m", "pip", "install", "--upgrade",
        "ninja", "cmake", "packaging", "pybind11", "pccm"
    )
    if ($install.ExitCode -ne 0) {
        throw "TRELLIS native build package installation failed: $($install.Output -join ' | ')"
    }

    Write-Result "OK" "TRELLIS native build packages ready"
}

function Ensure-TrellisExtensionRepository {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [string]$Ref = $null,
        [switch]$Recursive
    )

    $git = Get-GitInfo
    if (-not $git.Installed) {
        throw "Git is required to install TRELLIS native extensions."
    }

    if (-not (Test-Path -LiteralPath $TrellisNativeExtensionsRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $TrellisNativeExtensionsRoot -Force | Out-Null
    }

    $target = Join-Path $TrellisNativeExtensionsRoot $Name

    if (-not (Test-Path -LiteralPath (Join-Path $target ".git") -PathType Container)) {
        if (Test-Path -LiteralPath $target) {
            $entries = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)
            if ($entries.Count -gt 0) {
                throw "Native extension directory '$target' exists but is not a Git checkout. Nothing was deleted."
            }
            Remove-Item -LiteralPath $target -Force
        }

        $args = @("clone")
        if ($Recursive) {
            $args += "--recurse-submodules"
        }
        $args += @($Url, $target)

        Write-Result "INFO" "Cloning native extension $Name..."
        $clone = Invoke-NativeCapture -Executable $git.Path -Arguments $args
        if ($clone.ExitCode -ne 0) {
            throw "Could not clone $Name`: $($clone.Output -join ' | ')"
        }
    }

    $origin = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $target, "remote", "get-url", "origin")
    if ($origin.ExitCode -ne 0 -or $origin.Output.Count -eq 0) {
        throw "Could not verify Git origin for native extension $Name."
    }

    if ((Normalize-GitRemoteUrl $origin.Output[0].ToString().Trim()) -ne (Normalize-GitRemoteUrl $Url)) {
        throw "Native extension $Name has unexpected Git origin '$($origin.Output[0])'. Nothing was modified."
    }

    if (-not [string]::IsNullOrWhiteSpace($Ref)) {
        $checkout = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $target, "checkout", "--detach", $Ref)
        if ($checkout.ExitCode -ne 0) {
            Write-Result "INFO" "Fetching pinned ref for $Name..."
            $fetchRef = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $target, "fetch", "origin", $Ref)
            if ($fetchRef.ExitCode -ne 0) {
                throw "Could not fetch $Name ref $Ref`: $($fetchRef.Output -join ' | ')"
            }

            $checkout = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $target, "checkout", "--detach", "FETCH_HEAD")
            if ($checkout.ExitCode -ne 0) {
                throw "Could not checkout $Name ref $Ref after fetch: $($checkout.Output -join ' | ')"
            }
        }
    }

    if ($Recursive) {
        $sub = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $target, "submodule", "update", "--init", "--recursive")
        if ($sub.ExitCode -ne 0) {
            throw "Could not update submodules for $Name`: $($sub.Output -join ' | ')"
        }
    }

    return $target
}

function Invoke-TrellisPipInstallPath {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Editable,
        [switch]$NoDeps
    )

    if ($NoInstall) {
        throw "$DisplayName is not installed. -NoInstall prevents native extension installation."
    }

    $args = @("-m", "pip", "install", "--no-build-isolation", "-v")
    if ($NoDeps) {
        $args += "--no-deps"
    }
    if ($Editable) {
        $args += "-e"
    }
    $args += $Path

    Write-Result "INFO" "Installing $DisplayName..."
    $install = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments $args
    if ($install.ExitCode -ne 0) {
        $logDir = Join-Path $ProjectRoot "outputs\diagnostics\trellis\native-build"
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $safeName = ($DisplayName -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $logPath = Join-Path $logDir "$safeName-$stamp.log"
        Set-Content -LiteralPath $logPath -Value ($install.Output -join [Environment]::NewLine) -Encoding UTF8

        $interesting = @(
            $install.Output |
            Where-Object {
                $_ -match '(?i)(fatal error|error [A-Z]?\d{3,5}|error:|nvcc fatal|unsupported|not supported|FAILED:|ninja: build stopped|cl.exe|nvcc.exe)'
            } |
            Select-Object -First 20
        )

        Write-Result "FAIL" "$DisplayName build failed. Full log: $logPath"
        if ($interesting.Count -gt 0) {
            Write-Result "INFO" "First relevant compiler diagnostics:"
            foreach ($line in $interesting) {
                Write-Host "  $line"
            }
        } else {
            Write-Result "INFO" "No compiler diagnostic was recognized automatically; inspect the saved log."
        }

        throw "$DisplayName installation failed. See full build log: $logPath"
    }

    Write-Result "OK" "$DisplayName installation completed"
}

function Test-TrellisPythonImport {
    param(
        [Parameter(Mandatory)][string]$Module,
        [string]$Label = $Module
    )

    $probe = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @(
        "-c", "import $Module; print('OK')"
    )
    if ($probe.ExitCode -ne 0) {
        return [pscustomobject]@{
            Valid = $false
            Message = ($probe.Output -join " | ")
        }
    }

    return [pscustomobject]@{
        Valid = $true
        Message = "$Label import OK"
    }
}

function Get-TrellisNativeExtensionState {
    $checks = @(
        [pscustomobject]@{ Name = "spconv"; Module = "spconv.pytorch" },
        [pscustomobject]@{ Name = "nvdiffrast"; Module = "nvdiffrast.torch" },
        [pscustomobject]@{ Name = "diffoctreerast"; Module = "diffoctreerast" },
        [pscustomobject]@{ Name = "diff-gaussian-rasterization"; Module = "diff_gaussian_rasterization" },
        [pscustomobject]@{ Name = "kaolin"; Module = "kaolin" }
    )

    $results = @()
    foreach ($check in $checks) {
        $probe = Test-TrellisPythonImport -Module $check.Module -Label $check.Name
        $results += [pscustomobject]@{
            Name = $check.Name
            Module = $check.Module
            Valid = $probe.Valid
            Message = $probe.Message
        }
    }

    return $results
}

function Test-TrellisSpconvCuda {
    $code = @'
import torch
import spconv.pytorch as spconv

if not torch.cuda.is_available():
    raise RuntimeError("CUDA unavailable")

features = torch.randn((8, 4), device="cuda", dtype=torch.float32)
indices = torch.tensor([
    [0,0,0,0],[0,0,0,1],[0,0,1,0],[0,0,1,1],
    [0,1,0,0],[0,1,0,1],[0,1,1,0],[0,1,1,1],
], device="cuda", dtype=torch.int32)

x = spconv.SparseConvTensor(features, indices, [2,2,2], 1)
layer = spconv.SubMConv3d(4, 4, 3, padding=1, bias=False).cuda()
y = layer(x)
torch.cuda.synchronize()

print(tuple(y.features.shape))
print("SPCONV_CUDA_OK")
'@
    $probe = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @("-c", $code)
    if ($probe.ExitCode -ne 0 -or -not ($probe.Output -contains "SPCONV_CUDA_OK")) {
        throw "spconv CUDA validation failed: $($probe.Output -join ' | ')"
    }

    Write-Result "OK" "spconv CUDA sparse convolution passed on sm_120"
}



function Patch-TrellisPccmCcimportCpp17 {
    $code = @'
from pathlib import Path
import ccimport
import pccm

targets = [
    (Path(ccimport.__file__).resolve().parent / "core.py", [
        ('std: Optional[str] = "c++14"', 'std: Optional[str] = "c++17"'),
    ]),
    (Path(pccm.__file__).resolve().parent / "builder" / "pybind.py", [
        ('std="c++14"', 'std="c++17"'),
        ('cxx_standard="14"', 'cxx_standard="17"'),
    ]),
]

for path, replacements in targets:
    if not path.is_file():
        raise SystemExit(f"missing build helper: {path}")

    text = path.read_text(encoding="utf-8")
    original = text

    for old, new in replacements:
        text = text.replace(old, new)

    if text != original:
        path.write_text(text, encoding="utf-8")
        print(f"patched:{path}")
    else:
        print(f"already:{path}")

# Valide les valeurs par défaut effectives à partir du texte source, car l'import des
# modules seuls n'expose pas de manière fiable toutes les valeurs par défaut des fonctions.
ccimport_core = targets[0][0].read_text(encoding="utf-8")
pccm_pybind = targets[1][0].read_text(encoding="utf-8")

if 'std: Optional[str] = "c++14"' in ccimport_core:
    raise SystemExit("ccimport still defaults to c++14")
if 'std="c++14"' in pccm_pybind:
    raise SystemExit("pccm build_pybind/build_library still defaults to c++14")
if 'cxx_standard="14"' in pccm_pybind:
    raise SystemExit("pccm gen_cmake still defaults to c++14")

print("validated")
'@

    $result = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @("-c", $code)
    if ($result.ExitCode -ne 0) {
        throw "Could not patch pccm/ccimport C++17 defaults for CUDA 13: $($result.Output -join ' | ')"
    }

    foreach ($line in $result.Output) {
        if ($line -eq "validated") {
            continue
        }
        Write-Result "INFO" "pccm/ccimport C++17 patch: $line"
    }

    Write-Result "OK" "pccm/ccimport native build defaults pinned to C++17"
}

function Patch-TrellisCuda13Cpp17Tree {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "$Label source directory is missing: $Root"
    }

    # spconv/cumm génèrent actuellement des fichiers de compilation native pouvant forcer C++14.
    # CUDA 13.x exige que le chemin natif généré utilise C++17 dans cette pile.
    # Corrige chaque descripteur textuel de source/compilation dans le checkout local ignoré,
    # pas seulement les fichiers CMake, car pccm/ccimport peut émettre le standard depuis
    # des modèles Python et des fragments Ninja/CMake générés.
    $extensions = @(
        ".py", ".pyi", ".cmake", ".txt", ".in", ".ninja",
        ".cc", ".cpp", ".cxx", ".cu", ".h", ".hpp"
    )

    $files = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq "CMakeLists.txt" -or
            $extensions -contains $_.Extension.ToLowerInvariant()
        }
    )

    $patchedFiles = 0
    $replacements = 0

    foreach ($file in $files) {
        try {
            $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
            if ($null -eq $raw) {
                continue
            }

            $updated = $raw
            $pairs = @(
                @("/std:c++14", "/std:c++17"),
                @("-std=c++14", "-std=c++17"),
                @("--std=c++14", "--std=c++17"),
                @("cxx_std_14", "cxx_std_17")
            )

            foreach ($pair in $pairs) {
                $before = $updated
                $updated = $updated.Replace($pair[0], $pair[1])
                if ($updated -ne $before) {
                    $replacements++
                }
            }

            # Correspond aux déclarations tolérant les espaces contrôlées par
            # Assert-TrellisNoCpp14BuildFlags (par exemple : std = "c++14").
            # Conserve les espaces et les guillemets ; seule la version du standard est modifiée.
            $regexPairs = @(
                @('(std\s*=\s*["'']c\+\+)14(["''])', '${1}17${2}'),
                @('(std\s*=\s*["'']c\+\+17["'']\s+if\s+compat\.InMacOS\s+else\s+["'']c\+\+)14(["''])', '${1}17${2}'),
                @('(cxx_standard\s*=\s*["''])14(["''])', '${1}17${2}'),
                @('((?:CMAKE_)?(?:CXX|CUDA)_STANDARD\s+)14', '${1}17')
            )

            foreach ($pair in $regexPairs) {
                $before = $updated
                $updated = [regex]::Replace($updated, $pair[0], $pair[1])
                if ($updated -ne $before) {
                    $replacements++
                }
            }

            if ($updated -ne $raw) {
                Set-Content -LiteralPath $file.FullName -Value $updated -Encoding UTF8
                $patchedFiles++
            }
        } catch {
            # Les fichiers binaires ou illisibles sont volontairement ignorés.
        }
    }

    Write-Result "INFO" "$Label CUDA 13 C++17 compatibility patch: $patchedFiles file(s), $replacements replacement group(s)"
}

function Assert-TrellisNoCpp14BuildFlags {
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [Parameter(Mandatory)][string]$Label
    )

    $patterns = @(
        '/std:c\+\+14',
        '(?<!-)\-std=c\+\+14',
        '--std=c\+\+14',
        'cxx_std_14',
        'CXX_STANDARD\s+14',
        'CUDA_STANDARD\s+14',
        'CMAKE_CXX_STANDARD\s+14',
        'CMAKE_CUDA_STANDARD\s+14',
        'std\s*=\s*["'']c\+\+14["'']',
        'std\s*=\s*["'']c\+\+17["'']\s+if\s+compat\.InMacOS\s+else\s+["'']c\+\+14["'']',
        'cxx_standard\s*=\s*["'']14["'']'
    )

    $extensions = @(
        ".py", ".pyi", ".cmake", ".txt", ".in", ".ninja",
        ".cc", ".cpp", ".cxx", ".cu", ".h", ".hpp"
    )

    $hits = New-Object System.Collections.Generic.List[string]

    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $files = @(
            Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq "CMakeLists.txt" -or
                $extensions -contains $_.Extension.ToLowerInvariant()
            }
        )

        foreach ($file in $files) {
            try {
                $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
                if ($null -eq $raw) {
                    continue
                }

                foreach ($pattern in $patterns) {
                    if ($raw -match $pattern) {
                        $hits.Add("$($file.FullName) :: $pattern")
                        break
                    }
                }
            } catch {}
        }
    }

    if ($hits.Count -gt 0) {
        $sample = @($hits | Select-Object -First 12) -join " | "
        throw "$Label still contains CUDA 13-incompatible C++14 build flags after patching: $sample"
    }

    Write-Result "OK" "$Label contains no known C++14 native build flags"
}

function Reset-TrellisNativeBuildCache {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Label
    )

    $candidates = @(
        (Join-Path $Root "build"),
        (Join-Path $Root "dist")
    )

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Write-Result "INFO" "Removed stale $Label native build cache: $path"
        }
    }

    Get-ChildItem -LiteralPath $Root -Directory -Filter "*.egg-info" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
            Write-Result "INFO" "Removed stale $Label metadata cache: $($_.FullName)"
        }
}

function Patch-TrellisSpconvCompatibility {
    param([Parameter(Mandatory)][string]$Root)

    # MSVC ne peut pas ouvrir certains en-têtes générés dont les chemins dépassent 260 caractères.
    # Utilise l'option build_dir de pccm ; conserve le module résultant dans core_cc.
    $buildRoot = Join-Path $ProjectRoot "outputs\diagnostics\spconv\build"
    $code = @'
from pathlib import Path
import ast
import re
import sys

path = Path(sys.argv[1]) / "spconv" / "build.py"
build_root = Path(sys.argv[2])
text = path.read_text(encoding="utf-8-sig")
marker = "# Asset Factory: short MSVC build paths"
replacement = f"build_dir=Path({str(build_root)!r}), {marker}"
pattern = r"(?m)^(\s*)build_dir=.*?, # Asset Factory: short MSVC build paths$"
if marker in text:
    updated, count = re.subn(pattern, lambda m: m[1] + replacement, text)
else:
    calls = [n for n in ast.walk(ast.parse(text))
             if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
             and n.func.attr == "build_pybind"]
    if len(calls) != 1 or any(k.arg == "build_dir" for k in calls[0].keywords):
        raise SystemExit("unexpected spconv build_pybind call; refusing to overwrite build settings")
    pattern = r"(?m)^([ \t]*)namespace_root=PACKAGE_ROOT,"
    updated, count = re.subn(pattern, lambda m: m[0] + "\n" + m[1] + replacement, text)
if count != 1:
    raise SystemExit("expected exactly one spconv build directory patch")
ast.parse(updated)
if updated != text:
    path.write_text(updated, encoding="utf-8")

# Les en-têtes Thrust de CUDA 13 n'incluent plus tuple.h transitivement ici.
# L'ajoute uniquement au modèle qui génère les deux kernels de tri de l'allocateur.
source = Path(sys.argv[1]) / "spconv" / "csrc" / "sparse" / "all.py"
text = source.read_text(encoding="utf-8-sig")
needle = ("def sort_1d_by_key_allocator_template(self, use_allocator: bool):\n"
          "        code = pccm.FunctionCode()")
replacement = needle + '\n        code.code_after_include = "#include <thrust/tuple.h>"'
if replacement not in text:
    if text.count(needle) != 1:
        raise SystemExit("unexpected spconv allocator sort template; cannot add Thrust tuple include")
    updated = text.replace(needle, replacement, 1)
    ast.parse(updated)
    source.write_text(updated, encoding="utf-8")
print(build_root)
'@
    $result = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @("-c", $code, $Root, $buildRoot)
    if ($result.ExitCode -ne 0) {
        throw "Could not patch spconv Windows/CUDA compatibility: $($result.Output -join ' | ')"
    }
    Write-Result "OK" "spconv generated build directory: $buildRoot"
    Write-Result "OK" "spconv allocator sort kernels explicitly include thrust/tuple.h"
}

function Ensure-TrellisSpconv {
    # L'import d'un spconv éditable déclenche une compilation JIT. Corrige avant le
    # premier test ainsi qu'après un nouveau checkout afin que les relances puissent réutiliser les builds.
    $existingSpconv = Join-Path $TrellisNativeExtensionsRoot "spconv"
    if (Test-Path -LiteralPath (Join-Path $existingSpconv "spconv\build.py") -PathType Leaf) {
        Patch-TrellisSpconvCompatibility -Root $existingSpconv
        # Le test de réutilisation peut lui aussi régénérer du code cumm/spconv. Applique les mêmes
        # correctifs C++17 et la même protection avant ce chemin JIT, pas seulement avant pip.
        foreach ($name in @("cumm", "spconv")) {
            $sourceRoot = Join-Path $TrellisNativeExtensionsRoot $name
            if (Test-Path -LiteralPath $sourceRoot -PathType Container) {
                Patch-TrellisCuda13Cpp17Tree -Root $sourceRoot -Label $name
                Assert-TrellisNoCpp14BuildFlags -Roots @($sourceRoot) -Label "$name existing source tree"
            }
        }
    }
    $probe = Test-TrellisPythonImport -Module "spconv.pytorch" -Label "spconv"
    if ($probe.Valid) {
        try {
            Test-TrellisSpconvCuda
            return
        } catch {
            Write-Result "WARN" "Existing spconv is not usable on this Blackwell runtime; rebuilding from public source."
        }
    }

    if ($NoInstall) {
        throw "spconv is missing or unusable. -NoInstall prevents source installation."
    }

    Set-TrellisNativeBuildEnvironment
    Ensure-TrellisNativeBuildPackages
    Patch-TrellisPccmCcimportCpp17

    # Supprime d'abord les anciennes variantes binaires. Le projet spconv amont avertit explicitement
    # qu'il ne faut pas mélanger les packages CUDA spconv/cumm.
    $uninstall = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @(
        "-m", "pip", "uninstall", "-y",
        "spconv", "spconv-cu120", "spconv-cu121", "spconv-cu124", "spconv-cu126", "spconv-cu128", "spconv-cu130",
        "cumm", "cumm-cu120", "cumm-cu121", "cumm-cu124", "cumm-cu126", "cumm-cu128", "cumm-cu130"
    )
    if ($uninstall.ExitCode -ne 0) {
        Write-Result "WARN" "Cleanup of previous spconv/cumm packages returned exit code $($uninstall.ExitCode); continuing with source build."
    }

    $cumm = Ensure-TrellisExtensionRepository -Name "cumm" -Url $TrellisCummRepoUrl -Recursive
    $spconv = Ensure-TrellisExtensionRepository -Name "spconv" -Url $TrellisSpconvRepoUrl -Recursive
    Patch-TrellisSpconvCompatibility -Root $spconv

    # Important : corrige les DEUX arborescences de sources avant d'installer cumm. Le code core_cc
    # généré par spconv importe des modèles/en-têtes depuis cumm ; corriger uniquement spconv
    # laisse donc /std:c++14 dans les commandes de compilation Windows générées.
    Patch-TrellisCuda13Cpp17Tree -Root $cumm -Label "cumm"
    Patch-TrellisCuda13Cpp17Tree -Root $spconv -Label "spconv"
    Assert-TrellisNoCpp14BuildFlags -Roots @($cumm, $spconv) -Label "cumm/spconv source trees"

    # La tentative précédente ayant échoué peut déjà avoir généré des fichiers core_cc/Ninja
    # contenant /std:c++14. Supprime uniquement les sorties de compilation jetables afin qu'elles soient
    # régénérées à partir des arborescences de sources corrigées.
    Reset-TrellisNativeBuildCache -Root $cumm -Label "cumm"
    Reset-TrellisNativeBuildCache -Root $spconv -Label "spconv"

    Invoke-TrellisPipInstallPath -DisplayName "cumm (source)" -Path $cumm -Editable -NoDeps

    # L'installation de cumm peut générer des descripteurs de compilation locaux supplémentaires.
    # Corrige une nouvelle fois avant que spconv ne déclenche sa propre génération pccm/ccimport.
    Patch-TrellisCuda13Cpp17Tree -Root $cumm -Label "cumm"
    Patch-TrellisCuda13Cpp17Tree -Root $spconv -Label "spconv"
    Assert-TrellisNoCpp14BuildFlags -Roots @($cumm, $spconv) -Label "cumm/spconv regenerated trees"

    Invoke-TrellisPipInstallPath -DisplayName "spconv (source)" -Path $spconv -Editable -NoDeps
    Test-TrellisSpconvCuda
}


function Ensure-TrellisNvdiffrast {
    $probe = Test-TrellisPythonImport -Module "nvdiffrast.torch" -Label "nvdiffrast"
    if ($probe.Valid) {
        Write-Result "OK" "nvdiffrast import already works"
        return
    }

    Set-TrellisNativeBuildEnvironment
    Ensure-TrellisNativeBuildPackages
    $repo = Ensure-TrellisExtensionRepository -Name "nvdiffrast" -Url $TrellisNvdiffrastRepoUrl -Ref $TrellisNvdiffrastRef
    Invoke-TrellisPipInstallPath -DisplayName "nvdiffrast pinned source" -Path $repo -NoDeps

    $verify = Test-TrellisPythonImport -Module "nvdiffrast.torch" -Label "nvdiffrast"
    if (-not $verify.Valid) {
        throw "nvdiffrast import validation failed: $($verify.Message)"
    }
    Write-Result "OK" "nvdiffrast import validated"
}

function Ensure-TrellisDiffOctreeRast {
    $probe = Test-TrellisPythonImport -Module "diffoctreerast" -Label "diffoctreerast"
    if ($probe.Valid) {
        Write-Result "OK" "diffoctreerast import already works"
        return
    }

    Set-TrellisNativeBuildEnvironment
    Ensure-TrellisNativeBuildPackages
    $repo = Ensure-TrellisExtensionRepository -Name "diffoctreerast" -Url $TrellisDiffOctreeRepoUrl -Recursive
    Invoke-TrellisPipInstallPath -DisplayName "diffoctreerast" -Path $repo -NoDeps

    $verify = Test-TrellisPythonImport -Module "diffoctreerast" -Label "diffoctreerast"
    if (-not $verify.Valid) {
        throw "diffoctreerast import validation failed: $($verify.Message)"
    }
    Write-Result "OK" "diffoctreerast import validated"
}

function Ensure-TrellisMipGaussian {
    $probe = Test-TrellisPythonImport -Module "diff_gaussian_rasterization" -Label "diff-gaussian-rasterization"
    if ($probe.Valid) {
        Write-Result "OK" "diff-gaussian-rasterization import already works"
        return
    }

    Set-TrellisNativeBuildEnvironment
    Ensure-TrellisNativeBuildPackages
    $repo = Ensure-TrellisExtensionRepository -Name "mip-splatting" -Url $TrellisMipSplattingRepoUrl -Recursive
    $subdir = Join-Path $repo "submodules\diff-gaussian-rasterization"
    if (-not (Test-Path -LiteralPath $subdir -PathType Container)) {
        throw "mip-splatting diff-gaussian-rasterization submodule is missing: $subdir"
    }

    Invoke-TrellisPipInstallPath -DisplayName "mip-splatting diff-gaussian-rasterization" -Path $subdir -NoDeps

    $verify = Test-TrellisPythonImport -Module "diff_gaussian_rasterization" -Label "diff-gaussian-rasterization"
    if (-not $verify.Valid) {
        throw "diff-gaussian-rasterization import validation failed: $($verify.Message)"
    }
    Write-Result "OK" "diff-gaussian-rasterization import validated"
}


function Ensure-TrellisKaolinBuildPrerequisites {
    # Kaolin v0.18.0 exécute setup.py pendant la génération des métadonnées. Son setup.py
    # importe pkg_resources, Cython et NumPy avant la compilation réelle de l'extension ;
    # ils doivent donc tous être déjà présents dans l'environnement TRELLIS non isolé.
    $code = @'
import sys

errors = []

try:
    import setuptools
    import pkg_resources
    print("setuptools=" + setuptools.__version__)
except Exception as exc:
    errors.append("pkg_resources/setuptools: " + repr(exc))

try:
    import Cython
    print("cython=" + Cython.__version__)
except Exception as exc:
    errors.append("Cython: " + repr(exc))

try:
    import numpy
    print("numpy=" + numpy.__version__)
except Exception as exc:
    errors.append("numpy: " + repr(exc))

try:
    import pybind11
    print("pybind11=" + pybind11.__version__)
except Exception as exc:
    errors.append("pybind11: " + repr(exc))

if errors:
    print(" | ".join(errors))
    raise SystemExit(1)
'@

    $probe = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @("-c", $code)
    if ($probe.ExitCode -eq 0) {
        foreach ($line in $probe.Output) {
            Write-Result "OK" "Kaolin build prerequisite: $line"
        }
        return
    }

    if ($NoInstall) {
        throw "Kaolin build prerequisites are incomplete. -NoInstall prevents repair. Details: $($probe.Output -join ' | ')"
    }

    Write-Result "INFO" "Installing the complete Kaolin v0.18.0 metadata/build prerequisite set..."
    $install = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @(
        "-m", "pip", "install", "--upgrade",
        "setuptools==80.10.2",
        "Cython==3.0.12",
        "numpy",
        "pybind11"
    )
    if ($install.ExitCode -ne 0) {
        throw "Could not install Kaolin build prerequisites: $($install.Output -join ' | ')"
    }

    $verify = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments @("-c", $code)
    if ($verify.ExitCode -ne 0) {
        throw "Kaolin build prerequisites were installed but validation still fails: $($verify.Output -join ' | ')"
    }

    foreach ($line in $verify.Output) {
        Write-Result "OK" "Kaolin build prerequisite: $line"
    }
}

function Ensure-TrellisKaolinRuntimeDependencies {
    # Nous compilons Kaolin avec --no-deps afin d'empêcher ses anciennes métadonnées de setup
    # de modifier de manière inattendue la pile PyTorch validée. Installe explicitement à la place
    # les dépendances d'exécution autres que Torch.
    if ($NoInstall) {
        return
    }

    $packages = @(
        "usd-core",
        "Pillow>=8.0.0",
        "tqdm>=4.51.0",
        "scipy",
        "pygltflib",
        "warp-lang"
    )

    Write-Result "INFO" "Installing Kaolin non-Torch runtime dependencies..."
    $args = @("-m", "pip", "install", "--upgrade") + $packages
    $install = Invoke-TrellisPython -PythonPath $TrellisRuntimeVenvPython -Arguments $args
    if ($install.ExitCode -ne 0) {
        throw "Kaolin runtime dependency installation failed: $($install.Output -join ' | ')"
    }

    Write-Result "OK" "Kaolin non-Torch runtime dependencies ready"
}

function Ensure-TrellisKaolin {
    $probe = Test-TrellisPythonImport -Module "kaolin" -Label "kaolin"
    if ($probe.Valid) {
        Write-Result "OK" "kaolin import already works"
        return
    }

    if ($NoInstall) {
        throw "kaolin is missing. -NoInstall prevents source installation."
    }

    Set-TrellisNativeBuildEnvironment
    Ensure-TrellisNativeBuildPackages
    Ensure-TrellisKaolinBuildPrerequisites
    Ensure-TrellisKaolinRuntimeDependencies

    $repo = Ensure-TrellisExtensionRepository -Name "kaolin" -Url $TrellisKaolinRepoUrl -Ref $TrellisKaolinRef -Recursive

    # Kaolin v0.18 valide officiellement des versions de PyTorch bien plus anciennes que notre
    # environnement isolé 2.13, mais la source actuelle connaît CUDA 13 et sm_120.
    # Garde la surcharge locale à cette tentative d'installation et valide ensuite l'import.
    $oldIgnore = $env:IGNORE_TORCH_VER
    $env:IGNORE_TORCH_VER = "1"
    try {
        Invoke-TrellisPipInstallPath -DisplayName "kaolin $TrellisKaolinRef (source)" -Path $repo -NoDeps
    } finally {
        if ($null -eq $oldIgnore) {
            Remove-Item Env:\IGNORE_TORCH_VER -ErrorAction SilentlyContinue
        } else {
            $env:IGNORE_TORCH_VER = $oldIgnore
        }
    }

    $verify = Test-TrellisPythonImport -Module "kaolin" -Label "kaolin"
    if (-not $verify.Valid) {
        throw "kaolin import validation failed: $($verify.Message)"
    }
    Write-Result "OK" "kaolin import validated"
}

function Ensure-TrellisNativeExtensionsStage2 {
    Write-Header "TRELLIS Native Extensions - AF-08C Stage 2"

    Set-TrellisNativeBuildEnvironment
    Ensure-TrellisNativeBuildPackages

    # Installe dans l'ordre du risque de dépendance afin de localiser les échecs et de permettre aux relances
    # de reprendre à partir des composants déjà validés.
    Ensure-TrellisNvdiffrast
    Ensure-TrellisDiffOctreeRast
    Ensure-TrellisMipGaussian
    Ensure-TrellisKaolin
    Ensure-TrellisSpconv

    Write-Result "OK" "TRELLIS AF-08C native stage 2 extensions validated"
}

function Test-TrellisNativeExtensionsStage2 {
    $failures = 0
    $state = Get-TrellisNativeExtensionState

    foreach ($item in $state) {
        if ($item.Valid) {
            Write-Result "OK" "$($item.Name) import"
        } else {
            Write-Result "FAIL" "$($item.Name): $($item.Message)"
            $failures++
        }
    }

    if ($failures -eq 0) {
        try {
            Test-TrellisSpconvCuda
        } catch {
            Write-Result "FAIL" $_.Exception.Message
            $failures++
        }
    }

    return $failures
}


function Show-TrellisNativeStatus {
    Write-Header "TRELLIS Native Status"

    $toolchain = Get-TrellisNativeToolchainInfo

    if ($toolchain.CudaPresent) {
        Write-Result "OK" "CUDA Toolkit $($toolchain.NvccVersion) - $($toolchain.NvccPath)"
    } else {
        Write-Result "MISSING" "CUDA Toolkit 13.4"
    }

    if ($toolchain.VsInstalled) {
        Write-Result "OK" "MSVC $($toolchain.MsvcToolset) - $($toolchain.ClPath)"
    } else {
        Write-Result "MISSING" "Visual Studio 2022 C++ Build Tools"
    }

    if ($toolchain.IntegrationValid) {
        Write-Result "OK" "CUDA 13.4 Visual Studio integration"
    } else {
        Write-Result "MISSING" "CUDA 13.4 Visual Studio integration"
    }

    $sdpa = Get-TrellisSdpaInfo
    if ($sdpa.Available) {
        Write-Result "OK" "PyTorch SDPA CUDA attention backend"
    } else {
        Write-Result "FAIL" "PyTorch SDPA CUDA attention unavailable: $($sdpa.Message)"
    }

    $xformers = Get-TrellisXFormersInfo
    if (-not $xformers.Installed) {
        Write-Result "OK" "xformers not installed; SDPA is the selected backend"
    } elseif ($xformers.CudaKernel) {
        Write-Result "INFO" "xformers $($xformers.Version) is available but optional"
    } else {
        Write-Result "WARN" "xformers $($xformers.Version) is installed but incompatible with this Blackwell stack"
    }

    Write-Result "INFO" "Dense attention backend: $TrellisAttentionBackend"
    Write-Result "INFO" "Sparse attention: upstream TRELLIS 442aa1e requires xformers/flash_attn; Asset Factory compatibility is handled outside the upstream checkout"

    foreach ($item in (Get-TrellisNativeExtensionState)) {
        if ($item.Valid) {
            Write-Result "OK" "$($item.Name) import"
        } else {
            Write-Result "MISSING" "$($item.Name)"
        }
    }
}

function Invoke-TrellisNativeInstall {
    Write-Header "TRELLIS Native Install - AF-08C Stage 1"
    Assert-BootstrapHost

    $runtimeExit = Invoke-TrellisRuntimeDoctor
    if ($runtimeExit -ne 0) {
        throw "TRELLIS native installation aborted because runtime doctor failed."
    }

    $null = Assert-TrellisNativeToolchain
    $null = Invoke-TrellisNativeCompileTest
    Test-TrellisSdpa
    Remove-TrellisBrokenXFormers

    Write-Result "OK" "TRELLIS AF-08C native stage 1 validated"
    Write-Result "INFO" "Validated attention primitive: PyTorch SDPA CUDA"

    Ensure-TrellisNativeExtensionsStage2

    Write-Result "OK" "TRELLIS AF-08C native installation validated"
}

function Invoke-TrellisNativeDoctor {
    Write-Header "TRELLIS Native Doctor"
    $failures = 0

    try {
        $runtimeExit = Invoke-TrellisRuntimeDoctor
        if ($runtimeExit -ne 0) {
            $failures++
        }
    } catch {
        Write-Result "FAIL" $_.Exception.Message
        $failures++
    }

    try {
        $null = Assert-TrellisNativeToolchain
    } catch {
        Write-Result "FAIL" $_.Exception.Message
        $failures++
    }

    if ($failures -eq 0) {
        try {
            $null = Invoke-TrellisNativeCompileTest -Quiet
            Write-Result "OK" "CUDA/MSVC compile test passed for sm_120"
        } catch {
            Write-Result "FAIL" $_.Exception.Message
            $failures++
        }
    }

    if ($failures -eq 0) {
        try {
            Test-TrellisSdpa
        } catch {
            Write-Result "FAIL" $_.Exception.Message
            $failures++
        }
    }

    $xformers = Get-TrellisXFormersInfo
    if ($xformers.Installed -and -not $xformers.CudaKernel) {
        Write-Result "WARN" "xformers $($xformers.Version) is incompatible with this Blackwell runtime; SDPA remains the supported backend."
    } elseif ($xformers.Installed -and $xformers.CudaKernel) {
        Write-Result "INFO" "xformers $($xformers.Version) also works, but SDPA remains selected."
    } else {
        Write-Result "OK" "xformers absent; no incompatible attention backend can be selected accidentally."
    }

    if ($failures -eq 0) {
        $failures += Test-TrellisNativeExtensionsStage2
    }

    if ($failures -gt 0) {
        Write-Result "FAIL" "TRELLIS native doctor found $failures blocking issue(s)."
        return 1
    }

    Write-Result "OK" "TRELLIS AF-08C native stages 1 and 2 are healthy."
    Write-Result "INFO" "Validated attention primitive: PyTorch SDPA CUDA"
    return 0
}


function Show-TrellisStatus {
    Write-Header "TRELLIS Status"

    $repo = Test-TrellisRepository
    if ($repo.Valid) {
        Write-Result "OK" "Repository: $($repo.Origin)"
        $gitState = Get-TrellisGitState
        if ($null -ne $gitState) {
            Write-Result "INFO" "Repository HEAD: $($gitState.Head) / pinned: $TrellisPinnedCommit"
            Write-Result "INFO" "FlexiCubes: $($gitState.FlexiCubes)"
        }
    } elseif ($repo.State -eq "missing") {
        Write-Result "MISSING" "TRELLIS repository not prepared"
    } else {
        Write-Result "WARN" "TRELLIS repository state: $($repo.Message)"
    }

    if (Test-Path -LiteralPath $TrellisBootstrapVenvPython -PathType Leaf) {
        $version = Invoke-NativeCapture -Executable $TrellisBootstrapVenvPython -Arguments @("--version")
        if ($version.ExitCode -eq 0) {
            Write-Result "OK" "Bootstrap venv: $($version.Output[0])"
        }
    } else {
        Write-Result "MISSING" "TRELLIS bootstrap venv"
    }

    $gpu = Get-NvidiaInfo
    if ($gpu.Available) {
        $vramGiB = [math]::Round($gpu.VramMiB / 1024.0, 2)
        Write-Result "OK" "GPU: $($gpu.Name), driver $($gpu.DriverVersion), VRAM $vramGiB GiB"
        if ($gpu.VramMiB -lt 15360) {
            Write-Result "WARN" "Below upstream TRELLIS' official 16 GiB target; Asset Factory low-VRAM/offload execution is required."
        }
    } else {
        Write-Result "MISSING" "NVIDIA GPU information unavailable"
    }

    Write-Result "INFO" "Use 'trellis runtime-status' for the AF-08B runtime."
}

function Show-TrellisRuntimeStatus {
    Write-Header "TRELLIS Runtime Status"

    if (Test-Path -LiteralPath $TrellisRuntimeVenvPython -PathType Leaf) {
        $version = Invoke-NativeCapture -Executable $TrellisRuntimeVenvPython -Arguments @("--version")
        if ($version.ExitCode -eq 0 -and $version.Output.Count -gt 0) {
            Write-Result "OK" "Runtime venv: $($version.Output[0])"
        } else {
            Write-Result "WARN" "Runtime venv exists but Python does not run"
        }
    } else {
        Write-Result "MISSING" "TRELLIS runtime venv"
    }

    $torch = Get-TrellisRuntimeTorchInfo
    if ($torch.Available) {
        Write-Result "OK" "PyTorch $($torch.Torch) / CUDA $($torch.Cuda) / cuda_available=$($torch.CudaAvailable)"
        Write-Result "OK" "GPU: $($torch.Gpu)"
        Write-Result "INFO" "Torch architectures: $($torch.Arch)"
    } else {
        Write-Result "MISSING" "TRELLIS runtime PyTorch not ready"
    }

    Write-Result "INFO" "Use 'trellis native-status' for AF-08C native extension state."
    Write-Result "INFO" "Use trellis model-install to prepare local models, or trellis model-status to verify them offline."
}

function Invoke-TrellisInstall {
    Write-Header "TRELLIS Bootstrap Install"
    Assert-BootstrapHost

    if ($NoInstall) {
        $doctorExit = Invoke-TrellisDoctor
        if ($doctorExit -ne 0) {
            throw "TRELLIS bootstrap validation failed while -NoInstall was active."
        }
        return
    }

    $git = Get-GitInfo
    if (-not $git.Installed) {
        Install-WingetPackage -Id "Git.Git" -DisplayName "Git"
    }

    $gpu = Get-NvidiaInfo
    if (-not $gpu.Available) {
        throw "NVIDIA GPU is not detectable with nvidia-smi."
    }

    Ensure-TrellisRepository
    Ensure-TrellisVenv -VenvPath $TrellisBootstrapVenv -VenvPython $TrellisBootstrapVenvPython -PythonVersion $TrellisBootstrapPythonVersion -Label "TRELLIS bootstrap"
    Ensure-TrellisPackagingTools -PythonPath $TrellisBootstrapVenvPython -Label "TRELLIS bootstrap"

    Write-Result "OK" "TRELLIS AF-08A bootstrap prepared"
}

function Invoke-TrellisDoctor {
    Write-Header "TRELLIS Bootstrap Doctor"
    $failures = 0

    $repo = Test-TrellisRepository
    if ($repo.Valid) {
        Write-Result "OK" "Official TRELLIS repository valid"
        $gitState = Get-TrellisGitState
        if ($null -eq $gitState -or $gitState.Head -ne $TrellisPinnedCommit) {
            Write-Result "FAIL" "TRELLIS HEAD is not pinned to $TrellisPinnedCommit"
            $failures++
        } else {
            Write-Result "OK" "TRELLIS pinned commit $TrellisPinnedCommit"
        }
    } else {
        Write-Result "FAIL" "Repository: $($repo.Message)"
        $failures++
    }

    if (Test-Path -LiteralPath $TrellisBootstrapVenvPython -PathType Leaf) {
        Write-Result "OK" "TRELLIS bootstrap venv present"
    } else {
        Write-Result "FAIL" "TRELLIS bootstrap venv missing"
        $failures++
    }

    $gpu = Get-NvidiaInfo
    if ($gpu.Available) {
        $vramGiB = [math]::Round($gpu.VramMiB / 1024.0, 2)
        Write-Result "OK" "NVIDIA GPU detected: $($gpu.Name), $vramGiB GiB VRAM"
        if ($gpu.VramMiB -lt 15360) {
            Write-Result "WARN" "GPU is below upstream TRELLIS' official 16 GiB requirement; low-VRAM/offload execution is mandatory."
        }
    } else {
        Write-Result "FAIL" "NVIDIA GPU is not detectable with nvidia-smi."
        $failures++
    }

    if ($failures -gt 0) {
        Write-Result "FAIL" "TRELLIS bootstrap doctor found $failures blocking issue(s)."
        return 1
    }

    Write-Result "OK" "TRELLIS AF-08A bootstrap is ready."
    return 0
}

function Invoke-TrellisRuntimeInstall {
    Write-Header "TRELLIS Runtime Install"
    Assert-BootstrapHost

    $bootstrapExit = Invoke-TrellisDoctor
    if ($bootstrapExit -ne 0) {
        throw "TRELLIS runtime installation aborted because the bootstrap doctor failed."
    }

    Ensure-TrellisVenv -VenvPath $TrellisRuntimeVenv -VenvPython $TrellisRuntimeVenvPython -PythonVersion $TrellisRuntimePythonVersion -Label "TRELLIS runtime"
    Ensure-TrellisPackagingTools -PythonPath $TrellisRuntimeVenvPython -Label "TRELLIS runtime"
    Ensure-TrellisRuntimePyTorch
    Ensure-TrellisRuntimeBasicPackages
    Test-TrellisRuntimeBasicImports
    Test-TrellisSdpa
    Remove-TrellisBrokenXFormers

    Write-Result "OK" "TRELLIS AF-08B runtime foundation validated"
    Write-Result "INFO" "PyTorch CUDA 13 is isolated inside .venv-runtime; system CUDA Toolkit 12.8 was not modified."
    Write-Result "INFO" "No third-party installer or paid package was used."
    Write-Result "INFO" "Native TRELLIS CUDA extensions are intentionally deferred to AF-08C."
}

function Invoke-TrellisRuntimeDoctor {
    Write-Header "TRELLIS Runtime Doctor"
    $failures = 0

    if (-not (Test-Path -LiteralPath $TrellisRuntimeVenvPython -PathType Leaf)) {
        Write-Result "FAIL" "TRELLIS runtime venv missing"
        $failures++
    } else {
        $version = Invoke-NativeCapture -Executable $TrellisRuntimeVenvPython -Arguments @(
            "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        )
        if ($version.ExitCode -eq 0 -and $version.Output.Count -gt 0 -and $version.Output[0].ToString().Trim() -eq $TrellisRuntimePythonVersion) {
            Write-Result "OK" "TRELLIS runtime Python $TrellisRuntimePythonVersion"
        } else {
            Write-Result "FAIL" "TRELLIS runtime does not use a working Python $TrellisRuntimePythonVersion"
            $failures++
        }
    }

    if ($failures -eq 0) {
        $torch = Get-TrellisRuntimeTorchInfo
        if (-not $torch.Available) {
            Write-Result "FAIL" "TRELLIS runtime PyTorch is not importable"
            $failures++
        } else {
            Write-Result "OK" "PyTorch $($torch.Torch)"
            Write-Result "OK" "PyTorch CUDA $($torch.Cuda)"
            Write-Result "OK" "CUDA available: $($torch.CudaAvailable)"
            Write-Result "OK" "GPU: $($torch.Gpu)"
            Write-Result "INFO" "Torch architectures: $($torch.Arch)"

            if ($torch.Cuda -ne $TrellisExpectedTorchCuda) {
                Write-Result "FAIL" "Expected PyTorch CUDA $TrellisExpectedTorchCuda"
                $failures++
            }
            if (-not $torch.CudaAvailable) {
                Write-Result "FAIL" "CUDA execution unavailable"
                $failures++
            }
            if ($torch.Arch -notmatch "sm_120") {
                Write-Result "FAIL" "sm_120 is absent from the PyTorch architecture list"
                $failures++
            }
        }
    }

    if ($failures -eq 0) {
        try {
            Test-TrellisRuntimeBasicImports
        } catch {
            Write-Result "FAIL" $_.Exception.Message
            $failures++
        }
    }

    if ($failures -eq 0) {
        try {
            Test-TrellisSdpa
        } catch {
            Write-Result "FAIL" $_.Exception.Message
            $failures++
        }
    }

    $xformers = Get-TrellisXFormersInfo
    if ($xformers.Installed -and -not $xformers.CudaKernel) {
        Write-Result "WARN" "xformers $($xformers.Version) is installed but unusable on this Blackwell runtime; rerun 'trellis runtime-install' to remove it."
    } elseif ($xformers.Installed -and $xformers.CudaKernel) {
        Write-Result "INFO" "xformers $($xformers.Version) is present, but Asset Factory does not select it on Blackwell."
    } else {
        Write-Result "OK" "xformers absent; verified PyTorch SDPA remains the supported attention primitive."
    }

    if ($failures -gt 0) {
        Write-Result "FAIL" "TRELLIS runtime doctor found $failures blocking issue(s)."
        return 1
    }

    Write-Result "OK" "TRELLIS AF-08B runtime foundation is healthy."
    Write-Result "INFO" "This still does not certify image-to-3D inference; native CUDA extensions come next."
    return 0
}

function Invoke-TrellisRepair {
    Write-Header "TRELLIS Repair"
    Ensure-TrellisRepository
    Ensure-TrellisVenv -VenvPath $TrellisBootstrapVenv -VenvPython $TrellisBootstrapVenvPython -PythonVersion $TrellisBootstrapPythonVersion -Label "TRELLIS bootstrap"
    Ensure-TrellisPackagingTools -PythonPath $TrellisBootstrapVenvPython -Label "TRELLIS bootstrap"
    Write-Result "OK" "TRELLIS bootstrap repaired"
}

function Invoke-TrellisSmokeTest {
    Write-Header "TRELLIS Smoke Test"
    Write-Result "WARN" "TRELLIS inference smoke is not enabled yet."
    Write-Result "INFO" "Use tools\run-trellis.ps1 for image-to-GLB inference after trellis model-install."
}

function Invoke-TrellisModelPreparation {
    param([switch]$CheckOnly)

    Write-Header "TRELLIS Offline Models"
    Assert-BootstrapHost

    $helper = Join-Path $ProjectRoot "tools\trellis_models.py"
    $modelsDirectory = Join-Path $ProjectRoot "models\trellis"

    if (-not (Test-Path -LiteralPath $TrellisRuntimeVenvPython -PathType Leaf)) {
        throw "TRELLIS runtime is missing. Run 'trellis runtime-install' first."
    }
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        throw "Asset Factory model helper is missing: $helper. Extract the complete offline update pack."
    }

    $mode = if ($CheckOnly -or $NoInstall) { "--check" } else { "--install" }
    $arguments = @(
        "-B", "-s", "-u",
        $helper,
        $mode,
        "--models-dir", $modelsDirectory
    )

    Write-Result "INFO" "Model directory: $modelsDirectory"
    if ($mode -eq "--check") {
        Write-Result "INFO" "Validation only: no downloads, package installs or engine source changes."
    } else {
        Write-Result "INFO" "Preparing TRELLIS weights, pinned DINOv2 source/weights and U2Net."
        Write-Result "INFO" "Existing cached model files will be reused when available. No native rebuild."
    }

    # Affiche la progression du téléchargement en continu. Ne fusionne pas stderr via 2>&1 sous PS 5.1.
    $previousPreference = $ErrorActionPreference
    $exitCode = 1
    try {
        $ErrorActionPreference = "Continue"
        & $TrellisRuntimeVenvPython @arguments
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) {
        throw "TRELLIS model preparation/validation failed (exit code $exitCode). See the diagnostic above."
    }

    Write-Result "OK" "Local model files validated. The offline runner is ready for a generation test."
}


function Invoke-TrellisCommand {
    switch ($EngineCommand) {
        "install"         { Invoke-TrellisInstall }
        "status"          { Show-TrellisStatus }
        "doctor"          {
            $exitCode = Invoke-TrellisDoctor
            if ($exitCode -ne 0) { exit $exitCode }
        }
        "repair"          { Invoke-TrellisRepair }
        "smoke"           { Invoke-TrellisSmokeTest }
        "runtime-install" { Invoke-TrellisRuntimeInstall }
        "runtime-status"  { Show-TrellisRuntimeStatus }
        "runtime-doctor"  {
            $exitCode = Invoke-TrellisRuntimeDoctor
            if ($exitCode -ne 0) { exit $exitCode }
        }
        "native-install"  { Invoke-TrellisNativeInstall }
        "native-status"   { Show-TrellisNativeStatus }
        "native-doctor"   {
            $exitCode = Invoke-TrellisNativeDoctor
            if ($exitCode -ne 0) { exit $exitCode }
        }
        "model-install"   { Invoke-TrellisModelPreparation }
        "model-status"    { Invoke-TrellisModelPreparation -CheckOnly }
    }
}


function Get-ComfyUiPythonInfo {
    $path = Get-PythonPathForVersion -Version $ComfyUiPreferredPythonVersion
    if ($path) {
        return [pscustomobject]@{
            Installed = $true
            Version = $ComfyUiPreferredPythonVersion
            Path = $path
        }
    }

    return [pscustomobject]@{
        Installed = $false
        Version = $null
        Path = $null
    }
}

function Ensure-ComfyUiPython {
    $python = Get-ComfyUiPythonInfo
    if ($python.Installed) {
        Write-Result "OK" "ComfyUI Python $($python.Version) available - $($python.Path)"
        return $python
    }

    if ($NoInstall) {
        throw "ComfyUI requires Python 3.11, but it is not installed. -NoInstall prevents automatic installation."
    }

    Install-WingetPackage -Id "Python.Python.3.11" -DisplayName "Python 3.11 for ComfyUI"
    Refresh-ProcessPath

    $python = Get-ComfyUiPythonInfo
    if (-not $python.Installed) {
        throw "Python 3.11 installation completed, but ComfyUI-compatible Python is still not detectable. Open a new terminal and rerun 'comfyui install'."
    }

    return $python
}

function Test-ComfyUiRepository {
    if (-not (Test-Path -LiteralPath $ComfyUiRoot)) {
        return [pscustomobject]@{ Valid = $false; State = "missing"; Origin = $null; Message = "engines\comfyui does not exist" }
    }

    $gitDir = Join-Path $ComfyUiRoot ".git"
    if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) {
        return [pscustomobject]@{ Valid = $false; State = "partial"; Origin = $null; Message = "engines\comfyui exists but is not a Git repository" }
    }

    $git = Get-GitInfo
    if (-not $git.Installed) {
        return [pscustomobject]@{ Valid = $false; State = "blocked"; Origin = $null; Message = "Git is unavailable" }
    }

    $originResult = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $ComfyUiRoot, "remote", "get-url", "origin")
    if ($originResult.ExitCode -ne 0 -or $originResult.Output.Count -eq 0) {
        return [pscustomobject]@{ Valid = $false; State = "blocked"; Origin = $null; Message = "Could not read ComfyUI origin" }
    }

    $origin = ($originResult.Output | Select-Object -First 1).ToString().Trim()
    if ((Normalize-GitRemoteUrl $origin) -ne (Normalize-GitRemoteUrl $ComfyUiRepoUrl)) {
        return [pscustomobject]@{ Valid = $false; State = "wrong-origin"; Origin = $origin; Message = "Unexpected ComfyUI origin" }
    }

    if (-not (Test-Path -LiteralPath $ComfyUiMain -PathType Leaf)) {
        return [pscustomobject]@{ Valid = $false; State = "incomplete"; Origin = $origin; Message = "main.py is missing" }
    }

    if (-not (Test-Path -LiteralPath $ComfyUiRequirements -PathType Leaf)) {
        return [pscustomobject]@{ Valid = $false; State = "incomplete"; Origin = $origin; Message = "requirements.txt is missing" }
    }

    return [pscustomobject]@{ Valid = $true; State = "ready"; Origin = $origin; Message = "Official ComfyUI repository present" }
}

function Ensure-ComfyUiRepository {
    $git = Get-GitInfo
    if (-not $git.Installed) {
        throw "Git is required before installing ComfyUI."
    }

    $enginesDir = Join-Path $ProjectRoot "engines"
    if (-not (Test-Path -LiteralPath $enginesDir -PathType Container)) {
        New-Item -ItemType Directory -Path $enginesDir -Force | Out-Null
    }

    $state = Test-ComfyUiRepository
    if ($state.State -eq "missing") {
        Write-Result "INFO" "Cloning ComfyUI $ComfyUiPinnedRef..."
        $clone = Invoke-NativeCapture -Executable $git.Path -Arguments @(
            "clone",
            "--branch", $ComfyUiPinnedRef,
            "--single-branch",
            $ComfyUiRepoUrl,
            $ComfyUiRoot
        )
        if ($clone.ExitCode -ne 0) {
            throw "Could not clone ComfyUI $ComfyUiPinnedRef`: $($clone.Output -join ' | ')"
        }

        $state = Test-ComfyUiRepository
        if (-not $state.Valid) {
            throw "ComfyUI clone completed but repository verification failed: $($state.Message)"
        }
    } elseif (-not $state.Valid) {
        if ($state.State -eq "wrong-origin") {
            throw "engines\comfyui is a Git repository with unexpected origin '$($state.Origin)'. Nothing was modified."
        }

        throw "ComfyUI repository is incomplete or invalid: $($state.Message). Nothing was deleted."
    }

    # Reproductibilité : Asset Factory valide actuellement ComfyUI v0.35.0.
    # Les dépôts existants ne sont déplacés vers la version épinglée que lorsque les fichiers
    # suivis sont propres. Les données d'exécution telles que les modèles et .venv ne sont pas modifiées.
    $dirty = Invoke-NativeCapture -Executable $git.Path -Arguments @(
        "-C", $ComfyUiRoot,
        "status", "--porcelain", "--untracked-files=no"
    )
    if ($dirty.ExitCode -ne 0) {
        throw "Could not inspect ComfyUI worktree state: $($dirty.Output -join ' | ')"
    }

    $target = Invoke-NativeCapture -Executable $git.Path -Arguments @(
        "-C", $ComfyUiRoot,
        "rev-parse", "$ComfyUiPinnedRef^{commit}"
    )
    if ($target.ExitCode -ne 0 -or $target.Output.Count -eq 0) {
        $fetch = Invoke-NativeCapture -Executable $git.Path -Arguments @(
            "-C", $ComfyUiRoot,
            "fetch", "--tags", "origin", $ComfyUiPinnedRef
        )
        if ($fetch.ExitCode -ne 0) {
            throw "Could not fetch pinned ComfyUI ref $ComfyUiPinnedRef`: $($fetch.Output -join ' | ')"
        }
        $target = Invoke-NativeCapture -Executable $git.Path -Arguments @(
            "-C", $ComfyUiRoot,
            "rev-parse", "$ComfyUiPinnedRef^{commit}"
        )
    }

    if ($target.ExitCode -ne 0 -or $target.Output.Count -eq 0) {
        throw "Could not resolve pinned ComfyUI ref $ComfyUiPinnedRef."
    }

    $head = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $ComfyUiRoot, "rev-parse", "HEAD")
    if ($head.ExitCode -ne 0 -or $head.Output.Count -eq 0) {
        throw "Could not resolve current ComfyUI HEAD."
    }

    $headSha = $head.Output[0].ToString().Trim()
    $targetSha = $target.Output[0].ToString().Trim()

    if ($headSha -ne $targetSha) {
        if ($dirty.Output.Count -gt 0) {
            throw "ComfyUI tracked files contain local changes. Refusing to switch to pinned release $ComfyUiPinnedRef. Commit/revert those changes first."
        }

        Write-Result "INFO" "Switching ComfyUI to validated release $ComfyUiPinnedRef..."
        $checkout = Invoke-NativeCapture -Executable $git.Path -Arguments @(
            "-C", $ComfyUiRoot,
            "checkout", "--detach", $targetSha
        )
        if ($checkout.ExitCode -ne 0) {
            throw "Could not checkout ComfyUI $ComfyUiPinnedRef`: $($checkout.Output -join ' | ')"
        }
    }

    $verify = Test-ComfyUiRepository
    if (-not $verify.Valid) {
        throw "ComfyUI repository verification failed after pinning: $($verify.Message)"
    }

    Write-Result "OK" "Official ComfyUI repository ready at $ComfyUiPinnedRef"
}

function Ensure-ComfyUiVenv {
    # Réutilise un environnement virtuel valide existant même si l'installation Python de base n'est plus
    # détectable. Un interpréteur de base n'est requis que pour créer ou
    # recréer l'environnement virtuel.
    if (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf) {
        $versionResult = Invoke-NativeCapture -Executable $ComfyUiVenvPython -Arguments @(
            "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        )
        if ($versionResult.ExitCode -eq 0 -and $versionResult.Output.Count -gt 0) {
            $version = ($versionResult.Output | Select-Object -First 1).ToString().Trim()
            if ($version -eq $ComfyUiPreferredPythonVersion) {
                Write-Result "OK" "Reusing ComfyUI venv with Python $version"
                return
            }
        }

        if ($NoInstall) {
            throw "ComfyUI venv exists but is broken or does not use Python $ComfyUiPreferredPythonVersion. -NoInstall prevents recreation."
        }

        Write-Result "WARN" "ComfyUI venv exists with unsupported/broken Python; recreating only .venv"
        Remove-Item -LiteralPath $ComfyUiVenv -Recurse -Force
    } elseif (Test-Path -LiteralPath $ComfyUiVenv) {
        if ($NoInstall) {
            throw "Incomplete ComfyUI venv detected. -NoInstall prevents recreation."
        }

        Write-Result "WARN" "Incomplete ComfyUI venv detected; recreating only .venv"
        Remove-Item -LiteralPath $ComfyUiVenv -Recurse -Force
    }

    $python = Ensure-ComfyUiPython
    $result = Invoke-NativeCapture -Executable $python.Path -Arguments @("-m", "venv", $ComfyUiVenv)
    if ($result.ExitCode -ne 0) {
        throw "Could not create ComfyUI venv: $($result.Output -join ' | ')"
    }

    if (-not (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf)) {
        throw "ComfyUI venv creation returned success but python.exe is missing."
    }

    $verify = Invoke-NativeCapture -Executable $ComfyUiVenvPython -Arguments @(
        "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
    )
    if ($verify.ExitCode -ne 0 -or $verify.Output.Count -eq 0 -or $verify.Output[0].ToString().Trim() -ne $ComfyUiPreferredPythonVersion) {
        throw "ComfyUI venv was created but Python version validation failed."
    }

    Write-Result "OK" "Created isolated ComfyUI venv"
}

function Invoke-ComfyUiPython {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if (-not (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf)) {
        throw "ComfyUI venv is missing. Run '.\setup-asset-factory.ps1 comfyui install'."
    }

    return Invoke-NativeCapture -Executable $ComfyUiVenvPython -Arguments $Arguments -WorkingDirectory $ComfyUiRoot
}

function Ensure-ComfyUiPackagingTools {
    $result = Invoke-ComfyUiPython -Arguments @("-m", "pip", "install", "--upgrade", "pip")
    if ($result.ExitCode -ne 0) {
        throw "Could not upgrade ComfyUI pip: $($result.Output -join ' | ')"
    }

    Write-Result "OK" "ComfyUI pip ready"
}

function Get-ComfyUiTorchInfo {
    if (-not (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf)) {
        return [pscustomobject]@{
            Available = $false
            Torch = $null
            TorchVision = $null
            TorchAudio = $null
            Cuda = $null
            CudaAvailable = $false
            Gpu = $null
        }
    }

    $code = @'
import torch
try:
    import torchvision
    torchvision_version = torchvision.__version__
except Exception:
    torchvision_version = ""
try:
    import torchaudio
    torchaudio_version = torchaudio.__version__
except Exception:
    torchaudio_version = ""

print(torch.__version__)
print(torchvision_version)
print(torchaudio_version)
print(torch.version.cuda or "")
print(str(torch.cuda.is_available()))
print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else "")
'@

    $result = Invoke-ComfyUiPython -Arguments @("-c", $code)
    if ($result.ExitCode -ne 0 -or $result.Output.Count -lt 6) {
        return [pscustomobject]@{
            Available = $false
            Torch = $null
            TorchVision = $null
            TorchAudio = $null
            Cuda = $null
            CudaAvailable = $false
            Gpu = $null
        }
    }

    return [pscustomobject]@{
        Available = $true
        Torch = $result.Output[0].ToString().Trim()
        TorchVision = $result.Output[1].ToString().Trim()
        TorchAudio = $result.Output[2].ToString().Trim()
        Cuda = $result.Output[3].ToString().Trim()
        CudaAvailable = ($result.Output[4].ToString().Trim() -eq "True")
        Gpu = $result.Output[5].ToString().Trim()
    }
}

function Ensure-ComfyUiPyTorch {
    $existing = Get-ComfyUiTorchInfo
    $existingUsable = (
        $existing.Available -and
        $existing.Cuda -eq $ComfyUiExpectedTorchCuda -and
        $existing.CudaAvailable -and
        -not [string]::IsNullOrWhiteSpace($existing.Gpu) -and
        -not [string]::IsNullOrWhiteSpace($existing.TorchVision) -and
        -not [string]::IsNullOrWhiteSpace($existing.TorchAudio)
    )

    if ($existingUsable) {
        Write-Result "OK" "Reusing ComfyUI PyTorch $($existing.Torch) / CUDA $($existing.Cuda) / GPU $($existing.Gpu)"
        return
    }

    if ($NoInstall) {
        throw "ComfyUI requires a working PyTorch CUDA $ComfyUiExpectedTorchCuda environment. -NoInstall prevents automatic installation."
    }

    if ($existing.Available) {
        Write-Result "WARN" "Existing ComfyUI PyTorch environment is incomplete/incompatible; repairing only the ComfyUI venv"
    } else {
        Write-Result "INFO" "Installing PyTorch CUDA $ComfyUiExpectedTorchCuda in ComfyUI venv..."
    }

    $install = Invoke-ComfyUiPython -Arguments @(
        "-m", "pip", "install", "--upgrade",
        "torch", "torchvision", "torchaudio",
        "--index-url", $ComfyUiTorchIndexUrl
    )

    if ($install.ExitCode -ne 0) {
        throw "ComfyUI PyTorch installation failed: $($install.Output -join ' | ')"
    }

    $verify = Get-ComfyUiTorchInfo
    if (-not $verify.Available) {
        throw "ComfyUI PyTorch installation completed but torch/vision/audio imports failed."
    }
    if ($verify.Cuda -ne $ComfyUiExpectedTorchCuda) {
        throw "ComfyUI PyTorch installation completed but reports CUDA '$($verify.Cuda)' instead of expected '$ComfyUiExpectedTorchCuda'."
    }
    if (-not $verify.CudaAvailable -or [string]::IsNullOrWhiteSpace($verify.Gpu)) {
        throw "ComfyUI PyTorch installation completed but CUDA GPU execution is unavailable. Check the NVIDIA driver."
    }
    if ([string]::IsNullOrWhiteSpace($verify.TorchVision) -or [string]::IsNullOrWhiteSpace($verify.TorchAudio)) {
        throw "ComfyUI PyTorch installation completed but torchvision or torchaudio is not importable."
    }

    Write-Result "OK" "ComfyUI PyTorch $($verify.Torch) / CUDA $($verify.Cuda) / GPU $($verify.Gpu) installed"
}

function Get-ComfyUiVersion {
    if (-not (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf)) {
        return $null
    }

    $result = Invoke-ComfyUiPython -Arguments @(
        "-c",
        "import comfyui_version; print(comfyui_version.__version__)"
    )
    if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) {
        return $null
    }

    return $result.Output[0].ToString().Trim()
}

function Test-ComfyUiDependencies {
    if (-not (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf)) {
        return [pscustomobject]@{ Valid = $false; Message = "ComfyUI venv is missing" }
    }

    $code = @'
import importlib
modules = [
    "aiohttp",
    "yaml",
    "PIL",
    "numpy",
    "transformers",
    "safetensors",
    "torchsde",
    "sqlalchemy",
    "alembic",
]
failed = []
for name in modules:
    try:
        importlib.import_module(name)
    except Exception as exc:
        failed.append(f"{name}: {exc}")
if failed:
    print(" | ".join(failed))
    raise SystemExit(1)
print("OK")
'@

    $probe = Invoke-ComfyUiPython -Arguments @("-c", $code)
    if ($probe.ExitCode -ne 0) {
        $message = if ($probe.Output.Count -gt 0) { $probe.Output -join " | " } else { "One or more imports failed" }
        return [pscustomobject]@{ Valid = $false; Message = $message }
    }

    return [pscustomobject]@{ Valid = $true; Message = "Core ComfyUI dependencies import successfully" }
}

function Get-FreeTcpPort {
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        if ($null -ne $listener) {
            try { $listener.Stop() } catch {}
        }
    }
}

function Get-FileTailText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$Lines = 40
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    try {
        return ((Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop) -join [Environment]::NewLine)
    } catch {
        return ""
    }
}

function Ensure-ComfyUiRequirements {
    if (-not (Test-Path -LiteralPath $ComfyUiRequirements -PathType Leaf)) {
        throw "ComfyUI requirements.txt is missing."
    }

    if ($NoInstall) {
        $probe = Test-ComfyUiDependencies
        if (-not $probe.Valid) {
            throw "ComfyUI Python dependencies are incomplete. -NoInstall prevents installation. Details: $($probe.Message)"
        }
        Write-Result "OK" "ComfyUI Python dependencies already valid"
        return
    }

    # pip est idempotent ici : les dépendances déjà satisfaites sont réutilisées. PyTorch
    # a d'abord été installé depuis l'index CUDA 13.0 ; les entrées torch non épinglées
    # de requirements.txt restent donc satisfaites au lieu de remplacer le build CUDA.
    $result = Invoke-ComfyUiPython -Arguments @("-m", "pip", "install", "-r", $ComfyUiRequirements)
    if ($result.ExitCode -ne 0) {
        throw "ComfyUI requirements installation failed: $($result.Output -join ' | ')"
    }

    $check = Invoke-ComfyUiPython -Arguments @("-m", "pip", "check")
    if ($check.ExitCode -ne 0) {
        throw "ComfyUI dependency consistency check failed: $($check.Output -join ' | ')"
    }

    $probe = Test-ComfyUiDependencies
    if (-not $probe.Valid) {
        throw "ComfyUI requirements installation completed but runtime dependency probe failed: $($probe.Message)"
    }

    Write-Result "OK" "ComfyUI requirements installed and validated"
}

function Test-ComfyUiFluxModel {
    if (-not (Test-Path -LiteralPath $ComfyUiFluxModelPath -PathType Leaf)) {
        return [pscustomobject]@{
            Present = $false
            Path = $ComfyUiFluxModelPath
            SizeBytes = 0
            Message = "FLUX Schnell checkpoint is missing"
        }
    }

    try {
        $file = Get-Item -LiteralPath $ComfyUiFluxModelPath -ErrorAction Stop

        if ($file.Length -lt 1GB) {
            return [pscustomobject]@{
                Present = $false
                Path = $ComfyUiFluxModelPath
                SizeBytes = $file.Length
                Message = "FLUX Schnell checkpoint exists but is suspiciously small ($([math]::Round($file.Length / 1MB, 2)) MiB)"
            }
        }

        return [pscustomobject]@{
            Present = $true
            Path = $ComfyUiFluxModelPath
            SizeBytes = $file.Length
            Message = "FLUX Schnell checkpoint present"
        }
    } catch {
        return [pscustomobject]@{
            Present = $false
            Path = $ComfyUiFluxModelPath
            SizeBytes = 0
            Message = "Could not inspect FLUX Schnell checkpoint: $($_.Exception.Message)"
        }
    }
}

function Ensure-ComfyUiHuggingFaceHub {
    $probe = Invoke-ComfyUiPython -Arguments @(
        "-c",
        "import huggingface_hub; print(huggingface_hub.__version__)"
    )

    if ($probe.ExitCode -eq 0 -and $probe.Output.Count -gt 0) {
        Write-Result "OK" "huggingface_hub $($probe.Output[0]) available in ComfyUI venv"
        return
    }

    if ($NoInstall) {
        throw "huggingface_hub is missing from the ComfyUI venv. -NoInstall prevents installation."
    }

    Write-Result "INFO" "Installing huggingface_hub in ComfyUI venv..."
    $install = Invoke-ComfyUiPython -Arguments @(
        "-m", "pip", "install", "huggingface_hub"
    )

    if ($install.ExitCode -ne 0) {
        throw "Could not install huggingface_hub: $($install.Output -join ' | ')"
    }

    $verify = Invoke-ComfyUiPython -Arguments @(
        "-c",
        "import huggingface_hub; print(huggingface_hub.__version__)"
    )

    if ($verify.ExitCode -ne 0 -or $verify.Output.Count -eq 0) {
        throw "huggingface_hub installation completed but import validation failed."
    }

    Write-Result "OK" "huggingface_hub $($verify.Output[0]) ready"
}

function Invoke-ComfyUiModelInstall {
    Write-Header "ComfyUI Model Install"

    if (-not (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf)) {
        throw "ComfyUI venv is missing. Run '.\\setup-asset-factory.ps1 comfyui install' first."
    }

    $current = Test-ComfyUiFluxModel
    if ($current.Present) {
        $sizeGiB = [math]::Round($current.SizeBytes / 1GB, 2)
        Write-Result "OK" "FLUX Schnell model already present: $($current.Path) ($sizeGiB GiB)"
        return
    }

    if ($NoInstall) {
        throw "$($current.Message). -NoInstall prevents downloading the model."
    }

    Ensure-ComfyUiHuggingFaceHub

    if (-not (Test-Path -LiteralPath $ComfyUiFluxModelsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $ComfyUiFluxModelsDir -Force | Out-Null
    }

    Write-Result "INFO" "Downloading $ComfyUiFluxFileName from $ComfyUiFluxRepoId..."
    Write-Result "INFO" "The checkpoint is large. Rerunning this command can resume a Hugging Face download."

    $code = @'
import os
import sys
from huggingface_hub import hf_hub_download

repo_id = sys.argv[1]
filename = sys.argv[2]
target_dir = sys.argv[3]

os.makedirs(target_dir, exist_ok=True)
path = hf_hub_download(
    repo_id=repo_id,
    filename=filename,
    local_dir=target_dir,
)
print(path)
'@

    $download = Invoke-ComfyUiPython -Arguments @(
        "-c", $code,
        $ComfyUiFluxRepoId,
        $ComfyUiFluxFileName,
        $ComfyUiFluxModelsDir
    )

    if ($download.ExitCode -ne 0) {
        throw "FLUX Schnell model download failed: $($download.Output -join ' | ')"
    }

    $verify = Test-ComfyUiFluxModel
    if (-not $verify.Present) {
        throw "Model download completed but validation failed: $($verify.Message)"
    }

    $sizeGiB = [math]::Round($verify.SizeBytes / 1GB, 2)
    Write-Result "OK" "FLUX Schnell model ready: $($verify.Path) ($sizeGiB GiB)"
}

function Test-ComfyUiRuntime {
    $torch = Get-ComfyUiTorchInfo
    if (-not $torch.Available) {
        throw "PyTorch/torchvision/torchaudio are not fully importable in the ComfyUI venv."
    }

    Write-Result "INFO" "torch=$($torch.Torch)"
    Write-Result "INFO" "torchvision=$($torch.TorchVision)"
    Write-Result "INFO" "torchaudio=$($torch.TorchAudio)"
    Write-Result "INFO" "torch_cuda=$($torch.Cuda)"
    Write-Result "INFO" "cuda_available=$($torch.CudaAvailable)"
    Write-Result "INFO" "gpu=$($torch.Gpu)"

    if ($torch.Cuda -ne $ComfyUiExpectedTorchCuda) {
        throw "ComfyUI PyTorch reports CUDA '$($torch.Cuda)'; expected $ComfyUiExpectedTorchCuda."
    }
    if (-not $torch.CudaAvailable) {
        throw "CUDA is unavailable in the ComfyUI venv."
    }
    if ([string]::IsNullOrWhiteSpace($torch.Gpu)) {
        throw "ComfyUI could not identify the CUDA GPU."
    }
    if ([string]::IsNullOrWhiteSpace($torch.TorchVision) -or [string]::IsNullOrWhiteSpace($torch.TorchAudio)) {
        throw "torchvision or torchaudio is not importable in the ComfyUI venv."
    }

    $deps = Test-ComfyUiDependencies
    if (-not $deps.Valid) {
        throw "ComfyUI dependency probe failed: $($deps.Message)"
    }

    $version = Get-ComfyUiVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Could not read the ComfyUI version from comfyui_version.py."
    }
    Write-Result "INFO" "comfyui=$version"

    if ($version -ne $ComfyUiExpectedVersion) {
        throw "ComfyUI version '$version' is not the validated Asset Factory version '$ComfyUiExpectedVersion'. Run 'comfyui install' to restore the pinned release."
    }

    Write-Result "OK" "ComfyUI CUDA runtime validation passed"
}

function Show-ComfyUiStatus {
    Write-Header "ComfyUI Status"

    $repo = Test-ComfyUiRepository
    if ($repo.Valid) {
        Write-Result "OK" "Repository: $($repo.Origin)"
        $git = Get-GitInfo
        if ($git.Installed) {
            $head = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $ComfyUiRoot, "rev-parse", "--short", "HEAD")
            if ($head.ExitCode -eq 0 -and $head.Output.Count -gt 0) {
                Write-Result "INFO" "Repository HEAD: $($head.Output[0]) / pinned ref: $ComfyUiPinnedRef"
            }
        }
    } elseif ($repo.State -eq "missing") {
        Write-Result "MISSING" "ComfyUI repository not installed"
    } else {
        Write-Result "WARN" "ComfyUI repository state: $($repo.Message)"
    }

    $python = Get-ComfyUiPythonInfo
    if ($python.Installed) {
        Write-Result "OK" "Compatible base Python $($python.Version) - $($python.Path)"
    } else {
        Write-Result "INFO" "Base Python 3.11 not currently detectable (an existing valid venv can still be used)"
    }

    if (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf) {
        $version = Invoke-NativeCapture -Executable $ComfyUiVenvPython -Arguments @("--version")
        if ($version.ExitCode -eq 0) {
            Write-Result "OK" "Venv: $(($version.Output | Select-Object -First 1).ToString().Trim())"
        } else {
            Write-Result "WARN" "ComfyUI venv exists but Python does not run"
        }

        $torch = Get-ComfyUiTorchInfo
        if ($torch.Available) {
            Write-Result "OK" "PyTorch $($torch.Torch) / CUDA $($torch.Cuda) / cuda_available=$($torch.CudaAvailable)"
            if (-not [string]::IsNullOrWhiteSpace($torch.Gpu)) {
                Write-Result "OK" "GPU: $($torch.Gpu)"
            }
        } else {
            Write-Result "MISSING" "PyTorch/CUDA not ready in ComfyUI venv"
        }

        $comfyVersion = Get-ComfyUiVersion
        if (-not [string]::IsNullOrWhiteSpace($comfyVersion)) {
            if ($comfyVersion -eq $ComfyUiExpectedVersion) {
                Write-Result "OK" "ComfyUI version $comfyVersion"
            } else {
                Write-Result "WARN" "ComfyUI version $comfyVersion (validated version: $ComfyUiExpectedVersion)"
            }
        }
    } else {
        Write-Result "MISSING" "ComfyUI isolated venv"
    }

    $fluxModel = Test-ComfyUiFluxModel
    if ($fluxModel.Present) {
        $sizeGiB = [math]::Round($fluxModel.SizeBytes / 1GB, 2)
        Write-Result "OK" "FLUX Schnell model: $($fluxModel.Path) ($sizeGiB GiB)"
    } else {
        Write-Result "MISSING" "$($fluxModel.Message). Run .\setup-asset-factory.ps1 comfyui model-install"
    }

    if (Test-Path -LiteralPath $ComfyUiMain -PathType Leaf) {
        Write-Result "OK" "ComfyUI main.py present"
    } else {
        Write-Result "MISSING" "ComfyUI main.py"
    }
}

function Invoke-ComfyUiInstall {
    Write-Header "ComfyUI Install"
    Assert-BootstrapHost

    if ($NoInstall) {
        Write-Result "INFO" "-NoInstall: validation only; no repository/package changes will be made."
        $doctorExit = Invoke-ComfyUiDoctor
        if ($doctorExit -ne 0) {
            throw "ComfyUI validation failed while -NoInstall was active."
        }
        return
    }

    $git = Get-GitInfo
    if (-not $git.Installed) {
        if ($NoInstall) {
            throw "Git is missing and -NoInstall was specified."
        }
        Install-WingetPackage -Id "Git.Git" -DisplayName "Git"
    }

    $gpu = Get-NvidiaInfo
    if (-not $gpu.Available) {
        throw "NVIDIA GPU is not detectable with nvidia-smi."
    }
    Write-Result "OK" "NVIDIA GPU: $($gpu.Name), $($gpu.VramMiB) MiB VRAM"

    Ensure-ComfyUiRepository
    Ensure-ComfyUiVenv
    Ensure-ComfyUiPackagingTools
    Ensure-ComfyUiPyTorch
    Ensure-ComfyUiRequirements
    Test-ComfyUiRuntime

    Write-Result "OK" "ComfyUI installation validated"
}

function Invoke-ComfyUiDoctor {
    Write-Header "ComfyUI Doctor"
    $failures = 0

    if (-not (Test-IsWindows)) {
        Write-Result "FAIL" "Windows is required for this ComfyUI profile."
        $failures++
    } else {
        Write-Result "OK" "Windows detected"
    }

    if ($PSVersionTable.PSVersion -lt $MinimumPowerShellVersion) {
        Write-Result "FAIL" "PowerShell $MinimumPowerShellVersion or newer is required."
        $failures++
    } else {
        Write-Result "OK" "PowerShell version supported: $($PSVersionTable.PSVersion)"
    }

    $repo = Test-ComfyUiRepository
    if ($repo.Valid) {
        Write-Result "OK" "Official ComfyUI repository valid"
    } else {
        Write-Result "FAIL" "Repository: $($repo.Message)"
        $failures++
    }

    if (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf) {
        $version = Invoke-NativeCapture -Executable $ComfyUiVenvPython -Arguments @(
            "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        )
        if ($version.ExitCode -eq 0 -and $version.Output.Count -gt 0 -and $version.Output[0].ToString().Trim() -eq $ComfyUiPreferredPythonVersion) {
            Write-Result "OK" "ComfyUI venv Python $ComfyUiPreferredPythonVersion"
        } else {
            Write-Result "FAIL" "ComfyUI venv does not use a working Python $ComfyUiPreferredPythonVersion"
            $failures++
        }
    } else {
        Write-Result "FAIL" "ComfyUI venv missing"
        $failures++
    }

    if (-not (Test-Path -LiteralPath $ComfyUiMain -PathType Leaf)) {
        Write-Result "FAIL" "ComfyUI main.py missing"
        $failures++
    } else {
        Write-Result "OK" "ComfyUI main.py present"
    }

    if (-not (Test-Path -LiteralPath $ComfyUiRequirements -PathType Leaf)) {
        Write-Result "FAIL" "ComfyUI requirements.txt missing"
        $failures++
    } else {
        Write-Result "OK" "ComfyUI requirements.txt present"
    }

    if ($failures -eq 0) {
        try {
            $pipCheck = Invoke-ComfyUiPython -Arguments @("-m", "pip", "check")
            if ($pipCheck.ExitCode -ne 0) {
                throw "pip check failed: $($pipCheck.Output -join ' | ')"
            }
            Write-Result "OK" "Python dependency consistency check passed"
        } catch {
            Write-Result "FAIL" $_.Exception.Message
            $failures++
        }
    }

    if ($failures -eq 0) {
        try {
            Test-ComfyUiRuntime
        } catch {
            Write-Result "FAIL" $_.Exception.Message
            $failures++
        }
    }

    if ($failures -gt 0) {
        Write-Result "FAIL" "ComfyUI doctor found $failures blocking issue(s)."
        return 1
    }

    Write-Result "OK" "ComfyUI doctor found no blocking issue."
    return 0
}

function Invoke-ComfyUiSmokeTest {
    Write-Header "ComfyUI Smoke Test"

    $doctorExit = Invoke-ComfyUiDoctor
    if ($doctorExit -ne 0) {
        throw "ComfyUI smoke test aborted because doctor failed."
    }

    # Utilise toujours un port libre dédié afin que le smoke test n'interfère jamais avec
    # une instance interactive ComfyUI déjà active sur le port normal 8188.
    $smokePort = Get-FreeTcpPort
    $baseUrl = "http://$($ComfyUiSmokeHost):$smokePort"
    $healthUrl = "$baseUrl/system_stats"

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $logDir = Join-Path $ProjectRoot "outputs\tests\comfyui\$stamp"
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $stdoutPath = Join-Path $logDir "stdout.log"
    $stderrPath = Join-Path $logDir "stderr.log"

    $process = $null
    try {
        $arguments = @(
            "main.py",
            "--lowvram",
            "--listen", $ComfyUiSmokeHost,
            "--port", $smokePort.ToString()
        )

        $startParams = @{
            FilePath = $ComfyUiVenvPython
            ArgumentList = $arguments
            WorkingDirectory = $ComfyUiRoot
            WindowStyle = "Hidden"
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
            PassThru = $true
        }
        $process = Start-Process @startParams

        if ($null -eq $process) {
            throw "Could not start ComfyUI smoke process."
        }

        Write-Result "INFO" "Waiting for ComfyUI API at $healthUrl"
        $deadline = (Get-Date).AddSeconds($ComfyUiSmokeTimeoutSeconds)
        $ready = $false

        while ((Get-Date) -lt $deadline) {
            $process.Refresh()
            if ($process.HasExited) {
                $stderrTail = Get-FileTailText -Path $stderrPath
                $stdoutTail = Get-FileTailText -Path $stdoutPath
                $detailParts = @($stderrTail, $stdoutTail) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $details = $detailParts -join [Environment]::NewLine
                throw "ComfyUI exited before its API became ready (exit code $($process.ExitCode)).`n$details"
            }

            try {
                $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 3
                if ($response.StatusCode -eq 200) {
                    $stats = $response.Content | ConvertFrom-Json
                    if ($null -ne $stats) {
                        $ready = $true
                        break
                    }
                }
            } catch {}

            Start-Sleep -Milliseconds 750
        }

        if (-not $ready) {
            $stderrTail = Get-FileTailText -Path $stderrPath
            $stdoutTail = Get-FileTailText -Path $stdoutPath
            $detailParts = @($stderrTail, $stdoutTail) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $details = $detailParts -join [Environment]::NewLine
            throw "ComfyUI API did not become reachable within $ComfyUiSmokeTimeoutSeconds seconds.`n$details"
        }

        Write-Result "OK" "ComfyUI API smoke test passed at $healthUrl"
    } finally {
        if ($null -ne $process) {
            try {
                $process.Refresh()
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    try { Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue } catch {}
                }
            } catch {}
            try { $process.Dispose() } catch {}
        }
    }
}

function Invoke-ComfyUiCommand {
    switch ($EngineCommand) {
        "install" { Invoke-ComfyUiInstall }
        "status"  { Show-ComfyUiStatus }
        "doctor"  {
            $exitCode = Invoke-ComfyUiDoctor
            if ($exitCode -ne 0) { exit $exitCode }
        }
        "smoke"   { Invoke-ComfyUiSmokeTest }
        "model-install" { Invoke-ComfyUiModelInstall }
        "repair"  {
            Write-Result "INFO" "ComfyUI repair uses the idempotent install/revalidation path."
            Invoke-ComfyUiInstall
        }
    }
}


function Get-MultiViewBlenderPython {
    $blender = Get-BlenderInfo
    if (-not $blender.Installed) { return $null }

    $root = Split-Path -Parent $blender.Path
    $candidate = Get-ChildItem -LiteralPath $root -Filter python.exe -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\python\\bin\\python\.exe$' } |
        Select-Object -First 1
    if ($null -eq $candidate) { return $null }
    return $candidate.FullName
}

function Ensure-MultiViewFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Label
    )

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $item = Get-Item -LiteralPath $Destination
        if ($item.Length -gt 10MB) {
            Write-Result "OK" "$Label déjà présent"
            return
        }
        if ($NoInstall) { throw "$Label est incomplet : $Destination" }
        Remove-Item -LiteralPath $Destination -Force
    }
    if ($NoInstall) { throw "$Label absent : $Destination" }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $curl) { throw "curl.exe est requis pour télécharger $Label." }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    $partial = "$Destination.partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Write-Result "INFO" "Téléchargement : $Label"
    & $curl.Source -L --fail --retry 3 --retry-delay 3 --output $partial $Uri
    if ($LASTEXITCODE -ne 0) { throw "Téléchargement échoué : $Label" }
    if ((Get-Item -LiteralPath $partial).Length -lt 10MB) {
        throw "Fichier téléchargé anormalement petit : $Label"
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
    Write-Result "OK" "$Label prêt"
}

function Ensure-MultiViewBlenderDependencies {
    param([switch]$CheckOnly)

    $blender = Get-BlenderInfo
    if (-not $blender.Installed) {
        if ($NoInstall) { throw "Blender est requis pour le mode multi-vues." }
        Install-WingetPackage -Id "BlenderFoundation.Blender" -DisplayName "Blender"
        Refresh-ProcessPath
        $blender = Get-BlenderInfo
        if (-not $blender.Installed) { throw "Blender reste introuvable après installation." }
    }

    $python = Get-MultiViewBlenderPython
    if ([string]::IsNullOrWhiteSpace($python)) {
        throw "Python embarqué de Blender introuvable sous $($blender.Path)."
    }

    New-Item -ItemType Directory -Path $MultiViewDepsRoot -Force | Out-Null
    & $python -m pip --version *> $null
    if ($LASTEXITCODE -ne 0) {
        if ($CheckOnly -or $NoInstall) {
            throw "pip est absent de Python Blender."
        }
        & $python -m ensurepip --upgrade | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Impossible d'activer pip dans Python Blender." }
    }

    # L'installation ne doit avoir lieu que pendant install/repair.
    # Le doctor valide l'environnement existant sans relancer pip.
    if (-not $CheckOnly -and -not $NoInstall) {
        & $python -m pip install --disable-pip-version-check --upgrade --target $MultiViewDepsRoot "requests==2.32.3" | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Installation de requests pour Blender échouée." }

        & $python -m pip install --disable-pip-version-check --upgrade --no-deps --target $MultiViewDepsRoot `
            "websocket-client==1.8.0" `
            "imageio==2.37.0" `
            "imageio-ffmpeg==0.6.0" `
            "opencv-python-headless==4.11.0.86" `
            "pillow==11.2.1" | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Installation des dépendances Blender multi-vues échouée." }
    }

    $oldPythonPath = $env:PYTHONPATH
    try {
        $env:PYTHONPATH = $MultiViewDepsRoot
        & $python -c "import cv2, imageio, imageio_ffmpeg, requests, websocket; from PIL import Image; print('OK')" | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Validation des dépendances Blender multi-vues échouée." }
    }
    finally {
        $env:PYTHONPATH = $oldPythonPath
    }
    Write-Result "OK" "Dépendances Blender multi-vues validées"
}

function Ensure-MultiViewModels {
    Ensure-MultiViewFile `
        -Uri "https://huggingface.co/ByteDance/SDXL-Lightning/resolve/main/sdxl_lightning_8step_lora.safetensors?download=true" `
        -Destination $MultiViewLightningLora `
        -Label "SDXL Lightning 8-step LoRA"

    Ensure-MultiViewFile `
        -Uri "https://huggingface.co/xinsir/controlnet-depth-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors?download=true" `
        -Destination $MultiViewDepthModel `
        -Label "Depth ControlNet SDXL"

    Ensure-MultiViewFile `
        -Uri "https://huggingface.co/SG161222/RealVisXL_V5.0/resolve/main/RealVisXL_V5.0_fp16.safetensors?download=true" `
        -Destination $MultiViewCheckpoint `
        -Label "RealVisXL V5.0 fp16"
}

function Test-MultiViewModelFiles {
    $missing = @()
    foreach ($item in @(
        @{ Path = $MultiViewCheckpoint; Label = "RealVisXL V5.0 fp16" },
        @{ Path = $MultiViewDepthModel; Label = "Depth ControlNet SDXL" },
        @{ Path = $MultiViewLightningLora; Label = "SDXL Lightning 8-step LoRA" }
    )) {
        if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf) -or
            (Get-Item -LiteralPath $item.Path).Length -lt 10MB) {
            $missing += $item.Label
        }
    }
    return $missing
}

function Show-MultiViewStatus {
    Write-Header "Multi-vues Status"
    if (Test-Path -LiteralPath $MultiViewVendorRoot -PathType Container) {
        Write-Result "OK" "Module Blender multi-vues présent"
    } else {
        Write-Result "MISSING" "Module Blender multi-vues absent"
    }
    if (Test-Path -LiteralPath $MultiViewDriver -PathType Leaf) {
        Write-Result "OK" "Driver interne présent"
    } else {
        Write-Result "MISSING" "Driver interne absent"
    }
    if ((Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf) -and (Test-Path -LiteralPath $ComfyUiMain -PathType Leaf)) {
        Write-Result "OK" "ComfyUI disponible"
    } else {
        Write-Result "MISSING" "ComfyUI incomplet"
    }
    $blender = Get-BlenderInfo
    if ($blender.Installed) { Write-Result "OK" "Blender : $($blender.Path)" }
    else { Write-Result "MISSING" "Blender" }

    $missing = @(Test-MultiViewModelFiles)
    if ($missing.Count -eq 0) { Write-Result "OK" "Modèles multi-vues prêts" }
    else { Write-Result "MISSING" ("Modèles manquants : " + ($missing -join ", ")) }
}

function Invoke-MultiViewDoctor {
    Write-Header "Multi-vues Doctor"
    $failures = 0

    if (-not (Test-Path -LiteralPath $MultiViewVendorRoot -PathType Container)) {
        Write-Result "FAIL" "Module Blender multi-vues absent"; $failures++
    } else { Write-Result "OK" "Module Blender multi-vues présent" }

    if (-not (Test-Path -LiteralPath $MultiViewDriver -PathType Leaf)) {
        Write-Result "FAIL" "Driver interne absent"; $failures++
    } else { Write-Result "OK" "Driver interne présent" }

    if ((-not (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf)) -or
        (-not (Test-Path -LiteralPath $ComfyUiMain -PathType Leaf))) {
        Write-Result "FAIL" "ComfyUI incomplet"; $failures++
    } else { Write-Result "OK" "ComfyUI disponible" }

    $missing = @(Test-MultiViewModelFiles)
    if ($missing.Count -gt 0) {
        Write-Result "FAIL" ("Modèles manquants : " + ($missing -join ", ")); $failures++
    } else { Write-Result "OK" "Modèles multi-vues prêts" }

    try {
        Ensure-MultiViewBlenderDependencies -CheckOnly
    } catch {
        Write-Result "FAIL" $_.Exception.Message
        $failures++
    }

    if ($failures -gt 0) { return 1 }
    Write-Result "OK" "Pipeline multi-vues prêt"
    return 0
}

function Invoke-MultiViewInstall {
    Write-Header "Multi-vues Install"
    Assert-BootstrapHost

    if ((-not (Test-Path -LiteralPath $ComfyUiVenvPython -PathType Leaf)) -or
        (-not (Test-Path -LiteralPath $ComfyUiMain -PathType Leaf))) {
        if ($NoInstall) {
            throw "ComfyUI est absent et -NoInstall est actif."
        }
        Write-Result "INFO" "ComfyUI requis : installation/réparation..."
        Invoke-ComfyUiInstall
    }

    if (-not (Test-Path -LiteralPath $MultiViewVendorRoot -PathType Container)) {
        throw "Le module Blender multi-vues fourni avec Asset Factory est absent : $MultiViewVendorRoot"
    }
    if (-not (Test-Path -LiteralPath $MultiViewDriver -PathType Leaf)) {
        throw "Driver interne multi-vues absent : $MultiViewDriver"
    }

    Ensure-MultiViewBlenderDependencies
    Ensure-MultiViewModels

    $doctorOutput = @(Invoke-MultiViewDoctor)
    $exitCode = if ($doctorOutput.Count -gt 0) { [int]$doctorOutput[-1] } else { 1 }
    if ($exitCode -ne 0) { throw "Validation multi-vues échouée après installation." }
    Write-Result "OK" "Mode multi-vues installé"
}

function Invoke-MultiViewCommand {
    switch ($EngineCommand) {
        "install" { Invoke-MultiViewInstall }
        "status" { Show-MultiViewStatus }
        "doctor" {
            $doctorOutput = @(Invoke-MultiViewDoctor)
            $exitCode = if ($doctorOutput.Count -gt 0) { [int]$doctorOutput[-1] } else { 1 }
            if ($exitCode -ne 0) { exit $exitCode }
        }
        "repair" { Invoke-MultiViewInstall }
        # Conservés comme alias de compatibilité : les trois modèles sont un seul bundle.
        "model-install" { Invoke-MultiViewInstall }
        "model-status" {
            $missing = @(Test-MultiViewModelFiles)
            if ($missing.Count -eq 0) { Write-Result "OK" "Modèles multi-vues prêts" }
            else { Write-Result "MISSING" ($missing -join ", "); exit 1 }
        }
        default { throw "Sous-commande '$EngineCommand' non prise en charge pour multiview." }
    }
}

function Show-Status {
    Write-Header "Status"
    Write-Result "INFO" "Setup script version $ScriptVersion"
    Write-Result "INFO" "Project root: $ProjectRoot"
    Write-Result "OK" "PowerShell $($PSVersionTable.PSVersion)"

    if (Test-Winget) {
        Write-Result "OK" "winget available"
    } else {
        Write-Result "WARN" "winget not found; automatic installs are unavailable"
    }

    $git = Get-GitInfo
    if ($git.Installed) { Write-Result "OK" "$($git.Version) - $($git.Path)" }
    else { Write-Result "MISSING" "Git" }

    $python = Get-PythonInfo
    if ($python.Installed) { Write-Result "OK" "$($python.Version) - $($python.Path)" }
    else { Write-Result "MISSING" "Python" }

    $blender = Get-BlenderInfo
    if ($blender.Installed) { Write-Result "OK" "$($blender.Version) - $($blender.Path)" }
    else { Write-Result "MISSING" "Blender" }

    $gpu = Get-NvidiaInfo
    if ($gpu.Available) {
        $vramGiB = [math]::Round($gpu.VramMiB / 1024.0, 2)
        Write-Result "OK" "$($gpu.Name), driver $($gpu.DriverVersion), VRAM $vramGiB GiB"
        if ($gpu.VramMiB -lt 7168) {
            Write-Result "WARN" "Less than 7 GiB VRAM detected. Heavy local 3D AI workloads may be constrained."
        } elseif ($gpu.VramMiB -lt 10240) {
            Write-Result "INFO" "~8 GiB GPU class detected; heavy GPU workloads must remain sequential."
        }
    } else {
        Write-Result "WARN" "NVIDIA GPU information unavailable"
    }

    $missingDirs = @()
    foreach ($relativePath in $RequiredDirs) {
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $relativePath))) {
            $missingDirs += $relativePath
        }
    }

    if ($missingDirs.Count -eq 0) {
        Write-Result "OK" "Project directory structure present"
    } else {
        Write-Result "WARN" "Missing project directories: $($missingDirs -join ', ')"
    }

    if ($git.Installed) {
        $repoProbe = Invoke-NativeCapture -Executable $git.Path -Arguments @("-C", $ProjectRoot, "rev-parse", "--is-inside-work-tree")
        if ($repoProbe.ExitCode -eq 0) {
            Write-Result "OK" "Git repository initialized"
        } else {
            Write-Result "WARN" "Git repository not initialized"
        }
    }

    $tripoRepoState = Test-TripoSrRepository
    if ($tripoRepoState.Valid) {
        Write-Result "OK" "TripoSR repository installed"
    } elseif ($tripoRepoState.State -eq "missing") {
        Write-Result "INFO" "TripoSR not installed; run .\setup-asset-factory.ps1 triposr install"
    } else {
        Write-Result "WARN" "TripoSR repository state: $($tripoRepoState.Message)"
    }

    $trellisRepoState = Test-TrellisRepository
    if ($trellisRepoState.Valid) {
        Write-Result "OK" "TRELLIS repository installed"
    } elseif ($trellisRepoState.State -eq "missing") {
        Write-Result "INFO" "TRELLIS not installed; run .\setup-asset-factory.ps1 trellis install"
    } else {
        Write-Result "WARN" "TRELLIS repository state: $($trellisRepoState.Message)"
    }

    $comfyRepoState = Test-ComfyUiRepository
    if ($comfyRepoState.Valid) {
        Write-Result "OK" "ComfyUI repository installed"
    } elseif ($comfyRepoState.State -eq "missing") {
        Write-Result "INFO" "ComfyUI not installed; run .\setup-asset-factory.ps1 comfyui install"
    } else {
        Write-Result "WARN" "ComfyUI repository state: $($comfyRepoState.Message)"
    }

    $fluxModel = Test-ComfyUiFluxModel
    if ($fluxModel.Present) {
        $sizeGiB = [math]::Round($fluxModel.SizeBytes / 1GB, 2)
        Write-Result "OK" "FLUX Schnell model installed ($sizeGiB GiB)"
    } else {
        Write-Result "INFO" "FLUX Schnell model not ready; run .\setup-asset-factory.ps1 comfyui model-install"
    }
}

function Invoke-Install {
    Write-Header "Install"

    Assert-BootstrapHost

    Ensure-Directories
    Ensure-GitIgnore
    Ensure-DocumentationSkeleton
    Ensure-Readme

    $git = Get-GitInfo
    if (-not $git.Installed) {
        if ($NoInstall) {
            Write-Result "MISSING" "Git not installed"
        } else {
            Install-WingetPackage -Id "Git.Git" -DisplayName "Git"
            Assert-DetectedAfterInstall -DisplayName "Git" -Detector { (Get-GitInfo).Installed }
            $git = Get-GitInfo
        }
    } else {
        Write-Result "OK" "Reusing existing Git: $($git.Path)"
    }

    $python = Get-PythonInfo
    if (-not $python.Installed) {
        if ($NoInstall) {
            Write-Result "MISSING" "Python not installed"
        } else {
            # Uniquement le Python de bootstrap partagé. Les environnements Python des moteurs restent isolés et épinglés séparément.
            Install-WingetPackage -Id "Python.Python.3.12" -DisplayName "Python 3.12"
            Assert-DetectedAfterInstall -DisplayName "Python" -Detector { (Get-PythonInfo).Installed }
            $python = Get-PythonInfo
        }
    } else {
        Write-Result "OK" "Reusing existing Python: $($python.Path)"
    }

    $blender = Get-BlenderInfo
    if (-not $blender.Installed) {
        if ($NoInstall) {
            Write-Result "MISSING" "Blender not installed"
        } else {
            Install-WingetPackage -Id "BlenderFoundation.Blender" -DisplayName "Blender"
            Assert-DetectedAfterInstall -DisplayName "Blender" -Detector { (Get-BlenderInfo).Installed }
            $blender = Get-BlenderInfo
        }
    } else {
        Write-Result "OK" "Reusing existing Blender: $($blender.Path)"
    }

    Ensure-GitRepository

    Write-Result "INFO" "TripoSR remains an opt-in engine install: .\setup-asset-factory.ps1 triposr install"
    Write-Result "INFO" "ComfyUI remains an opt-in engine install: .\setup-asset-factory.ps1 comfyui install"
    Write-Result "INFO" "TRELLIS remains opt-in: .\setup-asset-factory.ps1 trellis install"
    Write-Result "INFO" "Each AI engine uses its own isolated Python environment."

    Show-Status
}

function Invoke-Doctor {
    Write-Header "Doctor"

    $failures = 0

    if (-not (Test-IsWindows)) {
        Write-Result "FAIL" "Unsupported OS: Windows is required for this bootstrap."
        $failures++
    } else {
        Write-Result "OK" "Windows detected"
    }

    if ($PSVersionTable.PSVersion -lt $MinimumPowerShellVersion) {
        Write-Result "FAIL" "PowerShell $MinimumPowerShellVersion or newer is required."
        $failures++
    } else {
        Write-Result "OK" "PowerShell version supported: $($PSVersionTable.PSVersion)"
    }

    try {
        $git = Get-GitInfo
        if ($git.Installed) {
            $result = Invoke-NativeCapture -Executable $git.Path -Arguments @("--version")
            if ($result.ExitCode -eq 0) { Write-Result "OK" "Git executable works" }
            else { Write-Result "FAIL" "Git executable returned exit code $($result.ExitCode)"; $failures++ }
        } else {
            Write-Result "FAIL" "Git is missing"
            $failures++
        }
    } catch {
        Write-Result "FAIL" "Git check failed: $($_.Exception.Message)"
        $failures++
    }

    try {
        $python = Get-PythonInfo
        if ($python.Installed) {
            $result = Invoke-NativeCapture -Executable $python.Path -Arguments @("-c", "import sys; print(sys.version_info[:3])")
            if ($result.ExitCode -eq 0) { Write-Result "OK" "Python executable works" }
            else { Write-Result "FAIL" "Python executable returned exit code $($result.ExitCode)"; $failures++ }
        } else {
            Write-Result "FAIL" "Python is missing"
            $failures++
        }
    } catch {
        Write-Result "FAIL" "Python check failed: $($_.Exception.Message)"
        $failures++
    }

    try {
        $blender = Get-BlenderInfo
        if ($blender.Installed) {
            $result = Invoke-NativeCapture -Executable $blender.Path -Arguments @(
                "--background",
                "--factory-startup",
                "--python-expr", "import bpy; print(bpy.app.version_string)"
            )
            if ($result.ExitCode -eq 0) { Write-Result "OK" "Blender headless works" }
            else { Write-Result "FAIL" "Blender headless returned exit code $($result.ExitCode)"; $failures++ }
        } else {
            Write-Result "FAIL" "Blender is missing"
            $failures++
        }
    } catch {
        Write-Result "FAIL" "Blender check failed: $($_.Exception.Message)"
        $failures++
    }

    $gpu = Get-NvidiaInfo
    if ($gpu.Available) {
        Write-Result "OK" "NVIDIA GPU detected: $($gpu.Name), $($gpu.VramMiB) MiB VRAM"
        if ($gpu.VramMiB -lt 7168) {
            Write-Result "WARN" "VRAM is below the expected V0 target."
        }
    } else {
        Write-Result "WARN" "Could not query NVIDIA GPU with nvidia-smi."
    }

    foreach ($relativePath in $RequiredDirs) {
        if (Test-Path -LiteralPath (Join-Path $ProjectRoot $relativePath)) {
            Write-Result "OK" "Directory exists: $relativePath"
        } else {
            Write-Result "FAIL" "Directory missing: $relativePath"
            $failures++
        }
    }

    $gitForRepo = Get-GitInfo
    if ($gitForRepo.Installed) {
        $repoProbe = Invoke-NativeCapture -Executable $gitForRepo.Path -Arguments @("-C", $ProjectRoot, "rev-parse", "--is-inside-work-tree")
        if ($repoProbe.ExitCode -eq 0) {
            Write-Result "OK" "Git repository initialized"
        } else {
            Write-Result "FAIL" "Git repository is not initialized"
            $failures++
        }
    }

    if ($failures -gt 0) {
        Write-Result "FAIL" "Doctor found $failures blocking issue(s)."
        return 1
    }

    Write-Result "OK" "Doctor found no blocking bootstrap issue."
    return 0
}

function Show-Help {
    @"
Asset Factory bootstrap setup v$ScriptVersion

Usage:
  .\setup-asset-factory.ps1 install
  .\setup-asset-factory.ps1 install -NoInstall
  .\setup-asset-factory.ps1 status
  .\setup-asset-factory.ps1 doctor
  .\setup-asset-factory.ps1 triposr install
  .\setup-asset-factory.ps1 triposr status
  .\setup-asset-factory.ps1 triposr doctor
  .\setup-asset-factory.ps1 triposr repair
  .\setup-asset-factory.ps1 triposr smoke
  .\setup-asset-factory.ps1 comfyui install
  .\setup-asset-factory.ps1 comfyui status
  .\setup-asset-factory.ps1 comfyui doctor
  .\setup-asset-factory.ps1 comfyui smoke
  .\setup-asset-factory.ps1 comfyui repair
  .\setup-asset-factory.ps1 comfyui model-install




  .\setup-asset-factory.ps1 trellis install
  .\setup-asset-factory.ps1 trellis status
  .\setup-asset-factory.ps1 trellis doctor
  .\setup-asset-factory.ps1 trellis runtime-install
  .\setup-asset-factory.ps1 trellis model-install
  .\setup-asset-factory.ps1 trellis model-status
  .\setup-asset-factory.ps1 trellis runtime-status
  .\setup-asset-factory.ps1 trellis runtime-doctor
  .\setup-asset-factory.ps1 trellis native-install
  .\setup-asset-factory.ps1 trellis native-status
  .\setup-asset-factory.ps1 trellis native-doctor
  .\setup-asset-factory.ps1 trellis repair
  .\setup-asset-factory.ps1 trellis smoke
  .\setup-asset-factory.ps1 help

Commands:
  install   Create the minimal repository structure and install missing shared tools.
            Existing installations are reused whenever possible.
  status    Show detected tools, paths, versions, repository state and GPU information.
  doctor    Run smoke tests for Git, Python, Blender headless, GPU query and repository structure.
  triposr   Manage the isolated TripoSR engine. Subcommands: install, status, doctor, repair, smoke.
  comfyui   Manage the isolated ComfyUI engine. Subcommands: install, status, doctor, smoke, repair, model-install.
  multiview Install/validate the integrated Blender multiview texturing path.
  trellis   Manage TRELLIS v1. AF-08A handles the pinned official repo/bootstrap venv;
            AF-08B runtime-* handles the isolated Python 3.12 / PyTorch CUDA 13 runtime foundation;
            AF-08C native-* validates CUDA/MSVC/sm_120, PyTorch SDPA and required TRELLIS native extensions.
  help      Show this help.

Options:
  -NoInstall  Initialize/detect only. Never invoke winget or install missing engine packages.

Important:
  - This bootstrap targets Windows 11 and requires Windows PowerShell 5.1+ or PowerShell 7+.
  - TripoSR is opt-in: use `triposr install`; it never installs packages into global Python.
  - ComfyUI is opt-in: use `comfyui install`; it uses its own Python 3.11 venv, PyTorch CUDA 13.0 and pinned ComfyUI v0.35.0.
  - The FLUX Schnell checkpoint is opt-in: use `comfyui model-install`; an existing valid checkpoint is reused.
  - Multi-view texturing is opt-in; use `multiview install`, then enable -Multiview `$true in the normal generation command.
  - TRELLIS v1 is pinned to a validated source revision and uses separate bootstrap/runtime venvs.
  - TRELLIS runtime PyTorch CUDA 13 is isolated; the system CUDA Toolkit used by other engines is not replaced.
  - AF-08C uses PyTorch SDPA on Blackwell. Upstream TRELLIS 442aa1e has no sparse SDPA backend; unsupported xformers builds are removed rather than selected.
  - `trellis native-install` installs native TRELLIS extensions from public upstream source checkouts under the ignored runtime tree and validates each component.
  - Windows native builds are pinned to the detected VS2022 Build Tools environment so setuptools cannot silently select a newer Visual Studio toolchain.
  - Native extension installation is idempotent: successful components are reused on rerun after a later component fails.
  - Kaolin v0.18.0 prerequisites are prepared explicitly: setuptools 80.10.2/pkg_resources, Cython 3.0.12, NumPy, pybind11 and its non-Torch runtime dependencies.
  - spconv/cumm local source trees are patched to C++17 before generation because upstream CUDA 13 builds can still emit C++14 native build flags.
  - pccm/ccimport build-helper defaults are also patched from C++14 to C++17 so spconv JIT/native validation cannot regenerate -std=c++14.
  - TRELLIS model-install prepares and verifies local weights, DINOv2 source/weights and U2Net; no native rebuild.
  - TRELLIS model-status (or model-install -NoInstall) verifies the local bundle without network access.
  - The Asset Factory runner uses local models only; missing model files are reported instead of downloaded.
  - Engine repositories, venvs, downloaded models and generated outputs are local runtime data, not repository source.
  - Each AI engine uses an isolated Python environment.
  - Heavy GPU workloads must remain sequential on the ~8 GiB target GPU.
"@ | Write-Host
}

try {
    switch ($Command) {
        "install" { Invoke-Install }
        "status"  { Show-Status }
        "doctor"  {
            $doctorExitCode = Invoke-Doctor
            if ($doctorExitCode -ne 0) {
                exit $doctorExitCode
            }
        }
        "triposr" { Invoke-TripoSrCommand }
        "comfyui" { Invoke-ComfyUiCommand }
        "trellis" { Invoke-TrellisCommand }
        "multiview" { Invoke-MultiViewCommand }
        "help"    { Show-Help }
    }
} catch {
    Write-Host ""
    Write-Result "FAIL" $_.Exception.Message
    exit 1
}

