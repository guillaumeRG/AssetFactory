[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "status", "doctor", "triposr", "comfyui", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [Alias("TriposrCommand", "ComfyUiCommand")]
    [ValidateSet("install", "status", "doctor", "repair", "smoke")]
    [string]$EngineCommand = "status",

    [switch]$NoInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.5.2"
$ProjectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$MinimumPowerShellVersion = [version]"5.1"
$Script:HadWarnings = $false

$RequiredDirs = @(
    "orchestrator",
    "engines",
    "blender\scripts",
    "jobs",
    "outputs",
    "tools",
    "workflows",
    "batches",
    "docs"
)

# TripoSR engine configuration. The engine is installed locally under engines/triposr
# and is intentionally isolated from the shared bootstrap Python.
$TripoSrRepoUrl = "https://github.com/VAST-AI-Research/TripoSR"
$TripoSrRoot = Join-Path $ProjectRoot "engines\triposr"
$TripoSrVenv = Join-Path $TripoSrRoot ".venv"
$TripoSrVenvPython = Join-Path $TripoSrVenv "Scripts\python.exe"
$TripoSrRequirements = Join-Path $TripoSrRoot "requirements.txt"
$TripoSrPreferredPythonVersions = @("3.11", "3.10")

# ComfyUI engine configuration. Runtime repository, venv and models stay local.
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
    # $IsWindows only exists in PowerShell Core. This also supports Windows PowerShell 5.1.
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Refresh-ProcessPath {
    if (-not (Test-IsWindows)) {
        return
    }

    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")

    # Keep process-local PATH entries too; setup may itself have been launched from a
    # shell that injected useful paths not persisted at User/Machine scope.
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

    # Do not use PowerShell's `2>&1` here. On Windows PowerShell 5.1,
    # stderr from a native executable can become a terminating
    # NativeCommandError when $ErrorActionPreference = "Stop".
    #
    # A non-zero native exit code is data for the caller to inspect,
    # not a PowerShell exception. System.Diagnostics.Process gives us
    # deterministic stdout/stderr capture on both Windows PowerShell
    # 5.1 and PowerShell 7+.
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

    # ProcessStartInfo.ArgumentList is unavailable on .NET Framework used
    # by Windows PowerShell 5.1, so build a correctly quoted argument string.
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

        # Windows command-line quoting compatible with CommandLineToArgvW:
        # escape backslashes that precede a quote, escape quotes, and double
        # trailing backslashes before the closing quote.
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

        # Read both redirected streams asynchronously enough to avoid the
        # classic full-buffer deadlock, then wait for process completion.
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

        # Ignore Windows Store aliases that can exist without a real Python installation.
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
        "PROJECT_OVERVIEW.md" = "# Asset Factory - Project Overview`r`n`r`nCanonical project context. Fill and evolve this document as decisions are validated.`r`n"
        "ARCHITECTURE.md" = "# Asset Factory - Architecture`r`n`r`nKeep the architecture simple, testable, reproducible, modular, and replaceable.`r`n"
        "V0_FUELTANK_T1.md" = "# V0 - FuelTank_T1`r`n`r`nProof of concept specification for the first Asset Factory pipeline.`r`n"
        "DEVELOPMENT_POLICY.md" = "# Development Policy`r`n`r`nPrefer small, reversible changes. Do not add infrastructure outside the active milestone.`r`n"
        "DEXTER_POLICY.md" = "# Dexter Policy`r`n`r`nDexter receives small, explicit, testable tasks with a constrained file scope.`r`n"
        "ENVIRONMENT.md" = "# Environment`r`n`r`nRecord validated host tools and engine-specific environments here.`r`n"
        "QA_POLICY.md" = "# QA Policy`r`n`r`nTechnical QA is deterministic. Artistic validation remains human.`r`n"
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

Local, modular asset-production tooling for NullOn.

The project is intentionally developed incrementally. The V0 exists only to test
whether a local concept-to-3D pipeline can produce a useful FuelTank_T1 candidate
on the target Windows 11 / RTX 5060 Ti (~8 GiB VRAM) workstation.

See `docs/PROJECT_OVERVIEW.md` and `docs/V0_FUELTANK_T1.md`.
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

    # Verify instead of assuming `git init` succeeded semantically.
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
    # Reuse an existing valid engine venv before looking for a base Python.
    # This avoids reinstalling Python simply because the original interpreter
    # is no longer on PATH after the venv has already been created.
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

    # TripoSR is not installed as a site-package (the official repository has no
    # setup.py/pyproject.toml). Python must therefore run with the repository root
    # as its working directory so `import tsr` resolves the local `tsr` package.
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
    # torchmcubes must build against the PyTorch already installed in this venv.
    # Its upstream installation instructions require disabling PEP 517 build
    # isolation and making the build tooling available in the active environment.
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

    # TripoSR requirements.txt contains torchmcubes directly from GitHub.
    # torchmcubes dynamically inspects the installed PyTorch version while
    # generating its metadata, so normal pip build isolation cannot work.
    # --no-build-isolation is therefore required for the requirements install.
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

    # Smoke tests validate; they do not silently repair dependencies.
    $onnx = Invoke-TripoSrPython -Arguments @("-c", "import rembg, onnxruntime; print(onnxruntime.__version__)")
    if ($onnx.ExitCode -ne 0) {
        throw "TripoSR rembg CPU backend is not ready. Run 'triposr install' or 'triposr repair'. Details: $($onnx.Output -join ' | ')"
    }
    Write-Result "OK" "TripoSR rembg CPU backend ready (onnxruntime $($onnx.Output[0]))"

    Test-TripoSrImports

    # Always use a unique output directory. Reusing outputs\triposr-smoke could
    # allow an old mesh to make a broken inference look successful.
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $outputDir = Join-Path $ProjectRoot "outputs\triposr-smoke\$stamp"
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

    # Reproducibility: Asset Factory currently validates ComfyUI v0.35.0.
    # Existing repositories are moved to the pinned release only when tracked
    # files are clean. Runtime data such as models and .venv are not touched.
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
    # Reuse an existing valid venv even if the base Python installation is no
    # longer discoverable. A base interpreter is only required to create or
    # recreate the venv.
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

    # pip is idempotent here: already-satisfied requirements are reused. PyTorch
    # was installed first from the CUDA 13.0 index, so the unpinned torch entries
    # in requirements.txt remain satisfied instead of replacing the CUDA build.
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

    # Always use a dedicated free port so the smoke test never interferes with
    # an already-running interactive ComfyUI instance on the normal port 8188.
    $smokePort = Get-FreeTcpPort
    $baseUrl = "http://$($ComfyUiSmokeHost):$smokePort"
    $healthUrl = "$baseUrl/system_stats"

    $logDir = Join-Path $ProjectRoot "outputs\comfyui-smoke"
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $stdoutPath = Join-Path $logDir "comfyui-$stamp.stdout.log"
    $stderrPath = Join-Path $logDir "comfyui-$stamp.stderr.log"

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
        "repair"  {
            Write-Result "INFO" "ComfyUI repair uses the idempotent install/revalidation path."
            Invoke-ComfyUiInstall
        }
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

    $comfyRepoState = Test-ComfyUiRepository
    if ($comfyRepoState.Valid) {
        Write-Result "OK" "ComfyUI repository installed"
    } elseif ($comfyRepoState.State -eq "missing") {
        Write-Result "INFO" "ComfyUI not installed; run .\setup-asset-factory.ps1 comfyui install"
    } else {
        Write-Result "WARN" "ComfyUI repository state: $($comfyRepoState.Message)"
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
            # Shared bootstrap Python only. Engine Python environments remain isolated and pinned separately.
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
    Write-Result "INFO" "Each AI engine uses its own isolated, pinned Python/Torch/CUDA environment."

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
  .\setup-asset-factory.ps1 help

Commands:
  install   Create the minimal repository structure and install missing shared tools.
            Existing installations are reused whenever possible.
  status    Show detected tools, paths, versions, repository state and GPU information.
  doctor    Run smoke tests for Git, Python, Blender headless, GPU query and repository structure.
  triposr   Manage the isolated TripoSR engine. Subcommands: install, status, doctor, repair, smoke.
  comfyui   Manage the isolated ComfyUI engine. Subcommands: install, status, doctor, smoke, repair.
  help      Show this help.

Options:
  -NoInstall  Initialize/detect only. Never invoke winget or install missing engine packages.

Important:
  - This bootstrap targets Windows 11 and requires Windows PowerShell 5.1+ or PowerShell 7+.
  - TripoSR is opt-in: use `triposr install`; it never installs packages into global Python.
  - ComfyUI is opt-in: use `comfyui install`; it uses its own Python 3.11 venv, PyTorch CUDA 13.0 and pinned ComfyUI v0.35.0.
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
        "help"    { Show-Help }
    }
} catch {
    Write-Host ""
    Write-Result "FAIL" $_.Exception.Message
    exit 1
}
