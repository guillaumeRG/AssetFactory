from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from trellis_models import default_models_dir
from trellis_offline import configure_offline, check_local_models, load_local_pipeline


def _project_root() -> Path:
    return Path(__file__).resolve().parents[1]


def _prepare_native_runtime() -> dict[str, object]:
    """Verifie les outils natifs necessaires aux compilations JIT de cumm/spconv."""
    scripts_dir = Path(sys.executable).resolve().parent
    current_path = os.environ.get("PATH", "")
    entries = [entry for entry in current_path.split(os.pathsep) if entry]
    if not any(Path(entry).resolve() == scripts_dir for entry in entries if Path(entry).exists()):
        os.environ["PATH"] = str(scripts_dir) + (os.pathsep + current_path if current_path else "")

    required = {"ninja": "ninja"}
    if os.name == "nt":
        required.update(
            {
                "cl": "compilateur MSVC cl.exe",
                "nvcc": "compilateur CUDA nvcc.exe",
            }
        )
    resolved: dict[str, object] = {}
    for command, label in required.items():
        executable = shutil.which(command)
        if executable is None:
            raise RuntimeError(
                f"Outil natif TRELLIS introuvable : {label}. "
                "Le runner doit initialiser Visual Studio 2022 et CUDA 13.4 avant l'inference. "
                "Relancez '.\\setup-asset-factory.ps1 trellis runtime-install' si le probleme persiste."
            )
        resolved[command] = Path(executable).resolve()

    try:
        ninja_path = Path(str(resolved["ninja"]))
        ninja_version = subprocess.run(
            [str(ninja_path), "--version"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        if ninja_version:
            resolved["ninja_version"] = ninja_version
    except Exception:
        pass
    return resolved


def _prepare_imports() -> tuple[Path, Path]:
    root = _project_root()
    trellis_root = root / "engines" / "trellis"
    compat_root = root / "tools" / "trellis_compat"

    if not trellis_root.is_dir():
        raise RuntimeError(f"TRELLIS checkout is missing: {trellis_root}")
    if not compat_root.is_dir():
        raise RuntimeError(f"Asset Factory TRELLIS compatibility layer is missing: {compat_root}")

    # Le répertoire de compatibilité doit précéder site-packages afin que TRELLIS utilise
    # le shim xformers fourni par le projet plutôt qu'un wheel système/runtime défectueux.
    sys.path.insert(0, str(compat_root))
    sys.path.insert(1, str(trellis_root))

    os.environ["ATTN_BACKEND"] = "sdpa"
    os.environ["SPARSE_ATTN_BACKEND"] = "xformers"
    os.environ["SPCONV_ALGO"] = "native"

    return root, trellis_root


def _self_test() -> int:
    _prepare_imports()

    import torch
    import torch.nn.functional as F
    import xformers
    import xformers.ops as xops

    if not getattr(xformers, "ASSET_FACTORY_SDPA_SHIM", False):
        raise RuntimeError("The Asset Factory SDPA compatibility shim was not selected")
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is unavailable")

    device = torch.device("cuda")
    dtype = torch.float16

    # Chemin sans masque utilisé par l'attention sérialisée/fenêtrée de taille fixe.
    q = torch.randn((2, 7, 4, 32), device=device, dtype=dtype)
    k = torch.randn((2, 7, 4, 32), device=device, dtype=dtype)
    v = torch.randn((2, 7, 4, 32), device=device, dtype=dtype)
    actual = xops.memory_efficient_attention(q, k, v)
    expected = F.scaled_dot_product_attention(
        q.transpose(1, 2), k.transpose(1, 2), v.transpose(1, 2)
    ).transpose(1, 2)
    torch.testing.assert_close(actual, expected, rtol=1e-3, atol=1e-3)

    # Chemin bloc-diagonal utilisé lorsque les séquences creuses ont des longueurs différentes.
    q_lens = [3, 5, 2]
    kv_lens = [4, 2, 6]
    q = torch.randn((1, sum(q_lens), 4, 32), device=device, dtype=dtype)
    k = torch.randn((1, sum(kv_lens), 4, 32), device=device, dtype=dtype)
    v = torch.randn((1, sum(kv_lens), 4, 32), device=device, dtype=dtype)
    mask = xops.fmha.BlockDiagonalMask.from_seqlens(q_lens, kv_lens)
    actual = xops.memory_efficient_attention(q, k, v, mask)

    expected_blocks = []
    q_start = 0
    kv_start = 0
    for q_len, kv_len in zip(q_lens, kv_lens):
        q_block = q[:, q_start:q_start + q_len].transpose(1, 2)
        k_block = k[:, kv_start:kv_start + kv_len].transpose(1, 2)
        v_block = v[:, kv_start:kv_start + kv_len].transpose(1, 2)
        expected_blocks.append(
            F.scaled_dot_product_attention(q_block, k_block, v_block).transpose(1, 2)
        )
        q_start += q_len
        kv_start += kv_len
    expected = torch.cat(expected_blocks, dim=1)
    torch.testing.assert_close(actual, expected, rtol=1e-3, atol=1e-3)
    torch.cuda.synchronize()

    print(f"torch={torch.__version__}")
    print(f"cuda={torch.version.cuda}")
    print(f"gpu={torch.cuda.get_device_name(0)}")
    print(f"compat={xformers.__version__}")
    print("ASSET_FACTORY_TRELLIS_SDPA_COMPAT_OK")
    return 0


def _run(args: argparse.Namespace) -> int:
    _, trellis_root = _prepare_imports()
    native_tools = _prepare_native_runtime()

    import torch
    import xformers
    from PIL import Image
    from trellis.utils import postprocessing_utils

    if not getattr(xformers, "ASSET_FACTORY_SDPA_SHIM", False):
        raise RuntimeError("The Asset Factory SDPA compatibility shim was not selected")
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is unavailable")

    input_paths = [Path(value).expanduser().resolve() for value in args.input]
    if not input_paths:
        raise ValueError("Au moins une image d'entrée est requise.")
    for input_path in input_paths:
        if not input_path.is_file():
            raise FileNotFoundError(f"Image d'entrée introuvable : {input_path}")

    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    output_stem = args.asset_id.strip() if args.asset_id else input_paths[0].stem
    if len(input_paths) > 1 and not args.asset_id:
        raise ValueError("--asset-id est requis lorsque plusieurs images sont fournies.")
    output_glb = output_dir / (output_stem + ".glb")

    print(f"[INFO] Racine TRELLIS : {trellis_root}")
    if len(input_paths) == 1:
        print(f"[INFO] Entrée : {input_paths[0]}")
    else:
        print(f"[INFO] Entrées multi-vues : {len(input_paths)} images")
        for index, input_path in enumerate(input_paths, start=1):
            print(f"[INFO]   Vue {index:02d} : {input_path}")
        print(f"[INFO] Fusion multi-image TRELLIS : {args.multi_image_mode}")
    print(f"[INFO] Sortie : {output_glb}")
    print("[INFO] Attention dense : PyTorch SDPA")
    print("[INFO] Attention creuse : shim API xFormers Asset Factory -> PyTorch SDPA")
    print(f"[INFO] GPU : {torch.cuda.get_device_name(0)}")
    print(f"[INFO] Outil de build Ninja : {native_tools['ninja']}")
    if "ninja_version" in native_tools:
        print(f"[INFO] Version Ninja : {native_tools['ninja_version']}")
    if "cl" in native_tools:
        print(f"[INFO] Compilateur natif MSVC : {native_tools['cl']}")
    if "nvcc" in native_tools:
        print(f"[INFO] Compilateur natif CUDA : {native_tools['nvcc']}")
    print("[INFO] Mode réseau : HORS LIGNE (modèles locaux uniquement)")
    print(f"[INFO] Modèles : {args.models_dir}")

    pipeline = load_local_pipeline(args.models_dir)
    pipeline.cuda()

    images = []
    for input_path in input_paths:
        with Image.open(input_path) as source:
            images.append(source.copy())

    # In multiview mode Asset Factory needs geometry only. Requesting only
    # "mesh" avoids decoding the Gaussian representation and, crucially,
    # avoids the TRELLIS UV/render/bake path. The Blender multiview stage owns
    # all appearance generation and baking.
    requested_formats = ["mesh"]
    if not args.geometry_only or args.save_ply:
        requested_formats.append("gaussian")

    if len(images) == 1:
        outputs = pipeline.run(
            images[0],
            seed=args.seed,
            formats=requested_formats,
        )
    else:
        outputs = pipeline.run_multi_image(
            images,
            seed=args.seed,
            formats=requested_formats,
            mode=args.multi_image_mode,
        )

    if args.geometry_only:
        import math
        import trimesh

        mesh = outputs["mesh"][0]
        vertices = mesh.vertices.detach().cpu().numpy()
        faces = mesh.faces.detach().cpu().numpy()

        vertices, faces = postprocessing_utils.postprocess_mesh(
            vertices,
            faces,
            simplify=args.simplify > 0,
            simplify_ratio=args.simplify,
            fill_holes=True,
            fill_holes_max_hole_size=0.04,
            fill_holes_max_hole_nbe=int(250 * math.sqrt(1.0 - args.simplify)),
            fill_holes_resolution=1024,
            fill_holes_num_views=1000,
            verbose=True,
        )
        # TRELLIS mesh coordinates are Z-up, while glTF assets are Y-up.
        # trimesh writes the supplied coordinates directly and does not add the
        # Blender/glTF axis conversion for us. Without this conversion Blender
        # imports the generated GLB on its side. Convert Z-up -> glTF Y-up here
        # so Blender's normal glTF import restores the original Z-up geometry.
        vertices_gltf = vertices[:, [0, 2, 1]].copy()
        vertices_gltf[:, 2] *= -1.0

        geometry = trimesh.Trimesh(
            vertices=vertices_gltf,
            faces=faces,
            process=False,
        )
        geometry.export(str(output_glb))
        print("[INFO] Export géométrie seule : axe glTF Y-up appliqué ; UV/rendu/bake TRELLIS ignorés.")
    else:
        glb = postprocessing_utils.to_glb(
            outputs["gaussian"][0],
            outputs["mesh"][0],
            simplify=args.simplify,
            texture_size=args.texture_size,
        )
        glb.export(str(output_glb))

    if args.save_ply:
        output_ply = output_dir / (output_stem + ".ply")
        outputs["gaussian"][0].save_ply(str(output_ply))
        print(f"[OK] PLY : {output_ply}")

    if not output_glb.is_file() or output_glb.stat().st_size <= 0:
        raise RuntimeError(f"TRELLIS completed but no valid GLB was produced: {output_glb}")

    print(f"[OK] GLB : {output_glb}")
    return 0


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Asset Factory TRELLIS runner with PyTorch-SDPA sparse compatibility"
    )
    parser.add_argument(
        "--input",
        action="append",
        default=[],
        help="Image d'entrée. Répétez --input pour activer le mode multi-image.",
    )
    parser.add_argument("--asset-id", default="")
    parser.add_argument("--output-dir")
    parser.add_argument(
        "--multi-image-mode",
        choices=("stochastic", "multidiffusion"),
        default="stochastic",
        help="Méthode de fusion utilisée par TRELLIS lorsque plusieurs images sont fournies.",
    )
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--models-dir", type=Path, default=default_models_dir())
    parser.add_argument("--check-models", action="store_true")
    parser.add_argument("--simplify", type=float, default=0.95)
    parser.add_argument("--texture-size", type=int, default=1024)
    parser.add_argument("--geometry-only", action="store_true")
    parser.add_argument("--save-ply", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if not args.self_test and not args.check_models:
        if not args.input:
            parser.error("--input est requis sauf avec --self-test ou --check-models")
        if not args.output_dir:
            parser.error("--output-dir is required unless --self-test is used")
    return args


def main() -> int:
    args = _parse_args()
    args.models_dir = args.models_dir.expanduser().resolve()
    configure_offline(args.models_dir)
    if args.self_test:
        return _self_test()
    check_local_models(args.models_dir)
    if args.check_models:
        print("[OK] Vérification des modèles locaux réussie ; aucune génération n’a été lancée.")
        return 0
    return _run(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("[FAIL] Interrompu", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise
