# Asset Factory V0.9.1

Asset Factory génère et prépare localement des assets 3D à partir d'un prompt texte ou d'une image.

```text
Prompt
  -> image
  -> génération 3D
  -> normalisation Blender
  -> texturing multi-vues optionnel
  -> import Unreal optionnel
```

Moteurs 3D pris en charge :

- **TRELLIS**
- **TripoSR**

Le mode multi-vues est optionnel et s'active avec `-Multiview $true`.

---

## Aperçu V0.8

<table>
  <tr>
    <td align="center"><strong>Prompt</strong></td>
    <td align="center"><strong>Image de référence</strong></td>
    <td align="center"><strong>Asset importé dans Unreal Engine</strong></td>
  </tr>
  <tr>
    <td align="center">/</td>
    <td align="center"><img src="docs/images/demo-chair-reference.png" alt="Chaise de référence" width="260"></td>
    <td align="center"><img src="docs/images/demo-chair-unreal.png" alt="Chaise générée et importée dans Unreal Engine" width="260"></td>
  </tr>
  <tr>
    <td align="center">A compact industrial spaceship fuel tank, single isolated object, realistic hard-surface design, short vertical cylindrical body with rounded end caps, sturdy metal construction, slightly worn off-white painted surface, subtle scratches and edge wear, two dark metal support bands around the tank, small red valve and simple pipe connector on top, a few technical details but clean overall silhouette, functional utilitarian design, fully visible, centered, three-quarter view, neutral plain light gray background, soft studio lighting, even exposure, clear readable shape, realistic product render, no environment, no text, no logo, no character.</td>
    <td align="center"><img src="docs/images/FuelTank_01.png" width="260"></td>
    <td align="center"><img src="docs/images/fuel_tank_3d.png" width="260"><img src="docs/images/fuel_tank_3d2.png" width="260"></td>
  </tr>
  <tr>
    <td align="center">A rugged industrial portable work light, rectangular black metal housing, large circular glass lamp, yellow tubular protective frame, black top handle, side adjustment knob, realistic industrial construction, single isolated object</td>
    <td align="center"><img src="docs/images/TEST_Image_Single.png" width="260"></td>
    <td align="center"><img src="docs/images/worklight_3d_2.png" width="260"><img src="docs/images/worklight_3d.png" width="260"></td>
  </tr>
</table>

## Aperçu V0.9 multiview texturing

<table>
  <tr>
    <td align="center">old industrial metal barrel, worn painted steel, scratches, rust marks, realistic game asset</td>
    <td align="center"><img src="docs/images/Barrel.png" width="260"></td>
    <td align="center"><img src="docs/images/Barrel_3d.png" width="260"></td>
  </tr>
</table>

---

## Prérequis machine

Pour l'installation complète :

- Windows 11 x64 avec **App Installer / winget** disponible ;
- PowerShell 5.1+ ou PowerShell 7+ ;
- GPU NVIDIA compatible et **pilote NVIDIA déjà installé** (`nvidia-smi` doit fonctionner) ;
- connexion Internet pour les dépôts, environnements Python et modèles.

Le setup installe ou prépare automatiquement, uniquement lorsqu'ils sont absents ou invalides :

- Git ;
- Python 3.12, ainsi que les versions Python isolées requises par les moteurs ;
- Blender ;
- Visual Studio 2022 C++ Build Tools ;
- CUDA Toolkit 13.4 et son intégration VS2022 ;
- ComfyUI + FLUX Schnell ;
- TRELLIS (bootstrap, runtime, extensions natives et modèles) ;
- TripoSR ;
- StableGen et les modèles de texturing multi-vues.

Le pilote NVIDIA reste volontairement externe : depuis CUDA 13.1, le Toolkit Windows ne contient plus le pilote graphique. Unreal Engine reste également optionnel et n'est nécessaire que pour l'import automatique.

---

## Installation

Si Git est déjà disponible :

```powershell
git clone https://github.com/guillaumeRG/AssetFactory.git
Set-Location .\AssetFactory
.\setup-asset-factory.ps1 install
```

Sur un Windows réellement vierge sans Git, télécharge d'abord l'archive ZIP du dépôt, extrais-la, ouvre PowerShell dans le dossier extrait puis lance :

```powershell
.\setup-asset-factory.ps1 install
```

