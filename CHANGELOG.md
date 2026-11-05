# Changelog

## 3.3.0 — 2026-11-05

- Runtime Node contrôlé : nouveau `verifie-runtime.py` (refuse un Node plus ancien que la dernière version de sécurité de sa branche, index nodejs.org, cache, `--ci` fail-closed) et hook PreToolUse Bash local (fail-open). `/kit-perso:ci-projet` : le job `node` utilise `actions/setup-node` sur `.nvmrc` (`check-latest`), impose `engines` et lance le contrôle ; génération de `.nvmrc` et `.npmrc` s'ils sont absents (#34).

## 3.2.0 — 2026-11-04

- garde-secret : directives `script` et `masque` dans `.garde-secret-exceptions`. Un script de banc local déclaré avec son `sha256` peut être lancé tel quel par l'agent (sans argument, depuis la racine, sans lien symbolique, URL locales seulement) ; toute autre mention en Bash et toute écriture du script sont refusées ; les valeurs des fichiers `masque` sont masquées dans les sorties. Durcissements : écriture du script refusée même depuis un `cwd` hors du dépôt, autorités d'URL vides ou `[::1]` suivi d'autre chose que `:port` refusées, mentions du script entre guillemets ou par joker refusées (#31).

## 3.1.4 — 2026-11-04

