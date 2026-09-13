"""Installation et vérification des modèles multi-vues d'Asset Factory."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

METHODS: dict[str, dict[str, str]] = {
    "zero123plus-v1.1": {
        "repo_id": "sudo-ai/zero123plus-v1.1",
        "revision": "36df7de980afd15f80b2e1a4e9a920d7020e2654",
        "license": "openrail",
    },
}
MANIFEST_NAME = "asset-factory-model-manifest.json"
MANIFEST_VERSION = 1


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def record_files(root: Path) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.name == MANIFEST_NAME:
            continue
        relative = path.relative_to(root).as_posix()
        result[relative] = {"size": path.stat().st_size, "sha256": sha256(path)}
    return result


def manifest_path(root: Path) -> Path:
    return root / MANIFEST_NAME


def validate(method: str, root: Path) -> dict[str, Any]:
    if method not in METHODS:
        raise ValueError(f"Méthode inconnue : {method}")
    path = manifest_path(root)
    if not path.is_file():
        raise FileNotFoundError(
            f"Manifest de modèle absent : {path}. Lancez 'multiview model-install'."
        )
    data = json.loads(path.read_text(encoding="utf-8"))
    expected = METHODS[method]
    if data.get("schemaVersion") != MANIFEST_VERSION or data.get("method") != method:
        raise ValueError("Manifest de modèle multi-vues incompatible.")
    if data.get("repoId") != expected["repo_id"] or data.get("revision") != expected["revision"]:
        raise ValueError("Le modèle local ne correspond pas à la source/révision épinglée.")
    files = data.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError("Inventaire de modèle vide.")
    if "model_index.json" not in files:
        raise ValueError("Le snapshot local est incomplet : model_index.json absent de l'inventaire.")
    for relative, expected_file in files.items():
        path = root / Path(relative)
        if not path.is_file():
            raise ValueError(f"Fichier de modèle manquant : {relative}")
        if path.stat().st_size != int(expected_file["size"]) or sha256(path) != expected_file["sha256"]:
            raise ValueError(f"Fichier de modèle endommagé : {relative}")
    return data


def install(method: str, root: Path) -> dict[str, Any]:
    if method not in METHODS:
        raise ValueError(f"Méthode inconnue : {method}")
    if root.exists() and manifest_path(root).is_file():
        # Un bundle déjà validé n'est jamais réécrit silencieusement.
        return validate(method, root)

    from huggingface_hub import snapshot_download

    root.parent.mkdir(parents=True, exist_ok=True)
    root.mkdir(parents=True, exist_ok=True)
    info = METHODS[method]
    # local_dir permet à un téléchargement interrompu (sans manifest final) de reprendre.
    snapshot_download(
        repo_id=info["repo_id"],
        revision=info["revision"],
        local_dir=str(root),
        local_dir_use_symlinks=False,
    )
    if not (root / "model_index.json").is_file():
        raise RuntimeError("Le téléchargement du modèle ne contient pas model_index.json.")
    manifest = {
        "schemaVersion": MANIFEST_VERSION,
        "method": method,
        "repoId": info["repo_id"],
        "revision": info["revision"],
        "license": info["license"],
        "files": record_files(root),
    }
    manifest_path(root).write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return validate(method, root)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "check"))
    parser.add_argument("--method", required=True)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()
    root = Path(args.root).resolve()
    data = install(args.method, root) if args.action == "install" else validate(args.method, root)
    size = sum(int(item["size"]) for item in data["files"].values())
    print(json.dumps({
        "status": "ok",
        "method": args.method,
        "root": str(root),
        "files": len(data["files"]),
        "bytes": size,
        "revision": data["revision"],
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
