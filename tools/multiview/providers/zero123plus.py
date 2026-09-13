"""Fournisseur Zero123++ v1.1 pour Asset Factory.

Le fournisseur charge uniquement un checkout local du code officiel et un snapshot
local du modèle. Aucune récupération réseau n'est autorisée pendant une génération.
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
from typing import Any

from PIL import Image, ImageOps


PROVIDER_ID = "zero123plus"
GRID_COLUMNS = 2
GRID_ROWS = 3


def _pose_token(value: int) -> str:
    sign = "p" if value >= 0 else "m"
    return f"{sign}{abs(int(value)):03d}"


def prepare_reference(input_path: Path, output_path: Path | None = None) -> tuple[Image.Image, Path | None, bool]:
    """Charge une image RGB carrée, avec padding gris si nécessaire.

    Zero123++ attend une image carrée. Le padding conserve toute la silhouette au
    lieu de rogner l'objet. Une copie préparée n'est écrite que si une adaptation
    est réellement nécessaire.
    """
    with Image.open(input_path) as source:
        image = source.convert("RGBA") if source.mode in ("RGBA", "LA") else source.convert("RGB")
        if image.mode == "RGBA":
            background = Image.new("RGBA", image.size, (127, 127, 127, 255))
            background.alpha_composite(image)
            image = background.convert("RGB")
        else:
            image = image.convert("RGB")

    target_side = max(320, image.width, image.height)
    changed = image.width != image.height or image.width < 320 or image.height < 320
    if changed:
        image = ImageOps.pad(image, (target_side, target_side), method=Image.Resampling.LANCZOS, color=(127, 127, 127), centering=(0.5, 0.5))
        if output_path is None:
            raise ValueError("Un chemin de sortie est requis pour la référence préparée.")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        image.save(output_path, format="PNG")
        return image, output_path, True
    return image, None, False


def load_pipeline(model_dir: Path, engine_root: Path):
    """Charge le pipeline officiel Zero123++ depuis des fichiers locaux."""
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["DIFFUSERS_OFFLINE"] = "1"

    import torch
    from diffusers import EulerAncestralDiscreteScheduler

    pipeline_file = engine_root / "diffusers-support" / "pipeline.py"
    if not pipeline_file.is_file():
        raise FileNotFoundError(
            f"Pipeline Zero123++ local introuvable : {pipeline_file}. "
            "Lancez '.\\setup-asset-factory.ps1 multiview install'."
        )
    if not (model_dir / "model_index.json").is_file():
        raise FileNotFoundError(
            f"Modèle Zero123++ local introuvable : {model_dir}. "
            "Lancez '.\\setup-asset-factory.ps1 multiview model-install'."
        )

    spec = importlib.util.spec_from_file_location("asset_factory_zero123plus_pipeline", pipeline_file)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Impossible de charger le pipeline Zero123++ : {pipeline_file}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pipeline_cls = module.Zero123PlusPipeline

    pipeline = pipeline_cls.from_pretrained(
        str(model_dir),
        torch_dtype=torch.float16,
        local_files_only=True,
    )
    pipeline.scheduler = EulerAncestralDiscreteScheduler.from_config(
        pipeline.scheduler.config,
        timestep_spacing="trailing",
    )
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA est indisponible pour Zero123++.")
    pipeline.to("cuda:0")
    return pipeline


def split_grid(grid: Image.Image, output_dir: Path, asset_id: str, camera_views: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if len(camera_views) != GRID_COLUMNS * GRID_ROWS:
        raise ValueError(f"Zero123++ v1.1 doit décrire exactement {GRID_COLUMNS * GRID_ROWS} vues.")
    if grid.width % GRID_COLUMNS != 0 or grid.height % GRID_ROWS != 0:
        raise ValueError(
            f"Grille Zero123++ inattendue : {grid.width}x{grid.height}; "
            f"elle doit être divisible par {GRID_COLUMNS}x{GRID_ROWS}."
        )

    tile_width = grid.width // GRID_COLUMNS
    tile_height = grid.height // GRID_ROWS
    output_dir.mkdir(parents=True, exist_ok=True)
    results: list[dict[str, Any]] = []

    for zero_index, camera in enumerate(camera_views):
        row = zero_index // GRID_COLUMNS
        column = zero_index % GRID_COLUMNS
        tile = grid.crop((
            column * tile_width,
            row * tile_height,
            (column + 1) * tile_width,
            (row + 1) * tile_height,
        ))
        azimuth = int(camera["azimuth"])
        elevation = int(camera["elevation"])
        filename = (
            f"{asset_id}_view_{zero_index + 1:02d}_"
            f"az{azimuth:03d}_el{_pose_token(elevation)}.png"
        )
        path = output_dir / filename
        tile.save(path, format="PNG")
        results.append({
            "index": zero_index + 1,
            "azimuth": azimuth,
            "elevation": elevation,
            "path": str(path),
            "width": tile.width,
            "height": tile.height,
        })
    return results


def generate(
    *,
    reference_path: Path,
    output_dir: Path,
    asset_id: str,
    model_dir: Path,
    engine_root: Path,
    camera_views: list[dict[str, Any]],
    steps: int,
    guidance_scale: float,
    seed: int,
    conditioning_prompt: str = "",
    keep_grid: bool = True,
) -> dict[str, Any]:
    import torch

    prepared_path = reference_path.parent / f"{asset_id}_reference_prepared.png"
    reference, written_prepared, changed = prepare_reference(reference_path, prepared_path)
    pipeline = load_pipeline(model_dir, engine_root)
    generator = torch.Generator(device="cuda").manual_seed(seed)

    with torch.inference_mode():
        result = pipeline(
            reference,
            prompt=conditioning_prompt,
            num_inference_steps=steps,
            guidance_scale=guidance_scale,
            generator=generator,
        ).images[0]

    if not isinstance(result, Image.Image):
        raise TypeError("Zero123++ n'a pas renvoyé une image PIL.")

    grid_path = output_dir / f"{asset_id}_multiview_grid.png"
    if keep_grid:
        output_dir.mkdir(parents=True, exist_ok=True)
        result.save(grid_path, format="PNG")
    views = split_grid(result, output_dir, asset_id, camera_views)

    return {
        "provider": PROVIDER_ID,
        "referencePrepared": changed,
        "preparedReferencePath": str(written_prepared) if written_prepared else str(reference_path),
        "gridPath": str(grid_path) if keep_grid else None,
        "gridWidth": result.width,
        "gridHeight": result.height,
        "views": views,
    }
