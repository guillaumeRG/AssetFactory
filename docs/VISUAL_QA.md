# Visual QA

Le Visual QA est un post-process optionnel exécuté après la normalisation Blender et avant l'import Unreal.

Il analyse l'asset sans modifier le mesh.

## Activation

Depuis une image :

```powershell
.\tools\generate-asset-from-image.ps1 `
    -InputPath ".\reference.png" `
    -AssetId "Asset_01" `
    -GeometryMethod trellis `
    -Postprocess qa
```

Depuis un prompt :

```powershell
.\tools\generate-asset-from-prompt.ps1 `
    -Prompt "single industrial object, neutral studio background" `
    -AssetId "Asset_01" `
    -Candidates 4 `
    -GeometryMethod trellis `
    -Postprocess qa
```

Le même paramètre fonctionne avec le pipeline multi-vues.

## Architecture

```text
reference image
      +
final mesh
      |
      v
prepare-reference
      |
      +--> reference mask
      |
      v
Blender QA
      |
      +--> camera matching
      +--> beauty
      +--> silhouette
      +--> clay
      +--> albedo
      +--> normal
      +--> depth
      |
      v
qa_core
      |
      +--> silhouette error
      +--> contour error
      +--> chroma error
      +--> anomaly map
      +--> qa-report.json
```

L'orchestration est centralisée dans `Invoke-AFVisualQA` dans `tools/internal/AssetFactory.Pipeline.psm1`.

Le traitement d'image déterministe est dans `tools/internal/postprocess/qa_core.py`. Le code dépendant de Blender est isolé dans `tools/internal/postprocess/blender_qa.py`.

## Recherche de caméra

La caméra est estimée à partir de la silhouette de l'image de référence.

La recherche se fait en deux passes :

1. grille grossière d'azimuts et d'élévations ;
2. raffinement local autour de la meilleure pose avec plusieurs focales.

Le score combine :

```text
silhouette IoU
bbox similarity
center similarity
occupancy similarity
```

La caméra retenue est ensuite réutilisée pour toutes les passes de contrôle.

## Analyse

Le rapport contient des métriques séparées :

```text
silhouetteIoU
edgeF1
color.meanDeltaE
color.p95DeltaE
overallScore
```

`overallScore` est un résumé pratique. Les métriques individuelles restent la source principale pour le diagnostic.

Les anomalies sont décrites avec un contrat commun :

```json
{
  "id": "A001",
  "type": "geometry",
  "subtype": "silhouette_mismatch",
  "severity": 0.03,
  "bbox": [10, 20, 80, 120],
  "autoFixable": false
}
```

Les types actuellement produits sont :

```text
geometry / silhouette_mismatch
geometry / contour_mismatch
color / chroma_mismatch
```

## Sorties

Quand le QA est activé :

```text
qa/
├─ reference/
│  ├─ reference-mask.png
│  ├─ reference-mask-search.png
│  └─ reference-analysis.json
├─ renders/
│  ├─ beauty.png
│  ├─ silhouette.png
│  ├─ clay.png
│  ├─ albedo.png
│  ├─ normal.png
│  └─ depth.png
├─ maps/
│  ├─ silhouette-error.png
│  ├─ edge-error.png
│  ├─ color-error.png
│  └─ anomaly-map.png
├─ camera.json
└─ qa-report.json
```

Les logs sont écrits dans `logs/visual-qa-*.log`.

## Fiabilité

Le Visual QA est non bloquant. Si l'analyse échoue :

```text
asset final conserve
postprocess.status = failed
pipeline 3D conserve
import Unreal peut continuer
```

Le mode `qa` n'écrit jamais dans `raw/` ou `final/` et ne modifie pas le mesh.

Une faible confiance du masque ou du camera matching produit un rapport `limited` et des warnings au lieu d'inventer un diagnostic fiable.

## Configuration

Les réglages internes sont centralisés dans :

```text
config/postprocess.json
```

La ligne de commande publique reste volontairement limitée à :

```text
-Postprocess none
-Postprocess qa
```

Les correcteurs automatiques ne font pas partie de cette version. Ils pourront consommer le même `qa-report.json` sans modifier l'API de génération.
