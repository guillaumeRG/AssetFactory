"""Analyse visuelle deterministe pour Asset Factory.

Ce module ne depend pas de Blender. Il prepare le masque de reference puis
compare les passes rendues par Blender avec l'image source.
"""
from __future__ import annotations

import argparse
from collections import deque
import json
import math
from pathlib import Path
import statistics
from typing import Iterable

from PIL import Image, ImageChops, ImageFilter


DEFAULT_CONFIG = {
    "referenceMask": {
        "deltaEThreshold": 18.0,
        "morphologySize": 5,
        "minCoverage": 0.04,
        "maxCoverage": 0.92,
    },
    "qa": {
        "renderSize": 512,
        "edgeThreshold": 28,
        "edgeTolerancePixels": 3,
        "edgeBoundaryIgnorePixels": 4,
        "colorDeltaEThreshold": 18.0,
        "colorLightnessWeight": 0.25,
        "colorEdgeIgnorePixels": 3,
        "minAnomalyAreaFraction": 0.0015,
        "maxAnomalies": 40,
    },
    "scoring": {
        "silhouetteWeight": 0.50,
        "edgeWeight": 0.30,
        "colorWeight": 0.20,
        "colorDeltaEReference": 35.0,
    },
}




def _pixels(image: Image.Image):
    getter = getattr(image, "get_flattened_data", None)
    if getter is not None:
        return getter()
    return image.getdata()

def _deep_merge(base: dict, override: dict) -> dict:
    result = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def load_config(path: str | Path | None) -> dict:
    config = DEFAULT_CONFIG
    if path:
        payload = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        config = _deep_merge(DEFAULT_CONFIG, payload)
    return config


def _srgb_channel_to_linear(value: float) -> float:
    value /= 255.0
    if value <= 0.04045:
        return value / 12.92
    return ((value + 0.055) / 1.055) ** 2.4


def rgb_to_lab(rgb: tuple[int, int, int]) -> tuple[float, float, float]:
    """Conversion sRGB D65 vers CIE Lab, suffisante pour les ecarts chromatiques QA."""
    r = _srgb_channel_to_linear(float(rgb[0]))
    g = _srgb_channel_to_linear(float(rgb[1]))
    b = _srgb_channel_to_linear(float(rgb[2]))

    x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047
    y = (r * 0.2126729 + g * 0.7151522 + b * 0.0721750) / 1.00000
    z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883

    epsilon = 216.0 / 24389.0
    kappa = 24389.0 / 27.0

    def f(value: float) -> float:
        if value > epsilon:
            return value ** (1.0 / 3.0)
        return (kappa * value + 16.0) / 116.0

    fx, fy, fz = f(x), f(y), f(z)
    return (116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))


def delta_e(left: tuple[float, float, float], right: tuple[float, float, float]) -> float:
    return math.sqrt(sum((a - b) ** 2 for a, b in zip(left, right)))


def weighted_delta_e(
    left: tuple[float, float, float],
    right: tuple[float, float, float],
    lightness_weight: float,
) -> float:
    """Ecart Lab en reduisant l'influence de la luminance de la reference rendue."""
    dl = (left[0] - right[0]) * lightness_weight
    da = left[1] - right[1]
    db = left[2] - right[2]
    return math.sqrt(dl * dl + da * da + db * db)


def _border_pixels(image: Image.Image, step: int = 2) -> list[tuple[int, int, int]]:
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels: list[tuple[int, int, int]] = []
    for x in range(0, width, max(1, step)):
        pixels.append(rgb.getpixel((x, 0)))
        if height > 1:
            pixels.append(rgb.getpixel((x, height - 1)))
    for y in range(1, max(1, height - 1), max(1, step)):
        pixels.append(rgb.getpixel((0, y)))
        if width > 1:
            pixels.append(rgb.getpixel((width - 1, y)))
    return pixels


