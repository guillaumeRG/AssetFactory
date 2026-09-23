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
