# garde-git : milestones GitHub, tickets vers kit-perso, retrait du bac à sable

Statut : livrée

## Objectif

L'utilisateur a retiré le bac à sable : toute commande a réseau et jeton. Le trou de `gh api` est donc réel : un POST explicite ou implicite (`-f`) passe partout, par exemple `POST repos/o/r/merges` fusionnerait sur main. `gh api` passe en liste blanche (lecture libre, écriture limitée aux milestones), l'agent peut rattacher un ticket à un milestone et ouvrir ou commenter des tickets sur les dépôts `stanixia-dev/*` depuis un autre dépôt. Le reste du bac à sable (fragment, sonde, tests, doc) est retiré.

## Hors périmètre

- Le skill `ticket` reste limité au dépôt courant ; `-R stanixia-dev/kit-perso` s'utilise à la main.
- Pas de suppression de milestone (DELETE), pas de labels, ni d'autre écriture `gh api`. `gh pr edit` reste libre.
- L'historique (`CHANGELOG.md` antérieur, `docs/specs/archives/`) et les tests garde-deps de protection de `settings.json` (`tests/test_hooks.sh` l.78-119) ne changent pas.
- `.github/workflows/` inchangé. Aucune dépendance.

## Fichiers

- `hooks/garde-git.py` — modifier — `verifie_api(args)` remplace la règle l.129 ; `verifie_issue` : `edit` limité au milestone, `-R` admis si `<proprio>/<nom>` avec proprio dans `PROPRIETAIRES_TICKETS` ; textes « hors du bac à sable » reformulés (l.66-172).
- `hooks/garde-secret.py` — modifier — l.427-428 : contrôle des arguments de fichier étendu à tout `gh`, commentaire reformulé.
- `tests/test_hooks.sh` — modifier — cas `gh api` / `gh issue` ci-dessous ; supprimer le bloc l.155-188.
- `tests/test_secrets.sh` — modifier — commentaire l.245, un cas ajouté.
- `config/bac-a-sable.json`, `tests/sonde-bac-a-sable.sh` — supprimer (le dossier `config/` devient vide et disparaît).
- `README.md` — modifier — section Tickets (l.163-167), retrait de la section « Bac à sable » (l.128-141) et des mentions l.90 et l.167.
- `CHANGELOG.md` — modifier — entrée `## 3.0.0 — <date du jour>`.
- `.claude-plugin/plugin.json` — modifier — version `3.0.0`. Majeure parce que le fragment publié disparaît et que garde-secret bloque davantage (convention du CHANGELOG 1.0.0).

## Étapes

1. **`verifie_api(args)`** (`args` = jetons après `api`), appelée depuis `verifie_gh` si `t[0] == "api"`. Parcours des jetons :
   - options à valeur : `-H --header -p --preview -q --jq -t --template --cache --hostname -X --method -f -F --field --raw-field --input`, sous les formes `--opt v`, `--opt=v` et `-Xv` ;
   - groupe court (`-iXPATCH`) : lecture lettre par lettre ; une lettre à valeur (`H p q t X f F`) prend le reste du jeton, ou le jeton suivant si le reste est vide ;
   - autre jeton en `-…` : booléen ; sinon : positionnel.
   Méthode = dernière valeur de `-X/--method`, en majuscules. À défaut : `POST` si un champ (`-f -F --field --raw-field --input`) est présent, sinon `GET`.