def estimate_background(image: Image.Image) -> dict:
    border = _border_pixels(image)
    if not border:
        raise ValueError("Image de reference vide ou invalide.")
    background = tuple(int(statistics.median(channel)) for channel in zip(*border))
    background_lab = rgb_to_lab(background)
    border_delta = [delta_e(rgb_to_lab(pixel), background_lab) for pixel in border]
    median_delta = float(statistics.median(border_delta))
    p90_delta = float(sorted(border_delta)[min(len(border_delta) - 1, int(len(border_delta) * 0.90))])
    uniformity = max(0.0, min(1.0, 1.0 - median_delta / 15.0))
    return {
        "rgb": list(background),
        "borderMedianDeltaE": median_delta,
        "borderP90DeltaE": p90_delta,
        "uniformity": uniformity,
    }


def _largest_component(mask: Image.Image) -> Image.Image:
    source = mask.convert("L")
    width, height = source.size
    data = bytearray(1 if value >= 128 else 0 for value in _pixels(source))
    visited = bytearray(width * height)
    best: list[int] = []

    for start in range(width * height):
        if not data[start] or visited[start]:
            continue
        visited[start] = 1
        queue = deque([start])
        component: list[int] = []
        while queue:
            index = queue.popleft()
            component.append(index)
            x = index % width
            y = index // width
            if x > 0:
                n = index - 1
                if data[n] and not visited[n]:
                    visited[n] = 1
                    queue.append(n)
            if x + 1 < width:
                n = index + 1
                if data[n] and not visited[n]:
                    visited[n] = 1
                    queue.append(n)
            if y > 0:
                n = index - width
                if data[n] and not visited[n]:
                    visited[n] = 1
                    queue.append(n)
            if y + 1 < height:
                n = index + width
                if data[n] and not visited[n]:
                    visited[n] = 1
                    queue.append(n)
        if len(component) > len(best):
            best = component

    output = bytearray(width * height)
    for index in best:
        output[index] = 255
    return Image.frombytes("L", (width, height), bytes(output))


def build_reference_mask(image: Image.Image, config: dict) -> tuple[Image.Image, dict]:
    settings = config["referenceMask"]
    background = estimate_background(image)
    threshold = float(settings["deltaEThreshold"])
    background_lab = rgb_to_lab(tuple(background["rgb"]))
    rgb = image.convert("RGB")
    mask_values = bytearray(rgb.width * rgb.height)

    for index, pixel in enumerate(_pixels(rgb)):
        if delta_e(rgb_to_lab(pixel), background_lab) >= threshold:
            mask_values[index] = 255

    mask = Image.frombytes("L", rgb.size, bytes(mask_values))
    morphology_size = int(settings.get("morphologySize", 5))
    if morphology_size >= 3:
        if morphology_size % 2 == 0:
            morphology_size += 1
        mask = mask.filter(ImageFilter.MaxFilter(morphology_size))
        mask = mask.filter(ImageFilter.MinFilter(morphology_size))
    mask = _largest_component(mask)

    foreground = sum(1 for value in _pixels(mask) if value >= 128)
    coverage = foreground / float(mask.width * mask.height)
    min_coverage = float(settings["minCoverage"])
    max_coverage = float(settings["maxCoverage"])
    if coverage < min_coverage or coverage > max_coverage:
        coverage_confidence = 0.25
    else:
        coverage_confidence = 1.0
    confidence = max(0.0, min(1.0, 0.70 * background["uniformity"] + 0.30 * coverage_confidence))

    bbox = mask.getbbox()
    info = {
        "background": background,
        "thresholdDeltaE": threshold,
        "coverage": coverage,
        "bbox": list(bbox) if bbox else None,
        "confidence": confidence,
    }
    return mask, info


