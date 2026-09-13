"""Tests de régression de l'adaptateur hors ligne : fixtures/mocks locaux, sans GPU ni téléchargement.

Exécution : python -B -m unittest discover -s tests -p test_trellis_offline.py -v
Ces tests ne constituent pas une validation d'une véritable inférence TRELLIS sous CUDA.
"""
from __future__ import annotations

import copy
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch
from zipfile import ZipFile

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
import trellis_models as tm
import trellis_offline as offline


def fixture(root: Path):
    config = {
        "name": "TrellisImageTo3DPipeline",
        "args": {
            "models": {key: "ckpts/" + key for key in sorted(tm.MODEL_KEYS)},
            "image_cond_model": tm.DINO_MODEL,
            "sparse_structure_sampler": {
                "name": "FlowEulerGuidanceIntervalSampler", "args": {"sigma_min": 1e-5},
                "params": {"steps": 25, "cfg_strength": 5.0},
            },
            "slat_sampler": {
                "name": "FlowEulerGuidanceIntervalSampler", "args": {"sigma_min": 1e-5},
                "params": {"steps": 25, "cfg_strength": 5.0},
            },
            "slat_normalization": {"mean": [0.0] * 8, "std": [1.0] * 8},
        },
    }
    paths = tm.required_model_files(config) + [
        "dinov2/repository/hubconf.py",
        "dinov2/repository/dinov2/hub/backbones.py",
        f"dinov2/{tm.DINO_WEIGHT}", "rembg/u2net.onnx",
    ]
    for name in paths:
        path = tm.inside(root, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"TEST FIXTURE - NOT A REAL MODEL\n")
    tm.write_json(root / "TRELLIS-image-large/pipeline.json", config)
    manifest = {
        "schema_version": tm.BUNDLE_VERSION,
        "sources": copy.deepcopy(tm.PROVENANCE),
        "files": {name: tm.record_file(tm.inside(root, name)) for name in paths},
    }
    tm.write_json(root / "model-manifest.json", manifest)
    return config, manifest


class ModelBundleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.config, self.manifest = fixture(self.root)

    def tearDown(self):
        self.directory.cleanup()

    def test_valid_bundle(self):
        self.assertEqual(tm.validate_bundle(self.root), self.manifest)

    def test_missing_manifest(self):
        (self.root / "model-manifest.json").unlink()
        with self.assertRaisesRegex(FileNotFoundError, "model-install"):
            tm.validate_bundle(self.root)

    def test_missing_weight_fails_early(self):
        (self.root / "rembg/u2net.onnx").unlink()
        with self.assertRaisesRegex(ValueError, "rembg/u2net.onnx"):
            tm.validate_bundle(self.root)

    def test_same_size_corruption_is_detected(self):
        target = self.root / "rembg/u2net.onnx"
        data = target.read_bytes()
        target.write_bytes(b"!" + data[1:])
        with self.assertRaisesRegex(ValueError, "damaged"):
            tm.validate_bundle(self.root)

    def test_inventory_cannot_omit_checkpoint(self):
        relative = next(name for name in self.manifest["files"] if name.endswith(".safetensors"))
        del self.manifest["files"][relative]
        tm.write_json(self.root / "model-manifest.json", self.manifest)
        with self.assertRaisesRegex(ValueError, "incomplete"):
            tm.validate_bundle(self.root)

    def test_source_revision_is_pinned(self):
        self.manifest["sources"]["dinov2_revision"] = "0" * 40
        tm.write_json(self.root / "model-manifest.json", self.manifest)
        with self.assertRaisesRegex(ValueError, "revision"):
            tm.validate_bundle(self.root)

    def test_remote_checkpoint_reference_is_rejected(self):
        self.config["args"]["models"]["slat_decoder_gs"] = "someone/remote/weights"
        with self.assertRaisesRegex(ValueError, "local checkpoint"):
            tm.required_model_files(self.config)

    def test_path_traversal_and_windows_paths_are_rejected(self):
        for relative in ("../escape", "a/../../escape", "/absolute", "C:/escape", "a\\..\\b", "x:ads"):
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                tm.inside(self.root, relative)

    def test_symlink_escape_rejected(self):
        with tempfile.TemporaryDirectory() as other:
            link = self.root / "link"
            try:
                link.symlink_to(other, target_is_directory=True)
            except OSError:
                self.skipTest("Symlink creation is unavailable")
            with self.assertRaises(ValueError):
                tm.inside(self.root, "link/file")

    def test_unrecorded_dino_source_is_rejected(self):
        (self.root / "dinov2/repository/extra.py").write_text("pass\n")
        with self.assertRaisesRegex(ValueError, "Unrecorded"):
            tm.validate_bundle(self.root)

    def test_completed_install_is_idempotent_and_has_no_network(self):
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        with patch.object(tm, "urlopen", side_effect=AssertionError("network attempted")):
            tm.install_bundle(self.root)
            tm.install_bundle(self.root)
        after = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_check_cli_does_not_generate_or_download(self):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        result = subprocess.run(
            [sys.executable, "-B", str(TOOLS / "run_trellis.py"), "--check-models", "--models-dir", str(self.root)],
            text=True, capture_output=True, timeout=20, env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("aucune génération", result.stdout)

    def test_missing_check_cli_has_actionable_failure(self):
        (self.root / "rembg/u2net.onnx").unlink()
        result = subprocess.run(
            [sys.executable, "-B", str(TOOLS / "run_trellis.py"), "--check-models", "--models-dir", str(self.root)],
            text=True, capture_output=True, timeout=20,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("model-install", result.stderr)
        self.assertNotIn("huggingface_hub", result.stderr)

    def test_loader_uses_only_local_dino_and_restores_sampler_parameters(self):
        fake_torch = ModuleType("torch")
        encoder = MagicMock()
        fake_torch.hub = SimpleNamespace(load=MagicMock(return_value=encoder))
        state = {"fixture": True}
        fake_torch.load = MagicMock(return_value=state)
        fake_transforms = SimpleNamespace(Compose=lambda seq: seq, Normalize=lambda **kw: kw)
        fake_tv = ModuleType("torchvision")
        fake_tv.transforms = fake_transforms

        class FakePipeline:
            def __init__(self, models, sparse_structure_sampler, slat_sampler, slat_normalization, image_cond_model):
                self.models = models
                self.sparse_structure_sampler = sparse_structure_sampler
                self.slat_sampler = slat_sampler
                self.slat_normalization = slat_normalization
                self._init_image_cond_model(image_cond_model)

        fake_models = SimpleNamespace(from_pretrained=MagicMock(side_effect=lambda path: path))
        fake_samplers = SimpleNamespace(FlowEulerGuidanceIntervalSampler=lambda **args: args)
        trellis = ModuleType("trellis")
        trellis.models = fake_models
        pipelines = ModuleType("trellis.pipelines")
        pipelines.TrellisImageTo3DPipeline = FakePipeline
        pipelines.samplers = fake_samplers
        with patch.dict(sys.modules, {
            "torch": fake_torch, "torchvision": fake_tv,
            "trellis": trellis, "trellis.pipelines": pipelines,
        }):
            pipeline = offline.load_local_pipeline(self.root)
        args, kwargs = fake_torch.hub.load.call_args
        self.assertEqual(args, (str(self.root / "dinov2/repository"), tm.DINO_MODEL))
        self.assertEqual(kwargs, {"source": "local", "pretrained": False})
        fake_torch.load.assert_called_once_with(
            str(self.root / "dinov2" / tm.DINO_WEIGHT), map_location="cpu", weights_only=True,
        )
        encoder.load_state_dict.assert_called_once_with(state, strict=True)
        self.assertEqual(fake_models.from_pretrained.call_count, 6)
        self.assertEqual(pipeline.sparse_structure_sampler_params, self.config["args"]["sparse_structure_sampler"]["params"])
        self.assertEqual(pipeline.slat_sampler_params, self.config["args"]["slat_sampler"]["params"])


class ArchiveTests(unittest.TestCase):
    def test_archive_extraction_uses_pinned_root_and_excludes_docs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            z = root / "code.zip"
            prefix = f"dinov2-{tm.DINO_REVISION}/"
            with ZipFile(z, "w") as bundle:
                for name in ("hubconf.py", "dinov2/hub/backbones.py", "LICENSE", "README.md", "image.png"):
                    bundle.writestr(prefix + name, "fixture\n")
            paths = tm.extract_dino_code(z, root / "repository")
            self.assertEqual(len(paths), 3)
            self.assertFalse((root / "repository/README.md").exists())

    def test_zip_slip_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            z = root / "code.zip"
            with ZipFile(z, "w") as bundle:
                bundle.writestr(f"dinov2-{tm.DINO_REVISION}/../../escape.py", "bad")
            with self.assertRaises(ValueError):
                tm.extract_dino_code(z, root / "repository")
            self.assertFalse((root / "escape.py").exists())


class OfflineGuardTests(unittest.TestCase):
    def test_guard_blocks_python_network_before_socket_connection(self):
        program = f"""
import sys, os
from pathlib import Path
sys.path.insert(0, {str(TOOLS)!r})
from trellis_offline import configure_offline
configure_offline(Path('models'))
assert os.environ['HF_HUB_OFFLINE'] == '1'
assert os.environ['TRANSFORMERS_OFFLINE'] == '1'
assert os.environ['U2NET_HOME'] == str(Path('models/rembg'))
import socket
from urllib.request import urlopen
for action in [lambda: socket.getaddrinfo('huggingface.co',443), lambda: urlopen('https://huggingface.co')]:
    try:
        action()
    except RuntimeError as exc:
        assert 'offline mode blocked' in str(exc), str(exc)
    else:
        raise AssertionError('network was not blocked')
print('GUARD_OK')
"""
        result = subprocess.run([sys.executable, "-B", "-c", program], text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("GUARD_OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
