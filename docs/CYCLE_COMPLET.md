# Cycle complet de génération

Le point d'entrée principal est :

```powershell
.\tools\run-image-to-3d.ps1
```

Il permet de choisir TRELLIS ou TripoSR sans dupliquer l'orchestration.

## Cycle depuis un prompt

```text
Prompt
  -> ComfyUI / FLUX
  -> image dans source/
  -> libération de la VRAM ComfyUI
  -> TRELLIS ou TripoSR
  -> modèle brut dans raw/
  -> Blender
  -> modèle normalisé dans final/
  -> import Unreal optionnel
```

## Cycle depuis une image

Avec `-InputPath`, l'étape ComfyUI est ignorée :

```text
Image existante
  -> copie dans source/
  -> TRELLIS ou TripoSR
  -> Blender
  -> import Unreal optionnel
```

## Choix du moteur

TRELLIS :

```powershell
.\tools\run-image-to-3d.ps1 `
    -Prompt "single wooden crate, neutral studio background" `
    -AssetId "WoodenCrate_01" `
    -TargetHeight 0.45 `
    -Engine trellis
```

TripoSR :

```powershell
.\tools\run-image-to-3d.ps1 `
    -Prompt "single wooden crate, neutral studio background" `
    -AssetId "WoodenCrate_01" `
    -TargetHeight 0.45 `
    -Engine triposr
```

Sans `-Engine`, TripoSR reste le moteur par défaut du mode `single`.

## Cycle multi-vues depuis le même point d'entrée

Le mode multi-vues est également lancé par `run-image-to-3d.ps1` :

```powershell
.\tools\run-image-to-3d.ps1 `
    -Mode multiview `
    -Prompt "single rigid industrial work light, isolated object, neutral studio background" `
    -AssetId "WorkLight_MV_01" `
    -ReferenceCandidates 8 `
    -ReferencePreset "multiview-rigid" `
    -ReferenceExclude "power cable","loose wire" `
    -TargetHeight 1.2 `
    -ProjectProfile ".\profiles\mon-projet.json" `
    -AutoImport $true
```

Cette commande enchaîne :

```text
prompt ou image
  -> référence(s) FLUX
  -> sélection de la référence
  -> moteur multi-vues
  -> scoring / sélection des vues
  -> TRELLIS run_multi_image()
  -> Blender
  -> import Unreal optionnel
```

Le mode multi-vues impose TRELLIS pour la reconstruction. Les runners `run-multiview.ps1` et `run-multiview-to-3d.ps1` restent des points d'entrée spécialisés pour le debug ou la reprise d'une étape sans recalculer toute la chaîne.

## Versionnement des générations

Toutes les sorties appartiennent à une génération :

```text
outputs/assets/<AssetId>/v001/
outputs/assets/<AssetId>/v002/
outputs/assets/<AssetId>/v003/
```

Le pipeline réserve une nouvelle version avant de lancer les traitements. Il refuse de réutiliser un dossier de version déjà existant.

Les données principales sont :

```text
source/       image de référence
raw/          sortie du moteur 3D
final/        sortie normalisée Blender
logs/         logs par étape
metadata/     métadonnées détaillées
generation.json
```

Voir `docs/OUTPUTS.md` pour le détail.

## Passage GPU entre ComfyUI et le moteur 3D

Par défaut, le pipeline demande à ComfyUI de décharger ses modèles avant de lancer TRELLIS ou TripoSR.

Il vérifie auparavant que la file ComfyUI est vide. Il n'interrompt pas un autre travail et ne purge pas la file d'attente.

Le verrou :

```text
outputs/.locks/image-to-3d.lock
```

empêche deux cycles complets Asset Factory de s'exécuter simultanément dans le même dépôt.

## Normalisation Blender

TRELLIS conserve le format GLB afin de préserver matériaux et textures :

```text
raw/<AssetId>.glb -> final/<AssetId>.glb
```

TripoSR suit :

```text
raw/<AssetId>.obj -> final/<AssetId>.obj + final/<AssetId>.fbx
```

Blender applique notamment la hauteur cible, le centrage X/Y et place la base géométrique à Z = 0.

## Import Unreal

L'import n'est déclenché qu'après la normalisation Blender.

Exemple :

```powershell
.\tools\run-image-to-3d.ps1 `
    -Prompt "single industrial console, neutral background" `
    -AssetId "Console_01" `
    -Engine trellis `
    -ProjectProfile ".\profiles\mon-projet.json" `
    -AutoImport $true
```

La destination est versionnée :

```text
/Game/AssetFactory/Console_01/v001/
```

ou, avec une catégorie :

```text
/Game/AssetFactory/Furniture/Industrial/Console_01/v001/
```

Si cette version existe déjà et que `overwriteExistingVersion` vaut `false`, l'importeur choisit la prochaine version libre.

Un échec d'import ne supprime pas `final/<AssetId>.*`. L'import peut donc être relancé sans recalculer ComfyUI, TRELLIS/TripoSR ou Blender.

## Batches

`tools/run-batch.ps1` appelle le même pipeline complet pour chaque asset lorsque le mode `full` est demandé.

Le dossier du batch contient uniquement son rapport et ses logs :

```text
outputs/batches/<BatchId>/<RunId>/
```

Les fichiers des assets restent dans leurs générations respectives sous `outputs/assets/`.

La priorité des paramètres est :

```text
ligne de commande > asset du manifest > manifest du batch > valeur par défaut
```

## Validation sans moteurs réels

Sous Windows :

```powershell
.\tests\test-cycle-contracts.ps1
```

Le test utilise des simulations de ComfyUI, TRELLIS, TripoSR, Blender et Unreal afin de vérifier l'orchestration sans calcul GPU ni modification d'un projet Unreal réel.
