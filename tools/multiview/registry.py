"""Chargement du registre des méthodes multi-vues d'Asset Factory."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class MultiViewConfigError(ValueError):
    """Configuration multi-vues invalide."""


def project_root_from_tools() -> Path:
    return Path(__file__).resolve().parents[2]


def load_registry(path: Path | None = None) -> dict[str, Any]:
    if path is None:
        path = project_root_from_tools() / "config" / "multiview-methods.json"
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    if data.get("schemaVersion") != 1:
        raise MultiViewConfigError(f"Version de registre multi-vues non prise en charge : {data.get('schemaVersion')!r}")
    methods = data.get("methods")
    if not isinstance(methods, dict) or not methods:
        raise MultiViewConfigError("Le registre multi-vues ne contient aucune méthode.")
    default = data.get("defaultMethod")
    if default not in methods:
        raise MultiViewConfigError("La méthode multi-vues par défaut n'existe pas dans le registre.")
    return data


def method_config(method: str, path: Path | None = None) -> dict[str, Any]:
    registry = load_registry(path)
    try:
        config = registry["methods"][method]
    except KeyError as exc:
        available = ", ".join(sorted(registry["methods"]))
        raise MultiViewConfigError(f"Méthode multi-vues inconnue '{method}'. Disponibles : {available}") from exc
    if config.get("type") != "image-to-multiview":
        raise MultiViewConfigError(f"La méthode '{method}' n'est pas une méthode image-vers-multi-vues.")
    return config
