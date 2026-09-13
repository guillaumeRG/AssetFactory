# Fonctions d'orchestration partagées. Aucune modification des sources des moteurs ni de l'environnement global.
# Compatible avec Windows PowerShell 5.1 et PowerShell 7.

function Write-AFInfo {
    param([string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-AFOk {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-AFFail {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Save-AFJson {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-AFProperty {
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) {
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
    } elseif ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

function Resolve-AFPath {
    param([string]$Path, [string]$BasePath)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "A non-empty path is required."
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Assert-AFFile {
    param([string]$Path, [string]$Label = "File")

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }
    if ((Get-Item -LiteralPath $Path).Length -le 0) {
        throw "$Label is empty: $Path"
    }
}

function Assert-AFFileStem {
    param([string]$Name, [string]$Label = "AssetId")

    # Des règles Windows explicites rendent également la validation déterministe dans les tests Linux.
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 120 -or
        $Name -match '[<>:"/\\|?*\x00-\x1f]' -or
        $Name -in @(".", "..") -or $Name -match '[. ]$' -or
        $Name -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {
        throw "$Label is not a safe Windows filename: '$Name'."
    }
}

function Assert-AFAssetVersion {
    param([string]$Version, [string]$Label = "AssetVersion")

    if ([string]::IsNullOrWhiteSpace($Version) -or $Version -notmatch '^v[0-9]{3,}$') {
        throw "$Label must use the form v001, v002, ... Got '$Version'."
    }
}

function Get-AFAssetRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$AssetId
    )

    Assert-AFFileStem -Name $AssetId
    return Join-Path $Root ("outputs\assets\" + $AssetId)
}

function Get-AFNextAssetVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$AssetId
    )

    $assetRoot = Get-AFAssetRoot -Root $Root -AssetId $AssetId
    $maxVersion = 0
    if (Test-Path -LiteralPath $assetRoot -PathType Container) {
        foreach ($directory in Get-ChildItem -LiteralPath $assetRoot -Directory -ErrorAction SilentlyContinue) {
            if ($directory.Name -match '^v([0-9]+)$') {
                $number = [int]$Matches[1]
                if ($number -gt $maxVersion) {
                    $maxVersion = $number
                }
            }
        }
    }
    return ('v{0:D3}' -f ($maxVersion + 1))
}

function Get-AFGenerationLayout {
    param(
        [Parameter(Mandatory = $true)][string]$GenerationRoot,
        [string]$Version = ""
    )

    $rootPath = [System.IO.Path]::GetFullPath($GenerationRoot)
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $leaf = Split-Path -Leaf $rootPath
        if ($leaf -match '^v[0-9]{3,}$') {
            $Version = $leaf
        }
    }
    return [pscustomobject]@{
        Root = $rootPath
        Version = $Version
        SourceDir = Join-Path $rootPath "source"
        RawDir = Join-Path $rootPath "raw"
        FinalDir = Join-Path $rootPath "final"
        LogsDir = Join-Path $rootPath "logs"
        MetadataDir = Join-Path $rootPath "metadata"
        GenerationMetadataPath = Join-Path $rootPath "generation.json"
    }
}

function Initialize-AFGenerationLayout {
    param(
        [Parameter(Mandatory = $true)][string]$GenerationRoot,
        [string]$Version = ""
    )

    $layout = Get-AFGenerationLayout -GenerationRoot $GenerationRoot -Version $Version
    foreach ($directory in @(
        $layout.Root,
        $layout.SourceDir,
        $layout.RawDir,
        $layout.FinalDir,
        $layout.LogsDir,
        $layout.MetadataDir
    )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return $layout
}

function New-AFAssetGeneration {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$AssetId,
        [string]$Version = ""
    )

    Assert-AFFileStem -Name $AssetId
    $assetRoot = Get-AFAssetRoot -Root $Root -AssetId $AssetId
    New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        Assert-AFAssetVersion -Version $Version
        $candidate = Join-Path $assetRoot $Version
        if (Test-Path -LiteralPath $candidate) {
            throw "Asset generation already exists: $candidate"
        }
        New-Item -ItemType Directory -Path $candidate | Out-Null
        return Initialize-AFGenerationLayout -GenerationRoot $candidate -Version $Version
    }

    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $candidateVersion = Get-AFNextAssetVersion -Root $Root -AssetId $AssetId
        $candidate = Join-Path $assetRoot $candidateVersion
        try {
            New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
            return Initialize-AFGenerationLayout -GenerationRoot $candidate -Version $candidateVersion
        } catch {
            if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
                throw
            }
            Start-Sleep -Milliseconds 10
        }
    }
    throw "Could not allocate a unique generation folder for '$AssetId'."
}