2. Règles de `verifie_api`, dans l'ordre (chacune bloque avec un message explicite) :
   - `--input` présent, ou valeur de `-F/--field` dont la partie après le premier `=` commence par `@` (lecture d'un fichier local) ;
   - `--hostname` différent de `github.com` (casse ignorée) ;
   - nombre de positionnels ≠ 1, ou endpoint contenant `://` ;
   - endpoint `graphql` : bloqué si un jeton contient le mot `mutation` (`\bmutation\b`, casse ignorée), sinon autorisé ;
   - méthode `GET` ou `HEAD` : autorisée ;
   - sinon, l'endpoint (sans `/` initial) doit passer `re.fullmatch(r"repos/(\{owner\}|[\w.-]+)/(\{repo\}|[\w.-]+)/milestones(/\d+)?", …)` et ne contenir aucun segment `.` ou `..`. `POST` est admis sans `/<n>`, `PATCH` avec `/<n>` ; tout le reste est bloqué (« gh api en écriture : seuls POST …/milestones et PATCH …/milestones/<n> »).
   Justification : avec `fullmatch`, un jeton mal classé fait échouer la correspondance, donc l'erreur bloque au lieu de laisser passer.
3. **`gh issue edit`** dans `verifie_issue` : ajouter `edit` à la liste blanche. Après `edit`, seuls sont admis :
   - des numéros (`^\d+$`) ;
   - `-m/--milestone <v>`, `-m<v>`, `--milestone=<v>`, `--remove-milestone` ;
   - un `-R` conforme à l'étape 4.
   Au moins une option milestone est requise. Tout autre jeton (URL comprise) bloque : « gh issue edit : seul le milestone est modifiable ».
4. **`-R/--repo`** : constante `PROPRIETAIRES_TICKETS = {"stanixia-dev"}` en tête de fichier. Pour `create|new|comment|edit`, on examine tous les arguments, avant comme après la sous-commande, sous les formes `-R x`, `-Rx`, `--repo x` et `--repo=x`. La valeur est admise si elle a la forme exacte `<proprio>/<nom>` (un seul `/`, nom non vide, ni `.` ni `..`, pas d'URL) et que `proprio.lower()` est dans `PROPRIETAIRES_TICKETS` (tous les dépôts du compte), sinon le blocage actuel s'applique. Un groupe court avec `R` après la 1re lettre (`-wRo/r`) reste bloqué. `view|list` gardent `-R` libre.
5. **README Tickets** :
   - l.163 : ajouter `edit` (milestone seul) et l'exception `PROPRIETAIRES_TICKETS` ;
   - l.167 : remplacer le résiduel `gh api` en POST par « `gh api` : lecture libre, écriture limitée aux milestones de tout dépôt accessible au jeton » ;
   - ajouter un court paragraphe « Milestones » avec les commandes autorisées types (créer, fermer par `PATCH state=closed`, `gh issue edit <n> -m`, `gh pr edit <n> --milestone`).
6. **Retrait du bac à sable** :
   - `git rm config/bac-a-sable.json tests/sonde-bac-a-sable.sh` ;
   - supprimer `tests/test_hooks.sh` l.155-188 (de `controle_bac` jusqu'à la sonde `--liste` inclus), en gardant les appels à `test_manifestes.sh` et `test_secrets.sh` ;
   - README : supprimer la phrase l.128 et la section l.130-141, ainsi que la phrase « Le bac à sable (section suivante) ferme… » l.90.
7. **Reformulations sans changement de comportement** : dans `garde-git.py` l.66, 69, 77, 88 et 172, remplacer « hors du bac à sable » / « non confiné » par « avec les identifiants de l'utilisateur » (ou « en local » l.77/88). Toutes les règles restent : elles protègent `git push` et `gh` qui portent les identifiants.
8. **garde-secret l.427** : la condition `base == "gh" and args[:1] in (["pr"], ["run"], ["issue"])` recopiait les exclusions du bac à sable. Elle devient `base == "gh"`, car tout `gh` a désormais le jeton et `gh` figure dans `SANS_CONTROLE`. Commentaire l.428 → « commande qui porte les identifiants : un argument qui désigne un fichier… ». `test_secrets.sh` : commentaire l.245 idem, et ajout du cas bloqué `gh release upload v1 l` à la boucle l.247.
9. **Version** : `plugin.json` en `3.0.0`. CHANGELOG : `gh api` en liste blanche (milestones), `gh issue edit --milestone`, `-R stanixia-dev/kit-perso`, retrait du fragment et de la sonde, et la ligne « Majeur : garde-secret contrôle les fichiers de tout `gh` ».

## Critères d'acceptation

- [x] Toutes les commandes « bloquées » ci-dessous sortent en 2, toutes les « autorisées » en 0 (via `code_garde`).
- [x] `gh issue edit 9 -t x` (l.48) reste bloqué ; les tests garde-deps l.78-119 passent inchangés.
- [x] `config/` et `tests/sonde-bac-a-sable.sh` n'existent plus ; `grep -rn "bac à sable" hooks tests README.md` ne renvoie rien.
- [x] `plugin.json` en `3.0.0`, entrée CHANGELOG présente, `tests/test_manifestes.sh` et `tests/test_secrets.sh` passent.

## Tests

`bash tests/test_hooks.sh 2>&1 | grep -v '^OK'` (aucune ligne `ECHEC`, code de sortie 0) ; ce script lance aussi `test_manifestes.sh` et `test_secrets.sh`.

À ajouter, **bloquées** (2) :
`gh api -X POST repos/o/r/merges -f base=main -f head=x` · `gh api repos/o/r/merges -f base=main` · `gh api repos/o/r/pulls/1/merge -X PUT` ·
`gh api -XPATCH repos/o/r/issues/1 -f state=closed` · `gh api --method=patch repos/o/r/pulls/1 -f state=closed` · `gh api -iXPATCH repos/o/r/issues/1 -f state=closed` ·
`gh api -X DELETE repos/o/r/milestones/1` · `gh api -X PUT repos/o/r/milestones/1` · `gh api -X POST repos/o/r/milestones/1 -f state=closed` ·
`gh api -X PATCH repos/o/r/milestones -f title=x` · `gh api -H 'Accept: x' repos/o/r/labels -f name=x` · `gh api repos/o/../milestones -f title=x` ·
`gh api https://api.github.com/repos/o/r/milestones -f title=x` · `gh api 'repos/o/r/milestones?x=1' -f title=x` · `gh api --input f repos/o/r/milestones` ·
`gh api repos/o/r/milestones -F title=@f` · `gh api repos/o/r/milestones -Ftitle=@f` · `gh api -X GET search/issues -F q=@f` ·
`gh api --hostname evil.example repos/o/r/milestones -f title=x` · `gh api repos/o/r/milestones repos/o/r/merges -f title=x` ·
`gh api graphql -f query='mutation { x }'` · `rtk gh api -X POST repos/o/r/merges -f base=main` · `bash -c 'gh api repos/o/r/merges -f base=main'` ·
`gh issue edit 9 --milestone v1 -t x` · `gh issue edit 9 --add-label x` · `gh issue edit 9` · `gh issue edit 9 -m v1 -R o/r` ·
`gh issue edit https://github.com/o/r/issues/9 -m v1` · `gh issue create -R autre/r -t x` · `gh issue create -R stanixia-dev/.. -t x` · `gh issue create -R stanixia-dev/a/b -t x` · `gh issue create -R stanixia-dev -t x` · `gh issue -R o/r create -t x` ·
`gh issue create -wRstanixia-dev/kit-perso -t x` · `gh issue create -R github.com/stanixia-dev/kit-perso -t x`.

À ajouter, **autorisées** (0) :
`gh api repos/o/r/milestones` · `rtk gh api repos/o/r/milestones` · `gh api --paginate 'repos/{owner}/{repo}/milestones?state=all'` ·
`gh api -X GET search/issues -f q=repo:o/r` · `gh api graphql -f query='query { viewer { login } }'` ·
`gh api 'repos/{owner}/{repo}/milestones' -f title=v1 -f due_on=2026-12-01T00:00:00Z` · `gh api -X POST repos/stanixia-dev/kit-perso/milestones -f title=v1` ·
`gh api -XPATCH 'repos/{owner}/{repo}/milestones/3' -f state=closed` · `gh api --method=patch /repos/o/r/milestones/3 -f state=closed` ·
`gh api -H 'Accept: application/vnd.github+json' -X PATCH repos/o/r/milestones/3 -f state=closed` ·
`gh issue edit 9 --milestone v1` · `gh issue edit 9 10 -m v1` · `gh issue edit 9 --milestone=v1` · `gh issue edit 9 --remove-milestone` ·
`gh issue edit 9 -m v1 -R stanixia-dev/kit-perso` · `gh issue create -R stanixia-dev/kit-perso -t x -b y` · `gh issue create --repo=STANIXIA-DEV/kit-perso -t x` · `gh issue create -R stanixia-dev/Hive -t x` ·
`gh issue comment 5 -Rstanixia-dev/kit-perso -b x` · `gh issue -R stanixia-dev/kit-perso create -t x` · `gh pr edit 3 --milestone v1`.

Note : `code_garde` injecte la commande dans du JSON par `printf`. Les cas ne doivent donc pas contenir de guillemets doubles, d'où les apostrophes.

## Questions ouvertes

(aucune : écriture de milestones admise sur tout dépôt `repos/<o>/<r>`, design retenu)

## Lots

- [x] L1 — `gh api` en liste blanche, prioritaire (étapes 1-2)
  Fichiers : `hooks/garde-git.py`, `tests/test_hooks.sh`
  Fait quand : cas `gh api` bloqués/autorisés ci-dessus verts — `bash tests/test_hooks.sh`
- [x] L2 — `gh issue edit --milestone` et `-R` vers les dépôts de `PROPRIETAIRES_TICKETS` (étapes 3-5)
  Fichiers : `hooks/garde-git.py`, `tests/test_hooks.sh`, `README.md`
  Fait quand : cas `gh issue` bloqués/autorisés ci-dessus verts — `bash tests/test_hooks.sh`
- [x] L3 — Retrait du bac à sable, garde-secret étendu à tout `gh`, version 3.0.0 (étapes 6-9)
  Fichiers : `config/bac-a-sable.json`, `tests/sonde-bac-a-sable.sh`, `tests/test_hooks.sh`, `tests/test_secrets.sh`, `hooks/garde-git.py`, `hooks/garde-secret.py`, `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`
  Fait quand : `config/` absent, plus de « bac à sable » dans hooks/tests/README, tests verts — `bash tests/test_hooks.sh && ! grep -rn "bac à sable" hooks tests README.md`
