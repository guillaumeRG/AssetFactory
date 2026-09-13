"""Contrats statiques uniquement : ils n'exécutent ni PowerShell, ni ComfyUI, ni Blender, ni Unreal."""
import json
from pathlib import Path
import re
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

    def test_glb_name_and_format_survive_processing(self):
        code = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('Join-Path $PipelineInputDir ($AssetId + $imageExtension)', code)
        self.assertIn('Join-Path $PipelineProcessedDir ($AssetId + ".glb")', code)
        self.assertIn('"--fbx-output", $ImportSourcePath', code)

    def test_blender_failure_propagates(self):
        code = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('"--python-exit-code", "1"', code)
        self.assertIn('Assert-StageSuccess $blenderResult', code)

    def test_exit_code_captured_in_invocation_scope(self):
        code = self.text("tools/pipeline-common.ps1")
        self.assertIn('$executionState.ExitCode = $LASTEXITCODE', code)
        self.assertIn('$exitCode = $executionState.ExitCode', code)

    def test_import_failure_preserves_model_and_failed_stage(self):
        code = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('$PipelineMetadata.failedStage = $Stage', code)
        self.assertNotIn('Remove-Item', code)
        self.assertIn('Import can be retried without regeneration', code)

    def test_no_python_embedded_in_new_orchestration(self):
        for filename in ['run-image-to-3d.ps1', 'run-batch.ps1', 'pipeline-common.ps1', 'run-trellis.ps1']:
            code = self.text('tools/' + filename)
            self.assertNotRegex(code, r"(?m)^\s*(import torch|from trellis|\$code\s*=\s*@')")

    def test_comfy_release_is_not_an_interrupt_or_queue_clear(self):
        code = self.text("tools/pipeline-common.ps1")
        self.assertIn('"$baseUrl/free"', code)
        self.assertIn('"queue_running"', code)
        self.assertNotIn('/interrupt', code)
        self.assertNotRegex(code, r'(?s)-Uri "\$baseUrl/queue" -Method Post')

    def test_trellis_stderr_is_guarded_for_ps51(self):
        code = self.text('tools/run-trellis.ps1')
        self.assertEqual(code.count('$nativePreference = $ErrorActionPreference'), 3)
        self.assertEqual(code.count('$ErrorActionPreference = $nativePreference'), 3)

    def test_offline_adapter_still_used(self):
        self.assertIn('"--models-dir", $ModelsDir', self.text('tools/run-trellis.ps1'))
        self.assertIn('load_local_pipeline(args.models_dir)', self.text('tools/run_trellis.py'))

    def test_profiles_keep_fbx_policy_and_override_glb_only(self):
        for name in ['nullon.json', 'unreal.example.json']:
            p = json.loads(self.text('profiles/' + name))
            self.assertFalse(p['import']['importMaterials'])
            self.assertFalse(p['import']['importTextures'])
            self.assertTrue(p['importGlb']['importMaterials'])
            self.assertTrue(p['importGlb']['importTextures'])
            self.assertTrue(p['importGlb']['assetSubfolder'])
        profile = json.loads(self.text('profiles/nullon.json'))
        self.assertTrue(profile['autoImport'])
        self.assertEqual(profile['contentRoot'], '/Game/Assets/Generated')

    def test_example_full_manifest(self):
        data = json.loads(self.text('batches/smoke-batch-3d.json'))
        self.assertEqual(data['mode'], 'full')
        self.assertEqual(data['engine'], 'trellis')
        self.assertEqual(data['projectProfile'], 'profiles/nullon.json')
        self.assertEqual(len(data['assets']), 1)

    def test_only_selected_engine_is_required(self):
        code = self.text('tools/run-image-to-3d.ps1')
        self.assertIn('Assert-AFFile -Path $GeometryRunner', code)
        self.assertNotIn('Assert-AFFile -Path $TripoRunner', code)


if __name__ == '__main__':
    unittest.main()
