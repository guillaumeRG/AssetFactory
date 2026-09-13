"""Heuristiques légères de qualité pour la chaîne multi-vues.

Objectifs :
- noter plusieurs images de référence candidates afin de choisir la plus propre ;
- produire un petit rapport de qualité des vues générées (cadrage, centrage,
  diversité perceptuelle).

Aucune dépendance réseau ou modèle additionnel n'est requise. Les heuristiques
s'appuient uniquement sur Pillow.
"""
from __future__ import annotations

from dataclasses import dataclass
import itertools
import json
import math
from pathlib import Path
from statistics import mean
from typing import Any, Iterable, Sequence

from PIL import Image, ImageStat


@dataclass(frozen=True)
class BBox:
    left: int
    top: int
    right: int
    bottom: int

    @property
    def width(self) -> int:
        return max(0, self.right - self.left + 1)

    @property
    def height(self) -> int:
        return max(0, self.bottom - self.top + 1)

    @property
    def area(self) -> int:
        return self.width * self.height


@dataclass(frozen=True)
class ImageAnalysis:
    path: str
    width: int
    height: int
    bbox: BBox
    occupancy: float
    coverage: float
    center_offset: float
    touches_border: bool
    border_stddev_mean: float
    ahash: str

    def to_json(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "width": self.width,
            "height": self.height,
            "bbox": {
                "left": self.bbox.left,
                "top": self.bbox.top,
                "right": self.bbox.right,
                "bottom": self.bbox.bottom,
                "width": self.bbox.width,
                "height": self.bbox.height,
            },
            "occupancy": round(self.occupancy, 6),
            "coverage": round(self.coverage, 6),
            "centerOffset": round(self.center_offset, 6),
            "touchesBorder": self.touches_border,
            "borderStddevMean": round(self.border_stddev_mean, 6),
            "aHash": self.ahash,
        }


