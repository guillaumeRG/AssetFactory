import argparse
import json
import os
import sys

import bpy
from mathutils import Vector


def parse_args():
    argv = sys.argv

    if "--" not in argv:
        raise RuntimeError("Missing Blender script arguments after '--'.")

    argv = argv[argv.index("--") + 1:]

    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--fbx-output", required=True)
    parser.add_argument("--target-height", type=float, required=True)

    args = parser.parse_args(argv)

    if args.target_height <= 0:
        raise ValueError("--target-height must be greater than 0.")

    return args


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)


def get_world_corners(obj):
    return [
        obj.matrix_world @ Vector(corner)
        for corner in obj.bound_box
    ]


def get_scene_bounds(mesh_objects):
    corners = []

    for obj in mesh_objects:
        corners.extend(get_world_corners(obj))

    if not corners:
        raise RuntimeError("Could not calculate mesh bounds.")

    return {
        "min_x": min(corner.x for corner in corners),
        "max_x": max(corner.x for corner in corners),
        "min_y": min(corner.y for corner in corners),
        "max_y": max(corner.y for corner in corners),
        "min_z": min(corner.z for corner in corners),
        "max_z": max(corner.z for corner in corners),
    }


def prepare_mesh_object(obj):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

    bpy.ops.object.transform_apply(
        location=False,
        rotation=True,
        scale=True
    )

    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")

    obj.select_set(False)


def normalize_meshes(mesh_objects, target_height):
    for obj in mesh_objects:
        prepare_mesh_object(obj)

    bpy.context.view_layer.update()

    bounds = get_scene_bounds(mesh_objects)
    current_height = bounds["max_z"] - bounds["min_z"]

    if current_height <= 0:
        raise RuntimeError("Mesh height is zero or invalid.")

    scale_factor = target_height / current_height

    # Uniformly scale geometry and relative object positions.
    for obj in mesh_objects:
        obj.location *= scale_factor
        obj.scale = tuple(value * scale_factor for value in obj.scale)

    bpy.context.view_layer.update()

    # Apply the new scale so exported transforms remain clean.
    for obj in mesh_objects:
        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
        bpy.ops.object.transform_apply(
            location=False,
            rotation=False,
            scale=True
        )
        obj.select_set(False)

    bpy.context.view_layer.update()

    # Center on X/Y and place the lowest point on Z = 0.
    bounds = get_scene_bounds(mesh_objects)

    center_x = (bounds["min_x"] + bounds["max_x"]) / 2.0
    center_y = (bounds["min_y"] + bounds["max_y"]) / 2.0
    min_z = bounds["min_z"]

    for obj in mesh_objects:
        obj.location.x -= center_x
        obj.location.y -= center_y
        obj.location.z -= min_z

    bpy.context.view_layer.update()

    # For the common single-object case, put the object's origin at the global
    # base center (0, 0, 0). The geometry remains in place.
    if len(mesh_objects) == 1:
        obj = mesh_objects[0]
        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
        bpy.context.scene.cursor.location = (0.0, 0.0, 0.0)
        bpy.ops.object.origin_set(
            type="ORIGIN_CURSOR",
            center="MEDIAN"
        )
        obj.select_set(False)

    bpy.context.view_layer.update()

    final_bounds = get_scene_bounds(mesh_objects)

    return {
        "requested_height_m": target_height,
        "original_height": current_height,
        "scale_factor": scale_factor,
        "final_height_m": final_bounds["max_z"] - final_bounds["min_z"],
        "final_width_m": final_bounds["max_x"] - final_bounds["min_x"],
        "final_depth_m": final_bounds["max_y"] - final_bounds["min_y"],
        "base_z": final_bounds["min_z"],
    }


def main():
    args = parse_args()

    input_path = os.path.abspath(args.input)
    output_path = os.path.abspath(args.output)
    fbx_output_path = os.path.abspath(args.fbx_output)

    if not os.path.isfile(input_path):
        raise FileNotFoundError(f"Input mesh not found: {input_path}")

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    os.makedirs(os.path.dirname(fbx_output_path), exist_ok=True)

    clear_scene()

    bpy.ops.wm.obj_import(filepath=input_path)

    mesh_objects = [
        obj for obj in bpy.context.scene.objects
        if obj.type == "MESH"
    ]

    if not mesh_objects:
        raise RuntimeError("No mesh object imported from OBJ.")

    bpy.ops.object.select_all(action="DESELECT")

    result = normalize_meshes(
        mesh_objects=mesh_objects,
        target_height=args.target_height
    )

    for obj in mesh_objects:
        obj.select_set(True)

    bpy.context.view_layer.objects.active = mesh_objects[0]

    bpy.ops.wm.obj_export(
        filepath=output_path,
        export_selected_objects=True
    )

    if not os.path.isfile(output_path):
        raise RuntimeError(f"Blender did not create output mesh: {output_path}")

    bpy.ops.export_scene.fbx(
        filepath=fbx_output_path,
        use_selection=True,
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_ALL",
        axis_forward="-Y",
        axis_up="Z",
        bake_space_transform=False,
        add_leaf_bones=False
    )

    if not os.path.isfile(fbx_output_path):
        raise RuntimeError(f"Blender did not create FBX output: {fbx_output_path}")

    result["obj_output"] = output_path
    result["fbx_output"] = fbx_output_path

    print(f"[OK] Processed mesh objects: {len(mesh_objects)}")
    print("[OK] Transformations applied")
    print("[OK] Normals recalculated")
    print("[OK] Mesh centered on X/Y")
    print("[OK] Pivot placed at mesh base")
    print(f"[OK] Target height: {result['requested_height_m']:.6f} m")
    print(f"[OK] Final height: {result['final_height_m']:.6f} m")
    print(f"[OK] Output mesh: {output_path}")
    print(f"[OK] FBX output: {fbx_output_path}")
    print("[RESULT_JSON] " + json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