`install` est le chemin normal et **complet**. Il est idempotent : un second lancement réutilise les outils, dépôts épinglés, venvs et modèles déjà valides au lieu de tout réinstaller.

Pour installer uniquement le socle Git/Python/Blender :

```powershell
.\setup-asset-factory.ps1 install -CoreOnly
```

Pour vérifier sans rien installer ni télécharger :

```powershell
.\setup-asset-factory.ps1 install -NoInstall
```

Vérification complète :

```powershell
.\setup-asset-factory.ps1 status
.\setup-asset-factory.ps1 doctor
```

Quand tout est prêt, le doctor termine par :

```text
[OK] ASSET FACTORY READY
```

### Installation manuelle par composant

Le chemin complet précédent est recommandé. Pour diagnostiquer ou préparer les composants séparément :

```powershell
.\setup-asset-factory.ps1 comfyui install
.\setup-asset-factory.ps1 comfyui model-install

.\setup-asset-factory.ps1 trellis install
.\setup-asset-factory.ps1 trellis runtime-install
.\setup-asset-factory.ps1 trellis native-install
.\setup-asset-factory.ps1 trellis model-install

.\setup-asset-factory.ps1 triposr install
.\setup-asset-factory.ps1 multiview install
```

L'ordre TRELLIS ci-dessus est important sur une machine neuve.

---

## Démarrer ComfyUI

```powershell
Set-Location .\engines\comfyui
.\.venv\Scripts\python.exe .\main.py --lowvram --listen 127.0.0.1 --port 8188
```

Puis revenir dans un second terminal à la racine d'Asset Factory.

---

# Utilisation

Asset Factory expose trois commandes principales.

## 1. Générer une image depuis un prompt

Une seule image :

```powershell
.\tools\generate-image.ps1 `
    -Prompt "compact industrial storage tank, worn metal, isolated object, neutral studio background" `
    -AssetId "StorageTank_Ref_01" `
    -Candidates 1 `
    -Seed 1234
```

Sélection automatique de la meilleure image parmi plusieurs candidats :

```powershell
.\tools\generate-image.ps1 `
    -Prompt "compact industrial storage tank, worn metal, isolated object, neutral studio background" `
    -NegativePrompt "text, logo, broken geometry" `
    -AssetId "StorageTank_Ref_02" `
    -Candidates 8 `
    -Seed 1234
```

`-Candidates 1` génère une seule image.

`-Candidates N` génère N candidats puis conserve automatiquement la meilleure référence.

---

## 2. Générer un asset depuis une image

### TRELLIS direct

```powershell
.\tools\generate-asset-from-image.ps1 `
    -InputPath ".\reference.png" `
    -AssetId "StorageTank_01" `
    -GeometryMethod trellis `
    -TargetHeight 1.5 `
    -AutoImport $false
```

### TRELLIS avec texturing multi-vues

```powershell
.\tools\generate-asset-from-image.ps1 `
    -InputPath ".\reference.png" `
    -AssetId "StorageTank_MV_01" `
    -GeometryMethod trellis `
    -Multiview $true `
    -MultiviewCameras 16 `
    -TexturePrompt "compact industrial storage tank, worn metal, realistic industrial asset" `
    -TargetHeight 1.5 `
    -AutoImport $false
```

### TripoSR

```powershell
.\tools\generate-asset-from-image.ps1 `
    -InputPath ".\reference.png" `
    -AssetId "StorageTank_TripoSR_01" `
    -GeometryMethod triposr `
    -TargetHeight 1.5 `
    -AutoImport $false
```

---

## 3. Générer un asset directement depuis un prompt

### Best-of-N puis TRELLIS direct

```powershell
.\tools\generate-asset-from-prompt.ps1 `
    -Prompt "compact industrial storage tank, worn metal, isolated object, neutral studio background" `
    -NegativePrompt "text, logo, broken geometry" `
    -AssetId "StorageTank_02" `
    -Candidates 8 `
    -Seed 1234 `
    -GeometryMethod trellis `
    -TargetHeight 1.5 `
    -AutoImport $false
```

### Best-of-N puis TRELLIS avec texturing multi-vues

```powershell
.\tools\generate-asset-from-prompt.ps1 `
    -Prompt "compact industrial storage tank, worn metal, isolated object, neutral studio background" `
    -AssetId "StorageTank_MV_02" `
    -Candidates 8 `
    -GeometryMethod trellis `
    -Multiview $true `
    -MultiviewCameras 16 `
    -TargetHeight 1.5 `
    -AutoImport $false
