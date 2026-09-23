"""Normalise un maillage statique Asset Factory sans modifier le dépôt du moteur.

Les anciens arguments OBJ -> OBJ + FBX restent pris en charge. TRELLIS utilise
GLB -> GLB, avec les matériaux/textures intégrés et la même politique de hauteur
cible et de centrage de la base.
"""

import argparse
import json
import math
import os
import struct
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Vector


def parse_args(argv=None):
    if argv is None:
        if "--" not in sys.argv:
            raise RuntimeError("Missing Blender script arguments after '--'.")
        argv = sys.argv[sys.argv.index("--") + 1:]

    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--fbx-output")
    parser.add_argument("--target-height", type=float, required=True)
    args = parser.parse_args(argv)

    if not math.isfinite(args.target_height) or args.target_height <= 0:
        raise ValueError("--target-height must be finite and greater than 0.")
    input_ext = Path(args.input).suffix.lower()
    output_ext = Path(args.output).suffix.lower()
    if input_ext not in (".obj", ".glb"):
        raise ValueError("--input must be an OBJ or GLB file.")
    if output_ext not in (".obj", ".glb"):
        raise ValueError("--output must be an OBJ or GLB file.")
    if input_ext == ".glb" and (output_ext != ".glb" or args.fbx_output):
        raise ValueError("Textured GLB input must remain GLB; no implicit conversion to OBJ/FBX.")
    if args.fbx_output and Path(args.fbx_output).suffix.lower() != ".fbx":
        raise ValueError("--fbx-output must end in .fbx.")
    targets = [Path(args.output).resolve()]
    if args.fbx_output:
        targets.append(Path(args.fbx_output).resolve())
    if Path(args.input).resolve() in targets or len(set(targets)) != len(targets):
        raise ValueError("Input and output paths must be distinct.")
    return args


def read_glb_json(path):
    """Valide l'enveloppe GLB et lit son JSON sans charger ses images."""
    path = Path(path)
    with path.open("rb") as handle:
        header = handle.read(12)
        if len(header) != 12:
            raise ValueError(f"Truncated GLB header: {path}")
        magic, version, length = struct.unpack("<4sII", header)
        if magic != b"glTF" or version != 2 or length != path.stat().st_size:
            raise ValueError(f"Invalid GLB 2.0 header or length: {path}")
        chunk_header = handle.read(8)
        if len(chunk_header) != 8:
            raise ValueError(f"Missing GLB JSON chunk: {path}")
        chunk_length, chunk_type = struct.unpack("<II", chunk_header)
        if chunk_type != 0x4E4F534A or chunk_length > length - 20:
            raise ValueError(f"Invalid GLB JSON chunk: {path}")
        return json.loads(handle.read(chunk_length).decode("utf-8").rstrip(" \x00"))




def glb_attribute_accessor_counts(document, attribute_name):
    """Return accessor counts for an attribute across every GLB primitive."""
    counts = []
    accessors = document.get("accessors", []) if document else []
    for mesh in (document or {}).get("meshes", []):
        for primitive in mesh.get("primitives", []):
            accessor_index = (primitive.get("attributes") or {}).get(attribute_name)
            if accessor_index is None:
                continue
            try:
                counts.append(int(accessors[int(accessor_index)].get("count", 0)))
            except (IndexError, KeyError, TypeError, ValueError):
                continue
    return counts


def glb_has_attribute(document, attribute_name):
    return bool(glb_attribute_accessor_counts(document, attribute_name))

