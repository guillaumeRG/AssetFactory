"""Vérifications statiques du passage PowerShell ; aucun moteur réel n'est exécuté."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT/'tools/run-trellis.ps1').read_text(encoding='utf-8-sig')
IMPORTER = (ROOT/'tools/import-unreal.ps1').read_text(encoding='utf-8-sig')


def test_runner_has_profile_override_parameters():
    for token in ('$ProjectProfile', '$AssetId', '$AssetVersion', '$Category', '[System.Nullable[bool]]$AutoImport = $null'):
        assert token in RUNNER
    assert '$effectiveAutoImport = [bool]$profile.autoImport' in RUNNER
    assert '$effectiveAutoImport = [bool]$AutoImport' in RUNNER


def test_handoff_follows_successful_generation_and_glb_validation():
    call = RUNNER.index('& $UnrealImportRunner')
    assert RUNNER.index('& $TrellisPython @arguments') < RUNNER.index('GLB TRELLIS généré :') < call
    assert 'SourcePath = $glb' in RUNNER
    assert 'if ($unrealConfig.autoImport)' in RUNNER


def test_no_python_generated_or_inline_in_runner():
    assert "@'" not in RUNNER and '@"' not in RUNNER
    assert 'Set-Content' not in RUNNER
    assert 'pip install' not in RUNNER


def test_filename_rule_and_offline_mode_are_kept():
    assert 'GetFileNameWithoutExtension($resolvedInput)' in RUNNER
    assert '($assetName + ".glb")' in RUNNER
    assert '"--models-dir", $ModelsDir' in RUNNER
    assert '$env:ATTN_BACKEND = "sdpa"' in RUNNER
    assert '$env:SPARSE_ATTN_BACKEND = "xformers"' in RUNNER


def test_diagnostics_do_not_enter_autoimport_handoff():
    config_call = RUNNER.index('$unrealConfig = Resolve-UnrealImportConfiguration')
    assert RUNNER.index('if ($SelfTest)') < config_call
    assert RUNNER.index('if ($CheckModels)') < config_call
    assert RUNNER[:config_call].count('        return\n') >= 2


def test_legacy_fbx_parameter_and_job_field_remain():
    assert '[Alias("FbxPath", "GlbPath")]' in IMPORTER
    assert '[string]$SourcePath' in IMPORTER
    assert 'fbxPath = $(if (-not $IsGlb)' in IMPORTER
    assert 'sourcePath = $ResolvedSourcePath' in IMPORTER


def test_glb_defaults_and_optional_profile_overrides():
    assert 'importMaterials = $IsGlb' in IMPORTER
    assert 'importTextures = $IsGlb' in IMPORTER
    assert '$settingsBlocks = @("import")' in IMPORTER
    assert '$settingsBlocks += "importGlb"' in IMPORTER
    assert 'assetSubfolder' not in IMPORTER


def test_unreal_versions_are_preserved_by_default():
    assert '$OverwriteExistingVersion = $false' in IMPORTER
    assert 'overwriteExistingVersion = $OverwriteExistingVersion' in IMPORTER
    assert 'requestedAssetVersion' in IMPORTER
    assert 'Existing versions are preserved by default.' in IMPORTER


def test_wrapper_records_failures_and_preserves_result_contract():
    assert '$result.status = "failed"' in IMPORTER
    assert 'Write-Ok "Unreal asset: $objectPath"' in IMPORTER
    assert 'Write-Ok "Unreal version: $($result.assetVersion)"' in IMPORTER
    assert 'Write-Ok "Import metadata: $JobPath"' in IMPORTER
    assert 'Remove-Item -LiteralPath $ResolvedSourcePath' not in IMPORTER
