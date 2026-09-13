# Architecture Asset Factory

## Principe

L'architecture publique est volontairement limitée à trois opérations :

```text
Prompt -> Image
Image  -> Asset 3D
Prompt -> Asset 3D
```

Les moteurs ne doivent pas dicter les points d'entrée utilisateurs.

## Points d'entrée publics

```text
tools/generate-image.ps1
tools/generate-asset-from-image.ps1
tools/generate-asset-from-prompt.ps1
```

### `generate-image.ps1`

Responsabilité : produire une image exploitable à partir d'un prompt.

```text
prompt
  -> ComfyUI / FLUX
  -> 1..N candidats
  -> scoring optionnel
  -> image sélectionnée
```

La logique best-of-N est indépendante de la reconstruction 3D.

### `generate-asset-from-image.ps1`

Responsabilité : transformer une image existante en asset 3D.

```text
image
  -> multi-vues optionnel
  -> geometry method
  -> Blender
  -> Unreal optionnel
```

`MultiviewMethod=none` envoie directement l'image au moteur de géométrie.

### `generate-asset-from-prompt.ps1`

Responsabilité : composer les deux opérations précédentes sans introduire une nouvelle logique métier.

```text
prompt
  -> image stage
  -> asset-from-image stage
```

Les paramètres d'image (`Candidates`, `Preset`, `Exclude`) restent orthogonaux aux paramètres 3D (`GeometryMethod`, `MultiviewMethod`).

## Code partagé

`tools/internal/AssetFactory.Pipeline.psm1` contient l'orchestration partagée, notamment `Invoke-AFImageStage`.

Cette fonction est appelée par :

- `generate-image.ps1` ;
- le mode prompt du pipeline direct ;
- le runner multi-vues lorsqu'il doit créer sa référence.

La génération des candidats, l'application des presets et leur scoring ne doivent exister qu'à cet endroit.

## Briques internes

Les fichiers suivants restent des runners bas niveau :

```text
run-comfyui.ps1
run-trellis.ps1
run-triposr.ps1
run-multiview.ps1
run-multiview-to-3d.ps1
import-unreal.ps1
```

Ils servent à l'implémentation, au diagnostic et à la reprise d'une étape. Ils ne sont pas les points d'entrée recommandés aux utilisateurs.

Le code des moteurs sous `engines/` reste intact.

## Règle de dépendance

```text
entrypoints publics
       |
       v
orchestration partagée
       |
       +--> image runner
       +--> multiview runner (optionnel)
       +--> geometry runner
       +--> Blender
       +--> Unreal (optionnel)
```

Aucune brique 3D ne doit réimplémenter la génération ou la sélection de l'image de référence.
