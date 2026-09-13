from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Tuple


@dataclass(frozen=True)
class BlockDiagonalMask:
    """Minimal replacement for xformers.ops.fmha.BlockDiagonalMask.

    TRELLIS uses only ``from_seqlens`` and passes the resulting object back to
    ``memory_efficient_attention``.  We keep the sequence lengths and execute
    each block independently with PyTorch SDPA, avoiding a large dense mask.
    """

    q_seqlen: Tuple[int, ...]
    kv_seqlen: Tuple[int, ...]

    @classmethod
    def from_seqlens(
        cls,
        q_seqlen: Iterable[int],
        kv_seqlen: Iterable[int] | None = None,
    ) -> "BlockDiagonalMask":
        q = tuple(int(x) for x in q_seqlen)
        kv = q if kv_seqlen is None else tuple(int(x) for x in kv_seqlen)

        if len(q) != len(kv):
            raise ValueError(
                "BlockDiagonalMask requires the same number of Q and KV sequences"
            )
        if any(x <= 0 for x in q) or any(x <= 0 for x in kv):
            raise ValueError("Sequence lengths must be positive")

        return cls(q_seqlen=q, kv_seqlen=kv)
