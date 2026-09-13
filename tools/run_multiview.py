"""Runner Python générique image-vers-multi-vues d'Asset Factory."""
from __future__ import annotations

import argparse
import importlib
import json
import os
from pathlib import Path
import sys
from typing import Any

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from multiview.registry import load_registry, method_config  # noqa: E402


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def resolve_under_root(root: Path, relative_or_absolute: str) -> Path:
    path = Path(relative_or_absolute)
    if not path.is_absolute():
        path = root / path
    return path.resolve()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Asset Factory image-vers-multi-vues")
    parser.add_argument("--method", default="")
    parser.add_argument("--reference", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--asset-id", required=True)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--steps", type=int)
    parser.add_argument("--guidance-scale", type=float)
    parser.add_argument("--conditioning-prompt")
    parser.add_argument("--keep-grid", choices=("true", "false"))
    parser.add_argument("--registry", default=str(ROOT / "config" / "multiview-methods.json"))
    parser.add_argument("--check-method", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    registry_path = Path(args.registry).resolve()
    registry = load_registry(registry_path)
    method = args.method or registry["defaultMethod"]
    config = method_config(method, registry_path)
    defaults = dict(config.get("parameters") or {})

    steps = args.steps if args.steps is not None else int(defaults.get("steps", 28))
    guidance = args.guidance_scale if args.guidance_scale is not None else float(defaults.get("guidanceScale", 4.0))
    conditioning_prompt = (
        args.conditioning_prompt
        if args.conditioning_prompt is not None
        else str(defaults.get("conditioningPrompt", ""))
    )
    keep_grid = (
        args.keep_grid.lower() == "true"
        if args.keep_grid is not None
        else bool(defaults.get("keepGrid", True))
    )
    if steps < 1 or steps > 200:
        raise ValueError("steps doit être compris entre 1 et 200.")
    if guidance < 0 or guidance > 30:
        raise ValueError("guidanceScale doit être compris entre 0 et 30.")

    engine_root = resolve_under_root(ROOT, str(config["engineRoot"]))
    model_root = resolve_under_root(ROOT, str(config["modelRoot"]))
    reference = Path(args.reference).resolve()
    output_dir = Path(args.output_dir).resolve()
    metadata_path = Path(args.metadata).resolve()

    if not reference.is_file():
        raise FileNotFoundError(f"Image de référence introuvable : {reference}")
    if args.check_method:
        print(f"[OK] Méthode multi-vues : {method}")
        print(f"[INFO] Moteur : {engine_root}")
        print(f"[INFO] Modèle : {model_root}")
        return 0

    # La génération doit être strictement locale après l'installation explicite du modèle.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["DIFFUSERS_OFFLINE"] = "1"

    provider_name = str(config.get("provider"))
    if not provider_name or not provider_name.replace("_", "").isalnum():
        raise ValueError(f"Nom de fournisseur multi-vues invalide : {provider_name!r}")
    try:
        provider_module = importlib.import_module(f"multiview.providers.{provider_name}")
        generate = provider_module.generate
    except (ImportError, AttributeError) as exc:
        raise ValueError(f"Fournisseur multi-vues non implémenté : {provider_name}") from exc

    result = generate(
        reference_path=reference,
        output_dir=output_dir,
        asset_id=args.asset_id,
        model_dir=model_root,
        engine_root=engine_root,
        camera_views=list(config["camera"]["views"]),
        steps=steps,
        guidance_scale=guidance,
        seed=args.seed,
        conditioning_prompt=conditioning_prompt,
        keep_grid=keep_grid,
    )

    metadata = {
        "schemaVersion": 1,
        "status": "completed",
        "method": method,
        "provider": provider_name,
        "referencePath": str(reference),
        "parameters": {
            "steps": steps,
            "guidanceScale": guidance,
            "conditioningPrompt": conditioning_prompt,
            "seed": args.seed,
            "keepGrid": keep_grid,
        },
        "camera": config["camera"],
        **result,
    }
    write_json(metadata_path, metadata)

    print(f"[OK] Méthode multi-vues : {method}")
    print(f"[OK] Vues générées : {len(result['views'])}")
    for view in result["views"]:
        print(f"[OK] Vue : {view['path']}")
    print(f"[OK] Métadonnées : {metadata_path}")
    print("[RESULT_JSON] " + json.dumps({
        "kind": "asset-factory-multiview",
        "status": "completed",
        "method": method,
        "viewCount": len(result["views"]),
        "views": [item["path"] for item in result["views"]],
        "metadataPath": str(metadata_path),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
