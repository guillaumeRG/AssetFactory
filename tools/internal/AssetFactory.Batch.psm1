Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ToolsRoot = Split-Path -Parent $PSScriptRoot
$script:AssetFactoryRoot = Split-Path -Parent $script:ToolsRoot
. (Join-Path $script:ToolsRoot "pipeline-common.ps1")

function Test-AFBatchHasProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -ceq $Name) { return $true }
    }
    return $false
}

function Get-AFBatchProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -ceq $Name) {
            # Windows PowerShell 5.1 enumerates arrays written to the pipeline by a
            # function. Without -NoEnumerate, a JSON array containing one element
            # becomes a scalar here (notably items, seeds and string[] parameters).
            Write-Output -NoEnumerate $property.Value
            return
        }
    }
    return $Default
}

function Assert-AFBatchObject {
    param($Value, [string]$Label)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [System.Array] -or
        $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        throw "$Label must be a JSON object."
    }
}

function Assert-AFBatchKnownProperties {
    param($Object, [string[]]$Allowed, [string]$Label)
    if ($null -eq $Object) { return }
    foreach ($property in $Object.PSObject.Properties) {
        if (-not ($Allowed -ccontains $property.Name)) {
            throw "Unknown property '$($property.Name)' in $Label."
        }
    }
}

function ConvertTo-AFBatchJsonName {
    param([string]$PowerShellName)
    if ([string]::IsNullOrEmpty($PowerShellName)) { return $PowerShellName }
    if ($PowerShellName.Length -eq 1) { return $PowerShellName.ToLowerInvariant() }
    return $PowerShellName.Substring(0, 1).ToLowerInvariant() + $PowerShellName.Substring(1)
}

function Get-AFBatchDefaultSnapshotValue {
    param($DefaultAst)
    if ($null -eq $DefaultAst) {
        return [pscustomobject]@{ HasValue = $false; Value = $null; Expression = $null }
    }

    $expression = $DefaultAst.Extent.Text
    if ($DefaultAst -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $DefaultAst -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return [pscustomobject]@{ HasValue = $true; Value = $DefaultAst.Value; Expression = $expression }
    }
    if ($DefaultAst -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = $DefaultAst.VariablePath.UserPath.ToLowerInvariant()
        if ($name -eq "true") { return [pscustomobject]@{ HasValue = $true; Value = $true; Expression = $expression } }
        if ($name -eq "false") { return [pscustomobject]@{ HasValue = $true; Value = $false; Expression = $expression } }
        if ($name -eq "null") { return [pscustomobject]@{ HasValue = $true; Value = $null; Expression = $expression } }
    }
    if ($expression -eq "@()") {
        return [pscustomobject]@{ HasValue = $true; Value = @(); Expression = $expression }
    }

    return [pscustomobject]@{ HasValue = $false; Value = $null; Expression = $expression }
}

function Get-AFBatchEntryPointContract {
    param([Parameter(Mandatory = $true)][string]$EntryPoint)

    $fileName = switch ($EntryPoint) {
        "generate-image" { "generate-image.ps1" }
        "generate-asset-from-image" { "generate-asset-from-image.ps1" }
        "generate-asset-from-prompt" { "generate-asset-from-prompt.ps1" }
        default { throw "Unknown entryPoint '$EntryPoint'." }
    }
    $scriptPath = Join-Path $script:ToolsRoot $fileName
    Assert-AFFile -Path $scriptPath -Label "Public entry point"

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Cannot parse public entry point '$scriptPath': $($parseErrors -join '; ')"
    }

    $command = Get-Command -Name $scriptPath -CommandType ExternalScript -ErrorAction Stop
    $excluded = switch ($EntryPoint) {
        "generate-image" { @("Prompt", "AssetId") }
        "generate-asset-from-image" { @("InputPath", "AssetId") }
        "generate-asset-from-prompt" { @("Prompt", "AssetId") }
    }

    $parameters = @()
    $defaults = [ordered]@{}
    foreach ($parameterAst in @($ast.ParamBlock.Parameters)) {
        $psName = $parameterAst.Name.VariablePath.UserPath
        if ($excluded -contains $psName) { continue }
        $metadata = $command.Parameters[$psName]
        if ($null -eq $metadata) { throw "Parameter metadata not found for '$psName' in '$fileName'." }
        $jsonName = ConvertTo-AFBatchJsonName $psName
        $defaultInfo = Get-AFBatchDefaultSnapshotValue $parameterAst.DefaultValue
        if ($defaultInfo.HasValue) {
            $defaults[$jsonName] = $defaultInfo.Value
        } elseif ($null -ne $defaultInfo.Expression) {
            $defaults[$jsonName] = [ordered]@{ expression = $defaultInfo.Expression }
        }
        $parameters += [pscustomobject]@{
            PowerShellName = $psName
            JsonName = $jsonName
            ParameterType = $metadata.ParameterType
            Attributes = @($metadata.Attributes)
            Default = $defaultInfo
        }
    }

    return [pscustomobject]@{
        EntryPoint = $EntryPoint
        ScriptPath = $scriptPath
        Parameters = $parameters
        JsonParameterNames = @($parameters | ForEach-Object { $_.JsonName })
        EntryPointDefaults = $defaults
    }
}

