# Asset Factory

Asset Factory est une chaîne locale, modulaire et reproductible de génération et de préparation d’assets 3D.

## Objectifs

Le pipeline actuellement validé permet de chaîner :

```text
Prompt
  -> génération d'image
  -> génération 3D
  -> post-traitement du mesh
  -> normalisation
  -> mise à l'échelle
  -> export OBJ / FBX
```

Les composants actuellement utilisés sont :

- ComfyUI pour l’exécution des workflows de génération d’images ;
- FLUX.1-schnell FP8 comme modèle d’image de référence ;
- TripoSR pour la conversion image vers 3D ;
- Blender pour le post-traitement et l’export des meshes ;
- PowerShell pour le bootstrap et l’orchestration ;
- des environnements Python isolés pour les moteurs IA.

---

## Principes

Asset Factory suit quelques règles simples :

- installation reproductible ;
- composants locaux isolés ;
- réutilisation des outils déjà installés lorsque c’est possible ;
- pas de modèles ou moteurs lourds versionnés dans Git ;
- traitements GPU lourds exécutés séquentiellement par défaut ;
- métadonnées conservées pour chaque job et pipeline ;
- sorties intermédiaires conservées lorsqu’elles facilitent le diagnostic ;
- paramètres propres au projet consommateur configurables plutôt que codés en dur.

---

## Structure du dépôt

```text
AssetFactory/
├─ batches/
├─ blender/
│  └─ scripts/
│     └─ process-mesh.py
├─ docs/
├─ engines/
│  ├─ comfyui/        # installation locale, ignorée par Git
│  └─ triposr/        # installation locale, ignorée par Git
├─ jobs/
├─ orchestrator/
├─ outputs/
├─ tools/
│  ├─ run-batch.ps1
│  ├─ run-comfyui.ps1
│  ├─ run-image-to-3d.ps1
│  └─ run-triposr.ps1
├─ workflows/
│  └─ comfyui-flux-schnell-base.json
├─ setup-asset-factory.ps1
└─ README.md
```
---

# Installation

Le bootstrap actuel cible Windows avec Windows PowerShell 5.1+ ou PowerShell 7+.

Cloner le dépôt :

```powershell
git clone https://github.com/guillaumeRG/AssetFactory.git
```

Entrer dans le dépôt :

```powershell
Set-Location .\AssetFactory
```

Installer ou détecter les outils partagés :

```powershell
.\setup-asset-factory.ps1 install
```

Le bootstrap tente de réutiliser les installations existantes lorsque celles-ci sont compatibles.

Pour effectuer uniquement la détection et l’initialisation sans installer de logiciel :

```powershell
.\setup-asset-factory.ps1 install -NoInstall
```

Afficher l’état général :

```powershell
.\setup-asset-factory.ps1 status
```

Vérifier le bootstrap partagé :

```powershell
.\setup-asset-factory.ps1 doctor
```

---

# Installation de TripoSR

Installer l’environnement isolé TripoSR :

```powershell
.\setup-asset-factory.ps1 triposr install
```

Afficher son état :

```powershell
.\setup-asset-factory.ps1 triposr status
```

Vérifier son environnement :

```powershell
.\setup-asset-factory.ps1 triposr doctor
```

Lancer le test réel image vers 3D :

```powershell
.\setup-asset-factory.ps1 triposr smoke
```

Les sorties du smoke test sont placées sous :

```text
outputs\triposr-smoke\
```

TripoSR utilise son propre environnement Python. Certaines dépendances natives peuvent nécessiter un toolkit CUDA et une chaîne de compilation C++ compatibles avec la version de PyTorch sélectionnée par le bootstrap.

---

# Installation de ComfyUI

Installer l’environnement isolé ComfyUI :

```powershell
.\setup-asset-factory.ps1 comfyui install
```

Afficher son état :

```powershell
.\setup-asset-factory.ps1 comfyui status
```

Vérifier son environnement :

```powershell
.\setup-asset-factory.ps1 comfyui doctor
```

Tester le démarrage de l’API :

```powershell
.\setup-asset-factory.ps1 comfyui smoke
```

Le smoke test démarre temporairement ComfyUI sur un port local libre, vérifie que l’API répond, puis arrête le processus.

---

# Installation du modèle d’image

Le workflow de référence actuel utilise :

```text
flux1-schnell-fp8.safetensors
```

Installer le checkpoint :

```powershell
.\setup-asset-factory.ps1 comfyui model-install
```

La commande est idempotente : un modèle déjà présent et valide est réutilisé.

Emplacement attendu :

```text
engines\comfyui\models\checkpoints\flux1-schnell-fp8.safetensors
```

Le checkpoint n’est pas stocké dans Git en raison de sa taille.

Source de référence :

```text
Comfy-Org/flux1-schnell
```

---

