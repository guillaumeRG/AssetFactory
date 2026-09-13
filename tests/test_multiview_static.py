"""Contrats du sous-système multi-vues sans exécuter de moteur GPU."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"

import sys
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from multiview.providers import zero123plus
from multiview import quality as multiview_quality
import multiview_models


class MultiViewStaticTests(unittest.TestCase):
    def text(self, path: str) -> str:
        return (ROOT / path).read_text(encoding="utf-8-sig")

    def json(self, path: str):
        return json.loads(self.text(path))

    def test_naive_prompt_per_view_strategy_is_absent(self):
        runner = self.text("tools/run-multiview.ps1")
        self.assertIn("Invoke-AFImageStage", runner)
        self.assertNotIn("Invoke-AFCommand -Executable $ComfyRunner", runner)
        self.assertNotIn("ViewPrompts", runner)
        self.assertNotIn("front view", runner.lower())
        self.assertNotIn("back view", runner.lower())
        self.assertIn("ReferenceImage", runner)
        self.assertIn("Génération de vues cohérentes depuis une seule image de référence", runner)

    def test_multiview_method_is_configurable(self):
        runner = self.text("tools/run-multiview.ps1")
        self.assertIn('[string]$Method = ""', runner)
        self.assertIn('[string]$MethodProfile = ""', runner)
        self.assertIn('$PSBoundParameters.ContainsKey("ConditioningPrompt")', runner)
        registry = self.json("config/multiview-methods.json")
        self.assertEqual(registry["defaultMethod"], "zero123plus-v1.1")
        self.assertIn("zero123plus-v1.1", registry["methods"])
        profile = self.json("profiles/multiview.example.json")
        self.assertEqual(profile["method"], "zero123plus-v1.1")

    def test_reference_candidates_limit_matches_top_level_runner(self):
        child = self.text("tools/run-multiview.ps1")
        top = self.text("tools/run-image-to-3d.ps1")
        self.assertIn("[ValidateRange(1, 64)]", child)
        self.assertIn("ReferenceCandidates doit être compris entre 1 et 64.", child)
        self.assertIn("[ValidateRange(1, 64)]", top)

    def test_reference_quality_features_are_configurable(self):
        runner = self.text("tools/run-multiview.ps1")
        self.assertIn('[int]$ReferenceCandidates = 1', runner)
        self.assertIn('[string]$ReferencePreset = ""', runner)
        self.assertIn('[string[]]$ReferenceExclude = @()', runner)
        self.assertIn('Invoke-AFImageStage', runner)
        shared = self.text('tools/internal/AssetFactory.Pipeline.psm1')
        self.assertIn('reference-quality.json', shared)
        self.assertIn('score-references', shared)
        self.assertIn('multiview-quality.log', runner)
        self.assertIn('promptUsed', runner)
        self.assertIn('negativePromptUsed', runner)
        presets = self.json("config/reference-presets.json")
        self.assertEqual(presets["defaultPreset"], "asset-reference")
        self.assertIn('asset-reference', presets["presets"])
        self.assertIn('multiview-object', presets["presets"])
        self.assertIn('multiview-rigid', presets["presets"])
        profile = self.json("profiles/multiview.example.json")
        self.assertEqual(profile["reference"]["preset"], "multiview-object")
        self.assertEqual(profile["reference"]["candidates"], 4)

    def test_cli_precedence_is_before_profile_and_defaults(self):
        runner = self.text("tools/run-multiview.ps1")
        steps_line = next(line for line in runner.splitlines() if line.strip().startswith("$resolvedSteps ="))
        self.assertLess(steps_line.index("$null -ne $Steps"), steps_line.index("$profileParameters"))
        self.assertLess(steps_line.index("$profileParameters"), steps_line.index("$defaults"))

    def test_empty_conditioning_prompt_is_passed_as_one_cli_token(self):
        runner = self.text("tools/run-multiview.ps1")
        self.assertIn('("--conditioning-prompt=" + $resolvedConditioningPrompt)', runner)
        self.assertNotIn('"--conditioning-prompt", $resolvedConditioningPrompt', runner)

    def test_registry_records_official_v11_fixed_camera_poses(self):
        method = self.json("config/multiview-methods.json")["methods"]["zero123plus-v1.1"]
        self.assertTrue(method["camera"]["relativeToReference"])
        poses = [(v["azimuth"], v["elevation"]) for v in method["camera"]["views"]]
        self.assertEqual(poses, [(30, 30), (90, -20), (150, 30), (210, -20), (270, 30), (330, -20)])

    def test_runtime_is_local_and_does_not_require_xformers(self):
        runner = self.text("tools/run_multiview.py")
        provider = self.text("tools/multiview/providers/zero123plus.py")
        setup = self.text("setup-asset-factory.ps1")
        multiview_section = setup.split('$Zero123PlusPackages = @(', 1)[1].split(')', 1)[0]
        self.assertIn('os.environ["HF_HUB_OFFLINE"] = "1"', runner)
        self.assertIn('local_files_only=True', provider)
        self.assertNotIn("xformers", multiview_section.lower())
        self.assertIn('"diffusers==0.20.2"', setup)
        self.assertIn('"transformers==4.29.2"', setup)

    def test_setup_exposes_multiview_commands(self):
        setup = self.text("setup-asset-factory.ps1")
        self.assertIn('"multiview" { Invoke-MultiViewCommand }', setup)
        self.assertIn('multiview model-install -Method zero123plus-v1.1', setup)
        self.assertIn('$Zero123PlusPinnedCommit = "7d0315c31be6eb906b34cf07d91310f8e12e9b95"', setup)

    def test_comfy_runner_supports_one_named_reference_output(self):
        code = self.text("tools/run-comfyui.ps1")
        self.assertIn('[string]$OutputFileStem = ""', code)
        self.assertIn('[string]$SourceSubfolder = ""', code)
        self.assertIn('[string]$MetadataPrefix = "comfyui"', code)
        self.assertIn('$OutputFileStem + $extension.ToLowerInvariant()', code)

    def test_comfy_runner_accepts_safe_nested_source_subfolders(self):
        code = self.text("tools/run-comfyui.ps1")
        self.assertIn('function Assert-SafeRelativeSubfolder', code)
        self.assertIn("[System.IO.Path]::IsPathRooted($Path)", code)
        self.assertIn('$segment -in @(".", "..")', code)
        self.assertIn('Assert-SafeRelativeSubfolder -Path $SourceSubfolder', code)
        self.assertNotIn('Assert-AFFileStem -Name $SourceSubfolder -Label "SourceSubfolder"', code)


class Zero123PlusProviderTests(unittest.TestCase):
    def test_split_grid_creates_six_pose_named_tiles(self):
        colors = [
            (255, 0, 0), (0, 255, 0),
            (0, 0, 255), (255, 255, 0),
            (255, 0, 255), (0, 255, 255),
        ]
        image = Image.new("RGB", (640, 960))
        for index, color in enumerate(colors):
            row, col = divmod(index, 2)
            tile = Image.new("RGB", (320, 320), color)
            image.paste(tile, (col * 320, row * 320))
        cameras = [
            {"azimuth": 30, "elevation": 30},
            {"azimuth": 90, "elevation": -20},
            {"azimuth": 150, "elevation": 30},
            {"azimuth": 210, "elevation": -20},
            {"azimuth": 270, "elevation": 30},
            {"azimuth": 330, "elevation": -20},
        ]
        with tempfile.TemporaryDirectory() as directory:
            outputs = zero123plus.split_grid(image, Path(directory), "Lamp", cameras)
            self.assertEqual(len(outputs), 6)
            self.assertIn("az030_elp030", Path(outputs[0]["path"]).name)
            self.assertIn("az090_elm020", Path(outputs[1]["path"]).name)
            for index, output in enumerate(outputs):
                with Image.open(output["path"]) as tile:
                    self.assertEqual(tile.size, (320, 320))
                    self.assertEqual(tile.getpixel((10, 10)), colors[index])

    def test_non_square_reference_is_padded_not_cropped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "wide.png"
            prepared = root / "prepared.png"
            Image.new("RGB", (640, 320), (10, 20, 30)).save(source)
            image, written, changed = zero123plus.prepare_reference(source, prepared)
            self.assertTrue(changed)
            self.assertEqual(written, prepared)
            self.assertEqual(image.size, (640, 640))
            # Le centre de l'image originale est conservé et non rogné.
            self.assertEqual(image.getpixel((320, 320)), (10, 20, 30))
            self.assertEqual(image.getpixel((320, 10)), (127, 127, 127))


class MultiViewModelManifestTests(unittest.TestCase):
    def test_local_manifest_validation_has_no_network_dependency(self):
        method = "zero123plus-v1.1"
        info = multiview_models.METHODS[method]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "model_index.json").write_text("{}", encoding="utf-8")
            payload = (root / "model_index.json").read_bytes()
            manifest = {
                "schemaVersion": 1,
                "method": method,
                "repoId": info["repo_id"],
                "revision": info["revision"],
                "license": info["license"],
                "files": {
                    "model_index.json": {
                        "size": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                    }
                },
            }
            (root / multiview_models.MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")
            validated = multiview_models.validate(method, root)
            self.assertEqual(validated["revision"], info["revision"])


class MultiViewQualityTests(unittest.TestCase):
    def test_reference_ranking_prefers_centered_subject(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            good = root / "good.png"
            bad = root / "bad.png"
            canvas_good = Image.new("RGB", (256, 256), (127, 127, 127))
            for y in range(64, 192):
                for x in range(64, 192):
                    canvas_good.putpixel((x, y), (220, 30, 30))
            canvas_good.save(good)

            canvas_bad = Image.new("RGB", (256, 256), (127, 127, 127))
            for y in range(5, 95):
                for x in range(5, 95):
                    canvas_bad.putpixel((x, y), (220, 30, 30))
            canvas_bad.save(bad)

            ranked = multiview_quality.rank_reference_candidates([bad, good])
            self.assertEqual(Path(ranked["selectedReferencePath"]).name, "good.png")
            self.assertGreater(ranked["candidates"][0]["score"], ranked["candidates"][1]["score"])

    def test_multiview_quality_detects_near_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = []
            for index in range(6):
                image = Image.new("RGB", (256, 256), (127, 127, 127))
                shift = 0 if index < 2 else index * 10
                for y in range(70, 186):
                    for x in range(70 + shift, 186 + shift):
                        if 0 <= x < 256:
                            image.putpixel((x, y), (20 + index * 20, 40, 220))
                path = root / f"view_{index}.png"
                image.save(path)
                paths.append(path)

            report = multiview_quality.analyze_multiview(paths)
            self.assertIn("vues_trop_similaires", report["warnings"])
            self.assertLess(report["score"], 100.0)


class RunImageTo3DMultiviewIntegrationTests(unittest.TestCase):
    def text(self, path: str) -> str:
        return (ROOT / path).read_text(encoding="utf-8-sig")

    def test_main_pipeline_exposes_multiview_mode(self):
        runner = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('[ValidateSet("single", "multiview")]', runner)
        self.assertIn('[string]$Mode = "single"', runner)
        self.assertIn('$MultiViewRunner = Join-Path $PSScriptRoot "run-multiview.ps1"', runner)
        self.assertIn('$MultiViewGeometryRunner = Join-Path $PSScriptRoot "run-multiview-to-3d.ps1"', runner)
        self.assertIn('if ($Mode -eq "multiview")', runner)
        self.assertIn('Invoke-AFMultiViewCycle', runner)

    def test_main_pipeline_forwards_quality_and_reference_parameters(self):
        runner = self.text("tools/run-image-to-3d.ps1")
        for token in (
            '[int]$ReferenceCandidates = 1',
            '[string]$ReferencePreset = ""',
            '[string[]]$ReferenceExclude = @()',
            '[string]$FusionMode = ""',
            '[System.Nullable[bool]]$IncludeReference = $null',
            '[int[]]$ViewIndices = @()',
            '[string]$ViewPolicy = ""',
            '[System.Nullable[int]]$MaxViews = $null',
            '[System.Nullable[double]]$MinViewScore = $null',
        ):
            self.assertIn(token, runner)
        self.assertIn('$multiviewParameters.ReferenceExclude = @($ReferenceExclude)', runner)
        self.assertIn('$geometryParameters.ViewIndices = @($ViewIndices)', runner)
        self.assertIn('$geometryParameters.ProjectProfile = $ProjectProfile', runner)
        self.assertIn('$geometryParameters.AutoImport = $AutoImport', runner)

    def test_main_pipeline_reuses_specialized_runners_instead_of_duplicating_them(self):
        runner = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('Invoke-AFCommand -Executable $MultiViewRunner', runner)
        self.assertIn('Invoke-AFCommand -Executable $MultiViewGeometryRunner', runner)
        self.assertNotIn('pipeline.run_multi_image(', runner)

    def test_child_runners_expose_machine_readable_results(self):
        multiview = self.text("tools/run-multiview.ps1")
        geometry = self.text("tools/run-multiview-to-3d.ps1")
        self.assertIn('kind = "asset-factory-multiview-generation"', multiview)
        self.assertIn('generationRoot = $Layout.Root', multiview)
        self.assertIn('kind = "asset-factory-multiview-3d"', geometry)
        self.assertIn('unrealStatus = $GeometryMetadata.unreal.status', geometry)

    def test_single_mode_remains_backward_compatible(self):
        runner = self.text("tools/run-image-to-3d.ps1")
        self.assertIn('[string]$Engine = "triposr"', runner)
        self.assertIn('[string]$Mode = "single"', runner)
        self.assertIn('$GeometryRunner = Join-Path $PSScriptRoot "run-$Engine.ps1"', runner)


if __name__ == "__main__":
    unittest.main()
