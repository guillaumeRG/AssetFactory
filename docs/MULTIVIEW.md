# Génération multi-vues

Asset Factory peut produire plusieurs vues cohérentes d'un même objet à partir d'une **seule image de référence**.

La chaîne est découpée en deux étapes indépendantes :

```text
Prompt ou image existante
  -> image de référence unique
  -> méthode image-vers-multi-vues
  -> vues cohérentes + métadonnées caméra
  -> méthode multi-vues-vers-3D
  -> normalisation Blender
  -> import Unreal optionnel
```

Cette séparation permet de tester ou remplacer la méthode multi-vues sans imposer une méthode de reconstruction 3D.

## Méthodes

Les méthodes disponibles sont déclarées dans `config/multiview-methods.json`. Le runner ne contient pas de liste d'angles codée sous forme de prompts : il délègue la synthèse des vues à la méthode sélectionnée.

La première méthode fournie est `zero123plus-v1.1`.

Elle utilise Zero123++ v1.1 pour synthétiser six vues à partir d'une image de référence. Les poses de caméra sont fixes et relatives à la vue d'entrée :

| Vue | Azimut | Élévation |
| ---: | ---: | ---: |
| 1 | 30° | 30° |
| 2 | 90° | -20° |
| 3 | 150° | 30° |
| 4 | 210° | -20° |
| 5 | 270° | 30° |
| 6 | 330° | -20° |

Source amont : <https://github.com/SUDO-AI-3D/zero123plus>

Le modèle v1.1 est publié sur Hugging Face sous l'identifiant `sudo-ai/zero123plus-v1.1`. Sa fiche de modèle indique une licence OpenRAIL : <https://huggingface.co/sudo-ai/zero123plus-v1.1>

## Installation

```powershell
.\setup-asset-factory.ps1 multiview install -Method zero123plus-v1.1
.\setup-asset-factory.ps1 multiview model-install -Method zero123plus-v1.1
.\setup-asset-factory.ps1 multiview doctor -Method zero123plus-v1.1
```

Le code du moteur, son environnement Python et ses poids restent des données d'exécution locales et ne sont pas versionnés dans Git.

Après `model-install`, le runner de production charge le modèle localement et active le mode hors ligne de Hugging Face/Diffusers.

## Générer depuis un prompt

ComfyUI doit être disponible pour créer l'image maîtresse :

```powershell
.\tools\run-multiview.ps1 `
    -Prompt "A rugged industrial portable work light, black metal body, yellow protective frame, single isolated object" `
    -NegativePrompt "multiple objects, text, logo, deformed geometry" `
    -AssetId "WorkLight_01" `
    -Seed 8127 `
    -Method "zero123plus-v1.1"
```

ComfyUI n'est appelé qu'une seule fois. Les six vues sont ensuite synthétisées à partir de cette image de référence.

## Générer depuis une image existante

```powershell
.\tools\run-multiview.ps1 `
    -ReferenceImage ".\reference.png" `
    -AssetId "WorkLight_01" `
    -Method "zero123plus-v1.1"
```

Une image non carrée est complétée avec des marges neutres plutôt que rognée, afin de conserver la silhouette complète.

## Paramétrer la méthode

Les paramètres peuvent être fournis directement :

```powershell
.\tools\run-multiview.ps1 `
    -ReferenceImage ".\reference.png" `
    -AssetId "WorkLight_01" `
    -Method "zero123plus-v1.1" `
    -Steps 40 `
    -GuidanceScale 4.5 `
    -KeepGrid $true
```

Ou via un profil :

```powershell
.\tools\run-multiview.ps1 `
    -ReferenceImage ".\reference.png" `
    -AssetId "WorkLight_01" `
    -MethodProfile ".\profiles\multiview.example.json"
```

Priorité de configuration :

```text
paramètre CLI explicite
  > profil multi-vues
  > valeur par défaut de la méthode
```

`ConditioningPrompt` est laissé vide par défaut : l'image de référence est la source principale d'identité de l'objet. Il peut être fourni explicitement pour les méthodes qui l'exploitent.

## Sorties

Exemple :

```text
outputs/assets/WorkLight_01/v001/
├─ source/
│  ├─ reference/
│  │  └─ WorkLight_01_reference.png
│  └─ views/
│     ├─ WorkLight_01_multiview_grid.png
│     ├─ WorkLight_01_view_01_az030_elp030.png
│     ├─ WorkLight_01_view_02_az090_elm020.png
│     └─ ...
├─ logs/
│  ├─ reference-comfyui.log
│  └─ multiview.log
├─ metadata/
│  ├─ reference-comfyui.json
│  └─ multiview.json
└─ generation.json
```

Les angles sont exprimés relativement à l'image de référence. Les noms ne prétendent donc pas qu'une vue est une face ou un arrière absolu de l'objet.

## Extension à d'autres méthodes

Le choix de méthode est indépendant du runner utilisateur. Une nouvelle implémentation image-vers-multi-vues doit :

1. être déclarée dans `config/multiview-methods.json` ;
2. disposer d'un fournisseur Python sous `tools/multiview/providers/` ;
3. recevoir une image de référence et produire des images de vues accompagnées de leurs informations caméra ;
4. utiliser un environnement isolé et des modèles locaux préparés par le setup.

Cette séparation permet d'ajouter ultérieurement d'autres méthodes sans changer le contrat utilisateur de `run-multiview.ps1`.

## Construire un asset 3D depuis une génération multi-vues

Une génération multi-vues validée peut être reconstruite avec :

```powershell
.\tools\run-multiview-to-3d.ps1 `
    -GenerationRoot ".\outputs\assets\WorkLight_01\v001" `
    -Method "trellis-multi-image" `
    -TargetHeight 1.2 `
    -FusionMode "stochastic"