def validate_glb_output(path, source_document=None):
    document = read_glb_json(path)
    if not document.get("meshes"):
        raise RuntimeError("Exported GLB contains no mesh.")
    for image in document.get("images", []):
        if "bufferView" not in image and not str(image.get("uri", "")).startswith("data:"):
            raise RuntimeError("Exported GLB refers to an external image instead of embedding it.")
    source_position_count = 0
    output_position_count = sum(glb_attribute_accessor_counts(document, "POSITION"))
    if source_document:
        for resource in ("materials", "textures", "images"):
            if source_document.get(resource) and not document.get(resource):
                raise RuntimeError(f"GLB export lost all {resource}; refusing to report success.")

        source_position_count = sum(glb_attribute_accessor_counts(source_document, "POSITION"))
        source_has_normals = glb_has_attribute(source_document, "NORMAL")
        source_has_texcoords = glb_has_attribute(source_document, "TEXCOORD_0")
        if (
            source_position_count > 0
            and not source_has_normals
            and not source_has_texcoords
            and output_position_count > source_position_count * 2
        ):
            raise RuntimeError(
                "Geometry-only GLB normalization exploded indexed topology: "
                f"POSITION count {source_position_count} -> {output_position_count}. "
                "Refusing to continue because downstream UV unwrapping would see "
                "almost one disconnected triangle per face."
            )

    return {
        "material_count": len(document.get("materials", [])),
        "texture_count": len(document.get("textures", [])),
        "image_count": len(document.get("images", [])),
        "source_position_count": source_position_count,
        "output_position_count": output_position_count,
    }


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 1.0


def get_world_corners(obj):
    return [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]


def get_scene_bounds(mesh_objects):
    corners = [corner for obj in mesh_objects for corner in get_world_corners(obj)]
    if not corners or any(not math.isfinite(value) for corner in corners for value in corner):
        raise RuntimeError("Could not calculate finite mesh bounds.")
    return {
        "min_x": min(corner.x for corner in corners),
        "max_x": max(corner.x for corner in corners),
        "min_y": min(corner.y for corner in corners),
        "max_y": max(corner.y for corner in corners),
        "min_z": min(corner.z for corner in corners),
        "max_z": max(corner.z for corner in corners),
    }


def prepare_mesh_objects(mesh_objects, preserve_normals=False):
    # Un GLB peut contenir des parents transformés et des instances. On capture
    # chaque matrice monde avant tout détachement et on copie les géométries partagées avant de les appliquer.
    matrices = {obj: obj.matrix_world.copy() for obj in mesh_objects}
    for obj in mesh_objects:
        if obj.data.users > 1:
            obj.data = obj.data.copy()
        obj.parent = None
        obj.data.transform(matrices[obj])
        obj.matrix_world = Matrix.Identity(4)
        if not preserve_normals:
            # bmesh fonctionne dans les versions modernes de Blender ; normals_make_consistent a été supprimé.
            bm = bmesh.new()
            try:
                bm.from_mesh(obj.data)
                bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
                bm.to_mesh(obj.data)
            finally:
                bm.free()
        obj.data.update()
    bpy.context.view_layer.update()


def normalize_meshes(mesh_objects, target_height, preserve_normals=False):
    if not math.isfinite(target_height) or target_height <= 0:
        raise ValueError("Target height must be finite and positive.")
    prepare_mesh_objects(mesh_objects, preserve_normals=preserve_normals)
    bounds = get_scene_bounds(mesh_objects)
    original_height = bounds["max_z"] - bounds["min_z"]
    if original_height <= 0:
        raise RuntimeError("Mesh height is zero or invalid.")
    scale_factor = target_height / original_height
    center_x = (bounds["min_x"] + bounds["max_x"]) / 2.0
    center_y = (bounds["min_y"] + bounds["max_y"]) / 2.0
    transform = Matrix.Scale(scale_factor, 4) @ Matrix.Translation(
        Vector((-center_x, -center_y, -bounds["min_z"]))
    )
    for obj in mesh_objects:
        # Les UV et emplacements de matériaux restent inchangés. Chaque origine de maillage conserve
        # le même centre global de base ; un import combiné ultérieur obtient ainsi un pivot cohérent.
        obj.data.transform(transform)
        obj.data.update()
        obj.matrix_world = Matrix.Identity(4)
    bpy.context.view_layer.update()
    final = get_scene_bounds(mesh_objects)
    final_height = final["max_z"] - final["min_z"]
    tolerance = max(1e-5, target_height * 1e-5)
    if abs(final_height - target_height) > tolerance or abs(final["min_z"]) > tolerance:
        raise RuntimeError("Normalized bounds do not match target height/base.")
    return {
        "requested_height_m": target_height,
        "original_height": original_height,
        "scale_factor": scale_factor,
        "final_height_m": final_height,
        "final_width_m": final["max_x"] - final["min_x"],
        "final_depth_m": final["max_y"] - final["min_y"],
        "base_z": final["min_z"],
        "pivot": "base-center",
        "normals_policy": "preserve" if preserve_normals else "recalculate",
    }


