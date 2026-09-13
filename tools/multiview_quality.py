"""CLI des heuristiques de qualité multi-vues."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from multiview.quality import analyze_multiview, rank_reference_candidates, save_json


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Outils de scoring heuristique pour Asset Factory multi-vues")
    subparsers = parser.add_subparsers(dest="command", required=True)

    score_refs = subparsers.add_parser("score-references", help="Classe plusieurs images de référence candidates")
    score_refs.add_argument("--image", action="append", required=True, help="Image candidate")
    score_refs.add_argument("--output", required=True, help="Fichier JSON de sortie")
    score_refs.add_argument("--target-occupancy", type=float, default=0.58)

    views = subparsers.add_parser("report-views", help="Produit un rapport de qualité sur un jeu de vues")
    views.add_argument("--image", action="append", required=True, help="Vue générée")
    views.add_argument("--output", required=True, help="Fichier JSON de sortie")

    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.command == "score-references":
        payload = rank_reference_candidates([Path(p) for p in args.image], target_occupancy=args.target_occupancy)
    elif args.command == "report-views":
        payload = analyze_multiview([Path(p) for p in args.image])
    else:
        raise ValueError(f"Commande inconnue : {args.command}")

    save_json(payload, Path(args.output))
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