- garde-deps : la licence OFL-1.1 (polices libres : Google Fonts, Fontsource), ses variantes `OFL-1.1-RFN` / `OFL-1.1-no-RFN` et le classifieur PyPI correspondant sont acceptés ; README et relecteur mis à jour (#26).
- verifie-manifestes : les dépendances vers un paquet d'un workspace npm (spec `*`, `""`, `x` ou version exacte du membre, hors alias `npm:`, avec `workspaces` à la racine) ne sont plus cherchées sur le registre ni bloquées en `--ci`, à condition que le `package-lock.json` de la racine prouve le lien (`link: true`, `resolved` vers le dossier du membre, aucune copie non liée). Sans lockfile, la vérification reste normale (#27).

## 3.1.3 — 2026-11-03

- garde-deps : le script de `sed -i` (valeur de `-e`/`--expression` ou de leurs préfixes et formes collées, sinon premier argument non-option) n'est plus pris pour une cible d'écriture ; `-f`/`--file` fournit le script, aucun argument n'est alors retiré. Le script reste une cible s'il contient une commande `w` ou `s///w` vers un chemin protégé, et une commande `e` (`1e cmd`) est analysée comme du shell. `sed -i … <chemin protégé>` reste bloqué. `perl -i` reste traité comme avant (son script peut écrire n'importe où).
- garde-deps : une apostrophe entre guillemets doubles (`echo "it's $(npm i x)"`) ne masque plus la substitution qui suit ; un `#` dans des backticks ne masque plus la suite ; `find -exec`/`-execdir`/`-ok`/`-okdir` (y compris après un premier `-exec … \;`) font analyser la commande lancée comme une commande complète (paquets, écritures protégées, `sh -c`).
- garde-deps : un seul analyseur de guillemets et de substitutions (`parcours()`) pour heredocs, substitutions et commentaires ; `saute_options` et `arguments` fusionnées (`sans_options`).

## 3.1.2 — 2026-11-03

- garde-git et garde-secret : les options `gh` placées avant ou entre les sous-commandes (`gh -R o/r pr merge`, `gh pr -R o/r merge`, `gh pr --body x merge`) ne contournent plus les règles (`merge`, `approve`, `api`, `issue`, `auth token`, `pr create`).
- garde-git : `-c`, `--config-env` et `--exec-path` devant `git push` sont bloqués, ainsi que `-c alias.*` pour toute sous-commande ; options globales à valeur (`--namespace`…) reconnues.
- garde-git : `git push --all` / `--branches`, refspec `*`, `HEAD`/`@` sur main, abréviations d'options longues (`--del`, `--mirr`, `--ex=`…) et groupes d'options courtes (`-ud`) sont bloqués.
- garde-secret : un chemin contenant un blanc (`cat "mon dossier/.env"`) est contrôlé ; le CLI (utilisé par le relecteur) est fail-closed : une erreur interne ou un fichier illisible sort en 2, jamais en 0 silencieux.
- verifie-manifestes : une erreur interne en CLI sort en 2 avec la trace, au lieu de « conforme ».
- deps_communs : une réponse de registre mal formée donne « vérification impossible » au lieu de laisser passer.
- garde-deps : `.github/./workflows` et `.github//workflows` sont traités comme `.github/workflows`.
- README : le check à rendre obligatoire est `deps / deps` (et non plus `tests / deps`) ; résidus `sandbox` retirés des tests.
- Correctif : commandes déjà interdites par les règles, détection complétée. Résiduels : `git config alias.x …` puis `git x`, `-C`/`--git-dir` vers un dépôt dont la config exécute du code.

## 3.1.1 — 2026-11-03

- `ci-projet` : la consigne « Require status checks » ne liste plus `pull_request`, `push` ni `contents`, seulement `deps` et les jobs de tests réels (#22).
- garde-deps : `python3 <script du plugin installé>` n'est plus bloqué comme une écriture ; les arguments suivants (et les redirections) vers un chemin protégé le restent ; le script doit résoudre (`realpath`) sous `~/.claude/plugins/` (#21).
- garde-deps bloque `git clone`, `git worktree add` et `git init` vers un chemin protégé.
- La CI du kit est séparée en deux workflows, `deps` et `tests`, un événement chacun (#20).

## 3.1.0 — 2026-11-03

- Skill `ci-projet` : génère hors de `.github/` le workflow CI kit-perso d'un projet (job `deps` fail-closed avec kit public à SHA figé, jobs de tests rust/node/python selon les manifestes) ; l'utilisateur le copie et le commite (#16).
- `livrer` et l'agent `specs` signalent un dépôt sans CI, sans le job `deps` ou à checks non obligatoires, et distinguent « pas de CI configurée » de « CI configurée mais pas déclenchée » (#17).
- Mineur : ajout d'un skill ; `livrer` ne bloque pas davantage.

## 3.0.1 — 2026-11-03

- garde-git détecte `gh` et `git push` derrière `timeout`, `nice`, `xargs`, `sudo`, `stdbuf`, `env`, `command`, `eval`, `bash -c`, un sous-shell `( )`, `$( )` ou des backticks, ainsi que derrière `exec -a`, `setsid`, `ionice`, `doas`, `chrt`, `taskset`, `flock`, `unbuffer`, `watch` et `find -exec` ; une affectation devant `eval`/`bash -c` reste refusée ; un shell alimenté par l'entrée standard (pipe, heredoc, `<<<`) avec `gh` ou `git push` est bloqué ; le corps des heredocs est analysé ligne à ligne (`$( )` et backticks y restent littéraux si le délimiteur est entre guillemets), `\x` et les commentaires `#` sont ignorés. Règle simple pour les exécuteurs de chaîne (`eval`, `bash|sh|zsh|dash|ksh -c`/`-s`/stdin, `busybox sh`, `watch`, `flock -c`, `find -exec sh -c`, `xargs sh`) : le texte brut de la commande entière est bloqué s'il contient le mot `gh` ou `git push` ; faux positifs admis (ex. `bash -c 'echo gh'` est bloqué).

Limites : la détection n'est pas étanche face à l'obfuscation (`${x}h`, `base64 -d | bash`, `source /dev/stdin`, `. <(…)`, une apostrophe ouverte dans `"$( … )"`, autres interpréteurs que bash/sh/zsh/dash/ksh via busybox). C'est un garde-fou contre les erreurs de l'IA, pas une frontière de sécurité.

## 3.0.0 — 2026-11-03

- `gh api` en liste blanche : lecture libre, écriture limitée aux milestones (`POST …/milestones`, `PATCH …/milestones/<n>`) ; fichiers locaux, hôtes autres que github.com et mutations GraphQL bloqués.
- `gh issue edit --milestone` / `--remove-milestone` admis (tout autre champ bloqué).
- `-R/--repo` admis sur `gh issue create|comment|edit` vers les dépôts `stanixia-dev/*`.
- Retrait du bac à sable : fragment `config/bac-a-sable.json` et sonde supprimés.
- Majeur : garde-secret contrôle les fichiers de tout `gh`.

## 2.0.0 — 2026-11-02

- Agents specs, codeur, relecteur : `> Coupure PR` libre et insérée par le codeur, lockfiles et config listés dans les lots, fichier imprévu ajouté au lot (#9, #10).
- Un lot peut compter plusieurs commits, tous suffixés `(L<n>)` ; le relecteur contrôle l'union de leurs fichiers (#11).
- Specs : item Conception facultatif (limite 200 lignes), ligne `Tickets` (#12).
- Statut de spec limité à `en cours` et `livrée` ; le relecteur bloque toute autre valeur (#13).
- Skill `ticket` (ouvre ou commente un ticket au format standard) ; `livrer` ajoute `Closes`/`Refs` au corps de PR.
- Majeur : garde-git bloque les sous-commandes de `gh issue` hors lecture, création et commentaire ; `gh issue create|comment` exclus du bac à sable.

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
