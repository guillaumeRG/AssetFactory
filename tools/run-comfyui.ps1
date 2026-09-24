[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Prompt,

    [string]$NegativePrompt = "",

    [ValidateRange(0, [long]::MaxValue)]
    [long]$Seed = 0,

    [ValidateNotNullOrEmpty()]
    [string]$WorkflowPath = "workflows\comfyui-flux-schnell-base.json",

    [ValidateNotNullOrEmpty()]
    [string]$ServerUrl = "http://127.0.0.1:8188",

    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 300,

    [ValidateRange(1, 30)]
    [int]$PollIntervalSeconds = 2,

    [string]$AssetId = "",
    [string]$GenerationRoot = "",
    [string]$AssetVersion = "",
    [string]$OutputFileStem = "",
    [string]$SourceSubfolder = "",
    [string]$MetadataPrefix = "comfyui",
    [switch]$PipelineManaged
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

$AssetFactoryRoot = [System.IO.Path]::GetFullPath(
    (Split-Path -Parent $PSScriptRoot)
)
. (Join-Path $PSScriptRoot "pipeline-common.ps1")

$ServerUrl = $ServerUrl.TrimEnd("/")
$OwnsGeneration = [string]::IsNullOrWhiteSpace($GenerationRoot)

# Nœuds attendus dans le workflow API ComfyUI de référence.
$PositivePromptNodeId = "2"
$NegativePromptNodeId = "3"
$SamplerNodeId = "5"
$ImageOutputNodeId = "7"

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

function Write-Info {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[INFO] $Message"
}

function Write-Ok {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Save-JobMetadata {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Metadata |
        ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Set-JobFailed {
    param(
        [Parameter(Mandatory = $true)]$Metadata,
        [Parameter(Mandatory = $true)][string]$MetadataPath,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $Metadata["status"] = "failed"
    $Metadata["failedAt"] = (Get-Date).ToString("o")
    $Metadata["error"] = $Message

    try {
        Save-JobMetadata -Metadata $Metadata -Path $MetadataPath
    } catch {
        Write-Fail "Impossible d’enregistrer les métadonnées d’échec : $($_.Exception.Message)"
    }
}

function Assert-WorkflowNode {
    param(
        [Parameter(Mandatory = $true)]$Workflow,
        [Parameter(Mandatory = $true)][string]$NodeId,
        [Parameter(Mandatory = $true)][string]$ExpectedClassType
    )

    if (-not ($Workflow.PSObject.Properties.Name -contains $NodeId)) {
        throw "Required workflow node '$NodeId' is missing."
    }

    $node = $Workflow.$NodeId

    if ($null -eq $node.inputs) {
        throw "Workflow node '$NodeId' does not contain an inputs object."
    }

    if (-not ($node.PSObject.Properties.Name -contains "class_type")) {
        throw "Workflow node '$NodeId' does not contain class_type."
    }

    if ([string]$node.class_type -ne $ExpectedClassType) {
        throw "Workflow node '$NodeId' has class_type '$($node.class_type)', expected '$ExpectedClassType'."
    }
}

function Get-ComfyUiErrorMessage {
    param([Parameter(Mandatory = $true)]$HistoryEntry)

    if ($HistoryEntry.PSObject.Properties.Name -contains "status") {
        $status = $HistoryEntry.status

        if ($null -ne $status -and ($status.PSObject.Properties.Name -contains "messages")) {
            $messagesJson = $status.messages | ConvertTo-Json -Depth 20 -Compress
            if (-not [string]::IsNullOrWhiteSpace($messagesJson) -and $messagesJson.Length -gt 1200) {
                $messagesJson = $messagesJson.Substring(0, 1200) + "..."
            }
            if (-not [string]::IsNullOrWhiteSpace($messagesJson)) {
                return "ComfyUI execution failed: $messagesJson"
            }
        }
    }

    return "ComfyUI execution failed."
}

# -----------------------------------------------------------------------------
# Informations de démarrage
# -----------------------------------------------------------------------------

if (-not $PipelineManaged) {
    Write-Info "Racine Asset Factory : $AssetFactoryRoot"
    Write-Info "Prompt : $Prompt"
    if ([string]::IsNullOrWhiteSpace($NegativePrompt)) {
        Write-Info "Prompt négatif : (vide)"
    } else {
        Write-Info "Prompt négatif : $NegativePrompt"
    }
    Write-Info "Graine : $Seed"
}

# -----------------------------------------------------------------------------
# Résolution et validation du workflow
# -----------------------------------------------------------------------------

try {
    if ([System.IO.Path]::IsPathRooted($WorkflowPath)) {
        $ResolvedWorkflowPath = [System.IO.Path]::GetFullPath($WorkflowPath)
    } else {
        $ResolvedWorkflowPath = [System.IO.Path]::GetFullPath(
            (Join-Path $AssetFactoryRoot $WorkflowPath)
        )
    }
} catch {
    Write-Fail "Chemin de workflow invalide : $WorkflowPath"
    Write-Info $_.Exception.Message
    exit 1
}

if (-not (Test-Path -LiteralPath $ResolvedWorkflowPath -PathType Leaf)) {
    Write-Fail "Workflow introuvable : $ResolvedWorkflowPath"
    exit 1
}

Write-Ok "Workflow trouvé : $ResolvedWorkflowPath"

# -----------------------------------------------------------------------------
# Validation de l'API ComfyUI
# -----------------------------------------------------------------------------

$SystemStatsUrl = "$ServerUrl/system_stats"

try {
    Invoke-RestMethod `
        -Uri $SystemStatsUrl `
        -Method Get `
        -TimeoutSec 5 | Out-Null

    Write-Ok "API ComfyUI disponible : $SystemStatsUrl"
} catch {
    Write-Fail "API ComfyUI indisponible : $SystemStatsUrl"
    Write-Info $_.Exception.Message
    exit 1
}

# -----------------------------------------------------------------------------
# Chargement et validation du workflow JSON
# -----------------------------------------------------------------------------

try {
    $WorkflowJson = Get-Content -LiteralPath $ResolvedWorkflowPath -Raw
    $Workflow = $WorkflowJson | ConvertFrom-Json
} catch {
    Write-Fail "Impossible de charger le workflow JSON : $ResolvedWorkflowPath"
    Write-Info $_.Exception.Message
    exit 1
}

try {
    Assert-WorkflowNode -Workflow $Workflow -NodeId $PositivePromptNodeId -ExpectedClassType "CLIPTextEncode"
    Assert-WorkflowNode -Workflow $Workflow -NodeId $NegativePromptNodeId -ExpectedClassType "CLIPTextEncode"
    Assert-WorkflowNode -Workflow $Workflow -NodeId $SamplerNodeId -ExpectedClassType "KSampler"
    if (-not ($Workflow.PSObject.Properties.Name -contains $ImageOutputNodeId)) {
        throw "Required image output node '$ImageOutputNodeId' is missing."
    }
    $OutputNodeClass = [string]$Workflow.$ImageOutputNodeId.class_type
    if ($OutputNodeClass -notin @("PreviewImage", "SaveImage")) {
        throw "Image output node '$ImageOutputNodeId' must be PreviewImage or SaveImage, got '$OutputNodeClass'."
    }
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}

# -----------------------------------------------------------------------------
# Création de l'identité de génération et personnalisation du workflow
# -----------------------------------------------------------------------------

function Assert-SafeRelativeSubfolder {
    param([string]$Path, [string]$Label = "SourceSubfolder")

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        throw "$Label doit être un chemin relatif : '$Path'."
    }

    $segments = @($Path -split '[\\/]' | Where-Object { $_ -ne "" })
    if ($segments.Count -eq 0) {
        throw "$Label ne contient aucun dossier valide : '$Path'."
    }
    foreach ($segment in $segments) {
        if ($segment -in @(".", "..")) {
            throw "$Label ne peut pas contenir '.' ou '..' : '$Path'."
        }
        Assert-AFFileStem -Name $segment -Label $Label
    }
}

if ([string]::IsNullOrWhiteSpace($AssetId)) {
    $AssetId = "Image_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
}
Assert-AFFileStem -Name $AssetId
if ([string]::IsNullOrWhiteSpace($OutputFileStem)) { $OutputFileStem = $AssetId }
Assert-AFFileStem -Name $OutputFileStem
Assert-SafeRelativeSubfolder -Path $SourceSubfolder
if ([string]::IsNullOrWhiteSpace($MetadataPrefix)) { throw "MetadataPrefix ne peut pas être vide." }
Assert-AFFileStem -Name $MetadataPrefix -Label "MetadataPrefix"

$Layout = Resolve-AFGenerationLayout `
    -Root $AssetFactoryRoot `
    -AssetId $AssetId `
    -GenerationRoot $GenerationRoot `
    -Version $AssetVersion

$JobId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$Workflow.$PositivePromptNodeId.inputs.text = $Prompt
$Workflow.$NegativePromptNodeId.inputs.text = $NegativePrompt
$Workflow.$SamplerNodeId.inputs.seed = $Seed
if ($Workflow.$ImageOutputNodeId.inputs.PSObject.Properties.Name -contains "filename_prefix") {
    $Workflow.$ImageOutputNodeId.inputs.filename_prefix = "assetfactory_$JobId"
}

Write-Ok "Workflow chargé et personnalisé"
Write-Info "AssetId : $AssetId"
Write-Info "Génération : $($Layout.Root)"
Write-Info "JobId : $JobId"

# -----------------------------------------------------------------------------
# Métadonnées de l'étape ComfyUI
# -----------------------------------------------------------------------------

$JobRoot = $Layout.Root
$JobWorkflowDir = $Layout.MetadataDir
$JobGeneratedDir = if ([string]::IsNullOrWhiteSpace($SourceSubfolder)) {
    $Layout.SourceDir
} else {
    Join-Path $Layout.SourceDir $SourceSubfolder
}
$JobLogsDir = $Layout.LogsDir
$ResolvedWorkflowOutput = Join-Path $JobWorkflowDir ($MetadataPrefix + "-workflow.json")
$JobMetadataPath = Join-Path $Layout.MetadataDir ($MetadataPrefix + ".json")
$ComfyRuntime = $null

try {
    foreach ($directory in @($JobRoot, $JobWorkflowDir, $JobGeneratedDir, $JobLogsDir)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $Workflow |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $ResolvedWorkflowOutput -Encoding UTF8
} catch {
    Write-Fail "Impossible d’initialiser les dossiers de génération ou le workflow."
    Write-Info $_.Exception.Message
    exit 1
}

$JobMetadata = [ordered]@{
    schemaVersion   = 3
    jobId           = $JobId
    assetId         = $AssetId
    assetVersion    = $Layout.Version
    generationRoot  = $Layout.Root
    createdAt       = (Get-Date).ToString("o")
    status          = "running"
    type            = "comfyui-image"
    prompt          = $Prompt
    negativePrompt  = $NegativePrompt
    seed            = $Seed
    serverUrl       = $ServerUrl
    workflowPath    = $ResolvedWorkflowOutput
    promptId        = $null
    outputFileStem  = $OutputFileStem
    sourceSubfolder = $SourceSubfolder
    imageCount      = 0
    imagePath       = $null
    imagePaths      = @()
}

$StandaloneGeneration = $null
$StandaloneGenerationPath = $Layout.GenerationMetadataPath
if ($OwnsGeneration) {
    $StandaloneGeneration = [ordered]@{
        schemaVersion = 3
        generationId = "$AssetId-$($Layout.Version)"
        assetId = $AssetId
        assetVersion = $Layout.Version
        generationRoot = $Layout.Root
        type = "image-only"
        engine = "comfyui"
        createdAt = $JobMetadata.createdAt
        completedAt = $null
        status = "running"
        imagePath = $null
        metadataPath = $JobMetadataPath
        error = $null
    }
}

try {
    Save-JobMetadata -Metadata $JobMetadata -Path $JobMetadataPath
    if ($null -ne $StandaloneGeneration) {
        Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath
    }
} catch {
    Write-Fail "Impossible de créer les métadonnées ComfyUI."
    Write-Info $_.Exception.Message
    exit 1
}

Write-Ok "Dossiers de génération prêts"
Write-Ok "Workflow résolu enregistré : $ResolvedWorkflowOutput"
Write-Ok "Métadonnées créées : $JobMetadataPath"

try {
    $ComfyRuntime = Start-AFComfyServer `
        -Root $AssetFactoryRoot `
        -ServerUrl $ServerUrl `
        -LogDirectory $JobLogsDir `
        -LogPrefix "comfyui-server"
    $JobMetadata["serverAutoStarted"] = [bool]$ComfyRuntime.Started
    $JobMetadata["serverStartupStdoutLogPath"] = $ComfyRuntime.StdoutPath
    $JobMetadata["serverStartupStderrLogPath"] = $ComfyRuntime.StderrPath
    Save-JobMetadata -Metadata $JobMetadata -Path $JobMetadataPath
    if ($ComfyRuntime.Started) {
        Write-Ok "ComfyUI démarré automatiquement : $($ComfyRuntime.BaseUrl)"
    } else {
        Write-Info "Réutilisation de ComfyUI : $($ComfyRuntime.BaseUrl)"
    }
} catch {
    Set-JobFailed -Metadata $JobMetadata -MetadataPath $JobMetadataPath -Message $_.Exception.Message
    if ($null -ne $StandaloneGeneration) {
        $StandaloneGeneration.status = "failed"
        $StandaloneGeneration.completedAt = (Get-Date).ToString("o")
        $StandaloneGeneration.error = $_.Exception.Message
        try { Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath } catch { }
    }
    Write-Fail "Le démarrage automatique de ComfyUI a échoué."
    Write-Info $_.Exception.Message
    exit 1
}

# -----------------------------------------------------------------------------
# Exécution du job
# -----------------------------------------------------------------------------

try {
    # Soumet le workflow.
    $PromptUrl = "$ServerUrl/prompt"
    $RequestJson = @{
        prompt = $Workflow
    } | ConvertTo-Json -Depth 100

    # Des octets UTF-8 explicites évitent les surprises d'encodage de texte sous Windows PowerShell 5.1.
    $RequestBody = [System.Text.Encoding]::UTF8.GetBytes($RequestJson)

    $QueueResponse = Invoke-RestMethod `
        -Uri $PromptUrl `
        -Method Post `
        -ContentType "application/json; charset=utf-8" `
        -Body $RequestBody `
        -TimeoutSec 30

    if (-not ($QueueResponse.PSObject.Properties.Name -contains "prompt_id")) {
        throw "ComfyUI response did not contain prompt_id."
    }

    $PromptId = [string]$QueueResponse.prompt_id

    if ([string]::IsNullOrWhiteSpace($PromptId)) {
        throw "ComfyUI returned an empty prompt_id."
    }

    $JobMetadata["promptId"] = $PromptId
    Save-JobMetadata -Metadata $JobMetadata -Path $JobMetadataPath

    Write-Ok "Workflow envoyé à ComfyUI"
    Write-Info "PromptId : $PromptId"

    # Attend la fin de l'exécution.
    $HistoryUrl = "$ServerUrl/history/$PromptId"
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $HistoryEntry = $null

    Write-Info "Génération de l’image par ComfyUI en cours..."

    while ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $PollIntervalSeconds

        try {
            $HistoryResponse = Invoke-RestMethod `
                -Uri $HistoryUrl `
                -Method Get `
                -TimeoutSec 10
        } catch {
            continue
        }

        if ($null -ne $HistoryResponse) {
            $HistoryProperty = $HistoryResponse.PSObject.Properties |
                Where-Object { $_.Name -eq $PromptId } |
                Select-Object -First 1

            if ($null -ne $HistoryProperty) {
                $HistoryEntry = $HistoryProperty.Value
                break
            }
        }
    }

    $Stopwatch.Stop()

    if ($null -eq $HistoryEntry) {
        throw "Timeout after $TimeoutSeconds seconds waiting for ComfyUI generation."
    }

    # L'historique ComfyUI peut contenir une entrée marquée terminée même si l'exécution a échoué.
    if ($HistoryEntry.PSObject.Properties.Name -contains "status") {
        $status = $HistoryEntry.status

        if ($null -ne $status -and
            ($status.PSObject.Properties.Name -contains "status_str") -and
            [string]$status.status_str -eq "error") {
            throw (Get-ComfyUiErrorMessage -HistoryEntry $HistoryEntry)
        }
    }

    Write-Ok "Génération ComfyUI terminée"

    # Valide les sorties de l'image.
    if (-not ($HistoryEntry.PSObject.Properties.Name -contains "outputs")) {
        throw "ComfyUI history does not contain outputs."
    }

    $Outputs = $HistoryEntry.outputs

    if ($null -eq $Outputs -or
        -not ($Outputs.PSObject.Properties.Name -contains $ImageOutputNodeId)) {
        throw "Image output node '$ImageOutputNodeId' output not found."
    }

    $ImageOutput = $Outputs.$ImageOutputNodeId

    if ($null -eq $ImageOutput -or
        -not ($ImageOutput.PSObject.Properties.Name -contains "images")) {
        throw "No images returned by Image output node '$ImageOutputNodeId'."
    }

    $GeneratedImages = @($ImageOutput.images)

    if ($GeneratedImages.Count -eq 0) {
        throw "Generated image list is empty."
    }

    # Récupère chaque image générée via le point d'accès /view de ComfyUI.
    # Cela évite de coupler le runner au répertoire physique de sortie de ComfyUI.
    $DestinationImagePaths = New-Object System.Collections.Generic.List[string]
    $imageIndex = 0

    foreach ($ImageInfo in $GeneratedImages) {
        $imageIndex++

        if ($null -eq $ImageInfo -or
            -not ($ImageInfo.PSObject.Properties.Name -contains "filename") -or
            [string]::IsNullOrWhiteSpace([string]$ImageInfo.filename)) {
            throw "ComfyUI returned an image entry without a filename."
        }

        $filename = [string]$ImageInfo.filename
        $subfolder = ""
        $imageType = "output"

        if ($ImageInfo.PSObject.Properties.Name -contains "subfolder" -and $null -ne $ImageInfo.subfolder) {
            $subfolder = [string]$ImageInfo.subfolder
        }

        if ($ImageInfo.PSObject.Properties.Name -contains "type" -and
            -not [string]::IsNullOrWhiteSpace([string]$ImageInfo.type)) {
            $imageType = [string]$ImageInfo.type
        }

        $ViewUrl = "{0}/view?filename={1}&subfolder={2}&type={3}" -f `
            $ServerUrl,
            [uri]::EscapeDataString($filename),
            [uri]::EscapeDataString($subfolder),
            [uri]::EscapeDataString($imageType)

        $extension = [System.IO.Path]::GetExtension($filename)
        if ([string]::IsNullOrWhiteSpace($extension)) {
            $extension = ".png"
        }
        $destinationName = if ($imageIndex -eq 1) {
            $OutputFileStem + $extension.ToLowerInvariant()
        } else {
            "{0}_{1:D2}{2}" -f $OutputFileStem, $imageIndex, $extension.ToLowerInvariant()
        }
        $DestinationImagePath = Join-Path $JobGeneratedDir $destinationName

        if (Test-Path -LiteralPath $DestinationImagePath) {
            throw "Generation source image already exists; refusing to overwrite it: $DestinationImagePath"
        }

        Invoke-WebRequest `
            -UseBasicParsing `
            -Uri $ViewUrl `
            -OutFile $DestinationImagePath `
            -TimeoutSec 60

        if (-not (Test-Path -LiteralPath $DestinationImagePath -PathType Leaf)) {
            throw "Generated image download did not create a file: $DestinationImagePath"
        }

        $imageFile = Get-Item -LiteralPath $DestinationImagePath
        if ($imageFile.Length -le 0) {
            throw "Generated image is empty: $DestinationImagePath"
        }

        $DestinationImagePaths.Add($DestinationImagePath)
        if (-not $PipelineManaged) { Write-Ok "Image générée récupérée : $DestinationImagePath" }
    }

    if ($DestinationImagePaths.Count -eq 0) {
        throw "No generated image could be recovered."
    }

    # Finalise les métadonnées.
    $JobMetadata["status"] = "completed"
    $JobMetadata["completedAt"] = (Get-Date).ToString("o")
    $JobMetadata["imageCount"] = $DestinationImagePaths.Count
    $JobMetadata["imagePath"] = $DestinationImagePaths[0]
    $JobMetadata["imagePaths"] = @($DestinationImagePaths)

    Save-JobMetadata -Metadata $JobMetadata -Path $JobMetadataPath
    if ($null -ne $StandaloneGeneration) {
        $StandaloneGeneration.status = "completed"
        $StandaloneGeneration.completedAt = $JobMetadata.completedAt
        $StandaloneGeneration.imagePath = $DestinationImagePaths[0]
        Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath
    }

    if ($PipelineManaged) {
        Write-Ok "Image générée : $($DestinationImagePaths[0])"
    } else {
        Write-Ok "Génération d’image Asset Factory terminée"
        Write-Ok "Job: $JobId"
        Write-Ok "Generation: $($Layout.Root)"
        if (-not [string]::IsNullOrWhiteSpace($Layout.Version)) {
            Write-Ok "Version: $($Layout.Version)"
        }
        Write-Ok "Images: $($DestinationImagePaths.Count)"
        Write-Ok "Image: $($DestinationImagePaths[0])"
        Write-Ok "Metadata: $JobMetadataPath"
        if ($null -ne $StandaloneGeneration) { Write-Ok "Generation metadata: $StandaloneGenerationPath" }
    }

    exit 0
} catch {
    $message = $_.Exception.Message

    Set-JobFailed `
        -Metadata $JobMetadata `
        -MetadataPath $JobMetadataPath `
        -Message $message
    if ($null -ne $StandaloneGeneration) {
        $StandaloneGeneration.status = "failed"
        $StandaloneGeneration.completedAt = (Get-Date).ToString("o")
        $StandaloneGeneration.error = $message
        try { Save-AFJson -Value $StandaloneGeneration -Path $StandaloneGenerationPath } catch { }
    }

    Write-Fail $message
    Write-Info "Métadonnées : $JobMetadataPath"
    exit 1
}
