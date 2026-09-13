"""Contrats TRELLIS multi-image et orchestration multi-vues-vers-3D sans GPU."""
from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import run_trellis as runner


class TrellisMultiImageRunnerTests(unittest.TestCase):
    def test_python_runner_calls_official_multi_image_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            inputs = []
            for index in range(3):
                path = root / f"view_{index + 1}.png"
                path.write_bytes(b"fixture")
                inputs.append(path)
            output_dir = root / "out"
            args = SimpleNamespace(
                input=[str(path) for path in inputs],
                asset_id="Lamp",
                output_dir=str(output_dir),
                models_dir=root / "models",
                seed=42,
                simplify=0.95,
                texture_size=1024,
                save_ply=False,
                multi_image_mode="multidiffusion",
            )

            torch = ModuleType("torch")
            torch.cuda = SimpleNamespace(is_available=lambda: True, get_device_name=lambda _: "MOCK GPU")
            shim = ModuleType("xformers")
            shim.ASSET_FACTORY_SDPA_SHIM = True
            pil = ModuleType("PIL")
            pil.Image = MagicMock()
            pil.Image.open.return_value.__enter__.return_value.copy.side_effect = ["A", "B", "C"]
            utils = ModuleType("trellis.utils")
            utils.postprocessing_utils = MagicMock()
            pipeline = MagicMock()
            gaussian = MagicMock()
            mesh = MagicMock()
            pipeline.run_multi_image.return_value = {"gaussian": [gaussian], "mesh": [mesh]}
            utils.postprocessing_utils.to_glb.return_value.export.side_effect = lambda path: Path(path).write_bytes(b"GLB")

            with patch.dict(sys.modules, {"torch": torch, "xformers": shim, "PIL": pil, "trellis.utils": utils}), \
                 patch.object(runner, "_prepare_imports", return_value=(root, root / "engine")), \
                 patch.object(runner, "_prepare_native_runtime", return_value={"ninja": "ninja"}), \
                 patch.object(runner, "load_local_pipeline", return_value=pipeline), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(runner._run(args), 0)

            pipeline.run.assert_not_called()
            pipeline.run_multi_image.assert_called_once_with(
                ["A", "B", "C"], seed=42, formats=["mesh", "gaussian"], mode="multidiffusion"
            )
            self.assertTrue((output_dir / "Lamp.glb").is_file())

    def test_single_image_path_stays_single_image(self):
        text = (TOOLS / "run_trellis.py").read_text(encoding="utf-8-sig")
        self.assertIn("if len(images) == 1:", text)
        self.assertIn("pipeline.run(", text)
        self.assertIn("pipeline.run_multi_image(", text)


class MultiViewTo3DStaticTests(unittest.TestCase):
    def text(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8-sig")

    def test_geometry_registry_is_configurable(self):
        registry = json.loads((ROOT / "config/geometry-methods.json").read_text(encoding="utf-8"))
        self.assertEqual(registry["defaultMethod"], "trellis-multi-image")
        method = registry["methods"]["trellis-multi-image"]
        self.assertEqual(method["provider"], "trellis")
        self.assertEqual(method["type"], "multiview-to-3d")
        self.assertEqual(method["parameters"]["fusionMode"], "stochastic")
        self.assertTrue(method["parameters"]["includeReference"])
        self.assertEqual(method["parameters"]["viewPolicy"], "quality")
        self.assertEqual(method["parameters"]["maxViews"], 4)

    def test_orchestrator_exposes_method_fusion_and_view_selection(self):
        runner = self.text("tools/run-multiview-to-3d.ps1")
        for token in (
            '[string]$Method = ""',
            '[string]$MethodProfile = ""',
            '[string]$FusionMode = ""',
            '[System.Nullable[bool]]$IncludeReference = $null',
            '[int[]]$ViewIndices = @()',
            '[string]$ViewPolicy = ""',
            '[System.Nullable[int]]$MaxViews = $null',
            '[System.Nullable[double]]$MinViewScore = $null',
        ):
            self.assertIn(token, runner)
        self.assertIn('InputPaths = @($inputPaths)', runner)
        self.assertIn('MultiImageMode = $resolvedFusionMode', runner)
        self.assertIn('AutoImport = $false', runner)

    def test_empty_view_selection_stays_an_array_under_strict_mode(self):
        runner = self.text("tools/run-multiview-to-3d.ps1")
        self.assertNotIn("$resolvedViewIndices = if", runner)
        self.assertIn("$resolvedViewIndices = @($ViewIndices)", runner)
        self.assertIn("$resolvedViewIndices = @($profileViewIndices)", runner)
        self.assertIn("if ($resolvedViewIndices.Count -gt 0)", runner)

    def test_multi_image_modes_are_supported_end_to_end(self):
        ps = self.text("tools/run-trellis.ps1")
        py = self.text("tools/run_trellis.py")
        self.assertIn('[ValidateSet("stochastic", "multidiffusion")]', ps)
        self.assertIn('"--multi-image-mode", $MultiImageMode', ps)
        self.assertIn('choices=("stochastic", "multidiffusion")', py)
        self.assertIn('mode=args.multi_image_mode', py)


    def test_quality_view_policy_is_available(self):
        runner = self.text("tools/run-multiview-to-3d.ps1")
        self.assertIn('ViewPolicy doit être', runner)
        self.assertIn('Select-SpacedViews', runner)
        self.assertIn('quality-fallback-balanced', runner)
        self.assertIn('selectionReason = $selectionReason', runner)

    def test_profile_can_override_geometry_defaults(self):
        profile = json.loads((ROOT / "profiles/geometry.example.json").read_text(encoding="utf-8"))
        self.assertEqual(profile["method"], "trellis-multi-image")
        params = profile["parameters"]
        self.assertIn("viewIndices", params)
        self.assertIn("includeReference", params)
        self.assertIn("fusionMode", params)
        self.assertEqual(params["viewPolicy"], "quality")
        self.assertEqual(params["maxViews"], 4)


if __name__ == "__main__":
    unittest.main()
