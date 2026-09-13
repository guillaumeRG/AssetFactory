"""Asset Factory's local-only TRELLIS loader; no edits to upstream sources.

The Python audit guard below catches ordinary Python network attempts. It is
not an operating-system firewall or a sandbox for arbitrary native libraries.
"""
from __future__ import annotations

import os
from pathlib import Path
import sys
from typing import Any

from trellis_models import DINO_MODEL, DINO_WEIGHT, read_json, validate_bundle

_GUARD_INSTALLED = False


def configure_offline(models_dir: Path) -> None:
    """Run before importing torch, Hugging Face, rembg or TRELLIS."""
    global _GUARD_INSTALLED
    for name in (
        "HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_DATASETS_OFFLINE",
        "HF_HUB_DISABLE_TELEMETRY", "HF_HUB_DISABLE_IMPLICIT_TOKEN",
        "HF_HUB_DISABLE_UPDATE_CHECK", "DO_NOT_TRACK",
    ):
        os.environ[name] = "1"
    os.environ["U2NET_HOME"] = str(models_dir / "rembg")
    # DINOv2 uses its supported PyTorch fallback; it must not mistake our
    # limited TRELLIS-only xFormers shim for the full xFormers package.
    os.environ["XFORMERS_DISABLED"] = "1"
    # Avoid creating Python bytecode inside third-party source directories.
    sys.dont_write_bytecode = True
    if _GUARD_INSTALLED:
        return

    def deny_python_network(event: str, args: tuple[Any, ...]) -> None:
        if event in {
            "socket.connect", "socket.getaddrinfo", "socket.gethostbyname",
            "socket.gethostbyaddr", "socket.sendto",
        }:
            raise RuntimeError(f"Asset Factory offline mode blocked a network operation: {event}")
        if event == "urllib.Request" and args and str(args[0]).startswith(("http://", "https://")):
            raise RuntimeError("Asset Factory offline mode blocked an HTTP request")

    sys.addaudithook(deny_python_network)
    _GUARD_INSTALLED = True


def check_local_models(models_dir: Path) -> dict[str, Any]:
    print("[INFO] Verifying local model files before loading (SHA-256)...", flush=True)
    result = validate_bundle(models_dir)
    print("[OK] TRELLIS, DINOv2 and U2Net local files verified.", flush=True)
    return result


def load_local_pipeline(models_dir: Path):
    """Use upstream models/samplers/run(); change only model acquisition.

    Upstream from_pretrained is a static method that constructs its base class,
    so overriding it through a subclass would not select a local DINO loader.
    Instead we construct the documented pipeline using the same JSON arguments
    and a subclass that only overrides _init_image_cond_model.
    """
    import torch
    from torchvision import transforms
    from trellis import models
    from trellis.pipelines import TrellisImageTo3DPipeline, samplers

    model_root = models_dir / "TRELLIS-image-large"
    config = read_json(model_root / "pipeline.json")["args"]
    dino_source = models_dir / "dinov2" / "repository"
    dino_weights = models_dir / "dinov2" / DINO_WEIGHT

    class LocalImagePipeline(TrellisImageTo3DPipeline):
        def _init_image_cond_model(self, name: str) -> None:
            if name != DINO_MODEL:
                raise ValueError(f"Unsupported local image conditioning model: {name}")
            print("[INFO] Loading DINOv2 from local source and weights...", flush=True)
            encoder = torch.hub.load(
                str(dino_source), name, source="local", pretrained=False,
            )
            weights = torch.load(str(dino_weights), map_location="cpu", weights_only=True)
            encoder.load_state_dict(weights, strict=True)
            del weights
            encoder.eval()
            self.models["image_cond_model"] = encoder
            # Same preprocessing transform as TRELLIS 442aa1e.
            self.image_cond_model_transform = transforms.Compose([
                transforms.Normalize(
                    mean=[0.485, 0.456, 0.406],
                    std=[0.229, 0.224, 0.225],
                ),
            ])

    loaded_models = {}
    for key, relative in config["models"].items():
        base = model_root / relative
        # No remote fallback like Pipeline.from_pretrained's broad except.
        if not Path(str(base) + ".json").is_file() or not Path(str(base) + ".safetensors").is_file():
            raise FileNotFoundError(f"Incomplete local checkpoint: {base}")
        print(f"[INFO] Loading local {key}...", flush=True)
        loaded_models[key] = models.from_pretrained(str(base))

    sparse_sampler = config["sparse_structure_sampler"]
    slat_sampler = config["slat_sampler"]
    pipeline = LocalImagePipeline(
        models=loaded_models,
        sparse_structure_sampler=getattr(samplers, sparse_sampler["name"])(**sparse_sampler["args"]),
        slat_sampler=getattr(samplers, slat_sampler["name"])(**slat_sampler["args"]),
        slat_normalization=config["slat_normalization"],
        image_cond_model=config["image_cond_model"],
    )
    pipeline.sparse_structure_sampler_params = dict(sparse_sampler["params"])
    pipeline.slat_sampler_params = dict(slat_sampler["params"])
    pipeline._pretrained_args = config
    return pipeline
