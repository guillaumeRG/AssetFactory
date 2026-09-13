# Cycle complet de génération

## Image depuis un prompt

```powershell
.\tools\generate-image.ps1 `
    -Prompt "single industrial work light" `
    -AssetId "WorkLight_Ref_01" `
    -Candidates 8
```

```text
Prompt
  -> FLUX x N
  -> scoring
  -> meilleure image
  -> STOP
```

## Asset depuis une image

```powershell
.\tools\generate-asset-from-image.ps1 `
    -InputPath ".\reference.png" `
    -AssetId "WorkLight_01" `
    -GeometryMethod trellis
```

```text
Image
  -> multi-vues optionnel
  -> TRELLIS ou TripoSR
  -> raw/
  -> Blender
  -> final/
  -> Unreal optionnel
```

## Asset depuis un prompt

```powershell
.\tools\generate-asset-from-prompt.ps1 `
    -Prompt "single industrial work light" `
    -AssetId "WorkLight_01" `
    -Candidates 8 `
    -GeometryMethod trellis `
    -MultiviewMethod none
```

Le même appel avec :

```powershell
-MultiviewMethod zero123plus-v1.1
```

insère simplement l'étape multi-vues entre l'image sélectionnée et TRELLIS.

## Versionnement

```text
outputs/assets/<AssetId>/v001/
outputs/assets/<AssetId>/v002/
```

Une génération contient :

```text
source/
raw/
final/
logs/
metadata/
generation.json
```

Le `raw/` n'est jamais remplacé par la normalisation Blender ; la sortie prête à importer reste sous `final/`.

## GPU

Après une génération d'image depuis un prompt, Asset Factory peut demander à ComfyUI de libérer sa VRAM avant la reconstruction 3D. Les traitements lourds restent séquentiels dans le pipeline complet.

## Import Unreal

L'import est déclenché uniquement après Blender lorsque `AutoImport` est activé et qu'un profil de destination valide est fourni.
