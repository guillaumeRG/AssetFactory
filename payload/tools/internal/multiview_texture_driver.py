"""AssetFactory multiview projection/texturing driver.

The adapter only orchestrates multiview. Camera placement, SDXL generation,
depth rendering, sequential projection/blending and baking are executed by
multiview's own Blender operators.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
import time
import traceback
from datetime import datetime
from pathlib import Path
from urllib.request import urlopen


def _argv() -> list[str]:
    if "--" not in sys.argv:
        return []
    return sys.argv[sys.argv.index("--") + 1 :]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    cli = parser.parse_args(_argv())
    config_path = Path(cli.config).resolve()
    data = json.loads(config_path.read_text(encoding="utf-8-sig"))
    required = ("mesh", "run_root", "python_deps")
    missing = [k for k in required if not data.get(k)]
    if missing:
        raise RuntimeError("Missing launch config field(s): " + ", ".join(missing))

    defaults = {
        "server": "127.0.0.1:8188",
        "checkpoint": "RealVisXL_V5.0_fp16.safetensors",
        "prompt": "realistic textured object",
        "negative_prompt": "",
        "seed": 42,
        "num_cameras": 4,
        "texture_resolution": 2048,
        "mesh_regex": ".*",
        "exclude_mesh_names": [],
        "final_blend": "",
        "final_glb": "",
        "keep_projected_blend": False,
    }
    for key, value in defaults.items():
        data.setdefault(key, value)

    data["seed"] = int(data["seed"])
    data["num_cameras"] = int(data["num_cameras"])
    data["texture_resolution"] = int(data["texture_resolution"])
    if data["num_cameras"] < 1 or data["num_cameras"] > 100:
        raise RuntimeError("num_cameras must be between 1 and 100")

    raw_asset_name = str(data.get("asset_name") or Path(data["mesh"]).stem)
    asset_name = re.sub(r"[^A-Za-z0-9._-]+", "_", raw_asset_name).strip("._-")
    data["asset_name"] = asset_name or "asset"
    return argparse.Namespace(**data)


ARGS = parse_args()
RUN_ROOT = Path(ARGS.run_root).resolve()
RESULT_PATH = RUN_ROOT / "multiview-result.json"
RUN_ROOT.mkdir(parents=True, exist_ok=True)

_DEPS = str(Path(ARGS.python_deps).resolve())
if _DEPS not in sys.path:
    sys.path.insert(0, _DEPS)

import addon_utils  # type: ignore  # noqa: E402
import bpy  # type: ignore  # noqa: E402


def log(message: str) -> None:
    print(f"[AF/MULTIVIEW] {message}", flush=True)


def write_result(status: str, **extra) -> None:
    payload = {
        "status": status,
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        **extra,
    }
    RESULT_PATH.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )


def fail(message: str, exc: BaseException | None = None) -> None:
    details = {"error": message}
    if exc is not None:
        details["exception"] = repr(exc)
        details["traceback"] = traceback.format_exc()
    log(f"FAILED: {message}")
    write_result("failed", **details)
    try:
        bpy.ops.wm.quit_blender()
    except Exception:
        pass


def get_json(endpoint: str):
    with urlopen(f"http://{ARGS.server}{endpoint}", timeout=15) as response:
        return json.loads(response.read().decode("utf-8"))


def clear_scene_for_import() -> None:
    if bpy.context.mode != "OBJECT":
        try:
            bpy.ops.object.mode_set(mode="OBJECT")
        except Exception:
            pass
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)


def load_source(path: Path) -> None:
    """Open/import a supported 3D asset into Blender."""
    suffix = path.suffix.lower()
    log(f"Loading source asset: {path}")

    if suffix == ".blend":
        bpy.ops.wm.open_mainfile(filepath=str(path))
        return

    clear_scene_for_import()
    if suffix == ".obj":
        bpy.ops.wm.obj_import(filepath=str(path))
    elif suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path))
    elif suffix in {".glb", ".gltf"}:
        bpy.ops.import_scene.gltf(filepath=str(path))
    elif suffix == ".stl":
        bpy.ops.wm.stl_import(filepath=str(path))
    else:
        raise RuntimeError(
            f"Unsupported asset format: {suffix}. "
            "Supported: .blend, .obj, .fbx, .glb, .gltf, .stl"
        )


def enable_assettexturing() -> None:
    addon_utils.enable("assettexturing", default_set=True, persistent=False)
    if "assettexturing" not in bpy.context.preferences.addons:
        raise RuntimeError(
            "multiview addon preferences are unavailable after enabling the vendor addon."
        )
    import assettexturing  # noqa: F401
    log("Vendored multiview enabled.")


def view3d_override() -> dict:
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type != "VIEW_3D":
                continue
            for region in area.regions:
                if region.type == "WINDOW":
                    return {"window": window, "area": area, "region": region}
    raise RuntimeError(
        "multiview requires a VIEW_3D UI context for its modal operators."
    )


def apply_original_assettexturing_modifiers() -> None:
    """Run multiview's mesh-preparation operator before texturing.

    Blender refuses to apply modifiers when several objects share the same Mesh
    datablock (multi-user data). Detach only those modifier-bearing meshes first.
    The source asset on disk is never overwritten.
    """
    detached = []
    for obj in bpy.context.scene.objects:
        if obj.type == "MESH" and obj.modifiers and obj.data and obj.data.users > 1:
            users_before = obj.data.users
            obj.data = obj.data.copy()
            detached.append((obj.name, users_before))

    if detached:
        log(
            "Made modifier-bearing multi-user meshes single-user in working copy: "
            + ", ".join(f"{name} (users={users})" for name, users in detached)
        )

    log(
        "Applying modifiers with vendored projection operator: "
        "object.apply_all_mesh_modifiers..."
    )
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    override = view3d_override()
    with bpy.context.temp_override(**override):
        result = bpy.ops.object.apply_all_mesh_modifiers("EXEC_DEFAULT")
    if "FINISHED" not in result:
        raise RuntimeError(
            f"mesh modifier application failed: {sorted(result)}"
        )
    log("mesh modifier application: FINISHED.")


def collect_targets(pattern: str, exclude_names) -> tuple[list, list]:
    rx = re.compile(pattern, re.IGNORECASE)
    excluded_names = {str(name) for name in (exclude_names or [])}
    targets = []
    excluded = []

    for obj in bpy.context.view_layer.objects:
        if obj.type != "MESH" or obj.hide_get() or not rx.search(obj.name):
            continue
        if obj.name in excluded_names:
            excluded.append(obj)
            continue
        targets.append(obj)

    if not targets:
        raise RuntimeError(
            f"No visible mesh matched {pattern!r} "
            f"after exclusions {sorted(excluded_names)!r}."
        )
    return targets, excluded


def collect_projection_risks(targets) -> list[dict]:
    """Record transforms/constraints/modifiers that may affect projection."""
    risks = []
    for obj in targets:
        non_unit_scale = any(abs(float(v) - 1.0) > 1e-4 for v in obj.scale)
        constraints = [c.name for c in obj.constraints]
        modifiers = [m.name for m in obj.modifiers]
        if non_unit_scale or constraints or modifiers:
            risks.append(
                {
                    "object": obj.name,
                    "scale": [float(v) for v in obj.scale],
                    "constraints": constraints,
                    "modifiers": modifiers,
                }
            )
    return risks


def select_only(objects) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.hide_set(False)
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]


def configure_assettexturing() -> None:
    from assettexturing.core import state
    from assettexturing.core.server_api import check_server_availability

    prefs = bpy.context.preferences.addons["assettexturing"].preferences
    prefs.server_address = ARGS.server
    prefs.output_dir = str(RUN_ROOT / "assettexturing-output")
    Path(prefs.output_dir).mkdir(parents=True, exist_ok=True)
    prefs.save_blend_file = False

    if not check_server_availability(ARGS.server, timeout=3.0):
        raise RuntimeError(f"ComfyUI is not reachable at {ARGS.server}")
    prefs.server_online = True

    checkpoints = get_json("/models/checkpoints")
    loras = get_json("/models/loras")
    controlnets = get_json("/models/controlnet")

    required_lora = "sdxl_lightning_8step_lora.safetensors"
    required_cn = "controlnet_depth_sdxl.safetensors"
    missing = []
    if ARGS.checkpoint not in checkpoints:
        missing.append(f"checkpoint:{ARGS.checkpoint}")
    if required_lora not in loras:
        missing.append(f"lora:{required_lora}")
    if required_cn not in controlnets:
        missing.append(f"controlnet:{required_cn}")
    if missing:
        raise RuntimeError("Missing ComfyUI model(s): " + ", ".join(missing))

    state._cached_checkpoint_list = [
        (n, n, f"Checkpoint: {n}") for n in sorted(checkpoints)
    ]
    state._cached_checkpoint_architecture = "sdxl"
    state._cached_lora_list = [(n, n, f"LoRA: {n}") for n in sorted(loras)]

    prefs.controlnet_model_mappings.clear()
    for name in sorted(controlnets):
        item = prefs.controlnet_model_mappings.add()
        item.name = name
        item.supports_depth = name == required_cn

    scene = bpy.context.scene
    scene.assettexturing_preset = "DEFAULT"
    result = bpy.ops.assettexturing.apply_preset()
    if "CANCELLED" in result:
        raise RuntimeError("multiview DEFAULT preset could not be applied.")

    # Keep multiview's stock DEFAULT preset intact and only supply job inputs.
    scene.model_name = ARGS.checkpoint
    scene.sg_model_name_backup = ARGS.checkpoint
    scene.comfyui_prompt = ARGS.prompt
    scene.comfyui_negative_prompt = ARGS.negative_prompt
    scene.seed = ARGS.seed
    scene.control_after_generate = "fixed"
    scene.texture_objects = "selected"
    scene.pbr_decomposition = False

    if scene.model_architecture != "sdxl":
        raise RuntimeError(
            f"multiview DEFAULT architecture changed unexpectedly: "
            f"{scene.model_architecture}"
        )
    if scene.generation_method != "sequential":
        raise RuntimeError(
            f"multiview DEFAULT generation method changed unexpectedly: "
            f"{scene.generation_method}"
        )
    if bool(scene.sequential_ipadapter):
        raise RuntimeError(
            "multiview DEFAULT unexpectedly requires sequential IPAdapter "
            "in this vendor revision."
        )
    if (
        len(scene.controlnet_units) != 1
        or scene.controlnet_units[0].unit_type != "depth"
    ):
        raise RuntimeError(
            "multiview DEFAULT did not configure exactly one Depth ControlNet unit."
        )
    if (
        len(scene.lora_units) != 1
        or scene.lora_units[0].model_name != required_lora
    ):
        raise RuntimeError(
            "multiview DEFAULT did not configure the expected SDXL Lightning LoRA."
        )


def create_cameras(targets):
    select_only(targets)
    override = view3d_override()
    log(f"Creating {ARGS.num_cameras} multiview camera(s)...")
    with bpy.context.temp_override(**override):
        result = bpy.ops.object.add_cameras(
            "EXEC_DEFAULT",
            placement_mode="normal_weighted",
            num_cameras=ARGS.num_cameras,
            purge_others=True,
            auto_aspect="per_camera",
            exclude_bottom=True,
            review_placement=False,
            occlusion_mode="none",
            auto_prompts=False,
        )
    if "CANCELLED" in result:
        raise RuntimeError("camera placement cancelled.")

    cameras = sorted(
        [obj for obj in bpy.context.scene.objects if obj.type == "CAMERA"],
        key=lambda obj: obj.name,
    )
    if not cameras:
        raise RuntimeError("camera placement produced no cameras.")
    log("generated cameras: " + ", ".join(cam.name for cam in cameras))
    return cameras


def launch_texturing(targets) -> None:
    select_only(targets)
    override = view3d_override()
    log("Starting original multiview generation operator...")
    with bpy.context.temp_override(**override):
        result = bpy.ops.object.test_stable("EXEC_DEFAULT")
    if "RUNNING_MODAL" not in result:
        raise RuntimeError(
            f"multiview texturing did not start: {sorted(result)}"
        )


def modal_active(bl_idname: str) -> bool:
    for window in bpy.context.window_manager.windows:
        for op in getattr(window, "modal_operators", []):
            if getattr(op, "bl_idname", "") == bl_idname:
                return True
    return False


def save_projected_snapshot(targets):
    """Optionally save the projection state before the final UV bake."""
    if not bool(ARGS.keep_projected_blend):
        return None

    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == "VIEW_3D":
                for space in area.spaces:
                    if space.type == "VIEW_3D":
                        space.shading.type = "MATERIAL"

    projected = RUN_ROOT / f"{ARGS.asset_name}_MULTIVIEW_PROJECTED.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(projected), copy=True)
    if not projected.is_file():
        raise RuntimeError(
            f"Projected multiview snapshot was not created: {projected}"
        )
    log(f"Saved pre-bake projection snapshot: {projected}")
    return projected


def _activate_bake_uv(obj) -> str | None:
    """Make the dedicated final-bake UV map explicit for material/export."""
    if not obj.data.uv_layers:
        return None

    layer = obj.data.uv_layers.get("BakeUV")
    if layer is None:
        return None

    obj.data.uv_layers.active = layer
    try:
        layer.active_render = True
    except Exception:
        pass
    return layer.name


def _uv_pair_close(left, right, epsilon: float = 1e-5) -> bool:
    return (
        abs(float(left[0]) - float(right[0])) <= epsilon
        and abs(float(left[1]) - float(right[1])) <= epsilon
    )


def _analyze_uv_islands(obj, uv_name: str) -> dict:
    """Count UV islands using mesh-edge continuity, without changing the mesh."""
    mesh = obj.data
    layer = mesh.uv_layers.get(uv_name)
    if layer is None:
        raise RuntimeError(f"UV map {uv_name!r} is missing on {obj.name}")

    face_count = len(mesh.polygons)
    if face_count == 0:
        return {
            "face_count": 0,
            "uv_island_count": 0,
            "single_face_island_count": 0,
            "island_ratio": 0.0,
            "single_face_ratio": 0.0,
        }

    parent = list(range(face_count))
    size = [1] * face_count

    def find(index: int) -> int:
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def union(left: int, right: int) -> None:
        a = find(left)
        b = find(right)
        if a == b:
            return
        if size[a] < size[b]:
            a, b = b, a
        parent[b] = a
        size[a] += size[b]

    edge_uses: dict[tuple[int, int], list[tuple[int, tuple, tuple]]] = {}
    for poly in mesh.polygons:
        loop_indices = list(poly.loop_indices)
        for offset, loop_index in enumerate(loop_indices):
            next_loop_index = loop_indices[(offset + 1) % len(loop_indices)]
            v0 = int(mesh.loops[loop_index].vertex_index)
            v1 = int(mesh.loops[next_loop_index].vertex_index)
            uv0 = tuple(layer.data[loop_index].uv)
            uv1 = tuple(layer.data[next_loop_index].uv)
            if v0 <= v1:
                key = (v0, v1)
                ordered_uv = (uv0, uv1)
            else:
                key = (v1, v0)
                ordered_uv = (uv1, uv0)
            edge_uses.setdefault(key, []).append(
                (int(poly.index), ordered_uv[0], ordered_uv[1])
            )

    for uses in edge_uses.values():
        if len(uses) < 2:
            continue
        base_face, base_uv0, base_uv1 = uses[0]
        for other_face, other_uv0, other_uv1 in uses[1:]:
            if (
                _uv_pair_close(base_uv0, other_uv0)
                and _uv_pair_close(base_uv1, other_uv1)
            ):
                union(base_face, other_face)

    component_sizes: dict[int, int] = {}
    for face_index in range(face_count):
        root = find(face_index)
        component_sizes[root] = component_sizes.get(root, 0) + 1

    island_count = len(component_sizes)
    single_face_islands = sum(1 for count in component_sizes.values() if count == 1)
    return {
        "face_count": face_count,
        "uv_island_count": island_count,
        "single_face_island_count": single_face_islands,
        "island_ratio": island_count / face_count,
        "single_face_ratio": single_face_islands / face_count,
    }


def _rebuild_bake_uv(obj) -> dict:
    """Create a fresh bake-only UV atlas; never reuse TRELLIS/import UVs."""
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")

    select_only([obj])
    existing = obj.data.uv_layers.get("BakeUV")
    if existing is not None:
        obj.data.uv_layers.remove(existing)

    layer = obj.data.uv_layers.new(name="BakeUV")
    obj.data.uv_layers.active = layer
    try:
        layer.active_render = True
    except Exception:
        pass

    bpy.ops.object.mode_set(mode="EDIT")
    try:
        bpy.context.scene.tool_settings.use_uv_select_sync = True
        bpy.ops.mesh.select_all(action="SELECT")
        # A high angle limit keeps adjacent triangles belonging to the same
        # hard-surface panel together instead of creating a triangle-per-island
        # atlas. The margin is expressed in UV space and corresponds to about
        # 16 px at the requested bake resolution.
        margin = max(0.002, min(0.02, 16.0 / float(ARGS.texture_resolution)))
        bpy.ops.uv.smart_project(
            angle_limit=math.radians(89.0),
            island_margin=margin,
            area_weight=0.0,
            correct_aspect=True,
            scale_to_bounds=True,
        )
    finally:
        bpy.ops.object.mode_set(mode="OBJECT")

    obj.data.uv_layers.active = obj.data.uv_layers["BakeUV"]
    try:
        obj.data.uv_layers["BakeUV"].active_render = True
    except Exception:
        pass
    obj.data.update()

    report = _analyze_uv_islands(obj, "BakeUV")
    log(
        "BakeUV rebuilt for "
        f"{obj.name}: faces={report['face_count']} "
        f"islands={report['uv_island_count']} "
        f"single_face_islands={report['single_face_island_count']} "
        f"island_ratio={report['island_ratio']:.4f}"
    )

    # Do not silently bake/export the exact failure mode seen on worklight_01:
    # almost one UV island per triangle. A bad atlas now stops the run and
    # leaves a useful diagnostic instead of producing a visibly corrupted GLB.
    if (
        report["face_count"] >= 100
        and report["island_ratio"] >= 0.80
        and report["single_face_ratio"] >= 0.70
    ):
        raise RuntimeError(
            "Generated BakeUV is still fragmented almost triangle-by-triangle "
            f"on {obj.name} (faces={report['face_count']}, "
            f"islands={report['uv_island_count']}, "
            f"single-face={report['single_face_island_count']}). "
            "Final bake/export aborted instead of emitting a corrupted texture."
        )

    return report


def bake_direct(targets) -> list[str]:
    """Use the same direct bake path validated by the original POC.

    Avoid the modal BakeTextures wrapper here: the multiview generation is
    already complete, so a synchronous final bake is deterministic and avoids
    a second modal operator competing with the launch UI context.
    """
    from assettexturing.texturing.rendering import (
        BakeTextures,
        bake_texture,
        prepare_baking,
    )
    from assettexturing.utils import get_dir_path

    context = bpy.context
    original_engine = context.scene.render.engine
    original_device = context.scene.cycles.device
    baked_paths: list[str] = []

    log(f"Starting direct final texture bake for {len(targets)} mesh(es)...")
    try:
        prepare_baking(context)
        for obj in targets:
            _rebuild_bake_uv(obj)
            uv_name = _activate_bake_uv(obj)
            if uv_name != "BakeUV":
                raise RuntimeError(f"Dedicated BakeUV was not activated on {obj.name}")

            ok = bake_texture(
                context,
                obj,
                ARGS.texture_resolution,
                output_dir=get_dir_path(context, "baked"),
            )
            if not ok:
                raise RuntimeError(f"Final texture bake failed for {obj.name}")

            class _BakeSettings:
                bake_pbr = False

            BakeTextures.add_baked_material(_BakeSettings(), context, obj)
            _activate_bake_uv(obj)
            baked_path = Path(get_dir_path(context, "baked")) / f"{obj.name}.png"
            if not baked_path.is_file() or baked_path.stat().st_size == 0:
                raise RuntimeError(f"Baked texture was not created: {baked_path}")
            baked_paths.append(str(baked_path.resolve()))
            log(f"Baked {obj.name} using UV map {uv_name}: {baked_path}")
    finally:
        try:
            context.scene.cycles.device = original_device
            context.scene.render.engine = original_engine
        except Exception:
            pass

    return baked_paths


def finalize(targets, cameras, projected_blend, excluded, projection_risks) -> None:
    from assettexturing.utils import get_dir_path, get_file_path, get_generation_dirs

    baked_dir = Path(get_dir_path(bpy.context, "baked")).resolve()
    baked = []
    missing = []
    for obj in targets:
        path = Path(
            get_file_path(bpy.context, "baked", object_name=obj.name)
        ).resolve()
        if not path.is_file() or path.stat().st_size == 0:
            missing.append(str(path))
        else:
            baked.append(str(path))
    if missing:
        raise RuntimeError(
            "Texture bake completed but texture file(s) are missing: "
            + ", ".join(missing)
        )

    revision = Path(get_generation_dirs(bpy.context)["revision"]).resolve()
    generated_dir = revision / "generated"
    generated = (
        [str(p) for p in sorted(generated_dir.glob("*.png"))]
        if generated_dir.exists()
        else []
    )

    # The generated cameras are implementation details. Removing them before
    # saving the final asset keeps the Blender scene clean and prevents the
    # camera wireframes from cluttering the viewport.
    camera_names = [cam.name for cam in cameras if cam]
    for cam in list(cameras):
        if cam and cam.name in bpy.data.objects:
            bpy.data.objects.remove(cam, do_unlink=True)

    select_only(targets)

    final_blend = (
        Path(ARGS.final_blend).resolve()
        if str(ARGS.final_blend).strip()
        else RUN_ROOT / f"{ARGS.asset_name}_MULTIVIEW.blend"
    )
    final_glb = (
        Path(ARGS.final_glb).resolve()
        if str(ARGS.final_glb).strip()
        else RUN_ROOT / f"{ARGS.asset_name}.glb"
    )
    final_blend.parent.mkdir(parents=True, exist_ok=True)
    final_glb.parent.mkdir(parents=True, exist_ok=True)

    bpy.ops.file.pack_all()
    bpy.ops.wm.save_as_mainfile(filepath=str(final_blend))
    if not final_blend.is_file():
        raise RuntimeError(f"Final Blender file was not created: {final_blend}")

    select_only(targets)
    for obj in targets:
        _activate_bake_uv(obj)
    bpy.ops.export_scene.gltf(
        filepath=str(final_glb),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
    )
    if not final_glb.is_file() or final_glb.stat().st_size == 0:
        raise RuntimeError(f"Final GLB was not created: {final_glb}")

    source_path = str(Path(ARGS.mesh).resolve())
    write_result(
        "success",
        asset_name=ARGS.asset_name,
        source_asset=source_path,
        projected_blend=(str(projected_blend) if projected_blend else None),
        final_blend=str(final_blend),
        final_glb=str(final_glb),
        revision_dir=str(revision),
        baked_dir=str(baked_dir),
        baked_textures=baked,
        generated_images=generated,
        mesh_objects=[obj.name for obj in targets],
        excluded_mesh_objects=[obj.name for obj in excluded],
        projection_risk_report=projection_risks,
        prompt=ARGS.prompt,
        seed=ARGS.seed,
        checkpoint=ARGS.checkpoint,
        cameras=camera_names,
    )
    log(f"DONE. Final Blender asset: {final_blend}")
    log(f"DONE. Final GLB asset: {final_glb}")
    bpy.ops.wm.quit_blender()


def install_watcher(targets, cameras, excluded, projection_risks) -> None:
    state = {
        "texturing_seen": False,
        "bake_started": False,
        "projected_blend": None,
        "baked_textures": [],
    }

    def watch():
        try:
            from assettexturing.texturing.generator import ComfyUIGenerate

            if not state["bake_started"]:
                status = bpy.context.scene.generation_status
                running = bool(ComfyUIGenerate._is_running)
                if (
                    status in {"running", "waiting"}
                    or running
                    or modal_active("OBJECT_OT_test_stable")
                ):
                    state["texturing_seen"] = True
                    return 0.5

                if not state["texturing_seen"]:
                    return 0.25
                if bpy.context.scene.sg_last_gen_error:
                    raise RuntimeError(
                        "multiview texturing finished with "
                        "sg_last_gen_error=true."
                    )

                state["projected_blend"] = save_projected_snapshot(targets)
                state["baked_textures"] = bake_direct(targets)
                state["bake_started"] = True

                finalize(
                    targets,
                    cameras,
                    state["projected_blend"],
                    excluded,
                    projection_risks,
                )
                return None

            return 0.25
        except Exception as exc:
            fail("multiview multiview failed", exc)
            return None

    bpy.app.timers.register(watch, first_interval=0.5)


def main() -> None:
    try:
        source = Path(ARGS.mesh).resolve()
        if not source.is_file():
            raise RuntimeError(f"Source asset does not exist: {source}")

        load_source(source)
        enable_assettexturing()
        apply_original_assettexturing_modifiers()

        if bpy.app.version < (4, 2, 0):
            raise RuntimeError(
                f"multiview requires Blender >= 4.2; "
                f"running {bpy.app.version_string}"
            )
        if not bpy.app.online_access:
            raise RuntimeError("Blender Online Access is disabled.")

        targets, excluded = collect_targets(
            ARGS.mesh_regex,
            ARGS.exclude_mesh_names,
        )
        select_only(targets)
        projection_risks = collect_projection_risks(targets)

        log(f"Target meshes: {len(targets)}")
        log(
            "Excluded non-target meshes: "
            + (
                ", ".join(obj.name for obj in excluded)
                if excluded
                else "none"
            )
        )
        if projection_risks:
            log(
                f"Projection preflight: {len(projection_risks)} target object(s) "
                "have modifiers, constraints, or non-unit scale; "
                "recorded in poc-result.json."
            )

        working = RUN_ROOT / f"{ARGS.asset_name}_ASSETTEXTURING_WORKING.blend"
        bpy.ops.wm.save_as_mainfile(filepath=str(working))

        configure_assettexturing()
        cameras = create_cameras(targets)
        launch_texturing(targets)
        install_watcher(
            targets,
            cameras,
            excluded,
            projection_risks,
        )
    except Exception as exc:
        fail("multiview multiview bootstrap failed", exc)


main()
