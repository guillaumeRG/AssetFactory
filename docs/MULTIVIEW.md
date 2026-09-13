# Multi-vues

Le multi-vues est une **étape optionnelle** de la transformation image -> asset 3D.

Il ne possède plus de logique propre de génération ou de sélection de référence. La même brique d'image est utilisée partout dans Asset Factory.

## Usage normal

Depuis une image existante :

```powershell
.\tools\generate-asset-from-image.ps1 `
    -InputPath ".\reference.png" `
    -AssetId "WorkLight_MV_01" `
    -GeometryMethod trellis `
    -MultiviewMethod zero123plus-v1.1 `
    -TargetHeight 1.2
```

Depuis un prompt avec sélection best-of-N :

```powershell
.\tools\generate-asset-from-prompt.ps1 `
    -Prompt "A rugged industrial portable work light, single isolated object" `
    -NegativePrompt "multiple objects, text, logo, deformed geometry" `
    -AssetId "WorkLight_MV_01" `
    -Candidates 8 `
    -Preset "multiview-rigid" `
    -Exclude "power cable","loose wire" `
    -GeometryMethod trellis `
    -MultiviewMethod zero123plus-v1.1 `
    -TargetHeight 1.2
```

La même génération d'image peut être utilisée sans multi-vues en passant simplement :

```powershell
-MultiviewMethod none
```

## Chaîne interne

```text
image sélectionnée
  -> Zero123++
  -> vues cohérentes
  -> scoring / sélection des vues
  -> TRELLIS run_multi_image()
  -> Blender
  -> Unreal optionnel
```

La première méthode fournie est `zero123plus-v1.1`.

Les poses sont fixes et relatives à l'image d'entrée :

| Vue | Azimut | Élévation |
| ---: | ---: | ---: |
| 1 | 30° | 30° |
| 2 | 90° | -20° |
| 3 | 150° | 30° |
| 4 | 210° | -20° |
| 5 | 270° | 30° |
| 6 | 330° | -20° |

Les méthodes sont déclarées dans `config/multiview-methods.json`.

## Installation

```powershell
.\setup-asset-factory.ps1 multiview install -Method zero123plus-v1.1
.\setup-asset-factory.ps1 multiview model-install -Method zero123plus-v1.1
.\setup-asset-factory.ps1 multiview doctor -Method zero123plus-v1.1
```

## Sélection des vues

Avant TRELLIS, Asset Factory peut sélectionner un sous-ensemble des vues générées :

- `all` ;
- `balanced` ;
- `quality`.

Les paramètres publics utiles sont :

```text
-ViewPolicy
-MaxViews
-MinViewScore
-FusionMode
-IncludeReference
```

Le mode par défaut reste orienté qualité et limite le nombre de vues transmises à TRELLIS.

## Runners bas niveau

`run-multiview.ps1` et `run-multiview-to-3d.ps1` restent disponibles pour le diagnostic ou la reprise d'une étape précise. Ils sont considérés comme des briques internes et ne sont plus les commandes recommandées pour un usage normal.
