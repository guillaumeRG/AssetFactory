from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8-sig")


def test_stablegen_enable_creates_preferences_and_uses_vendor_preference_api():
    driver = text("tools/internal/multiview_texture_driver.py")
    assert 'addon_utils.enable(' in driver
    assert '"stablegen",\n        default_set=True,' in driver
    assert 'default_set=False' not in driver
    assert 'get_stablegen_preferences()' in driver
    assert 'get_addon_prefs' in driver
    assert 'bpy.context.preferences.addons["stablegen"]' not in driver


def test_multiview_failure_surfaces_vendor_exception_and_log_paths():
    pipeline = text("tools/run-image-to-3d.ps1")
    assert '$result.exception' in pipeline
    assert 'exception: $($result.exception)' in pipeline
    assert 'Logs : $blenderOut / $blenderErr' in pipeline
    assert 'BLENDER_USER_CONFIG' in pipeline


def test_multiview_doctor_smoke_tests_blender_addon_preferences():
    setup = text("setup-asset-factory.ps1")
    smoke = text("tools/internal/multiview_addon_smoke.py")
    assert 'multiview_addon_smoke.py' in setup
    assert 'Test-MultiViewBlenderAddon' in setup
    assert '--factory-startup' in setup
    assert '--background' in setup
    assert 'BLENDER_USER_CONFIG' in setup
    assert 'default_set=True' in smoke
    assert 'get_addon_prefs' in smoke


def test_final_bake_forces_vendor_to_use_dedicated_bake_uv():
    driver = text("tools/internal/multiview_texture_driver.py")
    assert "def _mask_non_bake_uvs_for_vendor_bake" in driver
    assert 'name.startswith("ProjectionUV")' in driver
    assert 'candidate = f"ProjectionUV_AF_BAKE_SKIP_{index}"' in driver
    assert "renamed_uvs = _mask_non_bake_uvs_for_vendor_bake(obj)" in driver
    assert "_restore_masked_uv_names(obj, renamed_uvs)" in driver
    assert driver.index("renamed_uvs = _mask_non_bake_uvs_for_vendor_bake(obj)") < driver.index("ok = bake_texture(")


def test_bake_uv_rebuild_tries_multiple_unwrap_strategies_and_packs_islands():
    driver = text("tools/internal/multiview_texture_driver.py")
    assert 'def _unwrap_bake_uv_with_sharp_seams' in driver
    assert 'def _unwrap_bake_uv_with_smart_project' in driver
    assert 'bpy.ops.mesh.edges_select_sharp' in driver
    assert 'bpy.ops.uv.average_islands_scale()' in driver
    assert 'bpy.ops.uv.pack_islands' in driver
    assert 'sharp_seams_70deg' in driver
    assert 'sharp_seams_55deg' in driver
    assert 'smart_project_89deg' in driver
    assert 'estimated_fill_ratio' in driver
    assert 'selected_strategy' in driver


def test_bake_uv_selector_penalizes_texel_density_distortion():
    driver = text("tools/internal/multiview_texture_driver.py")
    assert 'def _estimate_uv_distortion' in driver
    assert 'density_spread_p95_p05' in driver
    assert 'density_spread_iqr' in driver
    assert 'report["density_spread_p95_p05"] * 1200.0' in driver
    assert 'distortion is more important than island count' in driver
    assert 'pack_islands(margin=margin, rotate=True, scale=True)' in driver


def test_final_multiview_asset_promotes_bake_uv_to_uv0_before_blend_and_glb_export():
    driver = text("tools/internal/multiview_texture_driver.py")
    assert "def _prepare_final_game_uvs" in driver
    assert 'if layer.name == "BakeUV"' in driver
    assert "layers.remove(layer)" in driver
    assert "BakeUV -> UV0" in driver
    assert "def _validate_final_glb_texture_uv0" in driver
    assert 'tex_coord = int(texture.get("texCoord", 0))' in driver
    assert "baked BaseColor must use TEXCOORD_0" in driver

    prepare = driver.index("_prepare_final_game_uvs(obj)")
    save_blend = driver.index("bpy.ops.wm.save_as_mainfile", prepare)
    export_glb = driver.index("bpy.ops.export_scene.gltf", save_blend)
    validate_glb = driver.index("_validate_final_glb_texture_uv0(final_glb)", export_glb)
    assert prepare < save_blend < export_glb < validate_glb


def test_multiview_uses_official_mesh_texture_preset_and_original_image_ipadapter():
    pipeline = text("tools/run-image-to-3d.ps1")
    driver = text("tools/internal/multiview_texture_driver.py")

    assert '[Parameter(Mandatory)][string]$ReferenceImagePath' in pipeline
    assert 'source_image = $ReferenceImagePath' in pipeline
    assert '-ReferenceImagePath $ImagePath' in pipeline

    assert 'required = ("mesh", "source_image", "run_root", "python_deps")' in driver
    assert 'scene.stablegen_preset = "DEFAULT (MESH + TEXTURE)"' in driver
    assert 'scene.trellis2_last_input_image = str(source_image)' in driver
    assert 'if not bool(scene.sequential_ipadapter)' in driver
    assert 'scene.sequential_ipadapter_mode != "trellis2_input"' in driver
    assert 'source image -> IPAdapter' in driver
    assert 'exclude_bottom=False' in driver
    assert 'auto_prompts=True' in driver


def test_multiview_setup_installs_official_stablegen_ipadapter_dependencies():
    setup = text("setup-asset-factory.ps1")
    assert 'https://github.com/cubiq/ComfyUI_IPAdapter_plus.git' in setup
    assert 'a0f451a5113cf9becb0847b92884cb10cbdec0ef' in setup
    assert 'function Ensure-MultiViewIpAdapterNode' in setup
    assert 'Ensure-MultiViewIpAdapterNode' in setup
    assert 'ip-adapter-plus_sdxl_vit-h.safetensors' in setup
    assert 'CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors' in setup


def test_multiview_install_migrates_recognized_unmanaged_dependency_snapshots_safely():
    setup = text("setup-asset-factory.ps1")
    assert "function Move-ManagedDependencyLegacyAside" in setup
    assert "function Restore-ManagedDependencyLegacy" in setup
    assert "Migrating legacy StableGen snapshot to managed official checkout" in setup
    assert "$looksLikeStableGen" in setup
    assert "Migrating legacy ComfyUI IPAdapter Plus snapshot to managed official checkout" in setup
    assert "IPAdapterPlus.py" in setup
    assert "previous unmanaged copy restored after install failure" in setup
