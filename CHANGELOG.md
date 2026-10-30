# Changelog

## 0.3.0 — 2026-10-29

- Hook garde-deps : bloque l'ajout d'un paquet à licence non permissive, faille OSV, déprécié/yanked ou inactif depuis plus de 2 ans.
- Contrôle des dépendances des manifestes du diff par le relecteur.
- CI `tests.yml` lançant `tests/test_hooks.sh`, suivie par `livrer`.
- Contrôle par résultat des manifestes et lockfiles (`verifie-manifestes.py`, PostToolUse, Stop, SubagentStop), failles transitives signalées via OSV.
- Job CI `deps` en `pull_request_target` (mode `--ci` strict) que la PR ne peut pas modifier.
- Fichier `.garde-deps-exceptions` : exceptions décidées par l'utilisateur, seules celles de `main` comptent en CI.
- Protection des réglages Claude, hooks, plugins, workflows CI et `.garde-deps-exceptions` contre les écritures de l'agent ; correctifs du parseur Bash de garde-deps ; section « Verrouillage » du README.

## 0.2.0 — 2026-10-29

- Gestion de lots : section facultative `## Lots` dans les specs, un commit par lot, relecture lot par lot.
- Clôture et archivage des specs : ligne `Statut : en cours` → `Statut : livrée`, critères cochés et déplacement dans `docs/specs/archives/` au dernier commit.

## 0.1.0 — 2026-10-29

- Premier jalon : 4 agents (specs, codeur, relecteur, explorateur), hooks garde-git et rappel-clear, skill livrer.
