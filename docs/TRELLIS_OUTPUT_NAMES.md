# TRELLIS - noms des sorties bases sur l'image

Correctif cible sur le pack hors ligne v0.6.23.

Extraire a la racine d'AssetFactory. Les deux fichiers de production remplaces sont :
- tools/run-trellis.ps1
- tools/run_trellis.py

Le reste du pack v0.6.23 reste necessaire et inchange.
Aucune reinstallation ni aucun telechargement de modele n'est necessaire.

Exemples :
- chair.png -> chair.glb
- FuelTank_T1.png -> FuelTank_T1.glb
- chair.v2.png -> chair.v2.glb

Les PLY optionnels suivent la meme convention. Le dossier de sortie horodate
et tous les parametres existants sont conserves. Les anciens exports ne sont
ni renommes ni supprimes. Aucune modification du code moteur ou du setup.

Commande inchangee :
    .\tools\run-trellis.ps1 -InputPath ".\engines\triposr\examples\chair.png"

Import automatique : NON CORRIGE dans ce pack. Le runner disponible ne contient
aucun appel a un importeur. Le code de l'import automatique existant est requis
pour l'integrer sans inventer une seconde architecture.

Validation locale : 25 tests reussis (17 tests hors ligne existants et 8 nouveaux
tests de nommage). L'inference et l'export des tests de nommage sont simules.
Le test PowerShell est statique, pas une execution Windows/Unreal/CUDA.
