[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath,

    [switch]$Resume,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "internal\AssetFactory.Batch.psm1") -Force

try {
    $result = Invoke-AFBatchManifest -ManifestPath $ManifestPath -Resume:$Resume -ValidateOnly:$ValidateOnly
    exit [int]$result.ExitCode
}
catch {
    Write-Host ("[FAIL] " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
