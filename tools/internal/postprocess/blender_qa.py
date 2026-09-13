"""Rendus de controle et recherche de camera pour le Visual QA Asset Factory.

Ce script est execute par Blender en mode headless. Il ne modifie pas le
fichier source : la scene existe uniquement le temps de l'analyse.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import sys

import bpy
from mathutils import Vector


def parse_args() -> argparse.Namespace:
    argv = sys.argv
    if "--" in argv:
        argv = argv[argv.index("--") + 1 :]
    else:
        argv = []
    parser = argparse.ArgumentParser()
    parser.add_argument("--mesh", required=True)
    parser.add_argument("--reference-mask", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--camera-output", required=True)
    parser.add_argument("--config", required=True)
    return parser.parse_args(argv)


def load_config(path: str) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.cameras, bpy.data.lights):
        # Les donnees orphelines ne sont pas toutes supprimables pendant l'iteration.
        for block in list(datablocks):
            if block.users == 0:
                datablocks.remove(block)


def import_mesh(path: str) -> list:
    ext = Path(path).suffix.lower()
    if ext == ".glb" or ext == ".gltf":
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".obj":
        if hasattr(bpy.ops.wm, "obj_import"):
            bpy.ops.wm.obj_import(filepath=path)
        else:
            bpy.ops.import_scene.obj(filepath=path)
    elif ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    else:
        raise ValueError(f"Format de mesh QA non pris en charge : {ext}")
    meshes = [obj for obj in bpy.context.scene.objects if obj.type == "MESH" and len(obj.data.polygons)]
    if not meshes:
        raise RuntimeError("Le mesh QA ne contient aucune face exploitable.")
    return meshes


def world_bounds(meshes: list) -> tuple[Vector, Vector, Vector, float]:
    corners = [obj.matrix_world @ Vector(corner) for obj in meshes for corner in obj.bound_box]
    minimum = Vector((min(v.x for v in corners), min(v.y for v in corners), min(v.z for v in corners)))
    maximum = Vector((max(v.x for v in corners), max(v.y for v in corners), max(v.z for v in corners)))
    center = (minimum + maximum) * 0.5
    radius = max((corner - center).length for corner in corners)
    if not math.isfinite(radius) or radius <= 0:
        raise RuntimeError("Bornes du mesh invalides pour le Visual QA.")
    return minimum, maximum, center, radius


def set_render_engine(scene) -> str:
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            scene.render.engine = engine
            return engine
        except Exception:
            continue
    raise RuntimeError("Aucun moteur Eevee compatible n'est disponible dans Blender.")


def configure_render(scene, size: int) -> None:
    set_render_engine(scene)
    scene.render.resolution_x = size
    scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.render.use_file_extension = True
    try:
        scene.view_settings.view_transform = "Standard"
    except Exception:
        pass
    scene.view_settings.exposure = 0.0
    scene.view_settings.gamma = 1.0


def set_world_color(scene, color: tuple[float, float, float]) -> None:
    scene.world.use_nodes = False
    scene.world.color = color


def make_emission_material(name: str, color=(1.0, 1.0, 1.0, 1.0)):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    emission = nodes.new("ShaderNodeEmission")
    emission.inputs["Color"].default_value = color
    emission.inputs["Strength"].default_value = 1.0
    links.new(emission.outputs["Emission"], output.inputs["Surface"])
    return material


def make_clay_material():
    material = bpy.data.materials.new("AF_QA_Clay")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    shader = nodes.new("ShaderNodeBsdfPrincipled")
    shader.inputs["Base Color"].default_value = (0.55, 0.55, 0.55, 1.0)
    if shader.inputs.get("Roughness"):
        shader.inputs["Roughness"].default_value = 0.8
    links.new(shader.outputs[0], output.inputs["Surface"])
    return material


def make_normal_material():
    material = bpy.data.materials.new("AF_QA_Normal")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    geometry = nodes.new("ShaderNodeNewGeometry")
    multiply = nodes.new("ShaderNodeVectorMath")
    multiply.operation = "MULTIPLY"
    multiply.inputs[1].default_value = (0.5, 0.5, 0.5)
    add = nodes.new("ShaderNodeVectorMath")
    add.operation = "ADD"
    add.inputs[1].default_value = (0.5, 0.5, 0.5)
    emission = nodes.new("ShaderNodeEmission")
    links.new(geometry.outputs["Normal"], multiply.inputs[0])
    links.new(multiply.outputs[0], add.inputs[0])
    links.new(add.outputs[0], emission.inputs["Color"])
    links.new(emission.outputs["Emission"], output.inputs["Surface"])
    return material


def make_depth_material(near_value: float, far_value: float):
    material = bpy.data.materials.new("AF_QA_Depth")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    camera = nodes.new("ShaderNodeCameraData")
    mapper = nodes.new("ShaderNodeMapRange")
    mapper.inputs["From Min"].default_value = float(near_value)
    mapper.inputs["From Max"].default_value = float(max(far_value, near_value + 0.001))
    mapper.inputs["To Min"].default_value = 1.0
    mapper.inputs["To Max"].default_value = 0.0
    try:
        mapper.clamp = True
    except Exception:
        pass
    emission = nodes.new("ShaderNodeEmission")
    depth_output = camera.outputs.get("View Z Depth") or camera.outputs.get("View Distance")
    if depth_output is None:
        raise RuntimeError("Sortie de profondeur Camera Data indisponible dans cette version de Blender.")
    links.new(depth_output, mapper.inputs["Value"])
    links.new(mapper.outputs["Result"], emission.inputs["Color"])
    links.new(emission.outputs["Emission"], output.inputs["Surface"])
    return material


def make_albedo_material(source):
    if source is None:
        return make_emission_material("AF_QA_Albedo_Fallback", (0.5, 0.5, 0.5, 1.0))

    material = source.copy()
    material.name = "AF_QA_Albedo_" + source.name
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    output = next((node for node in nodes if node.type == "OUTPUT_MATERIAL" and getattr(node, "is_active_output", True)), None)
    if output is None:
        output = nodes.new("ShaderNodeOutputMaterial")
    principled = next((node for node in nodes if node.type == "BSDF_PRINCIPLED"), None)
    emission = nodes.new("ShaderNodeEmission")
    emission.inputs["Strength"].default_value = 1.0

    if principled is not None and principled.inputs.get("Base Color") is not None:
        base = principled.inputs["Base Color"]
        if base.is_linked:
            links.new(base.links[0].from_socket, emission.inputs["Color"])
        else:
            emission.inputs["Color"].default_value = tuple(base.default_value)
    else:
        emission.inputs["Color"].default_value = tuple(source.diffuse_color)

    links.new(emission.outputs["Emission"], output.inputs["Surface"])
    return material


def create_camera(scene):
    data = bpy.data.cameras.new("AF_QA_Camera")
    camera = bpy.data.objects.new("AF_QA_Camera", data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    data.type = "PERSP"
    data.sensor_fit = "VERTICAL"
    return camera


def aim_camera(camera, target: Vector, azimuth: float, elevation: float, distance: float, lens: float, roll: float = 0.0) -> None:
    az = math.radians(azimuth)
    el = math.radians(elevation)
    direction = Vector((math.cos(el) * math.cos(az), math.cos(el) * math.sin(az), math.sin(el)))
    camera.location = target + direction * distance
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
    if abs(roll) > 1e-9:
        camera.rotation_euler.rotate_axis("Z", math.radians(roll))
    camera.data.lens = lens


def load_mask_pixels(path: str) -> tuple[list[bool], int, int, dict]:
    image = bpy.data.images.load(path, check_existing=False)
    width, height = image.size
    pixels = list(image.pixels[:])
    mask = []
    xs = []
    ys = []
    for index in range(width * height):
        value = max(pixels[index * 4], pixels[index * 4 + 1], pixels[index * 4 + 2]) >= 0.5
        mask.append(value)
        if value:
            x = index % width
            y = index // width
            xs.append(x)
            ys.append(y)
    bpy.data.images.remove(image)
    if xs:
        bbox = [min(xs), min(ys), max(xs) + 1, max(ys) + 1]
        center = [sum(xs) / len(xs), sum(ys) / len(ys)]
        occupancy = len(xs) / float(width * height)
    else:
        bbox = [0, 0, width, height]
        center = [width / 2.0, height / 2.0]
        occupancy = 0.0
    return mask, width, height, {"bbox": bbox, "center": center, "occupancy": occupancy}


def render_result_mask(scene) -> list[bool]:
    bpy.ops.render.render(write_still=False)
    image = bpy.data.images.get("Render Result")
    if image is None:
        raise RuntimeError("Blender n'a retourne aucun Render Result.")
    pixels = list(image.pixels[:])
    return [max(pixels[i], pixels[i + 1], pixels[i + 2]) >= 0.5 for i in range(0, len(pixels), 4)]


def mask_stats(mask: list[bool], width: int, height: int) -> dict:
    indices = [index for index, value in enumerate(mask) if value]
    if not indices:
        return {"bbox": [0, 0, width, height], "center": [width / 2.0, height / 2.0], "occupancy": 0.0}
    xs = [index % width for index in indices]
    ys = [index // width for index in indices]
    return {
        "bbox": [min(xs), min(ys), max(xs) + 1, max(ys) + 1],
        "center": [sum(xs) / len(xs), sum(ys) / len(ys)],
        "occupancy": len(indices) / float(width * height),
    }


def camera_score(reference: list[bool], rendered: list[bool], width: int, height: int, ref_stats: dict) -> tuple[float, dict]:
    intersection = sum(a and b for a, b in zip(reference, rendered))
    union = sum(a or b for a, b in zip(reference, rendered))
    iou = intersection / union if union else 1.0
    stats = mask_stats(rendered, width, height)

    ref_box = ref_stats["bbox"]
    box = stats["bbox"]
    ref_w = max(1, ref_box[2] - ref_box[0])
    ref_h = max(1, ref_box[3] - ref_box[1])
    box_w = max(1, box[2] - box[0])
    box_h = max(1, box[3] - box[1])
    bbox_similarity = max(0.0, 1.0 - 0.5 * abs(box_w - ref_w) / width - 0.5 * abs(box_h - ref_h) / height)
    center_distance = math.hypot(stats["center"][0] - ref_stats["center"][0], stats["center"][1] - ref_stats["center"][1])
    center_similarity = max(0.0, 1.0 - center_distance / math.hypot(width, height))
    occupancy_similarity = max(0.0, 1.0 - abs(stats["occupancy"] - ref_stats["occupancy"]))
    score = 0.60 * iou + 0.20 * bbox_similarity + 0.15 * center_similarity + 0.05 * occupancy_similarity
    return score, {
        "iou": iou,
        "bboxSimilarity": bbox_similarity,
        "centerSimilarity": center_similarity,
        "occupancySimilarity": occupancy_similarity,
        "renderedBbox": stats["bbox"],
        "renderedCenter": stats["center"],
        "renderedOccupancy": stats["occupancy"],
    }


def camera_distance(camera, radius: float, desired_fill: float) -> float:
    half_fov = max(0.05, camera.data.angle_y * 0.5)
    fill = min(0.90, max(0.20, desired_fill))
    distance = radius / max(0.03, fill * math.tan(half_fov))
    return max(radius * 1.25, distance * 1.10)


def find_camera(scene, camera, target, radius: float, reference_mask: list[bool], width: int, height: int, ref_stats: dict, config: dict) -> dict:
    settings = config["cameraMatch"]
    scene.view_layers[0].material_override = make_emission_material("AF_QA_Search", (1.0, 1.0, 1.0, 1.0))
    set_world_color(scene, (0.0, 0.0, 0.0))
    configure_render(scene, int(settings["searchResolution"]))

    desired_fill = max(
        (ref_stats["bbox"][2] - ref_stats["bbox"][0]) / width,
        (ref_stats["bbox"][3] - ref_stats["bbox"][1]) / height,
    )
    candidates = []
    step = float(settings["coarseAzimuthStep"])
    elevations = [float(value) for value in settings["coarseElevations"]]
    coarse_lens = float(settings["coarseLens"])

    azimuth = 0.0
    while azimuth < 360.0 - 1e-6:
        for elevation in elevations:
            camera.data.lens = coarse_lens
            distance = camera_distance(camera, radius, desired_fill)
            aim_camera(camera, target, azimuth, elevation, distance, coarse_lens)
            rendered = render_result_mask(scene)
            score, breakdown = camera_score(reference_mask, rendered, width, height, ref_stats)
            candidates.append({"azimuth": azimuth, "elevation": elevation, "roll": 0.0, "lens": coarse_lens, "distance": distance, "score": score, "breakdown": breakdown})
        azimuth += step

    best = max(candidates, key=lambda item: item["score"])
    refine_azimuth = [float(value) for value in settings["refineAzimuthOffsets"]]
    refine_elevation = [float(value) for value in settings["refineElevationOffsets"]]
    lenses = [float(value) for value in settings["refineLenses"]]
    refined = []
    seen = set()
    for az_offset in refine_azimuth:
        for el_offset in refine_elevation:
            for lens in lenses:
                az = (best["azimuth"] + az_offset) % 360.0
                el = max(-75.0, min(75.0, best["elevation"] + el_offset))
                key = (round(az, 4), round(el, 4), round(lens, 4))
                if key in seen:
                    continue
                seen.add(key)
                camera.data.lens = lens
                distance = camera_distance(camera, radius, desired_fill)
                aim_camera(camera, target, az, el, distance, lens)
                rendered = render_result_mask(scene)
                score, breakdown = camera_score(reference_mask, rendered, width, height, ref_stats)
                refined.append({"azimuth": az, "elevation": el, "roll": 0.0, "lens": lens, "distance": distance, "score": score, "breakdown": breakdown})

    if refined:
        best_refined = max(refined, key=lambda item: item["score"])
        if best_refined["score"] >= best["score"]:
            best = best_refined

    # Ajuste la distance des meilleurs candidats a partir du cadrage reel rendu.
    distance_refined = []
    current_pool = sorted(candidates + refined, key=lambda item: item["score"], reverse=True)[:5]
    for candidate in current_pool:
        box = candidate["breakdown"].get("renderedBbox", [0, 0, width, height])
        rendered_fill = max((box[2] - box[0]) / width, (box[3] - box[1]) / height)
        if rendered_fill <= 0.01:
            continue
        factor = max(0.70, min(1.40, rendered_fill / max(desired_fill, 0.05)))
        adjusted_distance = candidate["distance"] * factor
        aim_camera(camera, target, candidate["azimuth"], candidate["elevation"], adjusted_distance, candidate["lens"], candidate.get("roll", 0.0))
        rendered = render_result_mask(scene)
        score, breakdown = camera_score(reference_mask, rendered, width, height, ref_stats)
        distance_refined.append({
            "azimuth": candidate["azimuth"],
            "elevation": candidate["elevation"],
            "roll": candidate.get("roll", 0.0),
            "lens": candidate["lens"],
            "distance": adjusted_distance,
            "score": score,
            "breakdown": breakdown,
        })

    if distance_refined:
        candidate = max(distance_refined, key=lambda item: item["score"])
        if candidate["score"] >= best["score"]:
            best = candidate

    # Petit raffinement du roll sans multiplier la grille de recherche.
    roll_refined = []
    for roll in [float(value) for value in settings.get("refineRollOffsets", [0.0])]:
        aim_camera(camera, target, best["azimuth"], best["elevation"], best["distance"], best["lens"], roll)
        rendered = render_result_mask(scene)
        score, breakdown = camera_score(reference_mask, rendered, width, height, ref_stats)
        roll_refined.append({
            "azimuth": best["azimuth"],
            "elevation": best["elevation"],
            "roll": roll,
            "lens": best["lens"],
            "distance": best["distance"],
            "score": score,
            "breakdown": breakdown,
        })
    if roll_refined:
        candidate = max(roll_refined, key=lambda item: item["score"])
        if candidate["score"] >= best["score"]:
            best = candidate

    all_candidates = sorted(candidates + refined + distance_refined + roll_refined, key=lambda item: item["score"], reverse=True)
    result = dict(best)
    result["topCandidates"] = all_candidates[:10]
    result["candidateCount"] = len(all_candidates)
    return result


def clear_lights(scene) -> None:
    for obj in list(scene.objects):
        if obj.type == "LIGHT":
            bpy.data.objects.remove(obj, do_unlink=True)


def add_area_light(scene, name: str, location: tuple[float, float, float], energy: float, size: float, target: Vector) -> None:
    data = bpy.data.lights.new(name, "AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    obj = bpy.data.objects.new(name, data)
    scene.collection.objects.link(obj)
    obj.location = Vector(location)
    obj.rotation_euler = (target - obj.location).to_track_quat("-Z", "Y").to_euler()


def setup_lighting(scene, target: Vector, radius: float) -> None:
    clear_lights(scene)
    add_area_light(scene, "AF_QA_Key", (target.x + radius * 2.5, target.y - radius * 2.0, target.z + radius * 2.8), 900.0, radius * 2.0, target)
    add_area_light(scene, "AF_QA_Fill", (target.x - radius * 2.2, target.y - radius * 1.0, target.z + radius * 1.5), 450.0, radius * 2.5, target)
    add_area_light(scene, "AF_QA_Rim", (target.x, target.y + radius * 2.5, target.z + radius * 2.0), 650.0, radius * 1.5, target)


def render_to(scene, path: Path) -> None:
    scene.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)
    if not path.is_file() or path.stat().st_size <= 0:
        raise RuntimeError(f"Rendu QA manquant : {path}")


def render_passes(scene, meshes: list, camera, target: Vector, radius: float, camera_match: dict, output_dir: Path, size: int) -> dict:
    output_dir.mkdir(parents=True, exist_ok=True)
    configure_render(scene, size)
    aim_camera(
        camera,
        target,
        camera_match["azimuth"],
        camera_match["elevation"],
        camera_match["distance"],
        camera_match["lens"],
        camera_match.get("roll", 0.0),
    )
    view_layer = scene.view_layers[0]
    outputs = {}

    setup_lighting(scene, target, radius)
    set_world_color(scene, (0.08, 0.08, 0.08))
    view_layer.material_override = None
    beauty = output_dir / "beauty.png"
    render_to(scene, beauty)
    outputs["beauty"] = str(beauty)

    set_world_color(scene, (0.0, 0.0, 0.0))
    view_layer.material_override = make_emission_material("AF_QA_Silhouette", (1.0, 1.0, 1.0, 1.0))
    silhouette = output_dir / "silhouette.png"
    render_to(scene, silhouette)
    outputs["silhouette"] = str(silhouette)

    set_world_color(scene, (0.08, 0.08, 0.08))
    view_layer.material_override = make_clay_material()
    clay = output_dir / "clay.png"
    render_to(scene, clay)
    outputs["clay"] = str(clay)

    # Albedo : remplace temporairement chaque materiau par une emission issue de sa Base Color.
    view_layer.material_override = None
    originals = []
    material_cache = {}
    try:
        for obj in meshes:
            object_materials = []
            for slot in obj.material_slots:
                original = slot.material
                object_materials.append(original)
                key = original.name_full if original else "__none__"
                if key not in material_cache:
                    material_cache[key] = make_albedo_material(original)
                slot.material = material_cache[key]
            originals.append((obj, object_materials))
        set_world_color(scene, (0.0, 0.0, 0.0))
        albedo = output_dir / "albedo.png"
        render_to(scene, albedo)
        outputs["albedo"] = str(albedo)
    finally:
        for obj, materials in originals:
            for slot, material in zip(obj.material_slots, materials):
                slot.material = material

    view_layer.material_override = make_normal_material()
    normal = output_dir / "normal.png"
    render_to(scene, normal)
    outputs["normal"] = str(normal)

    near_value = max(0.001, camera_match["distance"] - radius * 1.5)
    far_value = camera_match["distance"] + radius * 1.5
    view_layer.material_override = make_depth_material(near_value, far_value)
    depth = output_dir / "depth.png"
    render_to(scene, depth)
    outputs["depth"] = str(depth)

    view_layer.material_override = None
    return outputs


def main() -> int:
    args = parse_args()
    mesh_path = str(Path(args.mesh).resolve())
    reference_mask_path = str(Path(args.reference_mask).resolve())
    output_dir = Path(args.output_dir).resolve()
    camera_output = Path(args.camera_output).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    camera_output.parent.mkdir(parents=True, exist_ok=True)
    config = load_config(args.config)

    clear_scene()
    meshes = import_mesh(mesh_path)
    minimum, maximum, center, radius = world_bounds(meshes)
    scene = bpy.context.scene
    camera = create_camera(scene)

    reference_mask, width, height, ref_stats = load_mask_pixels(reference_mask_path)
    search_size = int(config["cameraMatch"]["searchResolution"])
    if width != search_size or height != search_size:
        raise ValueError(f"Le masque de recherche doit mesurer {search_size}x{search_size}, recu {width}x{height}.")

    match = find_camera(scene, camera, center, radius, reference_mask, width, height, ref_stats, config)
    match.update(
        {
            "schemaVersion": 1,
            "meshPath": mesh_path,
            "referenceMaskPath": reference_mask_path,
            "target": [center.x, center.y, center.z],
            "bounds": {"min": list(minimum), "max": list(maximum), "radius": radius},
        }
    )

    outputs = render_passes(scene, meshes, camera, center, radius, match, output_dir, int(config["qa"]["renderSize"]))
    match["renders"] = outputs
    camera_output.write_text(json.dumps(match, indent=2), encoding="utf-8")

    print(f"[OK] Visual QA camera score: {match['score']:.4f}")
    print(f"[OK] Visual QA renders: {output_dir}")
    print("[RESULT_JSON] " + json.dumps(match, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
