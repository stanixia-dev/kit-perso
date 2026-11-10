# Spec — contre-tests (des tests qui prouvent le comportement)
Statut : livrée

## 1. Objectif
Faire en sorte que le flux specs → codeur → relecteur garantisse que les tests prouvent le changement, et pas seulement qu'ils sont verts. La spec relie chaque critère à un test et exige des cas négatifs. Le codeur écrit les tests d'abord et les voit échouer. Le relecteur rejoue les tests nouveaux de la branche sur le code de base (contre-test) : un test qui passe déjà sur la base ne prouve rien.

## 2. Hors périmètre
- Aucun changement dans `hooks/`, `hooks/hooks.json`, `.github/workflows/`, `skills/` ni `~/.claude/`. Les règles des lots, des suffixes `(L<n>)`, du statut, de la clôture et de l'archivage restent inchangées.
- Pas de contre-test commit par commit : un seul passage, sur la branche entière.
- Pas de contre-test des tests écrits dans le fichier source (`#[cfg(test)]` en Rust, doctests) : on ne peut pas les séparer de l'implémentation. Le relecteur le signale en mineur.
- Pas de nouvel agent ni de nouvelle skill.

## 3. Conception
**Script `scripts/contre-test.sh`** (bash, sans dépendance). Il centralise le contre-test pour qu'il soit testable et ne repose pas sur des commandes improvisées. On le place dans `scripts/` et non dans `hooks/`, car ce n'est pas un hook.

