"""Asset Factory compatibility shim for the tiny xFormers surface used by TRELLIS.

This is not xFormers.  TRELLIS commit 442aa1e hard-codes its sparse attention
backend to either ``xformers`` or ``flash_attn``.  On Windows/Blackwell, the
official xFormers wheel does not currently provide a usable memory-efficient
attention kernel.  Asset Factory therefore exposes only the two symbols TRELLIS
needs and implements them with PyTorch SDPA.
"""

ASSET_FACTORY_SDPA_SHIM = True
__version__ = "asset-factory-sdpa-shim-1.0"

from . import ops

__all__ = ["ops", "ASSET_FACTORY_SDPA_SHIM"]