function Assert-AFBatchInteger {
    param($Value, [string]$Label, [decimal]$Minimum = 0, [decimal]$Maximum = [long]::MaxValue)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) {
        throw "$Label must be an integer."
    }
    try { $number = [decimal]$Value } catch { throw "$Label must be an integer." }
    if ($number -ne [decimal]::Truncate($number) -or $number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Label must be an integer between $Minimum and $Maximum."
    }
    return $number
}

function Assert-AFBatchParameterValue {
    param($Value, $Parameter, [string]$Context)

    $type = $Parameter.ParameterType
    $underlying = [System.Nullable]::GetUnderlyingType($type)
    if ($null -ne $underlying) {
        if ($null -eq $Value) { return }
        $type = $underlying
    }

    if ($type -eq [string]) {
        if ($null -eq $Value -or $Value -isnot [string]) { throw "$Context must be a JSON string." }
    } elseif ($type -eq [string[]]) {
        if ($null -eq $Value -or $Value -isnot [System.Array]) { throw "$Context must be a JSON array of strings." }
        foreach ($entry in @($Value)) {
            if ($entry -isnot [string]) { throw "$Context must contain strings only." }
        }
    } elseif ($type -eq [bool]) {
        if ($Value -isnot [bool]) { throw "$Context must be a JSON boolean." }
    } elseif ($type -eq [int]) {
        $null = Assert-AFBatchInteger -Value $Value -Label $Context -Minimum ([int]::MinValue) -Maximum ([int]::MaxValue)
    } elseif ($type -eq [long]) {
        $null = Assert-AFBatchInteger -Value $Value -Label $Context -Minimum ([long]::MinValue) -Maximum ([long]::MaxValue)
    } elseif ($type -eq [double]) {
        if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { throw "$Context must be a JSON number." }
        try { $number = [double]$Value } catch { throw "$Context must be a JSON number." }
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw "$Context must be a finite JSON number." }
    } else {
        throw "$Context uses unsupported public parameter type '$($Parameter.ParameterType.FullName)'."
    }

    foreach ($attribute in @($Parameter.Attributes)) {
        if ($attribute -is [System.Management.Automation.ValidateNotNullOrEmptyAttribute]) {
            if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrEmpty($Value)) -or
                ($Value -is [System.Array] -and @($Value).Count -eq 0)) {
                throw "$Context cannot be null or empty."
            }
        } elseif ($attribute -is [System.Management.Automation.ValidateSetAttribute]) {
            $matched = $false
            foreach ($allowed in @($attribute.ValidValues)) {
                if ([string]::Equals([string]$Value, [string]$allowed, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $matched = $true
                    break
                }
            }
            if (-not $matched) { throw "$Context must be one of: $($attribute.ValidValues -join ', ')." }
        } elseif ($attribute -is [System.Management.Automation.ValidateRangeAttribute]) {
            if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { throw "$Context must be numeric." }
            try {
                $numeric = [decimal]$Value
                $minimum = [decimal]$attribute.MinRange
                $maximum = [decimal]$attribute.MaxRange
            } catch {
                throw "$Context is outside the supported numeric range."
            }
            if ($numeric -lt $minimum -or $numeric -gt $maximum) {
                throw "$Context must be between $minimum and $maximum."
            }
        }
    }
}

function Assert-AFBatchParameterObject {
    param($Object, $Contract, [string]$Label)
    if ($null -eq $Object) { return }
    Assert-AFBatchObject -Value $Object -Label $Label
    foreach ($property in $Object.PSObject.Properties) {
        if (-not ($Contract.JsonParameterNames -ccontains $property.Name)) {
            throw "Unknown parameter '$($property.Name)' for entryPoint '$($Contract.EntryPoint)' in $Label."
        }
        $parameter = @($Contract.Parameters | Where-Object { $_.JsonName -ceq $property.Name })[0]
        Assert-AFBatchParameterValue -Value $property.Value -Parameter $parameter -Context "$Label.$($property.Name)"
    }
}

function Copy-AFBatchPropertiesToHash {
    param($Object, [hashtable]$Target)
    if ($null -eq $Object) { return }
    foreach ($property in $Object.PSObject.Properties) {
        $Target[$property.Name] = $property.Value
    }
}

function Get-AFBatchEffectiveParameterValue {
    param([hashtable]$Merged, $Contract, [string]$JsonName, $Fallback = $null)
    if ($Merged.ContainsKey($JsonName)) { return $Merged[$JsonName] }
    if ($Contract.EntryPointDefaults.Contains($JsonName)) { return $Contract.EntryPointDefaults[$JsonName] }
    return $Fallback
}

function Resolve-AFBatchPathParameters {
    param([hashtable]$Parameters, [string]$ManifestDirectory)

    foreach ($name in @("workflowPath", "projectProfile", "blenderPath")) {
        if (-not $Parameters.ContainsKey($name)) { continue }
        $value = [string]$Parameters[$name]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $resolved = Resolve-AFPath -Path $value -BasePath $ManifestDirectory
        Assert-AFFile -Path $resolved -Label "Batch parameter '$name'"
        $Parameters[$name] = $resolved
    }
}