Usage : `contre-test.sh [--base <ref>] [--fichiers <pathspec>]... -- <commande> [args...]`, lancé depuis n'importe quel dossier du dépôt.
1. `R=$(git rev-parse --show-toplevel)`, `H=$(git rev-parse HEAD)`, `B=$(git merge-base <base> HEAD)` (`--base` vaut `main` par défaut). On prend la base de fusion, comme `git diff main...HEAD` : on compare au code dont la branche est partie.
2. Fichiers de test : `git diff -z --name-only --diff-filter=AMR "$B" "$H" -- <pathspecs>`. Sans `--fichiers`, les pathspecs par défaut sont `':(glob)**/tests/**' ':(glob)**/test/**' ':(glob)**/__tests__/**' ':(glob)**/spec/**' ':(glob)**/*_test.*' ':(glob)**/test_*' ':(glob)**/*.test.*' ':(glob)**/*.spec.*'`. Chaque `--fichiers` remplace ces valeurs par défaut (il ne s'y ajoute pas). Liste vide : sortie 3.
3. `T=$(mktemp -d "${TMPDIR:-/tmp}/contre-test.XXXXXX")`, avec `trap 'rm -rf "$T"' EXIT` et `trap 'exit 2' INT TERM` (une interruption sort en erreur, jamais en faux rouge). Ensuite `git clone -q --shared --no-checkout "$R" "$T/d"`, puis `git -C "$T/d" checkout -q --detach "$B"`, puis `git -C "$T/d" checkout -q "$H" -- <fichiers>`. Un clone `--shared` n'écrit rien dans le `.git` du dépôt (contrairement à `git worktree add`, qui écrit dans `.git/worktrees/`) : le dépôt reste en lecture seule.
4. Dépendances non suivies par git : si `$R/node_modules` ou `$R/.venv` existe, on crée un lien symbolique du même nom dans `$T/d`. Si `$R/Cargo.toml` existe et que `CARGO_TARGET_DIR` n'est pas défini, on exporte `CARGO_TARGET_DIR="$R/target"` (voir Q1). Sans cela, la base échouerait pour une mauvaise raison (dépendance absente) ou tout serait recompilé.
5. Le script affiche `contre-test : base <B court> ; fichiers : <liste>`, puis lance `(cd "$T/d" && "$@")`, avec sa sortie telle quelle. Pour un tube, on passe `bash -c '…'`.
6. Codes de sortie et dernière ligne affichée :
   - `0` : `CONTRE-TEST : rouge sur la base (code <n>)`. C'est le résultat attendu.
   - `1` : `CONTRE-TEST : vert sur la base`. Les tests ne prouvent pas le changement.
   - `2` : `contre-test : erreur : <raison>`, sur stderr. Cas : hors dépôt git, ref inconnue, commande absente après `--`, ou clone ou checkout en échec.
   - `3` : `contre-test : aucun fichier de test nouveau ou modifié`.

**Où trouver le script** (même schéma que `verifie-manifestes.py`) : `C=$(ls ~/.claude/plugins/cache/kit-perso/kit-perso/*/scripts/contre-test.sh 2>/dev/null | sort -V | tail -1)`. Dans le dépôt kit-perso, c'est `scripts/contre-test.sh`.

**Marqueurs dans les critères d'acceptation** (ils permettent un contrôle mécanique par le relecteur) :
- Chaque case se termine par `— test : <commande>`, suivie du nom du cas quand la commande en lance plusieurs. La forme `— test : manuel (<vérification>)` est admise seulement pour ce qui ne s'automatise pas.
- `(négatif)` : entrée invalide, erreur attendue ou refus. Il en faut au moins un par fonctionnalité.
- `(non-régression)` : comportement déjà présent sur `main`. Ce test peut passer sur la base.
- `(fumée)` : obligatoire si la spec touche une interface ou un serveur. L'appli démarre réellement (skill `run` si elle est disponible, sinon commande de lancement du projet). La commande s'arrête seule (`timeout`) et sort en 0 si l'appli répond.
- Spec sans changement de comportement (refactor, doc seule) : ligne `Contre-test : non applicable (<raison>)` sous les critères.

**Verdict du relecteur** : voir l'étape 5.

## 4. Fichiers
- `scripts/contre-test.sh` — créer — script décrit en Conception, exécutable (`chmod +x`).
- `tests/test_contre_test.sh` — créer — tests du script (dépôts jetables) et contrôles de texte des agents et du README.
- `tests/test_hooks.sh` — modifier — appelle `tests/test_contre_test.sh`, sur le même modèle que `test_ci_projet.sh` (lignes 320-321).
- `agents/specs.md` — modifier — item 6 « Critères d'acceptation » : marqueurs et règles de la Conception.
- `agents/codeur.md` — modifier — tests d'abord, rouge puis vert, ligne de rapport.
- `agents/relecteur.md` — modifier — contre-test, correspondance critère ↔ test, cas négatifs, fumée.
- `README.md` — modifier — nouvelle section `## Contre-test`, placée après `## Clôture et archivage`.
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — version `3.4.0`. C'est une montée MINEURE : on ajoute un outil et des règles d'agent, sans renommer ni modifier aucun hook.

## 5. Étapes
1. `tests/test_contre_test.sh`, partie script, écrite **avant** le script. Même squelette que `test_ci_projet.sh` : `ok`/`ko`, `ECHECS`, `exit $((ECHECS > 0))`, dossier `mktemp -d` supprimé par `trap`, `TMPDIR` pointé vers un sous-dossier vide de ce dossier. Le dépôt jetable contient sur `main` : `f.sh` (`echo 1`), `tests/t.sh` (`[ "$(bash f.sh)" = 1 ]`) et `.gitignore` (`node_modules/`). On y ajoute un `node_modules/marq` non suivi. Les branches :
   - `b1` : `f.sh` affiche 2, `tests/t.sh` attend 2 ;
   - `b2` : ajoute `tests/t2.sh`, qui attend 1, sans toucher au code ;
   - `b3` : modifie seulement `f.sh`.

   Cas à couvrir, à lancer avec `git checkout` de chaque branche dans le dépôt jetable :
   - b1, `-- bash tests/t.sh` → code 0, `rouge` ;
   - b2, `-- bash tests/t2.sh` → code 1, `vert` ;
   - b3 → code 3 ;
   - b1, `--fichiers nulle-part/` → code 3 ;
   - (négatif) `--base inexistante` → code 2 ;
   - (négatif) lancé hors d'un dépôt git → code 2 ;
   - (négatif) rien après `--` → code 2 ;
   - b1, `-- test -e node_modules/marq` → code 1, ce qui prouve que le lien existe ;
   - après tous les appels : `TMPDIR` est vide, `git status --porcelain` est vide, `.git/worktrees` est absent et la sortie de `git for-each-ref` n'a pas changé.

   Vérifier que le fichier échoue (le script est absent).
2. `tests/test_hooks.sh` appelle `tests/test_contre_test.sh`. Créer `scripts/contre-test.sh` : tous les cas de l'étape 1 passent.
3. `tests/test_contre_test.sh`, partie texte, écrite **avant** les modifications des agents. Contrôles par `grep -qF` :
   - `agents/specs.md` contient `— test :`, `(négatif)`, `(non-régression)`, `(fumée)`, `Contre-test : non applicable` et `skill \`run\`` ;
   - `agents/codeur.md` contient `tests rouges avant : oui/non` et `avant l'implémentation` ;
   - `agents/relecteur.md` contient `scripts/contre-test.sh`, `Contre-test :`, `(non-régression)`, `(négatif)`, `(fumée)` et `merge-base` ;
   - `README.md` contient `## Contre-test`.

   Vérifier que ces contrôles échouent.
4. `agents/specs.md`, item 6 : remplacer « cases à cocher testables » par la règle des marqueurs de la Conception, en 3 à 5 lignes. `agents/codeur.md`, une puce après « Lance les tests/lint… » :
   - écris ou modifie les tests **avant l'implémentation** ;
   - lance-les et vérifie qu'ils échouent pour la bonne raison ;
   - implémente, puis vérifie qu'ils passent ;
   - ne commite jamais l'état rouge (avec des lots, tests et implémentation vont dans le même commit) ;
   - la raison est obligatoire si tu réponds « non » (non-régression, refactor, doc).

   Au rapport final, ajouter « une ligne `tests rouges avant : oui/non (raison)` par lot, ou une seule sans lots ».
5. `agents/relecteur.md`, nouvelle puce « Contre-test », placée après « Relance les tests… » :
   - Lance `bash "$C" --base main -- <commande>` pour chaque commande de la section Tests de la spec qui exécute des fichiers de test nouveaux ou modifiés. `C` se résout selon la Conception. Passe `TMPDIR=<ton scratchpad>` si le dossier temporaire par défaut n'est pas inscriptible. Le script compare à la `merge-base` et supprime lui-même son clone. Ta seule écriture admise est ce clone, hors du dépôt.
   - Code 0 : vérifie dans la sortie que chaque cas nouveau lié à un critère non marqué `(non-régression)` fait partie des échecs. Un tel cas qui passe sur la base est bloquant. Un échec d'import ou de compilation du code nouveau compte comme rouge. Un échec d'environnement (dépendance absente sur la base) ne compte pas : mineur « contre-test non concluant ».
   - Code 1, ou code 3 alors que le comportement change : bloquant « les tests ne prouvent pas le changement ». Exceptions admises : tous les cas concernés sont `(non-régression)` ; la spec porte `Contre-test : non applicable (raison)` et le diff le confirme (refactor sans changement de comportement, doc) ; les tests sont dans le fichier source (mineur « contre-test non applicable : tests dans le source »).
   - Code 2 : mineur « contre-test impossible : <raison> ».
   - Correspondance critère ↔ test : un critère sans test qui le couvre réellement est bloquant. Une mention `— test :` absente alors que le test existe est mineure. Une fonctionnalité sans cas `(négatif)` testé est bloquante. Une commande `(fumée)` présente doit être relancée ; si elle échoue, c'est bloquant.
   - Au rapport, ajouter la ligne `Contre-test : rouge / vert (exception : …) / non applicable (raison)`.
6. `README.md`, section `## Contre-test` (8 lignes au plus) : marqueurs, tests d'abord, usage du script et codes de sortie, exceptions, limites (tests dans le source ; base qui échoue pour une raison d'environnement). `CHANGELOG.md` : entrée `3.4.0`. `plugin.json` : `3.4.0`.

