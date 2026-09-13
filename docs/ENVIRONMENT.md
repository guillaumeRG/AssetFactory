# Environnement

Consigner ici les outils hôtes validés et les environnements propres à chaque moteur.

## TRELLIS : compilation native

TRELLIS utilise des extensions natives, notamment `cumm` et `spconv`. Dans l'installation
Asset Factory actuelle, ces composants sont installés depuis leurs sources locales et utilisent
un cache de build Ninja/JIT.

La compilation doit normalement avoir lieu pendant `trellis native-install`, puis être réutilisée
pendant les générations. Une recompilation est normale si le cache est absent ou invalidé
(changement de sources, de compilateur, de CUDA ou de Ninja).

Le bootstrap et le runner utilisent volontairement le même `ninja.exe` :

```text
engines\trellis\.venv-runtime\Scripts\ninja.exe
```

Cela évite qu'un cache créé avec un Ninja différent soit invalidé au lancement suivant.
Les lignes détaillées `Remarque : inclusion du fichier : ...` émises par MSVC sont conservées
dans le log TRELLIS mais masquées dans la console du pipeline principal.