def _border_samples(image: Image.Image) -> list[tuple[int, int, int]]:
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    samples: list[tuple[int, int, int]] = []
    step_x = max(1, width // 64)
    step_y = max(1, height // 64)
    for x in range(0, width, step_x):
        samples.append(pixels[x, 0])
        samples.append(pixels[x, height - 1])
    for y in range(0, height, step_y):
        samples.append(pixels[0, y])
        samples.append(pixels[width - 1, y])
    return samples


def _mean_rgb(samples: Sequence[tuple[int, int, int]]) -> tuple[float, float, float]:
    if not samples:
        return (127.0, 127.0, 127.0)
    return tuple(sum(channel) / len(samples) for channel in zip(*samples))


def _rgb_distance(a: tuple[int, int, int], b: tuple[float, float, float]) -> float:
    return math.sqrt(
        (float(a[0]) - b[0]) ** 2 +
        (float(a[1]) - b[1]) ** 2 +
        (float(a[2]) - b[2]) ** 2
    )


def _alpha_bbox(image: Image.Image) -> BBox | None:
    if "A" not in image.getbands():
        return None
    alpha = image.getchannel("A")
    pixels = alpha.load()
    width, height = alpha.size
    min_x, min_y = width, height
    max_x, max_y = -1, -1
    for y in range(height):
        for x in range(width):
            if pixels[x, y] > 10:
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y = max(max_y, y)
    if max_x < 0:
        return None
    return BBox(min_x, min_y, max_x, max_y)


def _estimate_bbox(image: Image.Image) -> tuple[BBox, float]:
    alpha_bbox = _alpha_bbox(image)
    width, height = image.size
    if alpha_bbox is not None:
        return alpha_bbox, 0.0

    border = _border_samples(image)
    border_mean = _mean_rgb(border)
    border_canvas = Image.new("RGB", (max(1, len(border)), 1))
    border_canvas.putdata(border)
    border_stddev_mean = mean(ImageStat.Stat(border_canvas).stddev) if border else 0.0
    threshold = max(18.0, min(72.0, border_stddev_mean * 2.5 + 12.0))

    rgb = image.convert("RGB")
    pixels = rgb.load()
    min_x, min_y = width, height
    max_x, max_y = -1, -1
    for y in range(height):
        for x in range(width):
            if _rgb_distance(pixels[x, y], border_mean) > threshold:
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y = max(max_y, y)
    if max_x < 0:
        return BBox(0, 0, width - 1, height - 1), border_stddev_mean
    return BBox(min_x, min_y, max_x, max_y), border_stddev_mean


def average_hash(image: Image.Image, size: int = 8) -> str:
    grayscale = image.convert("L").resize((size, size), Image.Resampling.BILINEAR)
    values = list(grayscale.get_flattened_data()) if hasattr(grayscale, "get_flattened_data") else list(grayscale.getdata())
    avg = sum(values) / len(values)
    return "".join("1" if value >= avg else "0" for value in values)


def hamming_distance(a: str, b: str) -> int:
    if len(a) != len(b):
        raise ValueError("Les hashes doivent avoir la même longueur.")
    return sum(1 for left, right in zip(a, b) if left != right)


def analyze_image(path: Path | str) -> ImageAnalysis:
    source = Path(path)
    with Image.open(source) as image:
        bbox, border_stddev_mean = _estimate_bbox(image)
        width, height = image.size
        occupancy = bbox.area / float(width * height)
        coverage = max(bbox.width / float(width), bbox.height / float(height))
        center_x = (bbox.left + bbox.right + 1) / 2.0
        center_y = (bbox.top + bbox.bottom + 1) / 2.0
        norm_dx = abs(center_x - width / 2.0) / max(1.0, width / 2.0)
        norm_dy = abs(center_y - height / 2.0) / max(1.0, height / 2.0)
        center_offset = math.sqrt(norm_dx * norm_dx + norm_dy * norm_dy)
        touches_border = bbox.left <= 1 or bbox.top <= 1 or bbox.right >= width - 2 or bbox.bottom >= height - 2
        ahash = average_hash(image)
    return ImageAnalysis(
        path=str(source),
        width=width,
        height=height,
        bbox=bbox,
        occupancy=occupancy,
        coverage=coverage,
        center_offset=center_offset,
        touches_border=touches_border,
        border_stddev_mean=border_stddev_mean,
        ahash=ahash,
    )


def score_reference(analysis: ImageAnalysis, target_occupancy: float = 0.58) -> dict[str, Any]:
    score = 100.0
    score -= abs(analysis.occupancy - target_occupancy) * 95.0
    score -= analysis.center_offset * 28.0
    score -= max(0.0, analysis.border_stddev_mean - 8.0) * 0.8
    if analysis.touches_border:
        score -= 14.0
    if analysis.occupancy < 0.18 or analysis.occupancy > 0.92:
        score -= 18.0
    if analysis.coverage < 0.35:
        score -= 12.0
    score = max(0.0, min(100.0, score))

    warnings: list[str] = []
    if analysis.touches_border:
        warnings.append("objet_touche_bords")
    if analysis.occupancy < 0.25:
        warnings.append("objet_trop_petit")
    if analysis.occupancy > 0.88:
        warnings.append("objet_trop_grand")
    if analysis.center_offset > 0.18:
        warnings.append("objet_mal_centre")
    if analysis.border_stddev_mean > 18.0:
        warnings.append("fond_peu_uniforme")

    payload = analysis.to_json()
    payload["score"] = round(score, 3)
    payload["warnings"] = warnings
    return payload


def rank_reference_candidates(paths: Iterable[Path | str], target_occupancy: float = 0.58) -> dict[str, Any]:
    candidates = [score_reference(analyze_image(path), target_occupancy=target_occupancy) for path in paths]
    if not candidates:
        raise ValueError("Aucune image candidate fournie.")
    candidates.sort(key=lambda item: (-float(item["score"]), str(item["path"])))
    return {
        "schemaVersion": 1,
        "candidateCount": len(candidates),
        "selectedReferencePath": candidates[0]["path"],
        "selectedScore": candidates[0]["score"],
        "candidates": candidates,
    }


def analyze_multiview(paths: Sequence[Path | str]) -> dict[str, Any]:
    views = [analyze_image(path) for path in paths]
    if len(views) < 2:
        raise ValueError("Au moins deux vues sont requises pour un rapport multi-vues.")

    view_payloads = [score_reference(view, target_occupancy=0.55) for view in views]
    pairwise: list[dict[str, Any]] = []
    distances: list[int] = []
    duplicate_pairs: list[tuple[int, int]] = []
    for (left_index, left), (right_index, right) in itertools.combinations(enumerate(views, start=1), 2):
        distance = hamming_distance(left.ahash, right.ahash)
        distances.append(distance)
        if distance < 8:
            duplicate_pairs.append((left_index, right_index))
        pairwise.append({
            "left": left_index,
            "right": right_index,
            "hammingDistance": distance,
        })

    occupancies = [view.occupancy for view in views]
    center_offsets = [view.center_offset for view in views]
    warnings: list[str] = []
    if duplicate_pairs:
        warnings.append("vues_trop_similaires")
    if max(occupancies) - min(occupancies) > 0.30:
        warnings.append("cadrage_inconstant")
    if max(center_offsets) > 0.25:
        warnings.append("une_ou_plusieurs_vues_mal_centrees")

    score = 100.0
    if distances:
        score -= max(0.0, 12.0 - min(distances)) * 5.0
    score -= max(0.0, (max(occupancies) - min(occupancies)) - 0.10) * 60.0
    score -= max(0.0, max(center_offsets) - 0.10) * 45.0
    score = max(0.0, min(100.0, score))

    return {
        "schemaVersion": 1,
        "viewCount": len(views),
        "score": round(score, 3),
        "warnings": warnings,
        "summary": {
            "minHammingDistance": min(distances) if distances else None,
            "avgHammingDistance": round(sum(distances) / len(distances), 3) if distances else None,
            "occupancyMin": round(min(occupancies), 6),
            "occupancyMax": round(max(occupancies), 6),
            "occupancySpan": round(max(occupancies) - min(occupancies), 6),
            "maxCenterOffset": round(max(center_offsets), 6),
            "duplicatePairs": [{"left": left, "right": right} for left, right in duplicate_pairs],
        },
        "views": view_payloads,
        "pairwise": pairwise,
    }


def save_json(payload: dict[str, Any], path: Path | str) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
