# Changelog

## 1.0.1 — 2026-11-02

- Hook garde-deps : seul `python[3] -c "<code>"` (rien après le code) en lecture seule stricte (liste blanche : imports json, os, sys, re, tomllib ; `os.path`, `os.environ`, `os.getenv` ; `open` sans mode ou en `r`/`rb`) n'est plus bloqué comme écriture ; les autres interpréteurs et toute autre forme restent bloqués. Tout code non ASCII (identifiants Unicode pleine chasse) ou contenant `*` (dépaquetage) est refusé.

## 1.0.0 — 2026-11-02

- Fragment de réglages `config/bac-a-sable.json` (bac à sable Bash strict, exclusions étroites pour `git push` et quelques `gh`), à fusionner par l'utilisateur ; sonde `tests/sonde-bac-a-sable.sh`.
- Hook garde-git : bloque `git push --receive-pack|--exec` et toute affectation de variable devant `git push` ou `gh` (commandes exclues du bac à sable).
- Hook garde-secret : résout les arguments de fichier des commandes exclues et refuse ceux qui mènent à un chemin protégé.
- Majeur : les hooks bloquent davantage. README : section « Bac à sable ».

## 0.4.0 — 2026-10-30

- Hook garde-secret : refuse l'accès de l'agent à `~/.ssh`, `~/.config/gh` et aux `.env`, les secrets dans le contenu écrit ou les commandes, `gh auth token` et `git credential fill`.
- Masquage des secrets dans la sortie des outils (PostToolUse, `updatedToolOutput`) et alerte sur les erreurs (PostToolUseFailure).
- Scan du dépôt, commit par commit, avant `git commit`/`push`/`gh pr create`, à l'arrêt (Stop, SubagentStop) et en CI via le job `deps` (`verifie-manifestes.py --ci` enchaîne `garde-secret.py --ci`).
- Fichier `.garde-secret-exceptions`, protégé contre les écritures de l'agent ; le relecteur contrôle les secrets et ces exceptions.
- README : section « Contrôle des secrets » et règles `deny` supplémentaires (13).

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