```

### Best-of-N puis TripoSR

```powershell
.\tools\generate-asset-from-prompt.ps1 `
    -Prompt "compact industrial storage tank, worn metal, isolated object, neutral studio background" `
    -AssetId "StorageTank_TripoSR_02" `
    -Candidates 4 `
    -GeometryMethod triposr `
    -TargetHeight 1.5 `
    -AutoImport $false
```

---

## Paramètres principaux

```text
-Prompt            prompt image
-NegativePrompt    éléments à éviter
-AssetId           identifiant de l'asset
-Candidates        nombre d'images candidates
-Seed              seed de génération
-InputPath         image source existante
-GeometryMethod    trellis ou triposr
-Multiview         active le texturing multi-vues
-MultiviewCameras  nombre de caméras multi-vues
-TexturePrompt     prompt de texturing (requis depuis une image)
-TargetHeight      hauteur finale en mètres
-ProjectProfile    profil Unreal optionnel
-AutoImport        import Unreal automatique
-Postprocess       none ou qa
```

Contrôle qualité visuel optionnel :

```powershell
.\tools\generate-asset-from-image.ps1 `
    -InputPath ".\reference.png" `
    -AssetId "StorageTank_QA_01" `
    -GeometryMethod trellis `
    -Postprocess qa
```

`qa` produit un rapport et des rendus de contrôle sans modifier l'asset.

---

## Import Unreal

```powershell
.\tools\generate-asset-from-image.ps1 `
    -InputPath ".\reference.png" `
    -AssetId "Console_01" `
    -GeometryMethod trellis `
    -TargetHeight 1.2 `
    -ProjectProfile ".\profiles\mon-projet.json" `
    -AutoImport $true
```

---

## Batches

Image uniquement :

```powershell
.\tools\run-batch.ps1 `
    -BatchPath ".\batches\mon-batch.json" `
    -Mode images `
    -Candidates 8
```

Pipeline complet :

```powershell
.\tools\run-batch.ps1 `
    -BatchPath ".\batches\mon-batch.json" `
    -Mode full `
    -Engine trellis `
    -Candidates 8 `
    -AutoImport $false
```

Pipeline complet avec texturing multi-vues :

```powershell
.\tools\run-batch.ps1 `
    -BatchPath ".\batches\mon-batch.json" `
    -Mode full `
    -Engine trellis `
    -Multiview $true `
    -MultiviewCameras 8 `
    -TextureResolution 2048 `
    -AutoImport $false
```

Les mêmes paramètres peuvent être placés dans le manifeste au niveau batch ou asset : `multiview`, `multiviewCameras`, `textureResolution`, `textureCheckpoint`, `texturePrompt`, `textureNegativePrompt` et `keepProjectedBlend`.

---

## Sorties

Les assets sont versionnés :

```text
outputs/
└─ assets/
   └─ StorageTank_01/
      ├─ v001/
      ├─ v002/
      └─ ...
```

Une génération peut contenir notamment :

```text
source/
raw/
final/
logs/
metadata/
generation.json
```

Les versions existantes ne sont pas écrasées.

---

## Vérifications

```powershell
.\setup-asset-factory.ps1 status
.\setup-asset-factory.ps1 doctor
.\setup-asset-factory.ps1 comfyui status
.\setup-asset-factory.ps1 comfyui doctor
.\setup-asset-factory.ps1 triposr status
.\setup-asset-factory.ps1 triposr doctor
.\setup-asset-factory.ps1 trellis model-status
```

Tests du cycle :

```powershell
.\tests\test-cycle-contracts.ps1
```

---

## Structure

```text
AssetFactory/
├─ batches/
├─ blender/
├─ config/
├─ docs/
├─ engines/
├─ models/
├─ outputs/
├─ profiles/
├─ tools/
│  ├─ generate-image.ps1
│  ├─ generate-asset-from-image.ps1
│  ├─ generate-asset-from-prompt.ps1
│  ├─ internal/
│  └─ run-batch.ps1
├─ unreal/
├─ workflows/
├─ setup-asset-factory.ps1
└─ README.md
```

Les anciens scripts `run-*.ps1` restent disponibles pour le debug et les usages bas niveau.