## 6. Critères d'acceptation
- [x] Le script renvoie 0 quand un test nouveau échoue sur la base — test : `bash tests/test_contre_test.sh` (cas b1 « rouge »)
- [x] Le script renvoie 1 quand le test nouveau passe déjà sur la base — test : `bash tests/test_contre_test.sh` (cas b2 « vert »)
- [x] Le script renvoie 3 sans fichier de test nouveau ou modifié, et `--fichiers` remplace les valeurs par défaut — test : `bash tests/test_contre_test.sh` (cas b3 et `nulle-part/`)
- [x] (négatif) Une ref inconnue, un dossier hors dépôt ou une commande absente donnent le code 2 — test : `bash tests/test_contre_test.sh` (3 cas)
- [x] Le script ne laisse rien derrière lui et n'écrit rien dans le dépôt (`TMPDIR` vide, status propre, pas de `.git/worktrees`, refs inchangées) — test : `bash tests/test_contre_test.sh` (cas « propre »)
- [x] `node_modules` de la racine est visible dans le clone — test : `bash tests/test_contre_test.sh` (cas `marq`)
- [x] Les agents specs, codeur et relecteur et le README portent les règles et les marqueurs — test : `bash tests/test_contre_test.sh` (contrôles de texte)
- [x] (non-régression) La détection de la CI dans `agents/specs.md` est intacte — test : `bash tests/test_ci_projet.sh`
- [x] La suite complète passe et le plugin est valide — test : `bash tests/test_hooks.sh && claude plugin validate --strict .`

## 7. Tests
```
bash tests/test_contre_test.sh
bash tests/test_hooks.sh
claude plugin validate --strict .
bash scripts/contre-test.sh --base main -- bash tests/test_hooks.sh   # attendu : code 0, « rouge »
```

## 8. Décisions
- Rust : on garde `CARGO_TARGET_DIR="$R/target"`, pour réutiliser le cache de compilation et économiser le disque.
- Fumée : on garde « skill `run` si elle est disponible, sinon commande de lancement du projet ». `run` est une skill intégrée à Claude Code, pas une skill du kit.
- « Les tests ne prouvent pas le changement » reste bloquant dès maintenant, sans rodage. Les marqueurs `(non-régression)` et `Contre-test : non applicable` couvrent les faux positifs.

## Lots
- [x] L1 — Script de contre-test et ses tests, écrits d'abord (étapes 1-2)
  Fichiers : `scripts/contre-test.sh`, `tests/test_contre_test.sh`, `tests/test_hooks.sh`
  Fait quand : script et dépôts jetables verts, suite complète verte — `bash tests/test_hooks.sh`
- [x] L2 — Règles des agents, README et version (étapes 3-6)
  Fichiers : `tests/test_contre_test.sh`, `agents/specs.md`, `agents/codeur.md`, `agents/relecteur.md`, `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`
  Fait quand : contrôles de texte verts, contre-test rouge sur la base — `bash tests/test_hooks.sh && bash scripts/contre-test.sh --base main -- bash tests/test_hooks.sh`
