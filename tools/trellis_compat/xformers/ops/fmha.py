from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Tuple


@dataclass(frozen=True)
class BlockDiagonalMask:
    """Remplacement minimal de xformers.ops.fmha.BlockDiagonalMask.

    TRELLIS n'utilise que ``from_seqlens`` et retransmet l'objet résultant à
    ``memory_efficient_attention``. Nous conservons les longueurs de séquence et exécutons
    chaque bloc indépendamment avec PyTorch SDPA, ce qui évite un grand masque dense.
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
