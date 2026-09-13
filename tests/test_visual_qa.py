"""Tests unitaires du Visual QA sans Blender ni moteur 3D."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools" / "internal" / "postprocess" / "qa_core.py"
SPEC = importlib.util.spec_from_file_location("asset_factory_qa_core", MODULE_PATH)
qa_core = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(qa_core)


class VisualQACoreTests(unittest.TestCase):
    def setUp(self):
        self.config = qa_core.load_config(ROOT / "config" / "postprocess.json")

    def make_reference(self, path: Path) -> None:
        image = Image.new("RGB", (256, 256), (200, 200, 200))
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle((58, 48, 198, 212), radius=12, fill=(220, 35, 30))
        image.save(path)

    def test_reference_mask_finds_centered_object(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = root / "reference.png"
            self.make_reference(reference)
            result = qa_core.prepare_reference(reference, root / "qa-reference", self.config)

            self.assertGreater(result["confidence"], 0.8)
            self.assertGreater(result["coverage"], 0.20)
            self.assertLess(result["coverage"], 0.50)
            self.assertTrue(Path(result["maskPath"]).is_file())
            self.assertTrue(Path(result["searchMaskPath"]).is_file())
            with Image.open(result["searchMaskPath"]) as mask:
                self.assertEqual(mask.size, (128, 128))

    def test_identical_silhouettes_have_perfect_iou(self):
        mask = Image.new("L", (64, 64), 0)
        ImageDraw.Draw(mask).rectangle((10, 8, 50, 55), fill=255)
        self.assertEqual(qa_core.silhouette_iou(mask, mask), 1.0)

    def test_analysis_reports_geometry_and_color_differences(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = root / "reference.png"
            self.make_reference(reference)
            prepared = qa_core.prepare_reference(reference, root / "reference", self.config)

            silhouette = Image.new("L", (256, 256), 0)
            ImageDraw.Draw(silhouette).rounded_rectangle((72, 48, 212, 212), radius=12, fill=255)
            silhouette_path = root / "silhouette.png"
            silhouette.save(silhouette_path)

            beauty = Image.new("RGB", (256, 256), (0, 0, 0))
            ImageDraw.Draw(beauty).rounded_rectangle((72, 48, 212, 212), radius=12, fill=(20, 60, 220))
            beauty_path = root / "beauty.png"
            beauty.save(beauty_path)
            albedo_path = root / "albedo.png"
            beauty.save(albedo_path)

            camera_path = root / "camera.json"
            camera_path.write_text(json.dumps({"score": 0.85, "meshPath": "fixture.glb"}), encoding="utf-8")
            report_path = root / "qa-report.json"
            result = qa_core.analyze(
                reference,
                prepared["maskPath"],
                beauty_path,
                silhouette_path,
                beauty_path,
                albedo_path,
                camera_path,
                root / "maps",
                report_path,
                self.config,
            )

            self.assertLess(result["metrics"]["silhouetteIoU"], 1.0)
            self.assertGreater(result["metrics"]["color"]["meanDeltaE"], 18.0)
            self.assertTrue(any(item["type"] == "geometry" for item in result["anomalies"]))
            self.assertTrue(any(item["type"] == "color" for item in result["anomalies"]))
            self.assertTrue(report_path.is_file())
            self.assertTrue((root / "maps" / "anomaly-map.png").is_file())

    def test_internal_edge_comparison_detects_shifted_detail(self):
        reference = Image.new("RGB", (128, 128), (120, 120, 120))
        rendered = reference.copy()
        draw_ref = ImageDraw.Draw(reference)
        draw_render = ImageDraw.Draw(rendered)
        draw_ref.rectangle((30, 30, 55, 95), fill=(230, 230, 230))
        draw_render.rectangle((70, 30, 95, 95), fill=(230, 230, 230))
        mask = Image.new("L", (128, 128), 255)

        ref_edges = qa_core.internal_edge_mask(qa_core.image_edge_mask(reference, 20), mask, 2)
        rendered_edges = qa_core.internal_edge_mask(qa_core.image_edge_mask(rendered, 20), mask, 2)
        score, mismatch = qa_core.compare_edge_maps(ref_edges, rendered_edges, 2)

        self.assertLess(score, 0.5)
        self.assertIsNotNone(mismatch.getbbox())

    def test_low_camera_score_is_reported_as_warning_not_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = root / "reference.png"
            self.make_reference(reference)
            prepared = qa_core.prepare_reference(reference, root / "reference", self.config)
            mask = Image.open(prepared["maskPath"]).convert("L")
            silhouette_path = root / "silhouette.png"
            mask.save(silhouette_path)
            beauty_path = root / "beauty.png"
            reference_image = Image.open(reference).convert("RGB")
            reference_image.save(beauty_path)
            albedo_path = root / "albedo.png"
            reference_image.save(albedo_path)
            camera_path = root / "camera.json"
            camera_path.write_text(json.dumps({"score": 0.2, "meshPath": "fixture.glb"}), encoding="utf-8")

            result = qa_core.analyze(
                reference,
                prepared["maskPath"],
                beauty_path,
                silhouette_path,
                beauty_path,
                albedo_path,
                camera_path,
                root / "maps",
                root / "qa-report.json",
                self.config,
            )
            self.assertEqual(result["status"], "limited")
            self.assertIn("camera_match_low_confidence", result["warnings"])


if __name__ == "__main__":
    unittest.main()