function Resolve-AFGenerationLayout {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$AssetId,
        [string]$GenerationRoot = "",
        [string]$Version = ""
    )

    if ([string]::IsNullOrWhiteSpace($GenerationRoot)) {
        return New-AFAssetGeneration -Root $Root -AssetId $AssetId -Version $Version
    }

    $resolved = Resolve-AFPath -Path $GenerationRoot -BasePath $Root
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        Assert-AFAssetVersion -Version $Version
    }
    return Initialize-AFGenerationLayout -GenerationRoot $resolved -Version $Version
}

function Get-AFOutputValue {
    param([string[]]$Lines, [string]$Prefix, [switch]$Optional)

    $value = $null
    foreach ($line in $Lines) {
        if ($line.StartsWith($Prefix, [System.StringComparison]::Ordinal)) {
            $value = $line.Substring($Prefix.Length).Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($value) -and -not $Optional) {
        throw "Runner did not return '$Prefix'. See the stage log."
    }
    return $value
}

function Invoke-AFCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [hashtable]$Parameters,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$LogPath,
        [string[]]$SuppressConsolePatterns = @()
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $writer = [System.IO.StreamWriter]::new($LogPath, $false, [System.Text.Encoding]::UTF8)
    $writer.AutoFlush = $true
    $oldPreference = $ErrorActionPreference
    $exitCode = 1
    $failure = $null
    $executionState = @{
        ExitCode = 1
        Error = $null
    }
    $useParameters = $PSBoundParameters.ContainsKey("Parameters")

    try {
        # stderr contient des données de diagnostic, pas une NativeCommandError fatale sous PS5.
        # Le code de sortie de l'appelé et les artefacts produits déterminent le succès.
        $ErrorActionPreference = "Continue"
        $PSNativeCommandUseErrorActionPreference = $false
        $global:LASTEXITCODE = 0

        & {
            try {
                if ($useParameters) {
                    & $Executable @Parameters
                } else {
                    & $Executable @Arguments
                }
                # Capture dans cette portée. exit dans un .ps1 enfant met à jour le LASTEXITCODE
                # de cette portée, pas nécessairement la variable de l'appelant.
                $executionState.ExitCode = $LASTEXITCODE
            } catch {
                $executionState.ExitCode = 1
                $executionState.Error = $_.Exception.Message
                Write-AFFail $executionState.Error
            }
        } 6>&1 2>&1 | ForEach-Object {
            $text = $_.ToString()
            $lines.Add($text)
            $writer.WriteLine($text)

            $showOnConsole = $true
            foreach ($pattern in $SuppressConsolePatterns) {
                if ($text -match $pattern) {
                    $showOnConsole = $false
                    break
                }
            }
            if ($showOnConsole) {
                Write-Host $text
            }
        }
        $exitCode = $executionState.ExitCode
        $failure = $executionState.Error
    }
    catch {
        $failure = $_.Exception.Message
        $lines.Add($failure)
        $writer.WriteLine($failure)
        Write-AFFail $failure
        $exitCode = 1
    }
    finally {
        $ErrorActionPreference = $oldPreference
        $writer.Dispose()
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($lines.ToArray())
        Error = $failure
        LogPath = $LogPath
    }
}

