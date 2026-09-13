"""Contrats statiques de l'interface publique simplifiee."""
from __future__ import annotations

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PublicPipelineArchitectureTests(unittest.TestCase):
    def text(self, path: str) -> str:
        return (ROOT / path).read_text(encoding="utf-8-sig")

    def test_three_public_entrypoints_exist(self):
        for path in (
            "tools/generate-image.ps1",
            "tools/generate-asset-from-image.ps1",
            "tools/generate-asset-from-prompt.ps1",
        ):
            self.assertTrue((ROOT / path).is_file(), path)

    def test_image_generation_is_shared_between_direct_and_multiview(self):
        direct = self.text("tools/run-image-to-3d.ps1")
        multiview = self.text("tools/run-multiview.ps1")
        shared = self.text("tools/internal/AssetFactory.Pipeline.psm1")
        self.assertIn("Invoke-AFImageStage", direct)
        self.assertIn("Invoke-AFImageStage", multiview)
        self.assertIn("function Invoke-AFImageStage", shared)
        self.assertIn("score-references", shared)
        self.assertIn("Candidates", shared)

    def test_public_image_entrypoint_stops_after_image_stage(self):
        code = self.text("tools/generate-image.ps1")
        self.assertIn("Invoke-AFImageStage", code)
        self.assertNotIn("run-trellis.ps1", code)
        self.assertNotIn("run-triposr.ps1", code)
        self.assertNotIn("run-multiview.ps1", code)
        self.assertNotIn("Blender", code)

    def test_asset_from_image_has_no_prompt_generation(self):
        code = self.text("tools/generate-asset-from-image.ps1")
        self.assertIn("-InputKind Image", code)
        self.assertNotIn("Invoke-AFImageStage", code)
        self.assertNotIn("[string]$Prompt", code)
        self.assertNotIn("[int]$Candidates", code)

    def test_asset_from_prompt_exposes_image_and_geometry_choices(self):
        code = self.text("tools/generate-asset-from-prompt.ps1")
        self.assertIn("[int]$Candidates = 1", code)
        self.assertIn('[ValidateSet("trellis", "triposr")]', code)
        self.assertIn('[string]$MultiviewMethod = "none"', code)
        self.assertIn("-InputKind Prompt", code)

    def test_multiview_is_optional_and_not_an_image_generation_owner(self):
        runner = self.text("tools/run-multiview.ps1")
        self.assertIn("Invoke-AFImageStage", runner)
        self.assertNotIn("reference-comfyui-{0:D2}", runner)
        self.assertNotIn("score-references", runner)

    def test_batch_uses_public_entrypoints(self):
        code = self.text("tools/run-batch.ps1")
        self.assertIn('"generate-image.ps1"', code)
        self.assertIn('"generate-asset-from-prompt.ps1"', code)
        self.assertIn('"generate-asset-from-image.ps1"', code)
        self.assertNotIn('$PipelineRunner = Join-Path $PSScriptRoot "run-image-to-3d.ps1"', code)

    def test_reference_default_is_generic_not_multiview_specific(self):
        config = self.text("config/reference-presets.json")
        self.assertIn('"defaultPreset": "asset-reference"', config)


if __name__ == "__main__":
    unittest.main()