# Démarrer ComfyUI

Depuis le répertoire :

```text
engines\comfyui
```

lancer :

```powershell
.\.venv\Scripts\python.exe main.py --lowvram
```

L’API locale par défaut est alors disponible sur :

```text
http://127.0.0.1:8188
```

Le mode de lancement pourra évoluer afin d’être géré directement par l’orchestrateur.

---

# Générer une image

Une fois l’API ComfyUI démarrée :

```powershell
.\tools\run-comfyui.ps1 `
  -Prompt "industrial storage container, clean silhouette, neutral studio background" `
  -Seed 1234
```

Le runner :

1. charge le workflow API de référence ;
2. injecte le prompt, le prompt négatif et la seed ;
3. crée un job indépendant ;
4. soumet le workflow à ComfyUI ;
5. attend sa fin ;
6. récupère les images générées ;
7. écrit les résultats et métadonnées dans `outputs\jobs\`.

Chaque job possède son propre `job.json`.

---

# Générer un asset 3D complet

Le pipeline image vers 3D peut être lancé avec :

```powershell
.\tools\run-image-to-3d.ps1 `
  -Prompt "industrial storage container, clean silhouette, neutral studio background" `
  -Seed 1234 `
  -TargetHeight 1.0
```

`TargetHeight` correspond actuellement à la hauteur cible en mètres.

Le pipeline exécute successivement :

```text
ComfyUI
  -> image PNG
  -> TripoSR
  -> mesh OBJ brut
  -> Blender
  -> transformations appliquées
  -> normales recalculées
  -> centrage X/Y
  -> base placée sur Z = 0
  -> mise à l'échelle
  -> OBJ traité
  -> FBX
```

Les sorties sont regroupées sous :

```text
outputs\pipelines\<pipeline-id>\
```

Exemple :

```text
outputs\pipelines\<pipeline-id>\
├─ processed\
│  ├─ mesh.obj
│  └─ mesh.fbx
└─ pipeline.json
```

`pipeline.json` conserve notamment les identifiants des sous-jobs, les chemins des fichiers, la hauteur demandée, les dimensions finales et le facteur d’échelle appliqué.

---

# Génération par lots

Un batch est décrit dans un manifeste JSON placé par exemple sous :

```text
batches\
```

Le runner de batch est :

```powershell
.\tools\run-batch.ps1 -ManifestPath .\batches\smoke-batch.json
```

Les assets sont traités séquentiellement afin d’éviter que plusieurs charges GPU lourdes se disputent les mêmes ressources.

Les métadonnées du batch sont stockées sous :

```text
outputs\batches\<batch-id>\
```


---

# Workflow ComfyUI de référence

Le workflow actuellement utilisé est :

```text
workflows\comfyui-flux-schnell-base.json
```

Configuration de référence actuelle :

```text
résolution : 1024x1024
batch size : 1
steps : 4
CFG : 1
sampler : euler
scheduler : simple
denoise : 1
```

Le runner dépend de certains identifiants de nodes du workflow. Toute modification structurelle du graphe doit donc être accompagnée d’une validation du runner.

---

# Portabilité entre projets

Asset Factory ne doit pas contenir de règles propres à un jeu ou produit particulier.

Les éléments spécifiques à un projet consommateur doivent être fournis sous forme de configuration ou de manifestes, par exemple :

```text
profil artistique
catégorie d'asset
dimensions cibles
nomenclature
format de sortie
règles de collision
règles de LOD
répertoire ou moteur de destination
```

Un même Asset Factory doit ainsi pouvoir servir plusieurs projets sans fork de son cœur technique.

---

# Portabilité entre machines

Le dépôt ne suppose pas une configuration matérielle précise.

Le bootstrap détecte les composants disponibles et les environnements des moteurs restent isolés. Les capacités réelles dépendent néanmoins des moteurs et modèles activés.

Les points qui peuvent varier selon la machine sont notamment :

- système d’exploitation supporté par le bootstrap ;
- présence d’un GPU compatible ;
- quantité de VRAM ;
- version du pilote GPU ;
- toolkit CUDA éventuellement nécessaire ;
- chaîne de compilation native ;
- version de Blender ;
- espace disque disponible.

Les profils d’installation et de calcul devront rester configurables afin de pouvoir adapter Asset Factory à plusieurs classes de machines.

---

# Validation

Validation générale :

```powershell
.\setup-asset-factory.ps1 doctor
```

Validation TripoSR :

```powershell
.\setup-asset-factory.ps1 triposr doctor
```

Validation ComfyUI :

```powershell
.\setup-asset-factory.ps1 comfyui doctor
```

Smoke test TripoSR :

```powershell
.\setup-asset-factory.ps1 triposr smoke
```

Smoke test ComfyUI :

```powershell
.\setup-asset-factory.ps1 comfyui smoke
```
---
