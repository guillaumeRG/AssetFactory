[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("install", "status", "doctor", "help")]
    [string]$Command = "help",

    [switch]$NoInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptVersion = "0.3.1"
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
        [string[]]$Arguments = @()
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

    Write-Result "INFO" "TripoSR environment: not configured by bootstrap v$ScriptVersion"
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

    Write-Result "INFO" "TripoSR is intentionally NOT installed by bootstrap v$ScriptVersion."
    Write-Result "INFO" "Each AI engine will receive its own pinned Python/Torch/CUDA environment."

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
  .\setup-asset-factory.ps1 help

Commands:
  install   Create the minimal repository structure and install missing shared tools.
            Existing installations are reused whenever possible.
  status    Show detected tools, paths, versions, repository state and GPU information.
  doctor    Run smoke tests for Git, Python, Blender headless, GPU query and repository structure.
  help      Show this help.

Options:
  -NoInstall  Initialize/detect only. Never invoke winget.

Important:
  - This bootstrap targets Windows 11 and requires Windows PowerShell 5.1+ or PowerShell 7+.
  - TripoSR is intentionally not installed by this bootstrap version.
  - Each AI engine will use an isolated, pinned Python environment.
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
        "help"    { Show-Help }
    }
} catch {
    Write-Host ""
    Write-Result "FAIL" $_.Exception.Message
    exit 1
}
