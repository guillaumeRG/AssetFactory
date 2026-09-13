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
    [int]$PollIntervalSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

$AssetFactoryRoot = [System.IO.Path]::GetFullPath(
    (Split-Path -Parent $PSScriptRoot)
)

$ServerUrl = $ServerUrl.TrimEnd("/")

# Nœuds attendus dans le workflow API ComfyUI de référence.
$PositivePromptNodeId = "2"
$NegativePromptNodeId = "3"
$SamplerNodeId = "5"
$SaveImageNodeId = "7"

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
        Write-Fail "Could not persist failed job metadata: $($_.Exception.Message)"
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

function New-UniqueJobId {
    param([Parameter(Mandatory = $true)][string]$JobsRoot)

    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $candidate = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $candidatePath = Join-Path $JobsRoot $candidate

        if (-not (Test-Path -LiteralPath $candidatePath)) {
            return $candidate
        }

        Start-Sleep -Milliseconds 2
    }

    return "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$([guid]::NewGuid().ToString('N').Substring(0,8))"
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

Write-Info "AssetFactory root: $AssetFactoryRoot"
Write-Info "Prompt: $Prompt"
Write-Info "Seed: $Seed"

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
    Write-Fail "Invalid workflow path: $WorkflowPath"
    Write-Info $_.Exception.Message
    exit 1
}

if (-not (Test-Path -LiteralPath $ResolvedWorkflowPath -PathType Leaf)) {
    Write-Fail "Workflow not found: $ResolvedWorkflowPath"
    exit 1
}

Write-Ok "Workflow found: $ResolvedWorkflowPath"

# -----------------------------------------------------------------------------
# Validation de l'API ComfyUI
# -----------------------------------------------------------------------------

$SystemStatsUrl = "$ServerUrl/system_stats"

try {
    Invoke-RestMethod `
        -Uri $SystemStatsUrl `
        -Method Get `
        -TimeoutSec 5 | Out-Null

    Write-Ok "ComfyUI API available: $SystemStatsUrl"
} catch {
    Write-Fail "ComfyUI API unavailable: $SystemStatsUrl"
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
    Write-Fail "Could not load workflow JSON: $ResolvedWorkflowPath"
    Write-Info $_.Exception.Message
    exit 1
}

try {
    Assert-WorkflowNode -Workflow $Workflow -NodeId $PositivePromptNodeId -ExpectedClassType "CLIPTextEncode"
    Assert-WorkflowNode -Workflow $Workflow -NodeId $NegativePromptNodeId -ExpectedClassType "CLIPTextEncode"
    Assert-WorkflowNode -Workflow $Workflow -NodeId $SamplerNodeId -ExpectedClassType "KSampler"
    Assert-WorkflowNode -Workflow $Workflow -NodeId $SaveImageNodeId -ExpectedClassType "SaveImage"
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}

# -----------------------------------------------------------------------------
# Création de l'identité du job et personnalisation du workflow
# -----------------------------------------------------------------------------

$JobsRoot = Join-Path $AssetFactoryRoot "outputs\jobs"

if (-not (Test-Path -LiteralPath $JobsRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $JobsRoot -Force | Out-Null
}

$JobId = New-UniqueJobId -JobsRoot $JobsRoot

$Workflow.$PositivePromptNodeId.inputs.text = $Prompt
$Workflow.$NegativePromptNodeId.inputs.text = $NegativePrompt
$Workflow.$SamplerNodeId.inputs.seed = $Seed
$Workflow.$SaveImageNodeId.inputs.filename_prefix = "assetfactory_$JobId"

Write-Ok "Workflow loaded and customized"
Write-Info "JobId: $JobId"

# -----------------------------------------------------------------------------
# Création des répertoires du job et des métadonnées initiales
# -----------------------------------------------------------------------------

$JobRoot = Join-Path $JobsRoot $JobId
$JobWorkflowDir = Join-Path $JobRoot "workflow"
$JobGeneratedDir = Join-Path $JobRoot "generated"
$JobLogsDir = Join-Path $JobRoot "logs"
$ResolvedWorkflowOutput = Join-Path $JobWorkflowDir "workflow.json"
$JobMetadataPath = Join-Path $JobRoot "job.json"

try {
    foreach ($directory in @($JobRoot, $JobWorkflowDir, $JobGeneratedDir, $JobLogsDir)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $Workflow |
        ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $ResolvedWorkflowOutput -Encoding UTF8
} catch {
    Write-Fail "Could not initialize job directories/workflow."
    Write-Info $_.Exception.Message
    exit 1
}

$JobMetadata = [ordered]@{
    jobId          = $JobId
    createdAt      = (Get-Date).ToString("o")
    status         = "running"
    type           = "comfyui-image"
    prompt         = $Prompt
    negativePrompt = $NegativePrompt
    seed           = $Seed
    serverUrl      = $ServerUrl
    workflowPath   = $ResolvedWorkflowOutput
    promptId       = $null
    imageCount     = 0
    imagePath      = $null
    imagePaths     = @()
}

try {
    Save-JobMetadata -Metadata $JobMetadata -Path $JobMetadataPath
} catch {
    Write-Fail "Could not create job metadata."
    Write-Info $_.Exception.Message
    exit 1
}

Write-Ok "Job directories created"
Write-Ok "Resolved workflow saved: $ResolvedWorkflowOutput"
Write-Ok "Metadata created: $JobMetadataPath"

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

    Write-Ok "Workflow submitted to ComfyUI"
    Write-Info "PromptId: $PromptId"

    # Attend la fin de l'exécution.
    $HistoryUrl = "$ServerUrl/history/$PromptId"
    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $HistoryEntry = $null

    Write-Info "Waiting for ComfyUI generation to complete..."

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

    Write-Ok "ComfyUI generation completed"

    # Valide les sorties SaveImage.
    if (-not ($HistoryEntry.PSObject.Properties.Name -contains "outputs")) {
        throw "ComfyUI history does not contain outputs."
    }

    $Outputs = $HistoryEntry.outputs

    if ($null -eq $Outputs -or
        -not ($Outputs.PSObject.Properties.Name -contains $SaveImageNodeId)) {
        throw "SaveImage node '$SaveImageNodeId' output not found."
    }

    $SaveOutput = $Outputs.$SaveImageNodeId

    if ($null -eq $SaveOutput -or
        -not ($SaveOutput.PSObject.Properties.Name -contains "images")) {
        throw "No images returned by SaveImage node '$SaveImageNodeId'."
    }

    $GeneratedImages = @($SaveOutput.images)

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

        $destinationName = $filename
        $DestinationImagePath = Join-Path $JobGeneratedDir $destinationName

        if (Test-Path -LiteralPath $DestinationImagePath) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($filename)
            $extension = [System.IO.Path]::GetExtension($filename)
            $destinationName = "{0}_{1:D2}{2}" -f $baseName, $imageIndex, $extension
            $DestinationImagePath = Join-Path $JobGeneratedDir $destinationName
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
        Write-Ok "Generated image recovered: $DestinationImagePath"
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

    Write-Ok "Asset Factory job completed"
    Write-Ok "Job: $JobId"
    Write-Ok "Images: $($DestinationImagePaths.Count)"
    Write-Ok "Image: $($DestinationImagePaths[0])"
    Write-Ok "Metadata: $JobMetadataPath"

    exit 0
} catch {
    $message = $_.Exception.Message

    Set-JobFailed `
        -Metadata $JobMetadata `
        -MetadataPath $JobMetadataPath `
        -Message $message

    Write-Fail $message
    Write-Info "Metadata: $JobMetadataPath"
    exit 1
}
