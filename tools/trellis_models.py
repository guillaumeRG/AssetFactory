"""Asset Factory: prepare and verify the TRELLIS model bundle.

Network access belongs to --install only. --check uses the standard library
and local files. Nothing in the engine checkout or the installed packages is
patched. Completed files are copied out of the user's caches, not moved.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
from typing import Any
from urllib.request import Request, urlopen
from zipfile import ZipFile

BUNDLE_VERSION = 1
TRELLIS_REPO = "microsoft/TRELLIS-image-large"
TRELLIS_REVISION = "25e0d31ffbebe4b5a97464dd851910efc3002d96"
DINO_REVISION = "7764ea0f912e53c92e82eb78a2a1631e92725fc8"
DINO_MODEL = "dinov2_vitl14_reg"
DINO_WEIGHT = "dinov2_vitl14_reg4_pretrain.pth"
DINO_URL = f"https://dl.fbaipublicfiles.com/dinov2/dinov2_vitl14/{DINO_WEIGHT}"
DINO_CODE_URL = f"https://codeload.github.com/facebookresearch/dinov2/zip/{DINO_REVISION}"
U2NET_URL = "https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2net.onnx"
U2NET_MD5 = "60024c5c889badc19c04ad937298a77b"
MODEL_KEYS = {
    "sparse_structure_decoder", "sparse_structure_flow_model", "slat_flow_model",
    "slat_decoder_mesh", "slat_decoder_gs", "slat_decoder_rf",
}
PROVENANCE = {
    "trellis_repository": TRELLIS_REPO,
    "trellis_revision": TRELLIS_REVISION,
    "dinov2_revision": DINO_REVISION,
    "dinov2_model": DINO_MODEL,
    "dinov2_weights_url": DINO_URL,
    "u2net_url": U2NET_URL,
    "u2net_md5": U2NET_MD5,
}
INSTALL_HINT = "Run .\\setup-asset-factory.ps1 trellis model-install while connected."


def default_models_dir() -> Path:
    return Path(__file__).resolve().parents[1] / "models" / "trellis"


def inside(root: Path, relative: str) -> Path:
    """Accept portable relative file names only, including when run on Windows."""
    if not isinstance(relative, str) or not relative or "\\" in relative or ":" in relative:
        raise ValueError(f"Invalid model path: {relative!r}")
    parts = PurePosixPath(relative).parts
    if relative.startswith("/") or ".." in parts or not parts:
        raise ValueError(f"Unsafe model path: {relative!r}")
    path = root.joinpath(*parts)
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Model path escapes the bundle: {relative!r}")
    return path


def digest(path: Path, algorithm: str = "sha256") -> str:
    hasher = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8-sig") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object: {path}")
    return value


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    os.replace(temporary, path)


def record_file(path: Path) -> dict[str, Any]:
    return {"size": path.stat().st_size, "sha256": digest(path)}


def record_matches(path: Path, record: dict[str, Any] | None) -> bool:
    if not isinstance(record, dict) or not path.is_file():
        return False
    size = record.get("size")
    expected = record.get("sha256")
    if not isinstance(size, int) or size <= 0 or path.stat().st_size != size:
        return False
    if not isinstance(expected, str) or len(expected) != 64:
        return False
    return digest(path) == expected


def required_model_files(config: dict[str, Any]) -> list[str]:
    """Read the upstream model list; reject remote references instead of guessing."""
    if config.get("name") != "TrellisImageTo3DPipeline":
        raise ValueError("This bundle supports the TRELLIS v1 image pipeline only")
    arguments = config["args"]
    if set(arguments["models"]) != MODEL_KEYS:
        raise ValueError("Unexpected TRELLIS model list; refusing an incomplete offline bundle")
    if arguments.get("image_cond_model") != DINO_MODEL:
        raise ValueError("Unexpected image conditioning model in pipeline.json")
    paths = ["TRELLIS-image-large/pipeline.json"]
    for base in arguments["models"].values():
        if not isinstance(base, str) or not base.startswith("ckpts/"):
            raise ValueError(f"Expected a local checkpoint reference, got {base!r}")
        for extension in (".json", ".safetensors"):
            relative = "TRELLIS-image-large/" + base + extension
            inside(Path.cwd(), relative)
            paths.append(relative)
    return paths


def validate_bundle(root: Path) -> dict[str, Any]:
    """Full size/SHA-256 check. This function does not import any network library."""
    root = root.expanduser().resolve()
    manifest_path = root / "model-manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"Offline model manifest is missing: {manifest_path}. {INSTALL_HINT}")
    manifest = read_json(manifest_path)
    if manifest.get("schema_version") != BUNDLE_VERSION or manifest.get("sources") != PROVENANCE:
        raise ValueError(f"Offline model manifest has an unexpected version or source revision. {INSTALL_HINT}")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError(f"Offline manifest has no file inventory. {INSTALL_HINT}")
    pipeline_relative = "TRELLIS-image-large/pipeline.json"
    if pipeline_relative not in files:
        raise ValueError(f"pipeline.json is absent from the offline inventory. {INSTALL_HINT}")
    # Hash the config before trusting its paths.
    config_path = inside(root, pipeline_relative)
    if not record_matches(config_path, files[pipeline_relative]):
        raise ValueError(f"Missing or damaged local file: {pipeline_relative}. {INSTALL_HINT}")
    config = read_json(config_path)
    required = set(required_model_files(config)) | {
        "dinov2/repository/hubconf.py", "dinov2/repository/dinov2/hub/backbones.py",
        f"dinov2/{DINO_WEIGHT}", "rembg/u2net.onnx",
    }
    missing = sorted(required - set(files))
    if missing:
        raise ValueError(f"Offline inventory is incomplete: {', '.join(missing)}. {INSTALL_HINT}")
    for relative, record in files.items():
        if not record_matches(inside(root, relative), record):
            raise ValueError(f"Missing or damaged local file: {relative}. {INSTALL_HINT}")
    # Code added outside the recorded DINO revision should never be executed.
    code_root = root / "dinov2" / "repository"
    unexpected = [p for p in code_root.rglob("*.py") if p.relative_to(root).as_posix() not in files]
    if unexpected:
        raise ValueError(f"Unrecorded DINOv2 code in model bundle: {unexpected[0]}")
    return manifest


def _atomic_copy(source: Path, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".part")
    try:
        shutil.copyfile(source, temporary)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def _download(url: str, target: Path) -> None:
    """Download to .part first. An interrupted file is never marked complete."""
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".part")
    received = 0
    next_report = 64 * 1024 * 1024
    print(f"[INFO] Downloading {target.name}...", flush=True)
    try:
        request = Request(url, headers={"User-Agent": "AssetFactory-TRELLIS-ModelSetup/1.0"})
        with urlopen(request, timeout=120) as response, temporary.open("wb") as output:
            if not response.geturl().startswith("https://"):
                raise RuntimeError("Refusing a model download redirected outside HTTPS")
            length = response.headers.get("Content-Length")
            expected = int(length) if length is not None else None
            while chunk := response.read(4 * 1024 * 1024):
                output.write(chunk)
                received += len(chunk)
                if received >= next_report:
                    print(f"[INFO] {target.name}: {received / 1024**2:.0f} MiB", flush=True)
                    next_report += 64 * 1024 * 1024
        if received == 0 or (expected is not None and received != expected):
            raise RuntimeError(f"Incomplete download: {target.name}")
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def extract_dino_code(archive: Path, destination: Path) -> list[Path]:
    """Extract the pinned source unchanged; ignore docs, datasets and pictures."""
    prefix = f"dinov2-{DINO_REVISION}/"
    written: list[Path] = []
    with ZipFile(archive) as bundle:
        for info in bundle.infolist():
            if info.is_dir():
                continue
            if not info.filename.startswith(prefix):
                raise ValueError("Unexpected root in the DINOv2 source archive")
            relative = info.filename[len(prefix):]
            target = inside(destination, relative)
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise ValueError("Symlinks are not allowed in the DINOv2 source archive")
            selected = relative in {"hubconf.py", "LICENSE"} or (
                relative.startswith("dinov2/") and relative.endswith(".py")
            )
            if not selected:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(info) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            written.append(target)
    if not (destination / "hubconf.py").is_file() or not (destination / "dinov2/hub/backbones.py").is_file():
        raise ValueError("DINOv2 source archive is incomplete")
    return written


def _cache_candidates() -> tuple[list[Path], list[Path]]:
    cache = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
    torch_home = Path(os.environ.get("TORCH_HOME", str(cache / "torch")))
    dino = [torch_home / "hub" / "checkpoints" / DINO_WEIGHT]
    u2net = [Path.home() / ".u2net" / "u2net.onnx"]
    if os.environ.get("U2NET_HOME"):
        u2net.insert(0, Path(os.environ["U2NET_HOME"]) / "u2net.onnx")
    if os.environ.get("XDG_DATA_HOME"):
        u2net.append(Path(os.environ["XDG_DATA_HOME"]) / ".u2net" / "u2net.onnx")
    return dino, u2net


def install_bundle(root: Path) -> None:
    root = root.expanduser().resolve()
    if (root / "model-manifest.json").is_file():
        try:
            validate_bundle(root)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            print(f"[WARN] Bundle requires repair: {exc}", flush=True)
        else:
            print("[OK] All offline model files verified; no download needed.", flush=True)
            return
    root.mkdir(parents=True, exist_ok=True)
    state_path = root / ".download-state.json"
    state = {"schema_version": BUNDLE_VERSION, "sources": PROVENANCE, "files": {}}
    if state_path.is_file():
        previous = read_json(state_path)
        if previous.get("sources") != PROVENANCE or previous.get("schema_version") != BUNDLE_VERSION:
            raise RuntimeError("Another model revision already uses this directory; nothing was removed.")
        if not isinstance(previous.get("files"), dict):
            raise RuntimeError("Invalid model download state; nothing was removed.")
        state = previous
    records = state["files"]

    def keep(relative: str) -> None:
        records[relative] = record_file(inside(root, relative))
        write_json(state_path, state)

    def ready(relative: str) -> bool:
        return record_matches(inside(root, relative), records.get(relative))

    # The default Hugging Face cache is intentionally preserved and reused.
    # Copying completed files gives this project a self-contained model folder.
    from huggingface_hub import hf_hub_download

    def get_hf(filename: str) -> None:
        relative = "TRELLIS-image-large/" + filename
        if ready(relative):
            print(f"[OK] Reusing {relative}", flush=True)
            return
        print(f"[INFO] Preparing {filename} (existing HF cache reused when available)...", flush=True)
        source = Path(hf_hub_download(TRELLIS_REPO, filename, revision=TRELLIS_REVISION))
        _atomic_copy(source, inside(root, relative))
        keep(relative)

    get_hf("pipeline.json")
    config = read_json(root / "TRELLIS-image-large/pipeline.json")
    for relative in required_model_files(config)[1:]:
        get_hf(relative.removeprefix("TRELLIS-image-large/"))

    dino_records = [r for r in records if r.startswith("dinov2/repository/")]
    code_ready = (
        "dinov2/repository/hubconf.py" in dino_records
        and "dinov2/repository/dinov2/hub/backbones.py" in dino_records
        and all(ready(r) for r in dino_records)
    )
    if not code_ready:
        code_root = root / "dinov2/repository"
        if code_root.exists():
            # Do not clobber unrelated files in an unknown directory.
            unknown = [p for p in code_root.rglob("*.py") if p.relative_to(root).as_posix() not in records]
            if unknown:
                raise RuntimeError(f"Unmanaged DINOv2 code already exists: {unknown[0]}")
        with tempfile.TemporaryDirectory(prefix="af-dino-") as directory:
            archive = Path(directory) / "dinov2.zip"
            staged = Path(directory) / "repository"
            _download(DINO_CODE_URL, archive)
            files = extract_dino_code(archive, staged)
            for source in files:
                relative = "dinov2/repository/" + source.relative_to(staged).as_posix()
                _atomic_copy(source, inside(root, relative))
                keep(relative)
    print(f"[OK] DINOv2 source pinned to {DINO_REVISION}", flush=True)

    dino_cache, rembg_cache = _cache_candidates()
    for relative, url, candidates, md5 in (
        (f"dinov2/{DINO_WEIGHT}", DINO_URL, dino_cache, None),
        ("rembg/u2net.onnx", U2NET_URL, rembg_cache, U2NET_MD5),
    ):
        if ready(relative):
            print(f"[OK] Reusing {relative}", flush=True)
            continue
        target = inside(root, relative)
        source = next((p for p in candidates if p.is_file() and p.stat().st_size > 100 * 1024**2
                       and (md5 is None or digest(p, "md5") == md5)), None)
        if source is not None:
            print(f"[INFO] Reusing cached weights: {source}", flush=True)
            _atomic_copy(source, target)
        else:
            _download(url, target)
        if target.stat().st_size <= 100 * 1024**2:
            raise RuntimeError(f"Suspiciously small model file: {target}")
        if md5 is not None and digest(target, "md5") != md5:
            raise RuntimeError(f"Upstream checksum mismatch: {target}")
        keep(relative)

    manifest = {"schema_version": BUNDLE_VERSION, "sources": PROVENANCE, "files": records}
    write_json(root / "model-manifest.json", manifest)
    validate_bundle(root)
    size = sum(record["size"] for record in records.values()) / 1024**3
    print(f"[OK] Offline model bundle verified: {root} ({size:.2f} GiB)", flush=True)
    print("[INFO] Existing user caches were not removed or modified.", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--install", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--models-dir", type=Path, default=default_models_dir())
    args = parser.parse_args()
    if args.install:
        install_bundle(args.models_dir)
    else:
        print("[INFO] Checking local model files and SHA-256 hashes; no network access...", flush=True)
        validate_bundle(args.models_dir)
        print("[OK] TRELLIS offline model bundle is complete.", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("[FAIL] Interrupted. Run model-install again to reuse completed files.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
