from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8-sig")


def test_public_pipeline_uses_one_integrated_multiview_switch():
    prompt = text("tools/generate-asset-from-prompt.ps1")
    assert "[bool]$Multiview = $false" in prompt
    assert "-Multiview $Multiview" in prompt
    assert "run-multiview" not in prompt.lower()


def test_old_external_multiview_runners_are_removed():
    assert not (ROOT / "tools/run-multiview.ps1").exists()
    assert not (ROOT / "tools/run-multiview-to-3d.ps1").exists()
    assert not (ROOT / "tools/run_multiview.py").exists()


def test_geometry_only_handoff_is_used():
    pipeline = text("tools/run-image-to-3d.ps1")
    trellis = text("tools/run_trellis.py")
    assert "$trellisParameters.GeometryOnly = $true" in pipeline
    assert 'parser.add_argument("--geometry-only", action="store_true")' in trellis
    assert 'requested_formats = ["mesh"]' in trellis


def test_blender_multiview_is_internal():
    pipeline = text("tools/run-image-to-3d.ps1")
    assert "internal\\multiview_texture_driver.py" in pipeline
    assert "vendor\\StableGen\\stablegen" in pipeline
    assert "Invoke-AFIntegratedMultiview" in pipeline


def test_setup_bootstraps_and_pins_official_stablegen():
    setup = text("setup-asset-factory.ps1")
    assert "https://github.com/sakalond/StableGen.git" in setup
    assert "fae5474098c40ce149a93dbfffe02b33876b3cd4" in setup
    assert "function Ensure-MultiViewRepository" in setup
    assert "Ensure-MultiViewRepository" in setup


def test_forbidden_legacy_assettexturing_identifier_is_not_in_managed_setup():
    setup = text("setup-asset-factory.ps1").lower()
    assert "vendor\\assettexturing" not in setup
