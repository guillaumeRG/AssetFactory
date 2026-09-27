"""Static and JSON-contract checks for Batch Manifest Runner V1."""
from __future__ import annotations

import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BatchStaticTests(unittest.TestCase):
    def text(self, path: str) -> str:
        return (ROOT / path).read_text(encoding="utf-8-sig")

    def json(self, path: str):
        return json.loads(self.text(path))

    def test_runner_is_thin_and_cli_is_manifest_only(self):
        code = self.text("tools/run-batch.ps1")
        self.assertIn('[string]$ManifestPath', code)
        self.assertIn('[switch]$Resume', code)
        self.assertIn('[switch]$ValidateOnly', code)
        for legacy in ('$BatchPath', '$Mode', '$Engine', '$Candidates', '$Multiview', '$TargetHeight'):
            self.assertNotIn(legacy, code)
        self.assertIn('AssetFactory.Batch.psm1', code)
        self.assertIn('Invoke-AFBatchManifest', code)

    def test_batch_module_only_names_public_entrypoints(self):
        code = self.text("tools/internal/AssetFactory.Batch.psm1")
        for public in ('generate-image.ps1', 'generate-asset-from-image.ps1', 'generate-asset-from-prompt.ps1'):
            self.assertIn(public, code)
        for lower in ('run-comfyui.ps1', 'run-image-to-3d.ps1', 'run-trellis.ps1', 'run-triposr.ps1'):
            self.assertNotIn(lower, code)
        self.assertNotIn('Invoke-Expression', code)

    def test_strict_identity_and_unknown_property_checks_exist(self):
        code = self.text("tools/internal/AssetFactory.Batch.psm1")
        self.assertIn('asset-factory-batch', code)
        self.assertIn('schemaVersion', code)
        self.assertIn('Unknown property', code)
        self.assertIn('Unknown parameter', code)
        self.assertIn('maxParallelism=1 only', code)

    def test_contract_is_derived_from_real_script_parameters(self):
        code = self.text("tools/internal/AssetFactory.Batch.psm1")
        self.assertIn('Parser]::ParseFile', code)
        self.assertIn('Get-Command -Name $scriptPath -CommandType ExternalScript', code)
        self.assertIn('ParameterType = $metadata.ParameterType', code)
        self.assertIn('Attributes = @($metadata.Attributes)', code)

    def test_outputs_and_seed_expansion_are_present(self):
        code = self.text("tools/internal/AssetFactory.Batch.psm1")
        for token in ('"count"', '"seedStart"', '"seedStep"', '"seeds"'):
            self.assertIn(token, code)
        self.assertIn('$itemId + "__" + $variantIndex.ToString("D$width")', code)
        self.assertIn('$effectiveParameters["seed"] = $effectiveSeed', code)
        self.assertIn('Expanded AssetId collision', code)

    def test_reporting_and_resume_contract_is_present(self):
        code = self.text("tools/internal/AssetFactory.Batch.psm1")
        for name in ('manifest.original.json', 'manifest.resolved.json', 'batch-run.json', 'items.json', 'results.json'):
            self.assertIn(name, code)
        self.assertIn('manifestHash', code)
        self.assertIn('resumeAction = "skipped"', code)
        self.assertIn('resumeAction = "rerun"', code)
        self.assertIn('completed-with-errors', code)


    def test_batch_invokes_public_powershell_scripts_with_structured_splatting(self):
        code = self.text("tools/internal/AssetFactory.Batch.psm1")
        self.assertIn('function Invoke-AFBatchPublicEntryPoint', code)
        self.assertIn('& $ScriptPath @Parameters', code)
        self.assertIn('Invoke-AFBatchPublicEntryPoint -ScriptPath $plan.contract.ScriptPath', code)
        self.assertNotIn('Invoke-Expression', code)

    def test_result_json_is_used(self):
        code = self.text("tools/internal/AssetFactory.Batch.psm1")
        self.assertIn('[RESULT_JSON]', code)
        self.assertNotIn('StartsWith("[OK]', code)

    def test_validate_only_returns_before_run_directory_creation(self):
        code = self.text("tools/internal/AssetFactory.Batch.psm1")
        validate = code.index('if ($ValidateOnly)')
        run_id = code.index('$runId = $null', validate)
        self.assertLess(validate, run_id)
        self.assertIn('Expanded executions:', code[validate:run_id])

    def test_examples_are_v1_and_homogeneous(self):
        examples = {
            'batches/examples/images.json': 'generate-image',
            'batches/examples/assets-from-images.json': 'generate-asset-from-image',
            'batches/examples/assets-from-prompts.json': 'generate-asset-from-prompt',
        }
        for path, entrypoint in examples.items():
            data = self.json(path)
            self.assertEqual(data['kind'], 'asset-factory-batch')
            self.assertEqual(data['schemaVersion'], 1)
            self.assertEqual(data['entryPoint'], entrypoint)
            self.assertTrue(data['items'])
            self.assertEqual(data.get('execution', {}).get('maxParallelism', 1), 1)

    def test_image_example_distinguishes_candidates_and_outputs(self):
        data = self.json('batches/examples/images.json')
        self.assertEqual(data['defaults']['candidates'], 2)
        self.assertEqual(data['items'][0]['outputs']['count'], 3)

    def test_image_input_example_path_exists_relative_to_manifest(self):
        path = ROOT / 'batches/examples/assets-from-images.json'
        data = json.loads(path.read_text(encoding='utf-8'))
        source = (path.parent / data['items'][0]['inputPath']).resolve()
        self.assertTrue(source.is_file(), source)

    def test_schema_documents_v1_identity(self):
        schema = self.json('schemas/asset-factory-batch-v1.schema.json')
        self.assertEqual(schema['properties']['kind']['const'], 'asset-factory-batch')
        self.assertEqual(schema['properties']['schemaVersion']['const'], 1)
        self.assertEqual(schema['properties']['execution']['properties']['maxParallelism']['const'], 1)

    def test_smoke_manifests_were_migrated(self):
        image = self.json('batches/smoke-batch.json')
        asset = self.json('batches/smoke-batch-3d.json')
        self.assertEqual(image['entryPoint'], 'generate-image')
        self.assertEqual(asset['entryPoint'], 'generate-asset-from-prompt')
        self.assertNotIn('assets', image)
        self.assertNotIn('mode', asset)

    def test_readme_documents_batch_v1(self):
        readme = self.text('README.md')
        for token in ('Batch manifests', '-ManifestPath', '-ValidateOnly', '-Resume', 'outputs.count', 'candidates'):
            self.assertIn(token, readme)

    def test_batch002_validation_manifests_cover_three_real_families(self):
        manifests = {
            'batches/tests/batch002-images.json': ('generate-image', 6100, 6200),
            'batches/tests/batch002-assets-from-images.json': ('generate-asset-from-image', 7100, 7200),
            'batches/tests/batch002-assets-from-prompts.json': ('generate-asset-from-prompt', 8100, 8200),
        }
        for path, (entrypoint, first_seed, second_seed) in manifests.items():
            data = self.json(path)
            self.assertEqual(data['kind'], 'asset-factory-batch')
            self.assertEqual(data['schemaVersion'], 1)
            self.assertEqual(data['entryPoint'], entrypoint)
            self.assertEqual(len(data['items']), 2)
            self.assertTrue(all(item['outputs']['count'] >= 2 for item in data['items']))
            self.assertEqual(data['items'][0]['outputs']['seedStart'], first_seed)
            self.assertEqual(data['items'][1]['outputs']['seedStart'], second_seed)

        image_manifest = self.json('batches/tests/batch002-assets-from-images.json')
        manifest_dir = ROOT / 'batches/tests'
        for item in image_manifest['items']:
            self.assertTrue((manifest_dir / item['inputPath']).resolve().is_file())

    def test_batch_state_json_is_written_atomically(self):
        code = self.text('tools/internal/AssetFactory.Batch.psm1')
        start = code.index('function Save-AFBatchJson')
        end = code.index('function Save-AFBatchResults', start)
        save_code = code[start:end]
        self.assertIn('[System.IO.File]::WriteAllText', save_code)
        self.assertIn('[System.IO.File]::Replace', save_code)
        self.assertIn('$backupPath', save_code)
        self.assertNotIn('[System.IO.File]::Replace($temporaryPath, $Path, $null)', save_code)
        self.assertIn('[System.IO.File]::Move', save_code)
        self.assertNotIn('Set-Content -LiteralPath $Path', save_code)


if __name__ == '__main__':
    unittest.main()


def test_batch_property_preserves_singleton_json_arrays_on_windows_powershell():
    module = (ROOT / "tools" / "internal" / "AssetFactory.Batch.psm1").read_text(encoding="utf-8-sig")
    assert "Write-Output -NoEnumerate $property.Value" in module