def prepare_reference(reference_path: str | Path, output_dir: str | Path, config: dict) -> dict:
    reference_path = Path(reference_path).resolve()
    output_dir = Path(output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    with Image.open(reference_path) as image:
        image = image.convert("RGB")
        mask, info = build_reference_mask(image, config)
        mask_path = output_dir / "reference-mask.png"
        mask.save(mask_path)
        search_size = int(config["cameraMatch"]["searchResolution"])
        search_mask = mask.resize((search_size, search_size), Image.Resampling.NEAREST)
        search_mask_path = output_dir / "reference-mask-search.png"
        search_mask.save(search_mask_path)

    analysis_path = output_dir / "reference-analysis.json"
    payload = {
        "schemaVersion": 1,
        "referencePath": str(reference_path),
        "maskPath": str(mask_path),
        "searchMaskPath": str(search_mask_path),
        **info,
    }
    analysis_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    payload["analysisPath"] = str(analysis_path)
    return payload


def _binary(mask: Image.Image, size: tuple[int, int] | None = None) -> Image.Image:
    result = mask.convert("L")
    if size and result.size != size:
        result = result.resize(size, Image.Resampling.NEAREST)
    return result.point(lambda value: 255 if value >= 128 else 0)


def _mask_counts(left: Image.Image, right: Image.Image) -> tuple[int, int, int, int]:
    a = list(_pixels(_binary(left)))
    b = list(_pixels(_binary(right, left.size)))
    intersection = union = left_count = right_count = 0
    for av, bv in zip(a, b):
        af = av >= 128
        bf = bv >= 128
        if af:
            left_count += 1
        if bf:
            right_count += 1
        if af and bf:
            intersection += 1
        if af or bf:
            union += 1
    return intersection, union, left_count, right_count


def silhouette_iou(reference_mask: Image.Image, rendered_mask: Image.Image) -> float:
    intersection, union, _, _ = _mask_counts(reference_mask, rendered_mask)
    return float(intersection / union) if union else 1.0


def edge_mask(mask: Image.Image) -> Image.Image:
    binary = _binary(mask)
    dilated = binary.filter(ImageFilter.MaxFilter(3))
    eroded = binary.filter(ImageFilter.MinFilter(3))
    return ImageChops.difference(dilated, eroded).point(lambda value: 255 if value > 0 else 0)


def image_edge_mask(image: Image.Image, threshold: int, frame_ignore: int = 2) -> Image.Image:
    """Extrait les contours sans compter l'artefact de bord de FIND_EDGES.

    Pillow considere naturellement le cadre de l'image comme un contour fort.
    Ce cadre n'appartient pas a l'objet et fausserait fortement le score F1,
    en particulier lorsque deux images ont des details internes differents.
    """
    rgb = image.convert("RGB")
    channels = [channel.filter(ImageFilter.FIND_EDGES) for channel in rgb.split()]
    combined = ImageChops.lighter(ImageChops.lighter(channels[0], channels[1]), channels[2])
    binary = combined.point(lambda value: 255 if value >= threshold else 0)

    frame = max(0, int(frame_ignore))
    if frame == 0 or binary.width == 0 or binary.height == 0:
        return binary

    frame = min(frame, binary.width, binary.height)
    values = bytearray(_pixels(binary))
    width, height = binary.size
    for y in range(height):
        row = y * width
        if y < frame or y >= height - frame:
            values[row:row + width] = b"\x00" * width
            continue
        values[row:row + frame] = b"\x00" * frame
        values[row + width - frame:row + width] = b"\x00" * frame
    return Image.frombytes("L", binary.size, bytes(values))


def internal_edge_mask(edges: Image.Image, object_mask: Image.Image, boundary_ignore: int) -> Image.Image:
    object_mask = _binary(object_mask, edges.size)
    interior = object_mask
    erosion_size = max(1, int(boundary_ignore) * 2 + 1)
    if erosion_size >= 3:
        interior = interior.filter(ImageFilter.MinFilter(erosion_size))
    return ImageChops.multiply(_binary(edges), interior)


def compare_edge_maps(reference_edges: Image.Image, rendered_edges: Image.Image, tolerance: int) -> tuple[float, Image.Image]:
    ref_edge = _binary(reference_edges)
    render_edge = _binary(rendered_edges, reference_edges.size)
    filter_size = max(3, int(tolerance) * 2 + 1)
    if filter_size % 2 == 0:
        filter_size += 1
    ref_dilated = ref_edge.filter(ImageFilter.MaxFilter(filter_size))
    render_dilated = render_edge.filter(ImageFilter.MaxFilter(filter_size))

    ref_values = list(_pixels(ref_edge))
    render_values = list(_pixels(render_edge))
    ref_dilated_values = list(_pixels(ref_dilated))
    render_dilated_values = list(_pixels(render_dilated))

    render_total = sum(value >= 128 for value in render_values)
    ref_total = sum(value >= 128 for value in ref_values)
    render_match = sum(rv >= 128 and rd >= 128 for rv, rd in zip(render_values, ref_dilated_values))
    ref_match = sum(rv >= 128 and rd >= 128 for rv, rd in zip(ref_values, render_dilated_values))
    precision = render_match / render_total if render_total else 1.0
    recall = ref_match / ref_total if ref_total else 1.0
    f1 = 2.0 * precision * recall / (precision + recall) if precision + recall else 0.0

    mismatch_values = bytearray(reference_edges.width * reference_edges.height)
    for index, (re, rr, red, rrd) in enumerate(zip(ref_values, render_values, ref_dilated_values, render_dilated_values)):
        unmatched_ref = re >= 128 and rrd < 128
        unmatched_render = rr >= 128 and red < 128
        if unmatched_ref or unmatched_render:
            mismatch_values[index] = 255
    mismatch = Image.frombytes("L", reference_edges.size, bytes(mismatch_values))
    return float(f1), mismatch


def color_error(
    reference: Image.Image,
    albedo: Image.Image,
    reference_mask: Image.Image,
    rendered_mask: Image.Image,
    threshold: float,
    lightness_weight: float,
    edge_ignore_pixels: int,
) -> tuple[dict, Image.Image, Image.Image]:
    size = reference.size
    albedo = albedo.convert("RGB").resize(size, Image.Resampling.BICUBIC)
    reference = reference.convert("RGB")
    ref_mask = _binary(reference_mask, size)
    render_mask = _binary(rendered_mask, size)
    overlap = ImageChops.multiply(ref_mask, render_mask)
    erode_size = max(1, int(edge_ignore_pixels) * 2 + 1)
    if erode_size >= 3:
        overlap = overlap.filter(ImageFilter.MinFilter(erode_size))

    ref_pixels = list(_pixels(reference))
    albedo_pixels = list(_pixels(albedo))
    overlap_values = list(_pixels(overlap))
    errors: list[float] = []
    binary_values = bytearray(size[0] * size[1])
    heat_values = bytearray(size[0] * size[1] * 3)

    for index, enabled in enumerate(overlap_values):
        if enabled < 128:
            continue
        error = weighted_delta_e(
            rgb_to_lab(ref_pixels[index]),
            rgb_to_lab(albedo_pixels[index]),
            lightness_weight,
        )
        errors.append(error)
        if error >= threshold:
            binary_values[index] = 255
        intensity = max(0, min(255, int(round(255.0 * min(1.0, error / max(threshold * 2.0, 1.0))))))
        base = index * 3
        heat_values[base] = intensity
        heat_values[base + 1] = 0
        heat_values[base + 2] = 0

    binary = Image.frombytes("L", size, bytes(binary_values))
    heat = Image.frombytes("RGB", size, bytes(heat_values))
    if errors:
        ordered = sorted(errors)
        p95 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))]
        mean = sum(errors) / len(errors)
    else:
        mean = 0.0
        p95 = 0.0
    metrics = {
        "meanDeltaE": float(mean),
        "p95DeltaE": float(p95),
        "comparedPixelCount": len(errors),
        "coverage": len(errors) / float(size[0] * size[1]),
        "thresholdDeltaE": float(threshold),
        "lightnessWeight": float(lightness_weight),
    }
    return metrics, binary, heat