function Resolve-AFUnrealConfiguration {
    param(
        [string]$Root,
        [string]$ProjectProfile,
        [System.Nullable[bool]]$AutoImport,
        [string]$AssetId,
        [string]$Category
    )

    $result = [ordered]@{
        enabled = $false
        profilePath = $null
        autoImport = $false
        assetId = $AssetId
        category = $Category
    }
    if ([string]::IsNullOrWhiteSpace($ProjectProfile)) {
        if ($null -ne $AutoImport -and [bool]$AutoImport) {
            throw "-ProjectProfile is required when -AutoImport is true."
        }
        return $result
    }

    $profilePath = Resolve-AFPath -Path $ProjectProfile -BasePath $Root
    Assert-AFFile -Path $profilePath -Label "Project profile"
    $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profileAuto = Get-AFProperty $profile "autoImport" $false
    if ($profileAuto -isnot [bool]) {
        throw "Profile autoImport must be a JSON boolean."
    }
    $effectiveAuto = $profileAuto
    if ($null -ne $AutoImport) {
        $effectiveAuto = [bool]$AutoImport
    }

    if ($effectiveAuto) {
        if ([string](Get-AFProperty $profile "engine" "") -ne "unreal") {
            throw "Profile engine must be 'unreal'."
        }
        $contentRoot = [string](Get-AFProperty $profile "contentRoot" "")
        if ($contentRoot -notmatch '^/Game(?:/[A-Za-z0-9_]+)*/?$') {
            throw "Profile contentRoot must be /Game or valid folders under /Game."
        }
        $projectPath = Resolve-AFPath `
            -Path ([string](Get-AFProperty $profile "projectPath" "")) `
            -BasePath (Split-Path -Parent $profilePath)
        Assert-AFFile -Path $projectPath -Label "Unreal project"
        if ([System.IO.Path]::GetExtension($projectPath) -ne ".uproject") {
            throw "Profile projectPath must point to a .uproject file."
        }
        Assert-AFFile -Path (Join-Path $Root "tools\import-unreal.ps1") -Label "Unreal import runner"
        Assert-AFFile -Path (Join-Path $Root "unreal\import_asset.py") -Label "Unreal import script"
        if ([string]::IsNullOrWhiteSpace($AssetId)) {
            throw "AssetId is required for automatic Unreal import."
        }
    }

    $result.enabled = $true
    $result.profilePath = $profilePath
    $result.autoImport = $effectiveAuto
    return $result
}

function Request-AFComfyMemoryRelease {
    param(
        [string]$ServerUrl,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    $baseUrl = $ServerUrl.TrimEnd("/")
    $queue = Invoke-RestMethod -Uri "$baseUrl/queue" -Method Get -TimeoutSec 10
    if (-not ($queue.PSObject.Properties.Name -contains "queue_running") -or
        -not ($queue.PSObject.Properties.Name -contains "queue_pending")) {
        throw "Réponse inattendue de la file ComfyUI ; refus de décharger un serveur potentiellement occupé."
    }
    if (@($queue.queue_running).Count -gt 0 -or @($queue.queue_pending).Count -gt 0) {
        throw "ComfyUI a d’autres tâches en attente ou en cours. Rien n’a été interrompu. Réessayez lorsqu’il est inactif, ou utilisez -ReleaseComfyMemory `$false sur un autre GPU/serveur."
    }

    $body = [System.Text.Encoding]::UTF8.GetBytes('{"unload_models":true,"free_memory":true}')
    Invoke-RestMethod -Uri "$baseUrl/free" -Method Post `
        -ContentType "application/json" -Body $body -TimeoutSec 10 | Out-Null

    # /free ne fait que planifier le déchargement. On attend que la réservation torch propre à ComfyUI
    # passe sous 256 Mio ; cela ne dit rien sur les autres applications utilisant le GPU.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $stats = Invoke-RestMethod -Uri "$baseUrl/system_stats" -Method Get -TimeoutSec 10
        $devices = @(Get-AFProperty $stats "devices" @())
        $cudaDevices = @($devices | Where-Object { (Get-AFProperty $_ "type" "") -eq "cuda" })
        if ($cudaDevices.Count -eq 0) {
            if ($devices.Count -eq 0) {
                throw "ComfyUI system_stats ne retourne aucun périphérique ; impossible de vérifier la libération mémoire."
            }
            return [ordered]@{
                reservedBytes = 0
                message = "ComfyUI ne signale aucun périphérique CUDA."
            }
        }
        $reservedBytes = [long]0
        foreach ($device in $cudaDevices) {
            if (-not ($device.PSObject.Properties.Name -contains "torch_vram_total")) {
                throw "ComfyUI n’expose pas torch_vram_total. Utilisez -ReleaseComfyMemory `$false uniquement si la VRAM est gérée séparément."
            }
            $reservedBytes += [long]$device.torch_vram_total
        }
        if ($reservedBytes -le 256MB) {
            return [ordered]@{
                reservedBytes = $reservedBytes
                message = "La réservation CUDA de ComfyUI est inférieure à 256 Mio."
            }
        }
    } while ((Get-Date) -lt $deadline)

    throw "ComfyUI a accepté /free mais réserve encore $reservedBytes octets après $TimeoutSeconds secondes. Le PNG est conservé ; aucune génération 3D n’a été lancée."
}
