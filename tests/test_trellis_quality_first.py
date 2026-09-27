from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8-sig")


def test_public_trellis_simplification_defaults_to_zero():
    for rel in (
        "tools/generate-asset-from-prompt.ps1",
        "tools/generate-asset-from-image.ps1",
        "tools/run-image-to-3d.ps1",
        "tools/run-trellis.ps1",
        "tools/internal/AssetFactory.Pipeline.psm1",
    ):
        source = text(rel)
        assert "TrellisSimplify = 0.95" not in source
        assert "Simplify = 0.95" not in source


def test_trellis_runner_preserves_raw_geometry_in_quality_first_mode():
    runner = text("tools/run_trellis.py")
    assert 'default=0.0' in runner
    assert 'Geometrie TRELLIS brute conservee' in runner
    assert 'simplify=0.0' in runner
    assert 'fill_holes=False' in runner
    assert 'simplify=args.simplify > 0' not in runner
    assert 'simplify_ratio=args.simplify' not in runner


def test_powershell_wrappers_ignore_stale_nonzero_simplify_values():
    direct = text("tools/run-trellis.ps1")
    pipeline = text("tools/run-image-to-3d.ps1")
    assert 'if ($Simplify -ne 0.0)' in direct
    assert '$Simplify = 0.0' in direct
    assert 'if ($TrellisSimplify -ne 0.0)' in pipeline
    assert '$TrellisSimplify = 0.0' in pipeline