def _connected_components(mask: Image.Image, min_pixels: int) -> list[dict]:
    binary = _binary(mask)
    width, height = binary.size
    data = bytearray(1 if value >= 128 else 0 for value in _pixels(binary))
    visited = bytearray(width * height)
    components: list[dict] = []

    for start in range(width * height):
        if not data[start] or visited[start]:
            continue
        visited[start] = 1
        queue = deque([start])
        count = 0
        min_x = width
        min_y = height
        max_x = -1
        max_y = -1
        while queue:
            index = queue.popleft()
            x = index % width
            y = index // width
            count += 1
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if 0 <= nx < width and 0 <= ny < height:
                    neighbor = ny * width + nx
                    if data[neighbor] and not visited[neighbor]:
                        visited[neighbor] = 1
                        queue.append(neighbor)
        if count >= min_pixels:
            components.append({"pixelCount": count, "bbox": [min_x, min_y, max_x + 1, max_y + 1]})
    return components


def _anomalies_for_map(
    mask: Image.Image,
    kind: str,
    subtype: str,
    min_pixels: int,
    total_pixels: int,
    start_index: int,
) -> list[dict]:
    anomalies = []
    for offset, component in enumerate(_connected_components(mask, min_pixels)):
        severity = component["pixelCount"] / float(total_pixels)
        anomalies.append(
            {
                "id": f"A{start_index + offset:03d}",
                "type": kind,
                "subtype": subtype,
                "severity": severity,
                "pixelCount": component["pixelCount"],
                "bbox": component["bbox"],
                "detectorConfidence": 1.0,
                "autoFixable": False,
            }
        )
    return anomalies