function ConvertTo-AFBatchInvocationParameters {
    param($Execution, $Contract)

    $parameters = @{
        AssetId = [string]$Execution.assetId
        Seed = [long]$Execution.effectiveSeed
    }
    foreach ($parameter in @($Contract.Parameters)) {
        $name = $parameter.JsonName
        if ($name -ceq "seed") { continue }
        if ($Execution.invocationParameters.Contains($name)) {
            $parameters[$parameter.PowerShellName] = $Execution.invocationParameters[$name]
        }
    }
    if ($Contract.EntryPoint -eq "generate-image" -or $Contract.EntryPoint -eq "generate-asset-from-prompt") {
        $parameters.Prompt = [string]$Execution.prompt
    } else {
        $parameters.InputPath = [string]$Execution.inputPath
    }
    return $parameters
}

function Invoke-AFBatchPublicEntryPoint {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][hashtable]$Parameters,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $writer = [System.IO.StreamWriter]::new($LogPath, $false, [System.Text.Encoding]::UTF8)
    $writer.AutoFlush = $true
    $oldPreference = $ErrorActionPreference
    $exitCode = 1
    $failure = $null

    try {
        # Les trois API publiques sont des scripts PowerShell. Les invoquer directement
        # conserve le splatting typé (bool/nullables/tableaux/Int64) sans reconstruire
        # une ligne de commande texte.
        $ErrorActionPreference = "Continue"
        $global:LASTEXITCODE = 0
        & $ScriptPath @Parameters 6>&1 2>&1 | ForEach-Object {
            $text = $_.ToString()
            $lines.Add($text)
            $writer.WriteLine($text)
            Write-Host $text
        }
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
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

function Get-AFBatchManifestHash {
    param([string]$ManifestPath)
    return (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-AFBatchResolvedPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $resolvedManifestPath = Resolve-AFPath -Path $ManifestPath -BasePath (Get-Location).Path
    Assert-AFFile -Path $resolvedManifestPath -Label "Batch manifest"
    $manifestDirectory = Split-Path -Parent $resolvedManifestPath
    $raw = Get-Content -LiteralPath $resolvedManifestPath -Raw -Encoding UTF8
    try { $manifest = $raw | ConvertFrom-Json } catch { throw "Invalid batch JSON: $($_.Exception.Message)" }
    Assert-AFBatchObject -Value $manifest -Label "Manifest root"

    Assert-AFBatchKnownProperties -Object $manifest -Allowed @(
        "kind", "schemaVersion", "batchId", "description", "entryPoint", "execution", "defaults", "items"
    ) -Label "manifest root"

    foreach ($required in @("kind", "schemaVersion", "batchId", "entryPoint", "items")) {
        if (-not (Test-AFBatchHasProperty $manifest $required)) { throw "Missing required manifest property '$required'." }
    }
    if ((Get-AFBatchProperty $manifest "kind") -cne "asset-factory-batch") {
        throw "Manifest is not an Asset Factory Batch V1 manifest: kind must be 'asset-factory-batch'."
    }
    $schemaVersion = Get-AFBatchProperty $manifest "schemaVersion"
    $null = Assert-AFBatchInteger -Value $schemaVersion -Label "schemaVersion" -Minimum 1 -Maximum 1

    $batchId = Get-AFBatchProperty $manifest "batchId"
    if ($batchId -isnot [string]) { throw "batchId must be a JSON string." }
    Assert-AFFileStem -Name $batchId -Label "batchId"

    if (Test-AFBatchHasProperty $manifest "description") {
        $description = Get-AFBatchProperty $manifest "description"
        if ($description -isnot [string]) { throw "description must be a JSON string." }
    } else {
        $description = ""
    }

    $entryPoint = Get-AFBatchProperty $manifest "entryPoint"
    if ($entryPoint -isnot [string] -or $entryPoint -cnotin @("generate-image", "generate-asset-from-image", "generate-asset-from-prompt")) {
        throw "entryPoint must be generate-image, generate-asset-from-image, or generate-asset-from-prompt."
    }
    $contract = Get-AFBatchEntryPointContract -EntryPoint $entryPoint

    $continueOnError = $false
    $maxParallelism = 1
    if (Test-AFBatchHasProperty $manifest "execution") {
        $executionConfig = Get-AFBatchProperty $manifest "execution"
        Assert-AFBatchObject -Value $executionConfig -Label "execution"
        Assert-AFBatchKnownProperties -Object $executionConfig -Allowed @("continueOnError", "maxParallelism") -Label "execution"
        if (Test-AFBatchHasProperty $executionConfig "continueOnError") {
            $continueOnError = Get-AFBatchProperty $executionConfig "continueOnError"
            if ($continueOnError -isnot [bool]) { throw "execution.continueOnError must be a JSON boolean." }
        }
        if (Test-AFBatchHasProperty $executionConfig "maxParallelism") {
            $maxParallelismValue = Get-AFBatchProperty $executionConfig "maxParallelism"
            $null = Assert-AFBatchInteger -Value $maxParallelismValue -Label "execution.maxParallelism" -Minimum 1 -Maximum ([int]::MaxValue)
            $maxParallelism = [int]$maxParallelismValue
        }
    }
    if ($maxParallelism -ne 1) { throw "Batch V1 currently supports maxParallelism=1 only." }

    $defaults = $null
    if (Test-AFBatchHasProperty $manifest "defaults") {
        $defaults = Get-AFBatchProperty $manifest "defaults"
        Assert-AFBatchParameterObject -Object $defaults -Contract $contract -Label "defaults"
    }

    $itemsValue = Get-AFBatchProperty $manifest "items"
    if ($itemsValue -isnot [System.Array]) { throw "items must be a non-empty JSON array." }
    $items = @($itemsValue)
    if ($items.Count -eq 0) { throw "items must not be empty." }

    $seenItemIds = @{}
    $seenAssetIds = @{}
    $resolvedItems = @()
    $executions = @()

    for ($itemIndex = 0; $itemIndex -lt $items.Count; $itemIndex++) {
        $item = $items[$itemIndex]
        $label = "items[$itemIndex]"
        Assert-AFBatchObject -Value $item -Label $label
        $allowedItemProperties = if ($entryPoint -eq "generate-asset-from-image") {
            @("id", "inputPath", "params", "outputs")
        } else {
            @("id", "prompt", "params", "outputs")
        }
        Assert-AFBatchKnownProperties -Object $item -Allowed $allowedItemProperties -Label $label
        if (-not (Test-AFBatchHasProperty $item "id")) { throw "$label is missing required property 'id'." }
        $itemId = Get-AFBatchProperty $item "id"
        if ($itemId -isnot [string]) { throw "$label.id must be a JSON string." }
        Assert-AFFileStem -Name $itemId -Label "$label.id"
        if ($seenItemIds.ContainsKey($itemId)) { throw "Duplicate item id '$itemId'." }
        $seenItemIds[$itemId] = $true

        $prompt = $null
        $inputPath = $null
        if ($entryPoint -eq "generate-asset-from-image") {
            if (-not (Test-AFBatchHasProperty $item "inputPath")) { throw "$label is missing required property 'inputPath'." }
            $inputPathValue = Get-AFBatchProperty $item "inputPath"
            if ($inputPathValue -isnot [string] -or [string]::IsNullOrWhiteSpace($inputPathValue)) {
                throw "$label.inputPath must be a non-empty JSON string."
            }
            $inputPath = Resolve-AFPath -Path $inputPathValue -BasePath $manifestDirectory
            Assert-AFFile -Path $inputPath -Label "$label.inputPath"
            if ([System.IO.Path]::GetExtension($inputPath).ToLowerInvariant() -notin @(".png", ".jpg", ".jpeg", ".webp")) {
                throw "$label.inputPath must point to a PNG, JPEG, or WebP image."
            }
        } else {
            if (-not (Test-AFBatchHasProperty $item "prompt")) { throw "$label is missing required property 'prompt'." }
            $prompt = Get-AFBatchProperty $item "prompt"
            if ($prompt -isnot [string] -or [string]::IsNullOrWhiteSpace($prompt)) {
                throw "$label.prompt must be a non-empty JSON string."
            }
        }

        $itemParams = $null
        if (Test-AFBatchHasProperty $item "params") {
            $itemParams = Get-AFBatchProperty $item "params"
            Assert-AFBatchParameterObject -Object $itemParams -Contract $contract -Label "$label.params"
        }

        $merged = @{}
        Copy-AFBatchPropertiesToHash -Object $defaults -Target $merged
        Copy-AFBatchPropertiesToHash -Object $itemParams -Target $merged
        Resolve-AFBatchPathParameters -Parameters $merged -ManifestDirectory $manifestDirectory

        if ($merged.ContainsKey("assetVersion") -and -not [string]::IsNullOrWhiteSpace([string]$merged.assetVersion)) {
            Assert-AFAssetVersion -Version ([string]$merged.assetVersion) -Label "$label.params.assetVersion"
        }
        if ($entryPoint -ne "generate-image") {
            $geometryMethod = [string](Get-AFBatchEffectiveParameterValue -Merged $merged -Contract $contract -JsonName "geometryMethod")
            $multiview = [bool](Get-AFBatchEffectiveParameterValue -Merged $merged -Contract $contract -JsonName "multiview" -Fallback $false)
            if ($multiview -and $geometryMethod.ToLowerInvariant() -ne "trellis") {
                throw "${label}: multiview requires geometryMethod 'trellis'."
            }
            if ($entryPoint -eq "generate-asset-from-image" -and $multiview) {
                $texturePrompt = [string](Get-AFBatchEffectiveParameterValue -Merged $merged -Contract $contract -JsonName "texturePrompt" -Fallback "")
                if ([string]::IsNullOrWhiteSpace($texturePrompt)) {
                    throw "${label}: texturePrompt is required when multiview is true for generate-asset-from-image."
                }
            }
        }

        $outputs = $null
        if (Test-AFBatchHasProperty $item "outputs") {
            $outputs = Get-AFBatchProperty $item "outputs"
            Assert-AFBatchObject -Value $outputs -Label "$label.outputs"
            Assert-AFBatchKnownProperties -Object $outputs -Allowed @("count", "seedStart", "seedStep", "seeds") -Label "$label.outputs"
        }

        $hasCount = $null -ne $outputs -and (Test-AFBatchHasProperty $outputs "count")
        $hasSeedStart = $null -ne $outputs -and (Test-AFBatchHasProperty $outputs "seedStart")
        $hasSeedStep = $null -ne $outputs -and (Test-AFBatchHasProperty $outputs "seedStep")
        $hasSeeds = $null -ne $outputs -and (Test-AFBatchHasProperty $outputs "seeds")
        if ($hasSeeds -and ($hasSeedStart -or $hasSeedStep)) {
            throw "$label.outputs: seeds is mutually exclusive with seedStart/seedStep."
        }

        $explicitSeeds = @()
        if ($hasSeeds) {
            $seedsValue = Get-AFBatchProperty $outputs "seeds"
            if ($seedsValue -isnot [System.Array]) { throw "$label.outputs.seeds must be a non-empty JSON array." }
            $explicitSeeds = @($seedsValue)
            if ($explicitSeeds.Count -eq 0) { throw "$label.outputs.seeds must not be empty." }
            for ($seedIndex = 0; $seedIndex -lt $explicitSeeds.Count; $seedIndex++) {
                $null = Assert-AFBatchInteger -Value $explicitSeeds[$seedIndex] -Label "$label.outputs.seeds[$seedIndex]" -Minimum 0 -Maximum ([long]::MaxValue)
            }
        }

        $count = if ($hasSeeds) { $explicitSeeds.Count } elseif ($hasCount) {
            $countValue = Get-AFBatchProperty $outputs "count"
            $null = Assert-AFBatchInteger -Value $countValue -Label "$label.outputs.count" -Minimum 1 -Maximum ([int]::MaxValue)
            [int]$countValue
        } else { 1 }
        if ($hasSeeds -and $hasCount) {
            $countValue = Get-AFBatchProperty $outputs "count"
            $null = Assert-AFBatchInteger -Value $countValue -Label "$label.outputs.count" -Minimum 1 -Maximum ([int]::MaxValue)
            if ([int]$countValue -ne $explicitSeeds.Count) {
                throw "$label.outputs.count must equal seeds.length when both are provided."
            }
        }

        $baseSeed = [decimal](Get-AFBatchEffectiveParameterValue -Merged $merged -Contract $contract -JsonName "seed" -Fallback 0)
        $seedStart = if ($hasSeedStart) {
            $value = Get-AFBatchProperty $outputs "seedStart"
            $null = Assert-AFBatchInteger -Value $value -Label "$label.outputs.seedStart" -Minimum 0 -Maximum ([long]::MaxValue)
            [decimal]$value
        } else { $baseSeed }
        $seedStep = if ($hasSeedStep) {
            $value = Get-AFBatchProperty $outputs "seedStep"
            $null = Assert-AFBatchInteger -Value $value -Label "$label.outputs.seedStep" -Minimum 0 -Maximum ([long]::MaxValue)
            [decimal]$value
        } else { [decimal]1 }

        $width = [Math]::Max(2, $count.ToString().Length)
        $itemExecutionIds = @()
        for ($variantIndex = 1; $variantIndex -le $count; $variantIndex++) {
            $assetId = if ($count -eq 1) { $itemId } else { $itemId + "__" + $variantIndex.ToString("D$width") }
            Assert-AFFileStem -Name $assetId -Label "Expanded AssetId"
            if ($seenAssetIds.ContainsKey($assetId)) { throw "Expanded AssetId collision: '$assetId'." }
            $seenAssetIds[$assetId] = $true

            $effectiveSeedDecimal = if ($hasSeeds) { [decimal]$explicitSeeds[$variantIndex - 1] } else {
                $seedStart + (($variantIndex - 1) * $seedStep)
            }
            if ($effectiveSeedDecimal -lt 0 -or $effectiveSeedDecimal -gt [long]::MaxValue) {
                throw "$label outputs generate a seed outside the supported 64-bit range."
            }
            $effectiveSeed = [long]$effectiveSeedDecimal

            $invocationParameters = [ordered]@{}
            foreach ($key in $merged.Keys | Sort-Object) { $invocationParameters[$key] = $merged[$key] }
            $invocationParameters["seed"] = $effectiveSeed

            $effectiveParameters = [ordered]@{}
            foreach ($key in $contract.EntryPointDefaults.Keys) { $effectiveParameters[$key] = $contract.EntryPointDefaults[$key] }
            foreach ($key in $merged.Keys | Sort-Object) { $effectiveParameters[$key] = $merged[$key] }
            $effectiveParameters["seed"] = $effectiveSeed
            $effectiveParameters["assetId"] = $assetId
            if ($null -ne $prompt) { $effectiveParameters["prompt"] = $prompt }
            if ($null -ne $inputPath) { $effectiveParameters["inputPath"] = $inputPath }

            if ($entryPoint -ne "generate-image") {
                $projectProfile = if ($merged.ContainsKey("projectProfile")) { [string]$merged.projectProfile } else { "" }
                $autoImport = if ($merged.ContainsKey("autoImport")) { $merged.autoImport } else { $null }
                $category = if ($merged.ContainsKey("category")) { [string]$merged.category } else { "" }
                if (-not [string]::IsNullOrWhiteSpace($projectProfile) -or $null -ne $autoImport) {
                    $null = Resolve-AFUnrealConfiguration -Root $script:AssetFactoryRoot -ProjectProfile $projectProfile -AutoImport $autoImport -AssetId $assetId -Category $category
                }
            }

            $executionId = $assetId
            $executions += [pscustomobject][ordered]@{
                executionId = $executionId
                itemId = $itemId
                variantIndex = $variantIndex
                entryPoint = $entryPoint
                assetId = $assetId
                effectiveSeed = $effectiveSeed
                effectiveParameters = $effectiveParameters
                invocationParameters = $invocationParameters
                prompt = $prompt
                inputPath = $inputPath
                status = "pending"
            }
            $itemExecutionIds += $executionId
        }

        $resolvedItems += [pscustomobject][ordered]@{
            id = $itemId
            prompt = $prompt
            inputPath = $inputPath
            executionIds = $itemExecutionIds
        }
    }

    $resolvedDefaults = @{}
    Copy-AFBatchPropertiesToHash -Object $defaults -Target $resolvedDefaults
    Resolve-AFBatchPathParameters -Parameters $resolvedDefaults -ManifestDirectory $manifestDirectory

    return [pscustomobject][ordered]@{
        kind = "asset-factory-batch"
        schemaVersion = 1
        batchId = $batchId
        description = $description
        entryPoint = $entryPoint
        manifestPath = $resolvedManifestPath
        manifestDirectory = $manifestDirectory
        manifestHash = Get-AFBatchManifestHash -ManifestPath $resolvedManifestPath
        execution = [ordered]@{ continueOnError = [bool]$continueOnError; maxParallelism = 1 }
        entryPointDefaults = $contract.EntryPointDefaults
        defaults = $resolvedDefaults
        items = $resolvedItems
        executions = $executions
        contract = $contract
    }
}

function Save-AFBatchJson {
    param([Parameter(Mandatory = $true)]$Value, [Parameter(Mandatory = $true)][string]$Path)
    ConvertTo-Json -InputObject $Value -Depth 40 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Save-AFBatchResults {
    param([string]$RunRoot, $Results)
    Save-AFBatchJson -Value @($Results) -Path (Join-Path $RunRoot "results.json")
}

function Save-AFBatchItems {
    param([string]$RunRoot, $Plan, $Results)
    $items = @()
    foreach ($item in @($Plan.items)) {
        $states = @()
        foreach ($executionId in @($item.executionIds)) {
            $record = @($Results | Where-Object { $_.executionId -eq $executionId })[0]
            $states += [ordered]@{ executionId = $executionId; status = $record.status; resumeAction = $record.resumeAction }
        }
        $items += [ordered]@{
            id = $item.id
            prompt = $item.prompt
            inputPath = $item.inputPath
            executions = $states
        }
    }
    Save-AFBatchJson -Value @($items) -Path (Join-Path $RunRoot "items.json")
}

function Get-AFBatchResumeRun {
    param($Plan)
    $batchRoot = Join-Path $script:AssetFactoryRoot ("outputs\batches\" + $Plan.batchId)
    if (-not (Test-Path -LiteralPath $batchRoot -PathType Container)) {
        throw "No previous run exists for batchId '$($Plan.batchId)'."
    }
    $candidates = @(Get-ChildItem -LiteralPath $batchRoot -Directory | Sort-Object Name -Descending)
    foreach ($candidate in $candidates) {
        $runPath = Join-Path $candidate.FullName "batch-run.json"
        if (-not (Test-Path -LiteralPath $runPath -PathType Leaf)) { continue }
        try { $run = Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($run.status -eq "completed") { continue }
        if ([string]$run.manifestHash -cne [string]$Plan.manifestHash) {
            throw "Cannot resume batch '$($Plan.batchId)': the manifest changed since the latest incomplete run."
        }
        return [pscustomobject]@{ Root = $candidate.FullName; Run = $run }
    }
    throw "No incomplete run is available to resume for batchId '$($Plan.batchId)'."
}

function New-AFBatchResultRecords {
    param($Plan, [string]$LogsDirectory)
    $records = @()
    foreach ($execution in @($Plan.executions)) {
        $records += [pscustomobject][ordered]@{
            executionId = $execution.executionId
            itemId = $execution.itemId
            variantIndex = $execution.variantIndex
            entryPoint = $execution.entryPoint
            assetId = $execution.assetId
            seed = $execution.effectiveSeed
            status = "pending"
            resumeAction = $null
            attemptCount = 0
            effectiveParameters = $execution.effectiveParameters
            startedAt = $null
            completedAt = $null
            generationRoot = $null
            logPath = (Join-Path $LogsDirectory ($execution.executionId + ".log"))
            result = $null
            error = $null
        }
    }
    return $records
}

function Merge-AFBatchResumeResults {
    param($Plan, $ExistingResults, [string]$LogsDirectory)
    $records = @()
    foreach ($execution in @($Plan.executions)) {
        $existing = @($ExistingResults | Where-Object { $_.executionId -eq $execution.executionId })
        if ($existing.Count -ne 1) {
            throw "Resume data is incompatible: execution '$($execution.executionId)' is missing or duplicated."
        }
        $old = $existing[0]
        $status = [string]$old.status
        $resumeAction = $null
        if ($status -eq "completed" -or $status -eq "skipped") {
            $status = "completed"
            $resumeAction = "skipped"
        } else {
            $status = "pending"
            $resumeAction = "rerun"
        }
        $records += [pscustomobject][ordered]@{
            executionId = $execution.executionId
            itemId = $execution.itemId
            variantIndex = $execution.variantIndex
            entryPoint = $execution.entryPoint
            assetId = $execution.assetId
            seed = $execution.effectiveSeed
            status = $status
            resumeAction = $resumeAction
            attemptCount = [int](Get-AFProperty $old "attemptCount" 0)
            effectiveParameters = $execution.effectiveParameters
            startedAt = if ($status -eq "completed") { $old.startedAt } else { $null }
            completedAt = if ($status -eq "completed") { $old.completedAt } else { $null }
            generationRoot = if ($status -eq "completed") { $old.generationRoot } else { $null }
            logPath = (Join-Path $LogsDirectory ($execution.executionId + ".log"))
            result = if ($status -eq "completed") { $old.result } else { $null }
            error = $null
        }
    }
    if (@($records).Count -ne @($ExistingResults).Count) {
        throw "Resume data is incompatible with the current expanded execution plan."
    }
    return $records
}

function Invoke-AFBatchManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [switch]$Resume,
        [switch]$ValidateOnly
    )

    $plan = Get-AFBatchResolvedPlan -ManifestPath $ManifestPath
    $executionCount = @($plan.executions).Count
    if ($ValidateOnly) {
        Write-AFOk "Manifest valid"
        Write-AFOk "Entry point: $($plan.entryPoint)"
        Write-AFOk "Items: $(@($plan.items).Count)"
        Write-AFOk "Expanded executions: $executionCount"
        return [pscustomobject]@{ ExitCode = 0; Plan = $plan; RunRoot = $null; Status = "validated" }
    }

    $runId = $null
    $runRoot = $null
    $batchRun = $null
    $results = $null
    $logsDirectory = $null

    if ($Resume) {
        $resumeRun = Get-AFBatchResumeRun -Plan $plan
        $runRoot = $resumeRun.Root
        $batchRun = $resumeRun.Run
        $runId = [string]$batchRun.runId
        $logsDirectory = Join-Path $runRoot "logs"
        $resultsPath = Join-Path $runRoot "results.json"
        Assert-AFFile -Path $resultsPath -Label "Resume results"
        # Windows PowerShell 5.1 can preserve a top-level JSON array from
        # ConvertFrom-Json as a single nested Object[] pipeline result. Normalize
        # it explicitly so Resume always receives one record per execution.
        $decodedResults = Get-Content -LiteralPath $resultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $existingResults = @()
        foreach ($decodedResult in $decodedResults) {
            $existingResults += $decodedResult
        }
        $results = Merge-AFBatchResumeResults -Plan $plan -ExistingResults $existingResults -LogsDirectory $logsDirectory
        $batchRun.status = "running"
        $batchRun.completedAt = $null
        $batchRun.error = $null
        $batchRun.resumedAt = (Get-Date).ToString("o")
    } else {
        $runId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $runRoot = Join-Path $script:AssetFactoryRoot ("outputs\batches\" + $plan.batchId + "\" + $runId)
        if (Test-Path -LiteralPath $runRoot) { throw "Batch output already exists: $runRoot" }
        $logsDirectory = Join-Path $runRoot "logs"
        New-Item -ItemType Directory -Path $logsDirectory -Force | Out-Null
        Copy-Item -LiteralPath $plan.manifestPath -Destination (Join-Path $runRoot "manifest.original.json")

        $resolvedForFile = [ordered]@{
            kind = $plan.kind
            schemaVersion = $plan.schemaVersion
            batchId = $plan.batchId
            description = $plan.description
            entryPoint = $plan.entryPoint
            manifestPath = $plan.manifestPath
            manifestHash = $plan.manifestHash
            execution = $plan.execution
            entryPointDefaults = $plan.entryPointDefaults
            defaults = $plan.defaults
            items = $plan.items
            executions = @($plan.executions | ForEach-Object {
                [ordered]@{
                    executionId = $_.executionId
                    itemId = $_.itemId
                    variantIndex = $_.variantIndex
                    entryPoint = $_.entryPoint
                    assetId = $_.assetId
                    effectiveSeed = $_.effectiveSeed
                    effectiveParameters = $_.effectiveParameters
                    invocationParameters = $_.invocationParameters
                    status = $_.status
                }
            })
        }
        Save-AFJson -Value $resolvedForFile -Path (Join-Path $runRoot "manifest.resolved.json")
        $results = New-AFBatchResultRecords -Plan $plan -LogsDirectory $logsDirectory
        $batchRun = [pscustomobject][ordered]@{
            schemaVersion = 1
            batchId = $plan.batchId
            runId = $runId
            entryPoint = $plan.entryPoint
            status = "running"
            createdAt = (Get-Date).ToString("o")
            completedAt = $null
            resumedAt = $null
            manifestHash = $plan.manifestHash
            manifestPath = $plan.manifestPath
            itemCount = @($plan.items).Count
            executionCount = $executionCount
            completed = 0
            failed = 0
            skipped = 0
            error = $null
        }
    }

    if (-not (Test-Path -LiteralPath $logsDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $logsDirectory -Force | Out-Null
    }
    $batchRunPath = Join-Path $runRoot "batch-run.json"
    Save-AFJson -Value $batchRun -Path $batchRunPath
    Save-AFBatchResults -RunRoot $runRoot -Results $results
    Save-AFBatchItems -RunRoot $runRoot -Plan $plan -Results $results

    Write-AFInfo "Batch: $($plan.batchId) / $runId / entryPoint: $($plan.entryPoint)"
    Write-AFInfo "Executions: $executionCount"

    $hadFailure = $false
    $fatalMessage = $null
    for ($index = 0; $index -lt $executionCount; $index++) {
        $execution = $plan.executions[$index]
        $record = $results[$index]
        if ($record.status -eq "completed") {
            if ($Resume) { Write-AFInfo "Skip completed execution: $($record.executionId)" }
            continue
        }

        $record.status = "running"
        $record.startedAt = (Get-Date).ToString("o")
        $record.completedAt = $null
        $record.error = $null
        $record.attemptCount = [int]$record.attemptCount + 1
        Save-AFBatchResults -RunRoot $runRoot -Results $results
        Save-AFBatchItems -RunRoot $runRoot -Plan $plan -Results $results

        Write-AFInfo "Execution $($record.executionId) ($($index + 1)/$executionCount)"
        try {
            $parameters = ConvertTo-AFBatchInvocationParameters -Execution $execution -Contract $plan.contract
            $result = Invoke-AFBatchPublicEntryPoint -ScriptPath $plan.contract.ScriptPath -LogPath $record.logPath -Parameters $parameters
            if ($result.ExitCode -ne 0) {
                throw "Public entry point failed with exit code $($result.ExitCode). See $($record.logPath)"
            }
            $resultJson = Get-AFOutputValue -Lines $result.Output -Prefix "[RESULT_JSON] " -Optional
            if ([string]::IsNullOrWhiteSpace($resultJson)) {
                throw "Public entry point returned no [RESULT_JSON] payload. See $($record.logPath)"
            }
            try { $summary = $resultJson | ConvertFrom-Json } catch { throw "Invalid [RESULT_JSON] payload: $($_.Exception.Message)" }
            $record.result = $summary
            if ($summary.PSObject.Properties.Name -contains "generationRoot") { $record.generationRoot = $summary.generationRoot }
            $record.status = "completed"
            $record.completedAt = (Get-Date).ToString("o")
            $record.error = $null
        } catch {
            $hadFailure = $true
            $record.status = "failed"
            $record.completedAt = (Get-Date).ToString("o")
            $record.error = $_.Exception.Message
            Write-AFFail "Execution '$($record.executionId)' failed: $($record.error)"
            if (-not $plan.execution.continueOnError) {
                $fatalMessage = $record.error
            }
        }

        Save-AFBatchResults -RunRoot $runRoot -Results $results
        Save-AFBatchItems -RunRoot $runRoot -Plan $plan -Results $results
        if ($null -ne $fatalMessage) { break }
    }

    $batchRun.completed = @($results | Where-Object { $_.status -eq "completed" }).Count
    $batchRun.failed = @($results | Where-Object { $_.status -eq "failed" }).Count
    $batchRun.skipped = @($results | Where-Object { $_.resumeAction -eq "skipped" }).Count
    $batchRun.completedAt = (Get-Date).ToString("o")

    if ($fatalMessage) {
        $batchRun.status = "failed"
        $batchRun.error = $fatalMessage
    } elseif ($batchRun.failed -gt 0 -or $hadFailure) {
        $batchRun.status = "completed-with-errors"
        $batchRun.error = "One or more executions failed."
    } else {
        $batchRun.status = "completed"
        $batchRun.error = $null
    }
    Save-AFJson -Value $batchRun -Path $batchRunPath
    Save-AFBatchResults -RunRoot $runRoot -Results $results
    Save-AFBatchItems -RunRoot $runRoot -Plan $plan -Results $results

    if ($batchRun.status -eq "completed") {
        Write-AFOk "Batch completed: $($plan.batchId) / $runId"
    } else {
        Write-AFFail "Batch finished with status: $($batchRun.status)"
    }
    Write-AFInfo "Batch report: $runRoot"

    return [pscustomobject]@{
        ExitCode = $(if ($batchRun.status -eq "completed") { 0 } else { 1 })
        Plan = $plan
        RunRoot = $runRoot
        Status = $batchRun.status
    }
}

Export-ModuleMember -Function Get-AFBatchResolvedPlan, Invoke-AFBatchManifest
