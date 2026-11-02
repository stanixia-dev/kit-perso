# Spec — retours Hive et tickets GitHub
Statut : en cours
Tickets : #9, #10, #11, #12, #13

## 1. Objectif
Aligner specs, codeur et relecteur sur les règles de lots qui ont causé des blocages inutiles sur stanixia-dev/Hive#1 (coupure PR, fichiers imprévus, plusieurs commits par lot) et élargir le format de spec (section Conception, statut). Apprendre au kit à gérer les tickets du dépôt courant : la spec cite ses tickets, `livrer` les ferme via la PR, un skill crée ou commente un ticket au format standard, et garde-git et le bac à sable encadrent `gh issue`.

## 2. Hors périmètre
- Nouveau statut (`validée`, date de validation) ; découpage architecture.md + spec par jalon.
- Fermer, rouvrir, éditer, supprimer ou transférer un ticket ; tickets d'un autre dépôt ; labels, jalons, projets.
- Vérifier par hook l'auteur d'un ticket commenté (appel réseau à chaque commande) : règle documentée, appliquée par `--author @me` dans le skill.
- `gh api` en POST (sans jeton dans le bac à sable), `garde-secret.py` (contrôle déjà les arguments fichier de `gh issue`), la copie de garde-git dans `~/.claude`, `.github/workflows/`.
- Aucune dépendance ajoutée ; le dépôt n'a ni manifeste ni lockfile.

## 3. Fichiers
- `agents/specs.md` — modifier — coupure libre, lockfiles et config à lister, section Conception, limite 200, ligne Tickets, statut ≠ validation.
- `agents/codeur.md` — modifier — plusieurs commits par lot, suffixe obligatoire, coupure insérée, fichier imprévu ajouté au lot.
- `agents/relecteur.md` — modifier — brief ignoré, union des fichiers, lockfile admis, fichier ajouté au lot = mineur, deux statuts seulement.
- `README.md` — modifier — « Flux avec lots », « Clôture et archivage », « Bac à sable » (exclusions), nouvelle section « Tickets », vérification (2 skills).
- `hooks/garde-git.py` — modifier — règles `gh issue` dans `verifie_gh`.
- `tests/test_hooks.sh` — modifier — cas `gh issue` bloqués et admis ; `controle_bac` exige les nouvelles exclusions.
- `config/bac-a-sable.json` — modifier — exclut `gh issue create|comment` (avec et sans `rtk`).
- `skills/ticket/SKILL.md` — créer — ouvrir ou commenter un ticket au format standard.
- `skills/livrer/SKILL.md` — modifier — section « Tickets » (`Closes`/`Refs`) dans le corps de PR.
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — version 2.0.0 (majeur : garde-git bloque davantage, règle du README).

