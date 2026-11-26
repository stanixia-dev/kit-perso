---
name: archiver-memoire
description: Archive la mémoire automatique du projet dans un dossier frère `historique/` (copie datée, jamais chargée par Claude Code), signale les lignes d'index et fichiers trop gros, puis propose de ramener la mémoire au durable. À utiliser quand un chantier se clôt ou que MEMORY.md grossit.
argument-hint: "[--memoire <dossier>]"
---

Archive la mémoire du projet courant : $ARGUMENTS (`--memoire <dossier>` facultatif).

1. Lance `python3 "${CLAUDE_SKILL_DIR}/archiver-memoire.py" $ARGUMENTS`, avec `--memoire <dossier de MEMORY.md>` si ce chemin figure dans ton contexte (la dérivation du script imite Claude Code et peut diverger, par exemple avec `autoMemoryDirectory`). Code 1 : dis « pas de mémoire pour ce projet » et arrête-toi. Code 2 : affiche le message et arrête-toi.
2. Montre le rapport tel quel.
3. Propose la réécriture : le chantier clos réduit à 2-3 lignes, les lignes d'index et les fichiers signalés raccourcis au durable, sans numéro de PR ni historique de lots. Montre l'ancien et le nouveau texte, puis n'écris dans `memory/` qu'après un « oui » explicite de l'utilisateur.
4. Rapport final : chemin de l'archive, fichiers réécrits, signalements restants.

Interdit : supprimer un fichier de `memory/` ou de `historique/` sans confirmation, déplacer ou renommer une archive, citer `historique/` dans `MEMORY.md`.
