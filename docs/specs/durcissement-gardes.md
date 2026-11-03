# Durcissement des gardes : contournements gh/git et erreurs avalées

Statut : validée (2026-11-03)

## Objectif

Fermer les contournements relevés dans `garde-git` et `garde-secret` (options `gh` avant ou entre les sous-commandes, `git -c … push`, options globales à valeur, `push --all`, abréviations d'options, chemins contenant un blanc), et rendre fail-closed les erreurs que les scripts avalent en mode CLI (lancés par le relecteur) et dans `deps_communs.charge()`. Corriger les noms de checks CI du README. Version visée : **3.1.2** (correctif, même classement que 3.0.1 : ces commandes devaient déjà être bloquées).

## Hors périmètre

- Issues #21 et #22 (garde-deps et interpréteurs, `genere-ci.py`), refactor des scanners de garde-deps, `.github/workflows/`.
- Le mode `--hook` de `verifie-manifestes.py` (post, stop) reste fail-open, comme documenté.
- Résiduels conservés : `git config alias.x …` puis `git x`, et `git -C <dépôt>` ou `--git-dir` vers un dépôt dont la config exécute du code. Ce sont des garde-fous contre les erreurs de l'IA, pas une frontière de sécurité.
- Aucune dépendance. `garde-git.py` reste autonome (copié tel quel dans `~/.claude`, README l.185) : il n'importe aucun module voisin.

## Fichiers

- `hooks/garde-git.py` — modifier — normalisation des options `gh` ; options globales git ; règles push/commit (abréviations, `--all`, `HEAD`, `*`).
- `hooks/garde-secret.py` — modifier — normalisation `gh` (l.414-427) ; jetons à blanc (l.453-458) ; CLI fail-closed ; mode lu après `parse_args` (l.622-636).
- `hooks/garde-deps.py` — modifier — `GIT_OPT_VALEUR` (l.243) complété (utilisé par garde-secret).
- `hooks/verifie-manifestes.py` — modifier — `__main__` : exception hors `--hook` = code 2 + trace.
- `hooks/deps_communs.py` — modifier — `charge()` renvoie `None` sur réponse mal formée.
- `tests/test_hooks.sh`, `tests/test_secrets.sh`, `tests/test_manifestes.sh`, `tests/fixtures/garde-deps.json` — modifier — cas ci-dessous.
- `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — noms de checks, résiduels, version 3.1.2.

## Étapes

1. **gh, garde-git** : ajouter `mots_gh(args)` (`args` = jetons après `gh`). Elle parcourt les jetons, saute ceux en `-…` (`-R`/`--repo` sans `=` consomment aussi le jeton suivant) et renvoie `(mots, reste)` : `mots` = les 2 premiers jetons positionnels, `reste` = tous les autres jetons, dans l'ordre. Dans `verifie_gh`, les règles s'appliquent à `" ".join(mots + reste)`. Si `mots[0] == "api"` : `verifie_api(args)` sans ce seul jeton `api` (un `-R o/r` restant donne 2 positionnels, donc blocage). Même chose pour `issue` avec `verifie_issue` (qui gère déjà `-R` avant la sous-commande).
2. **gh, garde-secret** : même fonction, locale (`-h`/`--hostname` consomment en plus une valeur, pour `gh auth -h github.com token`). `auth token`, `auth status -t`, `pr create` (scan + livre) et `gist create|edit` se testent sur `mots`. Pour gist, tous les jetons de `reste` passent par `chemin_protege`.
3. **Options globales git** : dans `garde-git.py`, une constante `GIT_GLOBALES_VALEUR = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--attr-source"}` sert à `dossier_git` et `sous_commande` (la forme `--opt=v` ne consomme rien). Ajouter `--config-env`, `--attr-source` et `--super-prefix` à `GIT_OPT_VALEUR` de `garde-deps.py`. Bloquer ensuite :
   - avant `push`, toute option `-c`, `--config-env[=…]` ou `--exec-path[=…]` (« configuration à la volée devant `git push` interdite : elle peut exécuter du code avec les identifiants ») ;
   - pour toute sous-commande, `-c`/`--config-env` dont la clé (avant `=`, casse ignorée) commence par `alias.`.
   On bloque tout `-c` plutôt qu'une liste de clés : la liste (sshCommand, hooksPath, credential, protocol, url.insteadOf, include.path, fsmonitor…) serait incomplète.
4. **Abréviations et groupes courts** : ajouter `option_dangereuse(a, liste)`. Elle prend `nom = a.split("=", 1)[0]` ; si `nom` commence par `--`, fait plus de 2 caractères et est un préfixe d'une option de `liste`, elle renvoie cette option. Un préfixe de plusieurs options est refusé par git comme ambigu, le bloquer ne coûte rien. Remplacer les tests l.171-174, l.187-189 et l.207 :
   - push, `liste` = `--force --force-with-lease --force-if-includes --mirror --delete --no-verify --prune --all --branches --receive-pack --exec` ;
   - commit, `liste` = `--no-verify`.
   Groupes courts (`^-[a-zA-Z0-9]+$`) : seules comptent les lettres avant la première lettre à valeur. Push : `o` est à valeur, `f` ou `d` bloque. Commit : `mFCct` sont à valeur, `n` bloque. Corriger le commentaire « 3 caractères ».
5. **Cibles de push** :
   - `--all`/`--branches` sont bloqués par l'étape 4 (« pousse toutes les branches, main comprise ») ;
   - une refspec contenant `*` est bloquée ;
   - une cible (`r.split(":")[-1]`) égale à `HEAD` ou `@` est remplacée par `branche_cible(cwd)` avant le test `PROTEGEES`.
6. **Fail-closed en CLI, garde-secret** : variable globale `MODE`, posée juste après `parse_args` (`"ci"`, `"pre"`, `"post"`, `"stop"`, sinon `"cli"` ; valeur par défaut `"cli"`). Dans le `except Exception` final, `MODE in ("pre", "ci", "cli")` donne la trace sur stderr et le code 2, sinon le code 0. Cela remplace le test fragile `sys.argv[1:][-2:] == ["--hook", "pre"]`. Dans `commande()`, les illisibles (`git … a échoué`) rejoignent `blocs` hors `--ci` aussi : sans budget en CLI, ils ne viennent que d'un échec git.
7. **Fail-closed en CLI, verifie-manifestes** : dans `__main__`, une exception sans `--hook` (avec ou sans `--ci`) affiche la trace et met `code = 2`. Avec `--hook`, le comportement ne change pas.
8. **Jetons à blanc** (garde-secret l.454) : au lieu de `continue`, un jeton à blanc d'une commande non-interpréteur est testé entier par `classe_chemin(t, cwd)`, à condition de contenir `/` ou d'exister (`os.path.lexists`, relatif à cwd). Cela évite de bloquer `--msg 'voir la doc .env'`.
9. **`charge()`** : la normalisation (après le test `isinstance(d, dict)`) passe dans un `try`. Sur `KeyError`, `TypeError`, `AttributeError` ou `ValueError`, elle renvoie `None`, et l'appelant écrit alors « vérification impossible » (avertissement en local, blocage en `--ci`). Fixtures `npm-depublie` (`time` contient `"unpublished": {…}`, ni `versions` ni `dist-tags`) et `osv-npm-depublie: {}`.
10. **README** :
    - l.54 et l.97 : `tests / deps` devient `deps / deps` (workflow `deps.yml`, job `deps`) ;
    - l.147 : rendre obligatoires `deps / deps` et `tests / hooks` ;
    - l.113 : retirer le résiduel « un chemin contenant un blanc » ;
    - l.57 : ajouter « en CLI (`--base`), une erreur imprévue sort en 2 avec la trace » ;
    - section Tickets (l.176) : une phrase sur les nouveaux blocages de `git push` (`-c`/`--config-env`/`--exec-path`, `--all`/`--branches`, refspec `*`, `HEAD` sur main, abréviations) et sur la normalisation des options `gh`.
11. **Résidus** : dans `tests/test_hooks.sh` l.113, 150 et 154, remplacer la clé `sandbox` par `permissions`.
12. **Version** : `plugin.json` passe en `3.1.2`. Ajouter l'entrée `## 3.1.2 — <date du jour>` au CHANGELOG, avec une ligne par constat et la ligne « Correctif : commandes déjà interdites par les règles, détection complétée ».

## Critères d'acceptation

- [ ] Chaque cas « bloqué » ci-dessous sort en 2 et chaque « autorisé » en 0 ; chaque nouveau cas échoue sur `main`.
- [ ] `verifie-manifestes.py --base inexistant` et `garde-secret.py --base inexistant` (CLI) sortent en 2 ; `garde-secret.py --hook pre --depot x` sur une entrée vide sort en 2.
- [ ] `npm i depublie` donne « vérification impossible » : avertissement (0) en local, blocage (2) en `--ci`.
- [ ] `grep -c 'tests / deps' README.md` vaut 0, `grep -c sandbox tests/test_hooks.sh` vaut 0, version 3.1.2 et entrée CHANGELOG présentes.
- [ ] `bash tests/test_hooks.sh` sort en 0, sans ligne `ECHEC`.

## Tests

`bash tests/test_hooks.sh | grep -v '^OK'; echo "code ${PIPESTATUS[0]}"`. Ce script lance aussi `test_manifestes.sh`, `test_secrets.sh` et `test_ci_projet.sh`. Les cas ci-dessous sont à ajouter dans les boucles existantes. Pour `code_garde`, pas de guillemets doubles : utiliser des apostrophes, ou `code_garde_j`.

- **garde-git, bloqués** (`code_garde`, cwd /tmp) :
  - gh : `gh pr -R o/r merge 1` · `gh -R o/r pr merge 1` · `gh pr --repo=o/r merge 1` · `gh pr --repo o/r review 1 --approve` · `gh -R o/r pr close 1` · `gh -R o/r api -X POST repos/o/r/merges -f base=main` · `gh -R o/r issue close 3` · `gh --repo o/r secret set X` ;
  - options globales : `git -c core.sshCommand=x push origin b` · `git -c protocol.ext.allow=always push origin b` · `git --config-env core.sshCommand=E push origin b` · `git --config-env=core.sshCommand=E push origin b` · `git --exec-path=/tmp/x push origin b` · `git -c alias.p=push p origin main` · `git --namespace x push origin main` · `git --attr-source x push origin main` ;
  - options de push : `git push --all origin` · `git push --branches origin` · `git push --al origin` · `git push origin 'refs/heads/*:refs/heads/*'` · `git push --mirr origin` · `git push --del origin b` · `git push --ex=x origin b` · `git push --receive-p=x origin b` · `git push --no-veri origin b` · `git push --force-w origin b` · `git push --pru origin` · `git push -ud origin b` ;
  - commit : `git commit --no-veri -m x`.
- **garde-git, bloqués dans un dépôt jetable sur `main`** (helper `code_garde_main`, qui pose `cwd` = `mktemp -d` puis `git init -q -b main`, nettoyé par `trap`) : `git push origin HEAD` · `git push origin @`.
- **garde-git, autorisés** : `gh pr -R o/r view 1` · `gh -R o/r pr list` · `gh -R stanixia-dev/kit-perso issue create -t x` · `git -c user.name=x commit -m y` · `git -C x push origin b` · `git push --tags origin` · `git push --follow-tags origin b` · `git push --porcelain origin b` · `git push --dry-run origin b` · `git push -u origin b` · `git push --push-option=ci.skip origin b` · `git commit -am x` · `git push origin HEAD` (cwd /tmp, hors main).
- **garde-secret, bloqués** (`hk Bash "$TMP/w"`) : `cat "mon dossier/.env"` · `cat mon\ dossier/.env` · `gh auth -h github.com token` · `gh auth --hostname github.com status --show-token` · `gh -R o/r gist create .env`. Boucle « scan avant commit et push » (dépôt `precommit`) : ajouter `gh -R o/r pr create --fill` · `gh pr -R o/r create --fill` · `git --namespace x push origin f`.
- **garde-secret, autorisé** : `python3 x.py --msg 'voir la doc .env'`.
- **garde-secret, mode** : `printf '' | python3 "$S" --hook pre --depot x` sort en 2 ; `lance "$d" --base inexistant` sort en 2 avec `a échoué` sur stderr.
- **verifie-manifestes** (`test_manifestes.sh`, après la l.207) : `lance "$d" --base inexistant --cible HEAD` (sans `--ci`) sort en 2 avec `Traceback` sur stderr. Dépôt avec `package.json` `{"dependencies":{"depublie":"1.0.0"}}` : `lance … --ci` sort en 2 avec `vérification impossible` sur stderr ; `lance …` sans `--ci` sort en 0 avec `vérification impossible` sur stdout.
- **garde-deps** (`test_hooks.sh`) : `npm i depublie` sort en 0 et `sortie_deps` contient `vérification impossible`.

## Décisions (validées le 2026-11-03)

1. `-c`, `--config-env` et `--exec-path` devant `git push` : tous bloqués (pas de liste de clés). `-c alias.*` bloqué pour toute sous-commande.
2. Version 3.1.2 (correctif, précédent 3.0.1 ; 3.1.1 est prise par la PR #23).
3. Fail-closed étendu au CLI de `garde-secret.py` (exception ou fichier illisible = code 2 et message, jamais 0 silencieux).
4. Ajout : garde-deps doit normaliser les chemins cibles (`.github/./workflows/x.yml`, `.github//workflows/x.yml` → bloqués comme `.github/workflows/`) ; test dans `tests/test_hooks.sh`.
5. Ordre : la version et le CHANGELOG (étape 12) se font après la fusion de la PR #23 (`git merge main`, jamais de rebase).

## Lots

- [x] L1 — Options `gh` avant ou entre les sous-commandes, dans garde-git et garde-secret (étapes 1-2)
  Fichiers : `hooks/garde-git.py`, `hooks/garde-secret.py`, `tests/test_hooks.sh`, `tests/test_secrets.sh`
  Fait quand : cas gh bloqués/autorisés verts — `bash tests/test_hooks.sh`
- [x] L2 — `git push`/`commit` : options globales, abréviations, `--all`, `HEAD`, refspec `*` (étapes 3-5)
  Fichiers : `hooks/garde-git.py`, `hooks/garde-deps.py`, `tests/test_hooks.sh`, `tests/test_secrets.sh`
  Fait quand : cas git bloqués/autorisés et scan `git --namespace x push` verts — `bash tests/test_hooks.sh`
- [ ] L3 — Fail-closed en CLI (garde-secret, verifie-manifestes) et jetons à blanc (étapes 6-8)
  Fichiers : `hooks/garde-secret.py`, `hooks/verifie-manifestes.py`, `tests/test_secrets.sh`, `tests/test_manifestes.sh`
  Fait quand : `--base inexistant` sort en 2 pour les deux scripts, `cat "mon dossier/.env"` bloqué — `bash tests/test_hooks.sh`
- [ ] L4 — `charge()` : réponse de registre mal formée = « vérification impossible » (étape 9)
  Fichiers : `hooks/deps_communs.py`, `tests/fixtures/garde-deps.json`, `tests/test_hooks.sh`, `tests/test_manifestes.sh`
  Fait quand : cas `depublie` verts en local et en `--ci` — `bash tests/test_hooks.sh`
- [ ] L5 — README, résidus `sandbox`, version 3.1.2 (étapes 10-12)
  Fichiers : `README.md`, `tests/test_hooks.sh`, `CHANGELOG.md`, `.claude-plugin/plugin.json`
  Fait quand : critère README/version rempli, tests verts — `bash tests/test_hooks.sh && ! grep -q 'tests / deps' README.md && ! grep -q sandbox tests/test_hooks.sh`
