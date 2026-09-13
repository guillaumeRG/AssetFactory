"""Contrats d'integration du Visual QA dans le pipeline public."""
from pathlib import Path
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VisualQAStaticTests(unittest.TestCase):
    def text(self, path: str) -> str:
        return (ROOT / path).read_text(encoding="utf-8-sig")

    def test_visual_qa_is_internal_not_a_fourth_public_entrypoint(self):
        self.assertTrue((ROOT / "tools/internal/postprocess/qa_core.py").is_file())
        self.assertTrue((ROOT / "tools/internal/postprocess/blender_qa.py").is_file())
        self.assertFalse((ROOT / "tools/generate-visual-qa.ps1").exists())

    def test_public_asset_entrypoints_expose_one_simple_postprocess_switch(self):
        for path in ("tools/generate-asset-from-image.ps1", "tools/generate-asset-from-prompt.ps1"):
            code = self.text(path)
            self.assertIn('[ValidateSet("none", "qa")]', code)
            self.assertIn('[string]$Postprocess = "none"', code)
            self.assertIn('-Postprocess $Postprocess', code)

    def test_shared_module_owns_visual_qa_orchestration(self):
        code = self.text("tools/internal/AssetFactory.Pipeline.psm1")
        self.assertIn("function Invoke-AFVisualQA", code)
        self.assertIn('"prepare-reference"', code)
        self.assertIn('"analyze"', code)
        self.assertIn('"internal\\postprocess\\blender_qa.py"', code)
        self.assertIn("Invoke-AFVisualQA", code)

    def test_direct_pipeline_runs_qa_after_blender_before_unreal(self):
        code = self.text("tools/run-image-to-3d.ps1")
        blender = code.index('Assert-StageSuccess $blenderResult "Blender"')
        qa = code.index("Invoke-AFVisualQA")
        unreal = code.index('$Stage = "unreal"', qa)
        self.assertLess(blender, qa)
        self.assertLess(qa, unreal)
        self.assertIn('Write-AFFail "Visual QA non bloquant', code)

    def test_multiview_pipeline_uses_same_visual_qa_function(self):
        code = self.text("tools/run-multiview-to-3d.ps1")
        self.assertIn("Invoke-AFVisualQA", code)
        blender = code.index('Assert-AFFile -Path $expectedFinal -Label "Modèle final normalisé"')
        qa = code.index("Invoke-AFVisualQA")
        unreal = code.index('$Stage = "unreal"', qa)
        self.assertLess(blender, qa)
        self.assertLess(qa, unreal)

    def test_batch_forwards_postprocess_to_public_asset_entrypoints(self):
        code = self.text("tools/run-batch.ps1")
        self.assertIn('[string]$Postprocess = "none"', code)
        self.assertIn('"postprocess" "Postprocess" "none"', code)
        self.assertIn('Postprocess = $ActiveRecord.postprocess', code)

    def test_configuration_is_versioned_and_keeps_qa_bounded(self):
        config = json.loads(self.text("config/postprocess.json"))
        self.assertEqual(config["schemaVersion"], 1)
        self.assertLessEqual(config["cameraMatch"]["searchResolution"], 256)
        self.assertLessEqual(config["qa"]["renderSize"], 1024)
        self.assertGreater(config["qa"]["minAnomalyAreaFraction"], 0)

    def test_no_postprocess_code_was_added_under_engines(self):
        forbidden = []
        engines = ROOT / "engines"
        if engines.exists():
            for path in engines.rglob("*"):
                if path.is_file() and "postprocess" in path.name.lower():
                    forbidden.append(path)
        self.assertEqual(forbidden, [])


if __name__ == "__main__":
    unittest.main()
