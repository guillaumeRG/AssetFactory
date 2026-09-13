from __future__ import annotations

from typing import Any

import torch
import torch.nn.functional as F

from . import fmha
from .fmha import BlockDiagonalMask


def _sdpa(q: torch.Tensor, k: torch.Tensor, v: torch.Tensor, p: float, scale: float | None) -> torch.Tensor:
    # Les tenseurs xFormers/TRELLIS sont au format [B, N, H, C]. PyTorch SDPA attend
    # le format [B, H, N, C].
    q_t = q.transpose(1, 2)
    k_t = k.transpose(1, 2)
    v_t = v.transpose(1, 2)

    kwargs: dict[str, Any] = {
        "dropout_p": float(p),
        "is_causal": False,
    }
    if scale is not None:
        kwargs["scale"] = float(scale)

    out = F.scaled_dot_product_attention(q_t, k_t, v_t, **kwargs)
    return out.transpose(1, 2)


def memory_efficient_attention(
    query: torch.Tensor,
    key: torch.Tensor,
    value: torch.Tensor,
    attn_bias: object | None = None,
    p: float = 0.0,
    scale: float | None = None,
    op: object | None = None,
    **_: object,
) -> torch.Tensor:
    """Sous-ensemble de ``xformers.ops.memory_efficient_attention`` utilisé par TRELLIS.

    ``op`` est accepté pour compatibilité avec l'API mais volontairement ignoré : PyTorch
    choisit l'implémentation SDPA disponible pour le GPU courant.
    """

    del op

    if query.ndim != 4 or key.ndim != 4 or value.ndim != 4:
        raise ValueError(
            "Asset Factory SDPA shim expects query/key/value shaped [B, N, H, C]"
        )
    if query.shape[0] != key.shape[0] or query.shape[0] != value.shape[0]:
        raise ValueError("query/key/value batch sizes must match")
    if key.shape[1] != value.shape[1]:
        raise ValueError("key/value sequence lengths must match")
    if query.shape[2] != key.shape[2] or query.shape[2] != value.shape[2]:
        raise ValueError("query/key/value head counts must match")

    if attn_bias is None:
        return _sdpa(query, key, value, p=p, scale=scale)

    if not isinstance(attn_bias, BlockDiagonalMask):
        raise TypeError(
            "Asset Factory SDPA shim supports only BlockDiagonalMask or no attention bias"
        )

    if query.shape[0] != 1:
        raise ValueError(
            "TRELLIS block-diagonal sparse attention is expected to use a flattened batch of size 1"
        )

    if sum(attn_bias.q_seqlen) != query.shape[1]:
        raise ValueError(
            "BlockDiagonalMask Q lengths do not match the query sequence length"
        )
    if sum(attn_bias.kv_seqlen) != key.shape[1]:
        raise ValueError(
            "BlockDiagonalMask KV lengths do not match the key/value sequence length"
        )

    blocks = []
    q_start = 0
    kv_start = 0

    for q_len, kv_len in zip(attn_bias.q_seqlen, attn_bias.kv_seqlen):
        q_block = query[:, q_start:q_start + q_len]
        k_block = key[:, kv_start:kv_start + kv_len]
        v_block = value[:, kv_start:kv_start + kv_len]
        blocks.append(_sdpa(q_block, k_block, v_block, p=p, scale=scale))
        q_start += q_len
        kv_start += kv_len

    return torch.cat(blocks, dim=1)


__all__ = ["fmha", "BlockDiagonalMask", "memory_efficient_attention"]
