# Asset Factory - cycle complet a deux moteurs (patch v1)

## Base et perimetre

Patch construit a partir de `source.zip`, `sources.zip` et du correctif
`assetfactory-trellis-autoimport.zip` deja fourni. Le setup reste en v0.6.23.
Les sources dans `engines/`, les poids, les helpers offline et le shim SDPA
ne sont ni modifies, ni reinstallees par ce patch.

Le profil `profiles/nullon.json` conserve son chemin de projet, son contentRoot
et autoImport=true. Seul `importGlb` est ajoute pour activer materiaux/textures
et isoler chaque GLB dans un sous-dossier. Les options FBX restent identiques.

## Installation

Sauvegarder les fichiers remplaces (liste dans `AF_CYCLE_PATCH_MANIFEST.json`),
puis extraire le ZIP a la racine d'AssetFactory. Aucun `runtime-install`,
`native-install` ou telechargement de modele n'est necessaire.

Ce ZIP est un correctif, pas une installation autonome : il reutilise les
runners, workflows, moteurs et modeles deja fonctionnels sur cette machine.
Les deux fichiers d'import Unreal du correctif precedent sont inclus a
l'identique pour ne pas revenir a l'ancien importeur uniquement FBX.

## Verification rapide sans GPU

```powershell
.\tests\test-cycle-contracts.ps1
```

Ce script analyse les syntaxes PowerShell puis execute la vraie orchestration
avec des remplacements temporaires des moteurs, de Blender, d'Unreal et de
l'API ComfyUI. Il ne touche aucun projet Unreal, ni modele, ni resultat reel.
Il verifie notamment les codes d'echec, les choix de moteur, l'import unique,
le nommage, la priorite CLI/manifeste et le maintien du mode images seules.
Il n'a pas pu etre execute dans l'environnement de livraison sans PowerShell.

## Cycle prompt -> image -> modele -> Blender -> Unreal

ComfyUI doit deja etre demarre sur l'URL habituelle. Ce patch ne demarre ni
n'arrete le serveur. Le workflow existant `workflows/comfyui-flux-schnell-base.json`
reste utilise, sans reecriture de ses nodes ni ajout d'un workflow suppose.

Le profil NullOn active l'import automatique. Sauvegarder et fermer le projet
dans l'editeur avant le test : l'importeur existant ouvre UnrealEditor-Cmd.
Aucun processus utilisateur n'est ferme par le pipeline.

```powershell
.\tools\run-image-to-3d.ps1 `
    -Prompt "compact industrial sci-fi fuel tank, single object, neutral background" `
    -AssetId "FuelTank_T1" `
    -TargetHeight 1.5 `
    -Engine trellis `
    -ProjectProfile ".\profiles\nullon.json"
```

Remplacer uniquement `-Engine trellis` par `-Engine triposr` pour l'autre moteur.
Sans `-Engine`, TripoSR reste le defaut des anciennes commandes.
`-AutoImport $false` desactive explicitement l'import, meme si le profil l'active.
Sans profil, aucun import n'a lieu. Il n'existe aucun repli silencieux d'un
moteur vers l'autre en cas d'erreur.

Le mode image existante evite ComfyUI :

```powershell
.\tools\run-image-to-3d.ps1 `
    -InputPath ".\engines\triposr\examples\chair.png" `
    -AssetId "chair" -TargetHeight 1.0 -Engine trellis `
    -ProjectProfile ".\profiles\nullon.json"
```

Ce mode ne decharge pas ComfyUI : si un serveur utilise encore la meme carte,
il faut avoir libere ses modeles avant ce test. Les deux moteurs partent de
la meme copie d'image dans le dossier du pipeline.

### Sorties

```text
outputs/pipelines/<horodatage>/
  input/FuelTank_T1.png
  generated/trellis/FuelTank_T1.glb  # TRELLIS : export brut conserve
  processed/FuelTank_T1.glb         # TRELLIS : GLB normalise et texture
  logs/comfyui.log
  logs/trellis.log                 # ou triposr.log
  logs/blender.log
  logs/unreal.log                  # si import active
  pipeline.json
```

TripoSR continue a produire son job `outputs/jobs/<job>/mesh/mesh.obj` et les
sorties normalisees `processed/mesh.obj` et `processed/mesh.fbx`, comme avant.
La copie source ComfyUI et les poids ne sont pas renommes ou supprimes.

Le GLB garde le nom du PNG transmis a TRELLIS, avant ET apres Blender.
Les identifiants Unreal sont toujours assainis par l'importeur existant
(par exemple les points et tirets deviennent des underscores dans Unreal).

## Blender

Le script `blender/scripts/process-mesh.py` accepte maintenant OBJ ou GLB.
L'interface existante `--input ...obj --output ...obj --fbx-output ...fbx`
reste disponible. Un GLB texture reste un GLB : aucune conversion FBX implicite.

La normalisation conserve les UV et slots de materiaux, applique la hauteur
cible en metres, centre X/Y et place la base et les origines a zero. Les
transforms des parents/instances sont appliques avant de calculer les bornes.
Les normales importees sont conservees sur le chemin GLB. Le chemin OBJ
recalcule les normales via bmesh, sans l'ancien operateur retire de Blender.

L'export GLB demande explicitement les materiaux, textures, normales et UV.
Un controle de son enveloppe et de ses ressources refuse un fichier vide,
sans mesh, avec images externes, ou ayant perdu toutes ses textures/materiaux.
Ce controle ne remplace pas une verification visuelle dans Unreal.

## Batches

Les anciens manifestes restent valides et generent UNIQUEMENT des images :

