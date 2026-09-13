# TRELLIS offline models - Asset Factory v0.6.23

## Installation de la mise a jour

Conserver une copie du setup et du dossier tools fonctionnels, puis extraire
le ZIP a la racine d'AssetFactory. Ne pas remplacer les dossiers engines,
les environnements Python ou leurs packages. Le correctif ne contient pas
les poids des modeles.

Avec Internet disponible, lancer une seule fois :

```powershell
.\setup-asset-factory.ps1 trellis model-install
```

Cette commande utilise le Python de engines/trellis/.venv-runtime. Elle
n'appelle ni runtime-install ni native-install, n'installe aucun package
et ne lance pas d'inference. Elle prepare :

- Les six checkpoints references par le pipeline TRELLIS image-large et
  leurs configurations. Le decodeur radiance-field reste present pour
  conserver le meme ensemble de modeles charge que le runner precedent;
  le runner ne demande toujours que les sorties mesh et gaussian.
- Le code DINOv2 fixe a un commit et les poids dinov2_vitl14_reg4.
- Le fichier u2net.onnx de rembg, meme si la premiere image test avait deja
  un canal alpha. Les futures images sans transparence sont ainsi couvertes.

Les fichiers termines du cache Hugging Face sont copies dans le projet.
Les poids DINOv2/U2Net deja disponibles dans leurs caches habituels sont
reutilises si possible. Aucun cache utilisateur n'est supprime. Les copies
independantes occupent donc de l'espace disque supplementaire; ce choix
permet de ne pas dependre du cache global pendant la generation.

Un nouvel appel model-install verifie le bundle complet. S'il est valide,
aucune connexion n'est necessaire. Les fichiers deja verifies d'une
preparation interrompue sont reutilises. Les gros fichiers HF beneficient
aussi de la reprise du client Hugging Face. Les telechargements directs
DINOv2/U2Net interrompus reprennent depuis le debut pour le fichier concerne.

## Emplacements

```text
models/trellis/
  TRELLIS-image-large/pipeline.json
  TRELLIS-image-large/ckpts/...
  dinov2/repository/hubconf.py
  dinov2/repository/dinov2/...
  dinov2/dinov2_vitl14_reg4_pretrain.pth
  rembg/u2net.onnx
  model-manifest.json
  .download-state.json
```

Le manifeste enregistre des chemins relatifs, des tailles et des SHA-256.
Ces SHA-256 locaux detectent les modifications ulterieures; ils ne sont
pas tous des signatures publiees par les auteurs. Le MD5 U2Net est en plus
compare a celui publie dans le code rembg. Le dossier models/ est deja
ignore par le setup existant. Ne pas committer les poids dans Git.

## Verification et generation hors ligne

```powershell
.\setup-asset-factory.ps1 trellis model-status
# Equivalent sans installation :
.\setup-asset-factory.ps1 trellis model-install -NoInstall

# Meme commande de generation qu'avant :
.\tools\run-trellis.ps1 -InputPath ".\engines\triposr\examples\chair.png"
```

Le runner est local-only par defaut. Il verifie le manifeste AVANT
l'import de TRELLIS, passe des chemins locaux aux chargeurs de checkpoints,
charge DINOv2 avec source="local"/pretrained=False puis applique explicitement
les poids locaux. U2NET_HOME pointe sur le fichier local du bundle.

HF_HUB_OFFLINE, TRANSFORMERS_OFFLINE et la desactivation de la telemetrie
sont configures dans le processus Python. Un garde-fou d'audit intercepte
les appels reseau Python habituels et les fait echouer. Ce garde-fou n'est
pas un pare-feu systeme et ne couvre pas les appels natifs de bibliotheques
qui contourneraient Python. Pour valider le fonctionnement sur le poste,
faire une generation avec la connexion reseau coupee apres model-install.

Un fichier absent/corrompu provoque une erreur explicite demandant
model-install, jamais un telechargement implicite dans la generation.
Les options -SelfTest, -SavePly, -Seed, -Simplify et -TextureSize restent
presentes. -CheckModels controle uniquement les fichiers sans charger les
reseaux; -ModelsDir permet un autre emplacement explicite du bundle.

Le PowerShell n'embarque ni ne genere de programme Python. Les nouveaux
helpers Python sont des fichiers permanents appartenant a Asset Factory.
La couche SDPA est identique octet pour octet au pack deja valide. Le code
Microsoft, ses assets et les packages installes ne sont pas modifies par
ces nouveaux chemins model-install/model-status/generation. Les anciennes
commandes native-install restent telles qu'elles etaient dans la v0.6.22.

## Validation realisee et limites

17 tests locaux passes : integrite, fichiers manquants, chemins dangereux,
reutilisation idempotente, extraction du code, chargement local DINOv2
simule, preservation des parametres de sampling et garde-fou reseau.
Syntaxe Python verifiee; import PyTorch 2.10 CPU et SDPA CPU testes sous le
garde-fou. Les tests utilisent de petits fichiers factices et des mocks,
pas les vrais poids. Aucun telechargement de plusieurs Go ni inference
CUDA/Windows n'a ete execute dans l'environnement de preparation.
PowerShell 5.1/7 n'etait pas disponible pour executer les deux scripts.
Validation humaine restante : model-install, puis generation hors ligne
sur le poste Windows deja configure. Une installation neuve des outils et
dependances peut encore necessiter Internet; ce pack concerne l'inference.

## Sources utilisees

- TRELLIS 442aa1e: trellis/pipelines/trellis_image_to_3d.py,
  trellis/pipelines/base.py et trellis/models/__init__.py.
- https://huggingface.co/microsoft/TRELLIS-image-large/blob/25e0d31ffbebe4b5a97464dd851910efc3002d96/pipeline.json
- https://github.com/facebookresearch/dinov2/blob/7764ea0f912e53c92e82eb78a2a1631e92725fc8/dinov2/hub/backbones.py
- https://github.com/danielgatis/rembg/blob/main/rembg/sessions/u2net.py
- https://huggingface.co/docs/huggingface_hub/en/package_reference/environment_variables
- https://docs.pytorch.org/docs/2.13/hub.html