## 4. Étapes
1. **Coupure PR (#9).** `specs.md` : « Insère `> Coupure PR` entre deux lots là où une PR doit s'arrêter ; obligatoire au-delà de 5 lots (5 au plus par PR). » `codeur.md` : si le brief désigne des lots qui s'arrêtent avant la prochaine coupure, ajouter la ligne `> Coupure PR` juste après le dernier lot traité, dans le dernier commit de ce lot (rien si elle y est déjà). `relecteur.md` : « Ne te fie pas au brief : le périmètre de la PR vient des cases et des coupures de la spec à HEAD. » README « Flux avec lots » : même règle.
2. **Fichiers imprévus (#10).** `specs.md` : la ligne `Fichiers :` d'un lot liste aussi les lockfiles et la config d'outil qu'il touche (ex. `Cargo.lock`, `.cargo/config.toml`). `codeur.md` : un fichier non listé mais nécessaire est ajouté à la ligne `Fichiers :` du lot dans le même commit et signalé au rapport. `relecteur.md` : admis d'office, un lockfile (liste de la règle « Dépendances ») situé dans le dossier d'un manifeste listé dans le lot ou dans un dossier parent ; un fichier présent dans la liste du lot à HEAD mais absent de cette liste dans `<premier commit du lot>^` = mineur « fichier ajouté au lot » ; un fichier absent de la liste à HEAD reste bloquant.
3. **Plusieurs commits par lot (#11).** `codeur.md` remplace « un seul commit » : un lot = un ou plusieurs commits, chacun avec tests verts et un message finissant par `(L<n>)` (obligatoire, squelette compris) ; la case est cochée dans le dernier. En échec : ni case cochée ni commit de l'état rouge. `relecteur.md` : contrôle l'union des fichiers des commits `(L<n>)` d'un lot ; restent bloquants un lot sans commit et un commit sans suffixe (hors commit qui ne touche que la spec). README : « Un lot = un ou plusieurs commits verts suffixés `(L<n>)` ».
4. **Conception (#12).** `specs.md` : item facultatif **Conception** placé entre Hors périmètre et Fichiers (composants, modèle de données, API, sécurité), réservé aux specs d'architecture ; limite « ≤ 120 lignes, ≤ 200 si la section Conception est présente ». Renuméroter le format ; README cite « l'item Lots de `agents/specs.md` » au lieu de « l'item 8 ».
5. **Statut (#13).** `specs.md` et README « Clôture et archivage » : « Le statut n'a que deux valeurs, `en cours` et `livrée`. La validation de la spec est le feu vert de l'utilisateur à l'orchestrateur, pas un état : on n'écrit ni `validée` ni date. » `relecteur.md` (Clôture) : toute autre valeur est bloquante.
6. **garde-git.** Dans `verifie_gh`, si `t[0] == "issue"` : sous-commande = premier argument suivant qui n'est pas une option, en sautant la valeur de `-R`/`--repo`. Admises : `view`, `list`, `ls`, `status`, `create`, `new`, `comment` ; toute autre (ou absente) bloque « fermer, modifier ou supprimer un ticket est réservé à l'utilisateur ». Pour `create`, `new`, `comment`, bloque aussi : `-R`, `-R<x>`, `--repo`, `--repo=<x>` (« ticket hors du dépôt courant interdit »), `--edit-last`, `--delete-last`, et tout argument commençant par `http://`, `https://` ou `github.com/` (une URL vise un autre dépôt). `view`/`list` avec `-R` restent admis (lecture). Allowlist plutôt que liste noire : une future sous-commande de gh est bloquée par défaut.
7. **Bac à sable.** Ajouter à `excludedCommands` : `gh issue create *`, `gh issue comment *`, `rtk gh issue create *`, `rtk gh issue comment *` (gh a besoin du jeton). `controle_bac` vérifie leur présence. README « Bac à sable » : liste des exclusions à jour.
8. **Skill `ticket`.** `skills/ticket/SKILL.md` : `name: ticket`, description « Ouvre ou complète un ticket GitHub du dépôt courant au format standard. À utiliser quand l'utilisateur demande de signaler un problème ou un retour. », `argument-hint: "<constat à signaler>"`, `disable-model-invocation: true` (effet de bord public). Étapes du skill :
   a. `gh issue list -L 1` ; en échec, le dire et s'arrêter.
   b. Un ticket par problème. Doublon cherché parmi ses propres tickets : `gh issue list --author @me --state open --search "<mots-clés>"`. Doublon → `gh issue comment <n> --body-file <f>` ; sinon `gh issue create --title "<titre>" --body-file <f>`.
   c. Titre en français, ≤ 70 caractères, nomme le problème, pas la solution.
   d. Corps écrit dans un fichier du scratchpad (jamais de secret), suivi de la ligne d'attribution du contexte si elle existe :
      `**Constat** : <faits, fichier:ligne>` / `**Proposition** : <changement, ou « à définir »>` / `**Source** : <dépôt#n, commit ou PR d'origine>` / `**Reproduire** : <commande ou étapes, ou « non reproductible »>` (une ligne chacun).
   e. Interdit : `-R`/`--repo`, toute autre sous-commande que `list`, `view`, `create`, `comment`, commenter un ticket dont l'utilisateur n'est pas l'auteur.
   f. Termine par les liens des tickets créés ou commentés.
9. **livrer.** Étape 4, nouvelle section « Tickets » si la spec porte `Tickets : #a, #b` : une ligne `Closes #a` par ticket si la spec est archivée (PR qui la termine), sinon `Refs #a` ; sans ligne Tickets, pas de section.
10. **Docs tickets.** `specs.md` : « Si la spec répond à des tickets du dépôt, ajoute sous la ligne Statut : `Tickets : #9, #10`. » README, section « Tickets » (après « Clôture et archivage ») : ligne Tickets, `Closes`/`Refs`, skill `/kit-perso:ticket` et son format, règles garde-git, résiduels (`cd` vers un autre dépôt, `gh api` POST hors bac à sable, auteur du ticket commenté non vérifié par hook). README Installation : « 4 agents, 2 skills » et skill `/kit-perso:ticket`.
11. **Version.** `.claude-plugin/plugin.json` → `2.0.0` ; CHANGELOG `## 2.0.0 — <date du jour>` : une ligne par ticket #9-#13, une pour le skill `ticket` et `livrer`, une « Majeur : garde-git bloque les sous-commandes de `gh issue` hors lecture, création et commentaire ».

## 5. Critères d'acceptation
- [ ] `agents/codeur.md` impose `(L<n>)` sur chaque commit d'un lot et l'insertion de `> Coupure PR` quand le brief limite les lots.
- [ ] `agents/relecteur.md` : union des fichiers par lot, lockfile admis, fichier ajouté au lot = mineur, brief ignoré, statut hors `en cours`/`livrée` bloquant.
- [ ] `agents/specs.md` : coupure libre, lockfiles/config, item Conception, limite 200 conditionnelle, ligne Tickets, statut ≠ validation.
- [ ] garde-git bloque `gh issue close 9`, `gh issue edit 9 -t x`, `gh issue delete 9`, `gh issue reopen 9`, `gh issue transfer 9 o/r`, `gh issue create -R o/r -t x -b y`, `gh issue create --repo=o/r -t x`, `gh issue comment 9 --repo o/r -b x`, `gh issue comment https://github.com/o/r/issues/1 -b x`, `gh issue comment 9 --edit-last -b x`, `rtk gh issue close 9`, `bash -c 'gh issue delete 9'`.
- [ ] garde-git admet `gh issue create -t x -F f`, `gh issue comment 9 -F f`, `gh issue view 1 -R stanixia-dev/Hive`, `gh issue list --author @me --state open`.
- [ ] `config/bac-a-sable.json` exclut les 4 commandes de l'étape 7 et `controle_bac` le vérifie.
- [ ] `skills/ticket/SKILL.md` existe avec `disable-model-invocation: true` et les 4 rubriques Constat, Proposition, Source, Reproduire.
- [ ] `skills/livrer/SKILL.md` décrit `Closes #n` (spec archivée) et `Refs #n` (sinon).
- [ ] Version 2.0.0 dans `plugin.json` et en tête du CHANGELOG ; `claude plugin validate --strict .` vert.

## 6. Tests
- `bash tests/test_hooks.sh | grep -v '^OK'; echo "code ${PIPESTATUS[0]}"` → aucune ligne `ECHEC`, `code 0`.
- `python3 -m json.tool config/bac-a-sable.json >/dev/null`
- `claude plugin validate --strict .`
- `grep -c '(L<n>)' agents/codeur.md agents/relecteur.md` → ≥ 1 chacun ; `grep -q 'Conception' agents/specs.md && grep -q '200' agents/specs.md`

## 7. Questions ouvertes
- Skill `ticket` en `disable-model-invocation: true` : seul l'utilisateur l'invoque (`/kit-perso:ticket`), l'orchestrateur ne peut plus ouvrir de tickets de lui-même comme pour Hive. Recommandé : oui (effet de bord public, règle du README).

## Lots
- [x] L1 — règles des lots : coupure, fichiers imprévus, plusieurs commits (étapes 1-3)
  Fichiers : agents/specs.md, agents/codeur.md, agents/relecteur.md, README.md
  Fait quand : règles présentes, tests verts — `grep -q 'Coupure PR' agents/codeur.md && grep -q 'union' agents/relecteur.md && grep -q 'lockfile' agents/specs.md && bash tests/test_hooks.sh >/dev/null`
- [ ] L2 — format de spec : Conception et statut (étapes 4-5)
  Fichiers : agents/specs.md, agents/relecteur.md, README.md
  Fait quand : item Conception et règle de statut présents — `grep -q 'Conception' agents/specs.md && grep -q 'feu vert' README.md && bash tests/test_hooks.sh >/dev/null`
- [ ] L3 — garde-git et bac à sable pour `gh issue` (étapes 6-7)
  Fichiers : hooks/garde-git.py, tests/test_hooks.sh, config/bac-a-sable.json, README.md
  Fait quand : cas bloqués et admis des critères testés et verts — `bash tests/test_hooks.sh >/dev/null`
- [ ] L4 — skill ticket, livrer, docs et version 2.0.0 (étapes 8-11)
  Fichiers : skills/ticket/SKILL.md, skills/livrer/SKILL.md, agents/specs.md, README.md, CHANGELOG.md, .claude-plugin/plugin.json
  Fait quand : plugin valide et tests verts — `claude plugin validate --strict . && bash tests/test_hooks.sh >/dev/null`