def analyze(
    reference_path: str | Path,
    reference_mask_path: str | Path,
    beauty_path: str | Path,
    silhouette_path: str | Path,
    clay_path: str | Path,
    albedo_path: str | Path,
    camera_path: str | Path,
    output_dir: str | Path,
    report_path: str | Path,
    config: dict,
) -> dict:
    output_dir = Path(output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = Path(report_path).resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(reference_path) as reference_image, Image.open(reference_mask_path) as ref_mask_image, Image.open(silhouette_path) as silhouette_image, Image.open(clay_path) as clay_image, Image.open(albedo_path) as albedo_image, Image.open(beauty_path) as beauty_image:
        reference = reference_image.convert("RGB")
        ref_mask = _binary(ref_mask_image, reference.size)
        silhouette = _binary(silhouette_image, reference.size)
        clay = clay_image.convert("RGB").resize(reference.size, Image.Resampling.BICUBIC)
        albedo = albedo_image.convert("RGB").resize(reference.size, Image.Resampling.BICUBIC)
        beauty = beauty_image.convert("RGB").resize(reference.size, Image.Resampling.BICUBIC)

        silhouette_error = ImageChops.logical_xor(ref_mask.convert("1"), silhouette.convert("1")).convert("L")
        silhouette_error_path = output_dir / "silhouette-error.png"
        silhouette_error.save(silhouette_error_path)

        iou = silhouette_iou(ref_mask, silhouette)

        edge_threshold = int(config["qa"]["edgeThreshold"])
        boundary_ignore = int(config["qa"]["edgeBoundaryIgnorePixels"])
        reference_edges = internal_edge_mask(image_edge_mask(reference, edge_threshold), ref_mask, boundary_ignore)
        clay_edges = internal_edge_mask(image_edge_mask(clay, edge_threshold), silhouette, boundary_ignore)
        albedo_edges = internal_edge_mask(image_edge_mask(albedo, edge_threshold), silhouette, boundary_ignore)
        rendered_edges = ImageChops.lighter(clay_edges, albedo_edges)
        edge_score, edge_error_image = compare_edge_maps(
            reference_edges,
            rendered_edges,
            int(config["qa"]["edgeTolerancePixels"]),
        )
        edge_error_path = output_dir / "edge-error.png"
        edge_error_image.save(edge_error_path)

        color_metrics, color_binary, color_heat = color_error(
            reference,
            albedo,
            ref_mask,
            silhouette,
            float(config["qa"]["colorDeltaEThreshold"]),
            float(config["qa"]["colorLightnessWeight"]),
            int(config["qa"]["colorEdgeIgnorePixels"]),
        )
        color_error_path = output_dir / "color-error.png"
        color_heat.save(color_error_path)

        union = ImageChops.lighter(silhouette_error, edge_error_image)
        union = ImageChops.lighter(union, color_binary)
        overlay = beauty.copy()
        red = Image.new("RGB", reference.size, (255, 0, 0))
        overlay.paste(Image.blend(beauty, red, 0.50), mask=union)
        anomaly_map_path = output_dir / "anomaly-map.png"
        overlay.save(anomaly_map_path)

        total_pixels = reference.width * reference.height
        min_pixels = max(4, int(total_pixels * float(config["qa"]["minAnomalyAreaFraction"])))
        anomalies: list[dict] = []
        anomalies.extend(_anomalies_for_map(silhouette_error, "geometry", "silhouette_mismatch", min_pixels, total_pixels, len(anomalies) + 1))
        anomalies.extend(_anomalies_for_map(edge_error_image, "geometry", "contour_mismatch", min_pixels, total_pixels, len(anomalies) + 1))
        anomalies.extend(_anomalies_for_map(color_binary, "color", "chroma_mismatch", min_pixels, total_pixels, len(anomalies) + 1))
        anomalies.sort(key=lambda item: item["severity"], reverse=True)
        anomalies = anomalies[: int(config["qa"]["maxAnomalies"])]
        for index, anomaly in enumerate(anomalies, 1):
            anomaly["id"] = f"A{index:03d}"

    camera = json.loads(Path(camera_path).read_text(encoding="utf-8-sig"))
    reference_analysis_path = Path(reference_mask_path).parent / "reference-analysis.json"
    reference_analysis = {}
    if reference_analysis_path.is_file():
        reference_analysis = json.loads(reference_analysis_path.read_text(encoding="utf-8-sig"))

    weights = config["scoring"]
    color_quality = max(0.0, min(1.0, 1.0 - color_metrics["meanDeltaE"] / float(weights["colorDeltaEReference"])))
    overall = 100.0 * (
        float(weights["silhouetteWeight"]) * iou
        + float(weights["edgeWeight"]) * edge_score
        + float(weights["colorWeight"]) * color_quality
    )

    warnings: list[str] = []
    mask_confidence = float(reference_analysis.get("confidence", 1.0))
    if mask_confidence < 0.60:
        warnings.append("reference_mask_low_confidence")
    if color_metrics["coverage"] < 0.10:
        warnings.append("low_color_overlap")
    camera_score = float(camera.get("score", 0.0))
    if camera_score < 0.50:
        warnings.append("camera_match_low_confidence")

    payload = {
        "schemaVersion": 1,
        "status": "limited" if warnings else "completed",
        "referencePath": str(Path(reference_path).resolve()),
        "meshPath": camera.get("meshPath"),
        "camera": camera,
        "referenceMask": reference_analysis,
        "metrics": {
            "silhouetteIoU": iou,
            "edgeF1": edge_score,
            "color": color_metrics,
            "overallScore": overall,
            "overallFormula": (
                "100 * ("
                f"{float(weights['silhouetteWeight']):.3f} * silhouetteIoU + "
                f"{float(weights['edgeWeight']):.3f} * edgeF1 + "
                f"{float(weights['colorWeight']):.3f} * max(0, 1 - meanDeltaE/{float(weights['colorDeltaEReference']):.3f}))"
            ),
        },
        "anomalies": anomalies,
        "warnings": warnings,
        "outputs": {
            "silhouetteError": str(silhouette_error_path),
            "edgeError": str(edge_error_path),
            "colorError": str(color_error_path),
            "anomalyMap": str(anomaly_map_path),
        },
    }
    report_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    payload["reportPath"] = str(report_path)
    return payload


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Visual QA Asset Factory")
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare-reference")
    prepare.add_argument("--reference", required=True)
    prepare.add_argument("--output-dir", required=True)
    prepare.add_argument("--config")

    analyze_parser = subparsers.add_parser("analyze")
    analyze_parser.add_argument("--reference", required=True)
    analyze_parser.add_argument("--reference-mask", required=True)
    analyze_parser.add_argument("--beauty", required=True)
    analyze_parser.add_argument("--silhouette", required=True)
    analyze_parser.add_argument("--clay", required=True)
    analyze_parser.add_argument("--albedo", required=True)
    analyze_parser.add_argument("--camera", required=True)
    analyze_parser.add_argument("--output-dir", required=True)
    analyze_parser.add_argument("--report", required=True)
    analyze_parser.add_argument("--config")
    return parser


def main() -> int:
    args = _build_parser().parse_args()
    config = load_config(args.config)
    if args.command == "prepare-reference":
        result = prepare_reference(args.reference, args.output_dir, config)
    else:
        result = analyze(
            args.reference,
            args.reference_mask,
            args.beauty,
            args.silhouette,
            args.clay,
            args.albedo,
            args.camera,
            args.output_dir,
            args.report,
            config,
        )
    print("[RESULT_JSON] " + json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
