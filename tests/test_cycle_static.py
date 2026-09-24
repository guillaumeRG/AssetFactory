"""Contrats statiques du cycle complet ; aucun moteur externe n'est exécuté."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CycleStaticTests(unittest.TestCase):
    def text(self, path):
        return (ROOT / path).read_text(encoding="utf-8-sig")

    def test_pipeline_engine_default_and_choices(self):
        code = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('[ValidateSet("triposr", "trellis")]', code)
        self.assertIn('[string]$Engine = "triposr"', code)

    def test_batch_is_images_by_default(self):
        code = self.text("tools/run-batch.ps1")
        self.assertIn('[string]$Mode = "images"', code)
        self.assertIn('"mode" "Mode" "images"', code)
        original = json.loads(self.text("batches/smoke-batch.json"))
        self.assertNotIn("mode", original)

    def test_batch_choice_priority(self):
        code = self.text("tools/run-batch.ps1")
        helper = code.split('function Get-BatchSetting {', 1)[1].split('$BatchMetadata =', 1)[0]
        self.assertLess(helper.index('$CommandOverrides.ContainsKey'), helper.index('$Asset.PSObject.Properties.Name'))
        self.assertLess(helper.index('$Asset.PSObject.Properties.Name'), helper.index('Get-AFProperty $Batch'))

    def test_exactly_one_import_owned_by_pipeline(self):
        code = self.text("tools/run-image-to-3d.ps1")
        self.assertEqual(code.count('-Executable $UnrealImportRunner'), 1)
        self.assertIn('AutoImport = $false', code)
        self.assertLess(code.index('Assert-StageSuccess $blenderResult'), code.index('-Executable $UnrealImportRunner'))
        self.assertIn('SourcePath = $ImportSourcePath', code)

    def test_canonical_generation_layout(self):
        common = self.text("tools/pipeline-common.ps1")
        self.assertIn('"outputs\\assets\\" + $AssetId', common)
        for folder in ("source", "raw", "final", "logs", "metadata"):
            self.assertIn(f'Join-Path $rootPath "{folder}"', common)
        self.assertIn('GenerationMetadataPath = Join-Path $rootPath "generation.json"', common)
        self.assertIn("'v{0:D3}'", common)

    def test_new_generation_refuses_existing_version(self):
        common = self.text("tools/pipeline-common.ps1")
        self.assertIn('Asset generation already exists:', common)
        self.assertIn('Get-AFNextAssetVersion', common)

    def test_glb_name_and_format_survive_processing(self):
        code = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('Join-Path $Layout.SourceDir ($AssetId + $imageExtension)', code)
        self.assertIn('Join-Path $Layout.RawDir ($AssetId + ".glb")', code)
        self.assertIn('Join-Path $Layout.FinalDir ($AssetId + ".glb")', code)
        self.assertIn('"--fbx-output", $ImportSourcePath', code)

    def test_blender_failure_propagates(self):
        code = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('"--python-exit-code", "1"', code)
        self.assertIn('Assert-StageSuccess $blenderResult', code)

    def test_exit_code_captured_in_invocation_scope(self):
        code = self.text("tools/pipeline-common.ps1")
        self.assertIn('$executionState.ExitCode = $LASTEXITCODE', code)
        self.assertIn('$exitCode = $executionState.ExitCode', code)

    def test_unreal_runner_and_native_logs_are_distinct(self):
        code = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('logPath = (Join-Path $Layout.LogsDir "unreal.log")', code)
        self.assertIn('runnerLogPath = (Join-Path $Layout.LogsDir "unreal-runner.log")', code)
        self.assertIn('-LogPath $GenerationMetadata.unreal.runnerLogPath', code)
        self.assertIn('LogPath = $GenerationMetadata.unreal.logPath', code)

    def test_import_failure_preserves_model_and_failed_stage(self):
        code = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('$GenerationMetadata.failedStage = $Stage', code)
        self.assertNotIn('Remove-Item -LiteralPath $ImportSourcePath', code)
        self.assertIn('L’import peut être relancé sans régénérer le modèle', code)

    def test_no_python_embedded_in_orchestration(self):
        for filename in ['run-image-to-3d.ps1', 'run-batch.ps1', 'pipeline-common.ps1', 'run-trellis.ps1']:
            code = self.text('tools/' + filename)
            self.assertNotRegex(code, r"(?m)^\s*(import torch|from trellis|\$code\s*=\s*@')")

    def test_comfy_autostart_is_shared(self):
        common = self.text("tools/pipeline-common.ps1")
        comfy = self.text("tools/run-comfyui.ps1")
        pipeline = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('function Start-AFComfyServer {', common)
        self.assertIn('function Wait-AFComfyServer {', common)
        self.assertIn('function Test-AFComfyServer {', common)
        self.assertIn('Start-AFComfyServer `', comfy)
        self.assertIn('-LogPrefix "comfyui-server"', comfy)
        self.assertIn('Start-AFComfyServer `', pipeline)
        self.assertIn('-LogPrefix "multiview-comfyui"', pipeline)

    def test_comfy_release_is_not_an_interrupt_or_queue_clear(self):
        code = self.text("tools/pipeline-common.ps1")
        self.assertIn('"$baseUrl/free"', code)
        self.assertIn('"queue_running"', code)
        self.assertNotIn('/interrupt', code)
        self.assertNotRegex(code, r'(?s)-Uri "\$baseUrl/queue" -Method Post')


    def test_default_comfy_workflow_avoids_persistent_duplicate_output(self):
        workflow = json.loads(self.text('workflows/comfyui-flux-schnell-base.json'))
        self.assertEqual(workflow['7']['class_type'], 'PreviewImage')
        code = self.text('tools/run-comfyui.ps1')
        self.assertIn('@("PreviewImage", "SaveImage")', code)

    def test_trellis_stderr_is_guarded_for_ps51(self):
        code = self.text('tools/run-trellis.ps1')
        self.assertEqual(code.count('$nativePreference = $ErrorActionPreference'), 3)
        self.assertEqual(code.count('$ErrorActionPreference = $nativePreference'), 3)

    def test_offline_adapter_still_used(self):
        self.assertIn('"--models-dir", $ModelsDir', self.text('tools/run-trellis.ps1'))
        self.assertIn('load_local_pipeline(args.models_dir)', self.text('tools/run_trellis.py'))

    def test_generic_unreal_profile_is_versioned_and_safe(self):
        profile = json.loads(self.text('profiles/unreal.example.json'))
        self.assertEqual(profile['contentRoot'], '/Game/AssetFactory')
        self.assertFalse(profile['overwriteExistingVersion'])
        self.assertFalse(profile['import']['importMaterials'])
        self.assertFalse(profile['import']['importTextures'])
        self.assertTrue(profile['importGlb']['importMaterials'])
        self.assertTrue(profile['importGlb']['importTextures'])
        self.assertNotIn('assetSubfolder', profile['importGlb'])

    def test_example_full_manifest_is_generic(self):
        data = json.loads(self.text('batches/smoke-batch-3d.json'))
        self.assertEqual(data['mode'], 'full')
        self.assertEqual(data['engine'], 'trellis')
        self.assertEqual(data['projectProfile'], '')
        self.assertFalse(data['autoImport'])
        self.assertEqual(len(data['assets']), 1)

    def test_batch_output_only_references_generations(self):
        code = self.text('tools/run-batch.ps1')
        self.assertIn('"outputs\\batches\\$BatchId\\$BatchRunId"', code)
        self.assertIn('generationRoot = $null', code)
        self.assertNotIn('assets\\$($ActiveRecord.id)', code)

    def test_setup_uses_canonical_test_and_diagnostic_folders(self):
        code = self.text('setup-asset-factory.ps1')
        for fragment in (
            'outputs\\tests\\triposr\\$stamp',
            'outputs\\tests\\comfyui\\$stamp',
            'outputs\\diagnostics\\trellis\\native-toolchain',
            'outputs\\diagnostics\\trellis\\native-build',
            'outputs\\diagnostics\\spconv\\build',
        ):
            self.assertIn(fragment, code)
        for legacy in ('outputs\\triposr-smoke', 'outputs\\comfyui-smoke',
                       'outputs\\trellis-native-toolchain', 'outputs\\trellis-native-build',
                       'outputs\\spconv-build'):
            self.assertNotIn(legacy, code)

    def test_only_selected_engine_is_required(self):
        code = self.text('tools/run-image-to-3d.ps1')
        self.assertIn('Assert-AFFile -Path $GeometryRunner', code)
        self.assertNotIn('Assert-AFFile -Path $TripoRunner', code)


    def test_pipeline_managed_children_and_negative_prompt_visibility(self):
        pipeline = self.text('tools/run-image-to-3d.ps1')
        comfy = self.text('tools/run-comfyui.ps1')
        trellis = self.text('tools/run-trellis.ps1')
        shared = self.text('tools/internal/AssetFactory.Pipeline.psm1')
        self.assertIn('[string]$NegativePrompt = ""', pipeline)
        self.assertIn('NegativePrompt = $negativePromptUsed', shared)
        self.assertIn('Write-AFInfo "Prompt négatif : $NegativePrompt"', pipeline)
        self.assertGreaterEqual(pipeline.count('PipelineManaged = $true'), 1)
        self.assertIn('PipelineManaged = $true', shared)
        self.assertIn('[switch]$PipelineManaged', comfy)
        self.assertIn('[switch]$PipelineManaged', trellis)
        self.assertNotIn('Automatic Unreal import: $($unrealConfig.autoImport)', trellis)

    def test_trellis_compiler_noise_is_kept_in_log_but_hidden_from_console(self):
        pipeline = self.text('tools/run-image-to-3d.ps1')
        common = self.text('tools/pipeline-common.ps1')
        self.assertIn('SuppressConsolePatterns', common)
        self.assertIn('Remarque : inclusion du fichier', pipeline)
        self.assertIn('Note: including file:', pipeline)

    def test_setup_and_runtime_use_same_venv_ninja(self):
        setup = self.text('setup-asset-factory.ps1')
        runner = self.text('tools/run-trellis.ps1')
        self.assertIn('$runtimeScripts = Split-Path -Parent $TrellisRuntimeVenvPython', setup)
        self.assertIn('Ninja TRELLIS pinned to runtime venv', setup)
        self.assertIn('$TrellisScripts = Split-Path -Parent $TrellisPython', runner)
        self.assertIn('Initialize-TrellisNativeBuildEnvironment -RuntimeScripts $TrellisScripts', runner)



if __name__ == '__main__':
    unittest.main()