```powershell
.\tools\run-batch.ps1 -BatchPath ".\batches\smoke-batch.json"
```

Pour le cycle 3D complet avec le meme manifeste :

```powershell
.\tools\run-batch.ps1 `
    -BatchPath ".\batches\smoke-batch.json" `
    -Mode full -Engine trellis `
    -ProjectProfile ".\profiles\nullon.json"
```

`-Engine` seul ne fait pas basculer un ancien batch en mode 3D : `-Mode full`
ou `"mode": "full"` dans le manifeste est obligatoire.

Le nouveau `batches/smoke-batch-3d.json` contient un seul asset issu de ton
smoke-batch, pour valider un cycle avant de lancer une longue serie. Il declare
mode=full, engine=trellis, targetHeight=1.0 et le profil NullOn.

```powershell
.\tools\run-batch.ps1 -BatchPath ".\batches\smoke-batch-3d.json"
```

### Priorites et champs

Priorite du moteur : **CLI > asset.engine > batch.engine > triposr**.
`mode` est global au batch (CLI puis manifeste puis images).

Champs supplementaires disponibles au niveau batch et/ou asset :
- `engine` : trellis ou triposr ; sans rapport avec profile.engine=unreal.
- `targetHeight` : hauteur positive en metres ; defaut 1.0.
- `projectProfile`, `category`, `autoImport` (booleen JSON).
- `releaseComfyMemory` (booleen JSON, defaut true en mode full).
- `trellisSimplify` : 0 a 0.99 ; defaut 0.95.
- `trellisTextureSize` : 512, 1024 ou 2048 ; defaut 1024.

Les parametres CLI correspondants sont prioritaires sur les valeurs des
assets et du manifeste. `id`, `prompt`, `negativePrompt`, `seed` restent les
champs existants de chaque asset. Un asset full peut fournir `inputPath`
a la place du prompt pour partir d'une image locale.
Les chemins du manifeste sont relatifs a la racine d'AssetFactory.
La seed est transmise a ComfyUI et a TRELLIS ; TripoSR garde son appel original.

Les assets sont traites en serie. Une erreur arrete le batch en conservant
les succes precedents et les entrees suivantes en pending. Le dossier contient
`batch.json`, `logs/<asset>.log` et `assets/<asset>/pipeline.json` avec toutes
les etapes, le moteur utilise et le chemin du fichier final.

## Memoire GPU et concurrence

En mode prompt, le pipeline demande `/free` a ComfyUI apres avoir recupere le
PNG, avec unload_models=true et free_memory=true. Il refuse si la file contient
d'autres travaux : pas d'interruption, de purge ou de suppression de jobs.
Comme `/free` programme une action asynchrone, il attend jusqu'a 60 secondes
que la reservation PyTorch declaree par ComfyUI soit <= 256 MiB.
Cela ne mesure pas la memoire occupee par Unreal, Dexter ou d'autres processus.
Eviter toute autre generation concurrente sur cette carte.

`-ReleaseComfyMemory $false` permet d'ignorer cette etape lorsqu'un serveur
ComfyUI utilise un GPU distinct ou que sa memoire est geree separement. Les
batches images seules ne changent pas le comportement du cache ComfyUI.

Un verrou de fichier `outputs/.image-to-3d.lock` empeche deux pipelines complets
Asset Factory de tourner simultanement dans ce projet. Le fichier vide peut
rester sur disque ; c'est le verrou du processus, pas sa presence, qui compte.
Il n'empeche pas les jobs lances directement dans l'interface de ComfyUI.

## Echecs et reprise d'import

Le runner TRELLIS est toujours appele avec AutoImport=false depuis le pipeline.
Unreal n'est appele qu'une seule fois par asset, apres Blender.
Si l'import echoue : geometry et blender restent completed, failedStage vaut
unreal, le fichier final est conserve et importSourcePath indique quoi reimporter.
Le profil et la categorie sont aussi conserves dans pipeline.json.

```powershell
.\tools\import-unreal.ps1 `
    -ProfilePath ".\profiles\nullon.json" `
    -SourcePath ".\outputs\pipelines\<horodatage>\processed\FuelTank_T1.glb" `
    -AssetId "FuelTank_T1"
```

Il n'y a pas encore de reprise automatique du batch a mi-parcours. Ne pas
relancer une generation pour un simple echec d'import : utiliser cette commande
avec le chemin reel trouve dans pipeline.json.

## Tests et limites de validation

Voir `docs/CYCLE_COMPLET_TEST_REPORT.txt` pour les executions effectivement
realisees. Les tests Python locaux passent, mais utilisent des doubles pour
Blender/Unreal et l'inference. PowerShell, Blender natif, CUDA et Unreal ne sont
pas disponibles dans l'environnement de livraison. Aucune generation Windows
complete n'a ete executee ici, et aucun succes d'import reel n'est revendique.

Le test PowerShell joint doit etre lance sur la machine cible, puis un premier
cycle doit etre valide avec examen de la taille, du pivot et des textures dans
Unreal. Le comportement des bibliotheques/versions natives reste a confirmer
par ce test reel.

## Sources techniques pour les deux nouveaux raccordements

- Contrat local : les deux archives source de l'utilisateur et le correctif
  d'import precedent, identifies dans le manifeste du patch.
- API ComfyUI /free et /queue : https://docs.comfy.org/development/comfyui-server/comms_routes
- ComfyUI v0.35.0, flags de /free et compteurs system_stats :
  https://github.com/Comfy-Org/ComfyUI/blob/v0.35.0/server.py
- Export GLB Blender, selection, materiaux et convention Y-up :
  https://docs.blender.org/api/main/bpy.ops.export_scene.html
