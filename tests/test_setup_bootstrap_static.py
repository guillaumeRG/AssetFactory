from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8-sig")


def test_default_install_is_full_and_coreonly_preserves_minimal_bootstrap():
    setup = text("setup-asset-factory.ps1")
    assert '[switch]$CoreOnly' in setup
    assert 'function Invoke-CoreInstall' in setup
    full = setup.split('function Invoke-Install {', 1)[1].split('function Invoke-CoreDoctor {', 1)[0]
    for call in (
        'Ensure-Vs2022CppBuildTools',
        'Ensure-Cuda134Toolkit',
        'Invoke-ComfyUiInstall',
        'Invoke-ComfyUiModelInstall',
        'Invoke-TrellisInstall',
        'Invoke-TrellisRuntimeInstall',
        'Invoke-TrellisNativeInstall',
        'Invoke-TrellisModelPreparation',
        'Invoke-TripoSrInstall',
        'Invoke-MultiViewInstall',
    ):
        assert call in full
    assert 'remains an opt-in engine install' not in full


def test_native_prerequisites_are_converged_idempotently():
    setup = text("setup-asset-factory.ps1")
    assert 'Microsoft.VisualStudio.2022.BuildTools' in setup
    assert 'Microsoft.VisualStudio.Workload.VCTools' in setup
    assert 'Nvidia.CUDA' in setup
    assert 'Get-WingetMatchingVersion' in setup
    assert 'VersionPrefix "13.4"' in setup
    assert 'if ($info.CudaPresent -and $info.NvccVersion -eq "13.4")' in setup


def test_full_doctor_checks_all_subsystems():
    setup = text("setup-asset-factory.ps1")
    doctor = setup.split('function Invoke-Doctor {', 1)[1].split('function Show-Help {', 1)[0]
    for check in (
        'Invoke-CoreDoctor', 'Invoke-ComfyUiDoctor', 'Test-ComfyUiFluxModel',
        'Invoke-TrellisDoctor', 'Invoke-TrellisRuntimeDoctor', 'Invoke-TrellisNativeDoctor',
        'Invoke-TrellisModelPreparation -CheckOnly', 'Invoke-TripoSrDoctor', 'Invoke-MultiViewDoctor'
    ):
        assert check in doctor
    assert 'ASSET FACTORY READY' in doctor


def test_multiview_dependencies_are_not_reinstalled_when_exact_versions_match():
    setup = text("setup-asset-factory.ps1")
    assert 'function Test-MultiViewBlenderDependencies' in setup
    ensure = setup.split('function Ensure-MultiViewBlenderDependencies {', 1)[1].split('function Test-MultiViewBlenderAddon {', 1)[0]
    assert 'if (Test-MultiViewBlenderDependencies)' in ensure
    assert 'Dépendances Blender multi-vues déjà conformes' in ensure


def test_setup_version_matches_v09_line():
    setup = text("setup-asset-factory.ps1")
    assert '$ScriptVersion = "0.9.1"' in setup


def test_repeat_install_reuses_healthy_python_subsystems_before_pip():
    setup = text("setup-asset-factory.ps1")
    assert 'Reusing existing TripoSR requirements' in setup
    assert 'Reusing existing TRELLIS basic runtime dependencies' in setup
    assert 'Reusing existing ComfyUI Python dependencies' in setup
    assert 'Dépendances Blender multi-vues déjà conformes' in setup
