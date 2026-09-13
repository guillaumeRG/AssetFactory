# TRELLIS - nommage et emplacement des sorties

Le runner TRELLIS utilise l'identifiant de l'asset comme nom de fichier.

Exemples :

```text
chair.png + AssetId chair           -> chair.glb
crate.png + AssetId WoodenCrate_01  -> WoodenCrate_01.glb
```

Dans le pipeline complet, le GLB brut et le GLB final sont séparés :

```text
outputs/assets/WoodenCrate_01/v001/raw/WoodenCrate_01.glb
outputs/assets/WoodenCrate_01/v001/final/WoodenCrate_01.glb
```

Une nouvelle génération crée une nouvelle version (`v002`, `v003`, ...), sans remplacer la précédente.

Le PLY optionnel suit le même nom de base et reste dans `raw/`.

Le runner peut toujours être appelé directement :

```powershell
.\tools\run-trellis.ps1 -InputPath ".\reference.png" -AssetId "WoodenCrate_01"
```

Les sources de TRELLIS sous `engines/trellis` ne sont pas modifiées par ce mécanisme.
