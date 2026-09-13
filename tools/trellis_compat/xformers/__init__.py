"""Shim de compatibilité Asset Factory pour la petite surface xFormers utilisée par TRELLIS.

Il ne s'agit pas de xFormers. Le commit TRELLIS 442aa1e impose en dur le backend
d'attention creuse ``xformers`` ou ``flash_attn``. Sous Windows/Blackwell, le wheel
officiel xFormers ne fournit actuellement aucun kernel d'attention économe en mémoire
utilisable. Asset Factory n'expose donc que les deux symboles requis par TRELLIS
et les implémente avec PyTorch SDPA.
"""

ASSET_FACTORY_SDPA_SHIM = True
__version__ = "asset-factory-sdpa-shim-1.0"

from . import ops

__all__ = ["ops", "ASSET_FACTORY_SDPA_SHIM"]
