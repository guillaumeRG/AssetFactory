# Asset Factory

Asset Factory est une chaîne locale, modulaire et reproductible de génération et de préparation d’assets pour NullOn.

Le pipeline actuellement validé comprend :

- ComfyUI pour la génération d’images
- FLUX.1-schnell FP8 pour la génération de concepts
- TripoSR pour la conversion image vers 3D
- Blender pour le post-traitement des meshes
- PowerShell pour l’orchestration
- des environnements Python isolés pour chaque moteur

La machine de référence utilisée pour les validations est :

- Windows 11
- NVIDIA GeForce RTX 5060 Ti (~8 Gio de VRAM)
- PowerShell 5.1+
- Python 3.11 pour les moteurs IA
- Blender
- Git

Avec environ 8 Gio de VRAM, les charges GPU lourdes doivent rester séquentielles.

---

## Structure du dépôt

```text
AssetFactory/
├─ blender/
│  └─ scripts/
├─ docs/
├─ engines/
│  ├─ comfyui/        # installation locale, ignorée par Git
│  └─ triposr/        # installation locale, ignorée par Git
├─ jobs/
├─ orchestrator/
├─ outputs/
├─ tools/
│  ├─ run-comfyui.ps1
│  └─ run-triposr.ps1
├─ workflows/
│  └─ comfyui-flux-schnell-base.json
├─ setup-asset-factory.ps1
└─ README.md
```

Les dossiers des moteurs ne sont pas versionnés.

Ils sont recréés localement par le bootstrap.

---

# Installation

Cloner le dépôt :

```powershell
git clone https://github.com/guillaumeRG/AssetFactory.git
```

Entrer dans le dépôt :

```powershell
Set-Location .\AssetFactory
```

Lancer l’installation des outils partagés :

```powershell
.\setup-asset-factory.ps1 install
```

Le bootstrap détecte les outils déjà présents et les réutilise lorsque c’est possible.

---

# Installation de TripoSR

Installer l’environnement isolé TripoSR :

```powershell
.\setup-asset-factory.ps1 triposr install
```

Vérifier son état :

```powershell
.\setup-asset-factory.ps1 triposr doctor
```

Lancer le test réel image vers 3D :

```powershell
.\setup-asset-factory.ps1 triposr smoke
```

Un test réussi génère un mesh 3D dans :

```text
outputs\triposr-smoke\
```

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

Vérifier l’environnement :

```powershell
.\setup-asset-factory.ps1 comfyui doctor
```

Tester le démarrage de l’API :

```powershell
.\setup-asset-factory.ps1 comfyui smoke
```

Le smoke test démarre temporairement ComfyUI sur un port local libre, vérifie que l’API répond, puis arrête le processus.

---

# Modèle d’image

Le workflow de référence actuel utilise :

```text
flux1-schnell-fp8.safetensors
```

Emplacement attendu :

```text
engines\comfyui\models\checkpoints\flux1-schnell-fp8.safetensors
```

Le checkpoint n’est volontairement pas stocké dans Git en raison de sa taille.

La source actuellement validée est :

```text
Comfy-Org/flux1-schnell
```

Le workflow de référence attend exactement ce nom de fichier.

---

# Démarrer ComfyUI manuellement

Depuis :

```text
engines\comfyui
```

lancer :

```powershell
.\.venv\Scripts\python.exe main.py --lowvram
```

L’API locale par défaut est disponible sur :

```text
http://127.0.0.1:8188
```

---

# Générer une image

Une fois ComfyUI démarré :

```powershell
.\tools\run-comfyui.ps1 -Prompt "small sci-fi cargo container, hard surface design, clean silhouette, neutral studio background" -Seed 1234
```

Le runner :

1. charge le workflow API ComfyUI de référence ;
2. injecte le prompt et la seed ;
3. crée un job Asset Factory ;
4. envoie le workflow à ComfyUI ;
5. attend la fin de l’exécution ;
6. récupère les images générées ;
7. stocke les résultats et les métadonnées dans le dossier du job.

Exemple :

```text
outputs\jobs\20260912-165854-773\
├─ generated\
│  └─ assetfactory_20260912-165854-773_00001_.png
├─ logs\
├─ workflow\
│  └─ workflow.json
└─ job.json
```

---

# Workflow ComfyUI de référence

Le workflow actuellement utilisé est :

```text
workflows\comfyui-flux-schnell-base.json
```

Paramètres actuels :

```text
résolution : 1024x1024
batch size : 1
steps : 4
CFG : 1
sampler : euler
scheduler : simple
denoise : 1
```

Le runner `run-comfyui.ps1` s’appuie actuellement sur les IDs de nodes suivants :

```text
2 = prompt positif
3 = prompt négatif
5 = KSampler
7 = SaveImage
```

Si le graphe du workflow change, le runner doit être adapté en conséquence.

---

# Validation globale

Afficher l’état général :

```powershell
.\setup-asset-factory.ps1 status
```

Valider le bootstrap partagé :

```powershell
.\setup-asset-factory.ps1 doctor
```

Valider TripoSR :

```powershell
.\setup-asset-factory.ps1 triposr doctor
```

Valider ComfyUI :

```powershell
.\setup-asset-factory.ps1 comfyui doctor
```

---

# Sorties et politique Git

Les contenus générés sont stockés dans :

```text
outputs\
```

Les moteurs IA installés localement sont stockés dans :

```text
engines\
```

Les éléments suivants sont volontairement exclus de Git :

- dépôts locaux des moteurs IA
- environnements virtuels Python
- checkpoints de modèles IA
- contenus générés
- caches
- logs temporaires

Le dépôt doit contenir uniquement :

- la logique de bootstrap
- les scripts d’orchestration
- les workflows de référence
- la documentation
- la configuration reproductible

---

# État actuel du projet

Validé localement :

- bootstrap partagé
- détection et exécution headless de Blender
- détection du GPU NVIDIA
- environnement isolé TripoSR
- exécution CUDA TripoSR
- smoke test image vers 3D TripoSR
- environnement isolé ComfyUI
- exécution CUDA ComfyUI
- smoke test API ComfyUI
- génération automatisée prompt vers image

Prochaines étapes :

- génération par lots
- chaînage automatique image vers 3D
- normalisation des meshes dans Blender
- export orienté Unreal Engine