```

Les méthodes de reconstruction sont déclarées dans `config/geometry-methods.json`. Le premier fournisseur utilise l'API multi-image native de TRELLIS.

Deux stratégies de fusion TRELLIS sont exposées :

- `stochastic` : stratégie par défaut de TRELLIS ;
- `multidiffusion` : agrège les prédictions des différentes vues à chaque étape.

On peut inclure ou exclure l'image de référence et sélectionner un sous-ensemble des vues :

```powershell
.\tools\run-multiview-to-3d.ps1 `
    -GenerationRoot ".\outputs\assets\WorkLight_01\v001" `
    -Method "trellis-multi-image" `
    -FusionMode "multidiffusion" `
    -IncludeReference $true `
    -ViewIndices 1,2,3,4,5,6 `
    -TargetHeight 1.2
```

Les paramètres peuvent aussi être placés dans `profiles/geometry.example.json`. La priorité reste :

```text
paramètre CLI explicite
  > profil de reconstruction
  > valeur par défaut de la méthode
```

Le GLB brut est écrit dans `raw/`, puis Blender produit le GLB final normalisé dans `final/`. L'import Unreal reste optionnel et utilise le même système de profil que le pipeline mono-image.


## Améliorations qualité (référence → multi-vues)

La chaîne `run-multiview.ps1` peut maintenant améliorer automatiquement la qualité en amont du moteur multi-vues :

- **preset de prompt de référence** via `config/reference-presets.json` ;
- **plusieurs références candidates** (`-ReferenceCandidates 4` par exemple) ;
- **sélection heuristique** de la meilleure référence (centrage, taille de l’objet, fond uniforme, objet non rogné) ;
- **rapport qualité multi-vues** (centrage, stabilité du cadrage, diversité perceptuelle des vues) écrit dans `metadata/multiview-quality.json`.

### Paramètres CLI utiles

```powershell
.	oolsun-multiview.ps1 `
  -Prompt "compact sci-fi generator module" `
  -AssetId "GeneratorModule" `
  -MethodProfile ".\profiles\multiview.example.json" `
  -ReferenceCandidates 4 `
  -ReferencePreset "multiview-object"
```

### Métadonnées supplémentaires

Le `generation.json` de la génération contient désormais :

- `methods.reference.promptUsed`
- `methods.reference.negativePromptUsed`
- `methods.reference.candidates[]`
- `methods.reference.quality`
- `methods.multiview.quality`
- `methods.multiview.qualityPath`

Ces rapports sont **informatifs** : ils n’arrêtent pas la pipeline, mais signalent les cas à revoir manuellement (vues trop similaires, cadrage instable, objet trop petit / trop grand, etc.).

## Réduction des détails difficiles

Pour les objets destinés à la reconstruction 3D, les éléments fins et flexibles (câbles, chaînes, sangles, tuyaux souples, cordes) peuvent produire des incohérences entre vues puis dégrader le maillage.

Deux mécanismes sont disponibles :

- `-ReferencePreset multiview-rigid` ajoute automatiquement ces éléments au prompt négatif ;
- `-ReferenceExclude` permet de choisir explicitement les détails à éviter.

Exemple :

```powershell
.\tools\run-multiview.ps1 `
  -Prompt "A rugged industrial portable work light, black metal housing, yellow protective frame" `
  -AssetId "WorkLight_Rigid_01" `
  -ReferenceCandidates 4 `
  -ReferencePreset "multiview-rigid" `
  -ReferenceExclude "power cable","loose wire" `
  -Method "zero123plus-v1.1"
```

Ce filtrage est optionnel : il ne faut pas l'utiliser si ces éléments font réellement partie de l'asset final souhaité.

## Sélection des vues avant TRELLIS

`run-multiview-to-3d.ps1` peut maintenant limiter les vues envoyées à TRELLIS. Cela évite qu'une vue visuellement faible ou redondante dégrade toutes les étapes de reconstruction.

Politiques disponibles :

- `all` : toutes les vues générées ;
- `balanced` : sous-ensemble réparti autour de l'objet ;
- `quality` : filtre les vues faibles puis conserve un sous-ensemble réparti et de meilleure qualité.

Le mode par défaut est `quality`, avec au maximum 4 vues (`maxViews=4`). Un `ViewIndices` explicite reste prioritaire et désactive la sélection automatique.

Exemple :

```powershell
.\tools\run-multiview-to-3d.ps1 `
  -GenerationRoot ".\outputs\assets\WorkLight_Rigid_01\v001" `
  -ViewPolicy "quality" `
  -MaxViews 4 `
  -MinViewScore 45 `
  -IncludeReference $true `
  -FusionMode "stochastic" `
  -TargetHeight 1.2
```

Les vues réellement utilisées et la raison de la sélection sont enregistrées dans `metadata/geometry.json`.
