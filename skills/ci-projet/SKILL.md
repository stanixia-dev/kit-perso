---
name: ci-projet
description: Génère le workflow CI kit-perso (job deps + tests par langage) du projet courant, à copier et commiter par l'utilisateur. À utiliser quand un projet n'a pas de CI ou pas le job deps.
argument-hint: "[--sans-tests]"
disable-model-invocation: true
---

Génère le workflow CI du projet courant : $ARGUMENTS (`--sans-tests` facultatif).

1. Lance `python3 "${CLAUDE_SKILL_DIR}/genere-ci.py" $ARGUMENTS` depuis la racine du projet. Ajoute `--sans-tests` si `origin/main` a déjà des workflows (`git ls-tree --name-only origin/main .github/workflows/`). Si le script échoue sur `git ls-remote`, dis que kit-perso doit être public et joignable, et arrête-toi.
2. Montre les jobs générés (fichier de sortie indiqué par la commande) et demande à l'utilisateur de les relire : ce sont des emplacements par défaut.
3. Donne la commande imprimée par le script, à lancer **par l'utilisateur dans un terminal**, pas par toi.
4. Rappelle l'étape après la fusion : `deps` ne tourne qu'une fois le workflow sur main ; ensuite Settings > Rules > Rulesets > New branch ruleset, cible `main`, Require status checks (`deps` + jobs de tests générés). Mise à jour du kit : relancer ce skill et recopier.

Interdit : écrire dans `.github/`, copier le fichier toi-même, `git push`.
