# Changelog

## 0.3.0 — 2026-10-29

- Hook garde-deps : bloque l'ajout d'un paquet à licence non permissive, faille OSV, déprécié/yanked ou inactif depuis plus de 2 ans.
- Contrôle des dépendances des manifestes du diff par le relecteur.
- CI `tests.yml` lançant `tests/test_hooks.sh`, suivie par `livrer`.

## 0.2.0 — 2026-10-29

- Gestion de lots : section facultative `## Lots` dans les specs, un commit par lot, relecture lot par lot.
- Clôture et archivage des specs : ligne `Statut : en cours` → `Statut : livrée`, critères cochés et déplacement dans `docs/specs/archives/` au dernier commit.

## 0.1.0 — 2026-10-29

- Premier jalon : 4 agents (specs, codeur, relecteur, explorateur), hooks garde-git et rappel-clear, skill livrer.
