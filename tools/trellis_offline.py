"""Chargeur TRELLIS uniquement local d'Asset Factory ; aucune modification des sources amont.

La protection d'audit Python ci-dessous intercepte les tentatives réseau Python ordinaires.
Ce n'est ni un pare-feu du système d'exploitation ni une sandbox pour des bibliothèques natives arbitraires.
"""
from __future__ import annotations

import os
from pathlib import Path
import sys
from typing import Any

from trellis_models import DINO_MODEL, DINO_WEIGHT, read_json, validate_bundle

_GUARD_INSTALLED = False


def configure_offline(models_dir: Path) -> None:
    """À exécuter avant d'importer torch, Hugging Face, rembg ou TRELLIS."""
    global _GUARD_INSTALLED
    for name in (
        "HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_DATASETS_OFFLINE",
        "HF_HUB_DISABLE_TELEMETRY", "HF_HUB_DISABLE_IMPLICIT_TOKEN",
        "HF_HUB_DISABLE_UPDATE_CHECK", "DO_NOT_TRACK",
    ):
        os.environ[name] = "1"
    os.environ["U2NET_HOME"] = str(models_dir / "rembg")
    # DINOv2 utilise son repli PyTorch pris en charge ; il ne doit pas confondre notre
    # shim xFormers limité à TRELLIS avec le package xFormers complet.
    os.environ["XFORMERS_DISABLED"] = "1"
    # Évite de créer du bytecode Python dans les répertoires de sources tierces.
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
    print("[INFO] Vérification des modèles locaux avant chargement (SHA-256)...", flush=True)
    result = validate_bundle(models_dir)
    print("[OK] Fichiers locaux TRELLIS, DINOv2 et U2Net vérifiés.", flush=True)
    return result


def load_local_pipeline(models_dir: Path):
    """Utilise les modèles/samplers/run() amont ; seule l'acquisition des modèles change.

    from_pretrained amont est une méthode statique qui construit sa classe de base ;
    la surcharger via une sous-classe ne sélectionnerait donc pas un chargeur DINO local.
    Nous construisons à la place le pipeline documenté avec les mêmes arguments JSON
    et une sous-classe qui surcharge uniquement _init_image_cond_model.
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
            print("[INFO] Chargement de DINOv2 depuis les sources et poids locaux...", flush=True)
            encoder = torch.hub.load(
                str(dino_source), name, source="local", pretrained=False,
            )
            weights = torch.load(str(dino_weights), map_location="cpu", weights_only=True)
            encoder.load_state_dict(weights, strict=True)
            del weights
            encoder.eval()
            self.models["image_cond_model"] = encoder
            # Même transformation de prétraitement que TRELLIS 442aa1e.
            self.image_cond_model_transform = transforms.Compose([
                transforms.Normalize(
                    mean=[0.485, 0.456, 0.406],
                    std=[0.229, 0.224, 0.225],
                ),
            ])

    loaded_models = {}
    for key, relative in config["models"].items():
        base = model_root / relative
        # Aucun repli distant comme dans le except large de Pipeline.from_pretrained.
        if not Path(str(base) + ".json").is_file() or not Path(str(base) + ".safetensors").is_file():
            raise FileNotFoundError(f"Incomplete local checkpoint: {base}")
        print(f"[INFO] Chargement local de {key}...", flush=True)
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
