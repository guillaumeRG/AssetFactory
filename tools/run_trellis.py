from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from trellis_models import default_models_dir
from trellis_offline import configure_offline, check_local_models, load_local_pipeline


def _project_root() -> Path:
    return Path(__file__).resolve().parents[1]


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

    import torch
    import xformers
    from PIL import Image
    from trellis.utils import postprocessing_utils

    if not getattr(xformers, "ASSET_FACTORY_SDPA_SHIM", False):
        raise RuntimeError("The Asset Factory SDPA compatibility shim was not selected")
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is unavailable")

    input_path = Path(args.input).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    # Conserve le nom de l'image d'entrée ; seule son extension finale est remplacée.
    output_glb = output_dir / (input_path.stem + ".glb")

    if not input_path.is_file():
        raise FileNotFoundError(f"Input image does not exist: {input_path}")

    print(f"[INFO] TRELLIS root: {trellis_root}")
    print(f"[INFO] Input: {input_path}")
    print(f"[INFO] Output: {output_glb}")
    print("[INFO] Dense attention: PyTorch SDPA")
    print("[INFO] Sparse attention: Asset Factory xFormers-API shim -> PyTorch SDPA")
    print(f"[INFO] GPU: {torch.cuda.get_device_name(0)}")
    print("[INFO] Network mode: OFFLINE (local models only)")
    print(f"[INFO] Models: {args.models_dir}")

    pipeline = load_local_pipeline(args.models_dir)
    pipeline.cuda()

    with Image.open(input_path) as source:
        image = source.copy()

    # Ne décode que ce qui est nécessaire à l'export GLB. L'exemple officiel décode aussi
    # un champ de radiance et génère trois vidéos ; omettre ces chemins réduit la VRAM
    # et le calcul sur la cible Asset Factory d'environ 8 Gio sans modifier la génération
    # du maillage/GS requise par to_glb().
    outputs = pipeline.run(
        image,
        seed=args.seed,
        formats=["mesh", "gaussian"],
    )

    glb = postprocessing_utils.to_glb(
        outputs["gaussian"][0],
        outputs["mesh"][0],
        simplify=args.simplify,
        texture_size=args.texture_size,
    )
    glb.export(str(output_glb))

    if args.save_ply:
        output_ply = output_dir / (input_path.stem + ".ply")
        outputs["gaussian"][0].save_ply(str(output_ply))
        print(f"[OK] PLY: {output_ply}")

    if not output_glb.is_file() or output_glb.stat().st_size <= 0:
        raise RuntimeError(f"TRELLIS completed but no valid GLB was produced: {output_glb}")

    print(f"[OK] GLB: {output_glb}")
    return 0


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Asset Factory TRELLIS runner with PyTorch-SDPA sparse compatibility"
    )
    parser.add_argument("--input")
    parser.add_argument("--output-dir")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--models-dir", type=Path, default=default_models_dir())
    parser.add_argument("--check-models", action="store_true")
    parser.add_argument("--simplify", type=float, default=0.95)
    parser.add_argument("--texture-size", type=int, default=1024)
    parser.add_argument("--save-ply", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if not args.self_test and not args.check_models:
        if not args.input:
            parser.error("--input is required unless --self-test is used")
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
        print("[OK] Local model check passed; no generation was started.")
        return 0
    return _run(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("[FAIL] Interrupted", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"[FAIL] {type(exc).__name__}: {exc}", file=sys.stderr)
        raise
