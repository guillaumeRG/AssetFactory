# Organisation des sorties

Asset Factory regroupe les fichiers générés sous `outputs/` selon leur rôle.

## Générations d'assets

Une génération complète est toujours rattachée à un identifiant d'asset et à une version :

```text
outputs/assets/<AssetId>/vNNN/
```

Exemple :

```text
outputs/assets/WoodenCrate_01/v001/
```

Une nouvelle génération du même asset prend automatiquement la prochaine version libre (`v002`, `v003`, etc.). Une version déjà créée n'est pas réutilisée par défaut.

Structure d'une génération TRELLIS :

```text
v001/
├─ source/
│  └─ WoodenCrate_01.png
├─ raw/
│  └─ WoodenCrate_01.glb
├─ final/
│  └─ WoodenCrate_01.glb
├─ logs/
│  ├─ comfyui.log
│  ├─ trellis.log
│  ├─ blender.log
│  ├─ unreal.log
│  └─ unreal-runner.log
├─ metadata/
│  ├─ comfyui.json
│  ├─ comfyui-workflow.json
│  ├─ trellis.json
│  └─ unreal.json
├─ qa/                       # uniquement avec -Postprocess qa
│  ├─ reference/
│  ├─ renders/
│  ├─ maps/
│  ├─ camera.json
│  └─ qa-report.json
└─ generation.json
```

Avec TripoSR, `raw/` contient l'OBJ produit par le moteur et `final/` contient les fichiers OBJ/FBX normalisés par Blender.

Tous les fichiers ne sont présents que si l'étape correspondante a été exécutée. Par exemple, `unreal.log`, `unreal-runner.log` et `unreal.json` n'existent pas lorsque l'import Unreal est désactivé.

## Rôle des sous-dossiers

- `source/` : image utilisée comme entrée du moteur 3D ;
- `raw/` : sortie brute de TRELLIS ou TripoSR ;
- `final/` : résultat normalisé par Blender, prêt à être utilisé/importé ;
- `logs/` : sortie détaillée de chaque étape ;
- `metadata/` : métadonnées techniques propres aux sous-étapes ;
- `qa/` : rendus, cartes d'erreur et rapport du Visual QA optionnel ;
- `generation.json` : résumé de la génération complète.

Les fichiers intermédiaires sont conservés volontairement. Un échec Blender ou Unreal ne force donc pas à recalculer la génération 3D.


## Images candidates

Avec `Candidates > 1`, la meilleure image reste la source canonique de la génération :

```text
source/<AssetId>.png
```

Les candidats sont conservés séparément :

```text
source/candidates/<AssetId>_candidate_01.png
source/candidates/<AssetId>_candidate_02.png
...
metadata/image-selection.json
```

La même logique est utilisée pour une référence multi-vues, sous `source/reference/` et `source/reference/candidates/`.

## Batches

Les batches ne recopient pas les assets :

```text
outputs/batches/<BatchId>/<RunId>/
├─ logs/
└─ batch.json
```

`batch.json` référence les générations réelles stockées sous `outputs/assets/`.

## Imports Unreal lancés manuellement

Un appel direct à `tools/import-unreal.ps1` qui n'est pas rattaché à une génération écrit son suivi sous :

```text
outputs/imports/<AssetId>/<RunId>/
├─ import.json
└─ unreal.log
```

Lorsqu'un import est lancé par le pipeline complet, son log et ses métadonnées restent dans la génération de l'asset au lieu d'être dupliqués ici.

## Tests et diagnostics

Les smoke tests utilisent :

```text
outputs/tests/comfyui/<RunId>/
outputs/tests/triposr/<RunId>/
```

Les artefacts de diagnostic et de compilation utilisent :

```text
outputs/diagnostics/
```

Ils sont ainsi séparés des vrais assets produits.

## Verrous

Les verrous temporaires d'orchestration sont regroupés dans :

```text
outputs/.locks/
```

## Import Unreal versionné

Avec le profil d'exemple, la destination suit la même idée :

```text
/Game/AssetFactory/<Categorie optionnelle>/<AssetId>/vNNN/
```

Par défaut, `overwriteExistingVersion` vaut `false`. Si la version demandée existe déjà dans Unreal, l'importeur choisit la prochaine version libre au lieu de la remplacer.

Cette protection est indépendante des fichiers locaux. Même si `outputs/` a été supprimé, un asset Unreal déjà présent n'est pas écrasé silencieusement.

## Anciennes sorties

La refonte ne supprime et ne déplace **aucun ancien fichier automatiquement**. Cette règle évite toute perte d'asset lors d'une mise à jour du dépôt.

Après validation d'une première génération avec la nouvelle structure, les anciens dossiers de sortie devenus inutiles peuvent être archivés ou supprimés manuellement par l'utilisateur.
