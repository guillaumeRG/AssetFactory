"""Naming regressions. Inference/export are mocked: no GPU or downloads.

Run from the project root:
    python -B -m unittest discover -s tests -p test_trellis_output_names.py -v
"""
from __future__ import annotations

import contextlib
import io
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
import run_trellis as runner


class OutputNameTests(unittest.TestCase):
    def run_mocked_generation(self, filename, *, save_ply=False, write_glb=True):
        """Exercise the actual _run function with fake model and export APIs."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            input_path = root / filename
            input_path.write_bytes(b'input image fixture')
            before = input_path.read_bytes()
            output_dir = root / 'outputs' / 'unique-job'
            args = SimpleNamespace(
                input=str(input_path), output_dir=str(output_dir),
                models_dir=root / 'models', seed=1, simplify=0.95,
                texture_size=1024, save_ply=save_ply,
            )
            torch = ModuleType('torch')
            torch.cuda = SimpleNamespace(
                is_available=lambda: True, get_device_name=lambda _: 'MOCK GPU'
            )
            shim = ModuleType('xformers')
            shim.ASSET_FACTORY_SDPA_SHIM = True
            pil = ModuleType('PIL')
            pil.Image = MagicMock()
            pil.Image.open.return_value.__enter__.return_value.copy.return_value = 'IMAGE'
            utils = ModuleType('trellis.utils')
            utils.postprocessing_utils = MagicMock()
            gaussian = MagicMock()
            mesh = MagicMock()
            pipeline = MagicMock()
            pipeline.run.return_value = {'gaussian': [gaussian], 'mesh': [mesh]}

            def export(path):
                if write_glb:
                    Path(path).write_bytes(b'FAKE EXPORT: NOT A REAL GLB')

            def export_ply(path):
                Path(path).write_bytes(b'FAKE EXPORT: NOT A REAL PLY')

            utils.postprocessing_utils.to_glb.return_value.export.side_effect = export
            gaussian.save_ply.side_effect = export_ply
            modules = {'torch': torch, 'xformers': shim, 'PIL': pil, 'trellis.utils': utils}
            with patch.dict(sys.modules, modules), \
                 patch.object(runner, '_prepare_imports', return_value=(root, root / 'engine')), \
                 patch.object(runner, 'load_local_pipeline', return_value=pipeline), \
                 contextlib.redirect_stdout(io.StringIO()):
                if not write_glb:
                    with self.assertRaisesRegex(RuntimeError, 'no valid GLB'):
                        runner._run(args)
                    return
                self.assertEqual(runner._run(args), 0)

            expected_glb = output_dir / (input_path.stem + '.glb')
            self.assertTrue(expected_glb.is_file())
            utils.postprocessing_utils.to_glb.return_value.export.assert_called_once_with(str(expected_glb))
            self.assertFalse((output_dir / 'asset.glb').exists())
            self.assertEqual(input_path.read_bytes(), before)
            pipeline.run.assert_called_once_with('IMAGE', seed=1, formats=['mesh', 'gaussian'])
            if save_ply:
                expected_ply = output_dir / (input_path.stem + '.ply')
                gaussian.save_ply.assert_called_once_with(str(expected_ply))
                self.assertTrue(expected_ply.is_file())
                self.assertFalse((output_dir / 'asset.ply').exists())
            else:
                gaussian.save_ply.assert_not_called()

    def test_chair(self):
        self.run_mocked_generation('chair.png')

    def test_asset_id_preserved(self):
        self.run_mocked_generation('FuelTank_T1.png')

    def test_spaces_and_unicode_preserved(self):
        self.run_mocked_generation('R\u00e9servoir jaune.png')

    def test_only_final_extension_is_replaced(self):
        self.run_mocked_generation('chair.v2.preview.png')

    def test_uppercase_extension(self):
        self.run_mocked_generation('CHAIR.PNG')

    def test_optional_ply_uses_same_stem(self):
        self.run_mocked_generation('chair.v2.png', save_ply=True)

    def test_missing_export_is_not_success(self):
        self.run_mocked_generation('chair.png', write_glb=False)

    def test_powershell_expected_filename_matches_python_convention(self):
        text = (TOOLS / 'run-trellis.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('[System.IO.Path]::GetFileNameWithoutExtension($resolvedInput)', text)
        self.assertIn('Join-Path $resolvedOutput ($assetName + ".glb")', text)
        self.assertNotIn('Join-Path $resolvedOutput "asset.glb"', text)


if __name__ == '__main__':
    unittest.main()