def ensure_output(path):
    if not os.path.isfile(path) or os.path.getsize(path) <= 0:
        raise RuntimeError(f"Blender did not create a non-empty output: {path}")


def main():
    args = parse_args()
    input_path = os.path.abspath(args.input)
    output_path = os.path.abspath(args.output)
    fbx_path = os.path.abspath(args.fbx_output) if args.fbx_output else None
    if not os.path.isfile(input_path):
        raise FileNotFoundError(f"Input mesh not found: {input_path}")
    source_is_glb = Path(input_path).suffix.lower() == ".glb"
    source_document = read_glb_json(input_path) if source_is_glb else None
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    if fbx_path:
        os.makedirs(os.path.dirname(fbx_path), exist_ok=True)
    clear_scene()
    if source_is_glb:
        bpy.ops.import_scene.gltf(filepath=input_path)
    else:
        bpy.ops.wm.obj_import(filepath=input_path)
    mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    if not mesh_objects or not any(len(obj.data.polygons) for obj in mesh_objects):
        raise RuntimeError("Input contains no static mesh faces.")
    result = normalize_meshes(mesh_objects, args.target_height, preserve_normals=source_is_glb)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in mesh_objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = mesh_objects[0]
    if Path(output_path).suffix.lower() == ".glb":
        # Preserve the source attribute contract. Geometry-only TRELLIS GLBs have
        # POSITION + indices but no NORMAL/TEXCOORD attributes. Exporting generated
        # flat normals here makes glTF duplicate vertices per triangle, turning an
        # indexed mesh into a visually identical but topologically disconnected
        # triangle soup. The multiview bake needs the original shared adjacency.
        export_normals = bool(source_document and glb_has_attribute(source_document, "NORMAL"))
        export_texcoords = bool(source_document and glb_has_attribute(source_document, "TEXCOORD_0"))
        bpy.ops.export_scene.gltf(
            filepath=output_path,
            export_format="GLB",
            use_selection=True,
            export_texcoords=export_texcoords,
            export_normals=export_normals,
            export_materials="EXPORT",
            export_animations=False,
            export_yup=True,
        )
        result["glb_export_normals"] = export_normals
        result["glb_export_texcoords"] = export_texcoords
        ensure_output(output_path)
        result.update(validate_glb_output(output_path, source_document))
        result["glb_output"] = output_path
    else:
        bpy.ops.wm.obj_export(filepath=output_path, export_selected_objects=True)
        ensure_output(output_path)
        result["obj_output"] = output_path
    if fbx_path:
        bpy.ops.export_scene.fbx(
            filepath=fbx_path,
            use_selection=True,
            apply_unit_scale=True,
            apply_scale_options="FBX_SCALE_ALL",
            axis_forward="-Y",
            axis_up="Z",
            bake_space_transform=False,
            add_leaf_bones=False,
        )
        ensure_output(fbx_path)
        result["fbx_output"] = fbx_path
    result["output"] = output_path
    result["format"] = Path(output_path).suffix.lower().lstrip(".")
    print(f"[OK] Processed mesh objects: {len(mesh_objects)}")
    print("[OK] Mesh centered on X/Y; geometry base and all origins at Z=0")
    print(f"[OK] Final height: {result['final_height_m']:.6f} m")
    print(f"[OK] Output mesh: {output_path}")
    print("[RESULT_JSON] " + json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
