[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "status", "doctor", "triposr", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [ValidateSet("install", "status", "doctor", "repair", "smoke")]
    [string]$TriposrCommand = "status",

    [switch]$NoInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.4.3"
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
    $python = Ensure-TripoSrPython

    if (Test-Path -LiteralPath $TripoSrVenvPython) {
        $versionResult = Invoke-NativeCapture -Executable $TripoSrVenvPython -Arguments @("-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        if ($versionResult.ExitCode -eq 0 -and $versionResult.Output.Count -gt 0) {
            $version = ($versionResult.Output | Select-Object -First 1).ToString().Trim()
            if ($version -in $TripoSrPreferredPythonVersions) {
                Write-Result "OK" "Reusing TripoSR venv with Python $version"
                return
            }
        }

        Write-Result "WARN" "TripoSR venv exists with unsupported/broken Python; recreating only .venv"
        Remove-Item -LiteralPath $TripoSrVenv -Recurse -Force
    } elseif (Test-Path -LiteralPath $TripoSrVenv) {
        Write-Result "WARN" "Incomplete TripoSR venv detected; recreating only .venv"
        Remove-Item -LiteralPath $TripoSrVenv -Recurse -Force
    }

    $result = Invoke-NativeCapture -Executable $python.Path -Arguments @("-m", "venv", $TripoSrVenv)
    if ($result.ExitCode -ne 0) {
        throw "Could not create TripoSR venv: $($result.Output -join ' | ')"
    }

    if (-not (Test-Path -LiteralPath $TripoSrVenvPython)) {
        throw "TripoSR venv creation returned success but python.exe is missing."
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

    if (-not (Test-Path -LiteralPath $TripoSrVenvPython)) {
        throw "TripoSR venv is missing. Run '.\setup-asset-factory.ps1 triposr install' first."
    }

    $example = Join-Path $TripoSrRoot "examples\chair.png"
    if (-not (Test-Path -LiteralPath $example)) {
        throw "Official TripoSR example image is missing: $example"
    }

    Test-TripoSrCuda
    Ensure-TripoSrRembgBackend
    Test-TripoSrImports

    $outputDir = Join-Path $ProjectRoot "outputs\triposr-smoke"
    if (-not (Test-Path -LiteralPath $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

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
        throw "TripoSR inference returned success but no 3D model was found in $outputDir"
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
    Repair-TripoSrTorchMcubes
    Ensure-TripoSrRequirements
    Ensure-TripoSrRembgBackend
    Test-TripoSrImports
    Test-TripoSrCli

    Write-Result "OK" "TripoSR repair completed and validated"
}

function Invoke-TripoSrCommand {
    switch ($TriposrCommand) {
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
  .\setup-asset-factory.ps1 help

Commands:
  install   Create the minimal repository structure and install missing shared tools.
            Existing installations are reused whenever possible.
  status    Show detected tools, paths, versions, repository state and GPU information.
  doctor    Run smoke tests for Git, Python, Blender headless, GPU query and repository structure.
  triposr   Manage the isolated TripoSR engine. Subcommands: install, status, doctor, repair, smoke.
  help      Show this help.

Options:
  -NoInstall  Initialize/detect only. Never invoke winget.

Important:
  - This bootstrap targets Windows 11 and requires Windows PowerShell 5.1+ or PowerShell 7+.
  - TripoSR is opt-in: use `triposr install`; it never installs packages into global Python.
  - TripoSR uses an isolated Python 3.11/3.10 venv and a CUDA/PyTorch profile matching the local CUDA Toolkit major version.
  - Each AI engine uses an isolated, pinned Python environment.
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
        "help"    { Show-Help }
    }
} catch {
    Write-Host ""
    Write-Result "FAIL" $_.Exception.Message
    exit 1
}
