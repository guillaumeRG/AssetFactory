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
    assert "vendor\\AssetTexturing\\assettexturing" in pipeline
    assert "Invoke-AFIntegratedMultiview" in pipeline


def test_forbidden_legacy_product_identifier_is_not_in_code():
    forbidden = ("stable" + "gen").lower()
    extensions = {".py", ".ps1", ".json", ".toml", ".osl"}
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in extensions:
            continue
        assert forbidden not in path.read_text(encoding="utf-8-sig", errors="ignore").lower(), path
