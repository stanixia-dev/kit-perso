# Spec — garde-secret (accès, affichage et commit de secrets par l'IA)
Statut : en cours

## 1. Objectif
Nouveau hook qui applique les règles « Secrets » du CLAUDE.md global : l'agent ne lit pas `~/.ssh/`, `~/.config/gh/` ni les `.env`, n'affiche et n'écrit aucun token ou mot de passe, n'en commite aucun. Le filtre de commandes reste une aide : les barrières sont le **masquage de la sortie** (PostToolUse) et le **scan du résultat git** (Stop, CI `pull_request_target`). L'utilisateur garde une échappatoire, `.garde-secret-exceptions`, que seul lui modifie.

## 2. Hors périmètre
- Aucune dépendance (stdlib, Python ≥ 3.11). `~/.claude/settings.json` et `.github/workflows/` ne sont **pas** modifiés par le codeur (voir Q1).
- Purge d'historique, révocation : à la charge de l'utilisateur. Secrets déjà sur `main` : seuls les ajouts depuis la base sont scannés.
- Hooks git (`core.hooksPath`) : à poser dépôt par dépôt et contournables par `git -c`. Push Protection GitHub : dépôt privé, licence payante requise.
- CI dans les autres dépôts : ils n'ont que les couches locales (réutilisation documentée plus tard).
- Résiduels assumés : script qui lit un fichier protégé et transforme la valeur avant de l'afficher (encodage) ; mot de passe sans signature, absent des valeurs connues ; sortie d'une commande en échec, non réécrivable (alerte seule) ; `cd x && git push`, le scan local vise `cwd` (CI et Stop rattrapent) ; jeton de chemin contenant un blanc.

## 3. Fichiers
- `hooks/garde-secret.py` — créer — motifs, masquage, exceptions, scan git, modes `--hook pre|post|stop`, CLI, `--ci`.
- `hooks/hooks.json` — modifier — déclarations PreToolUse, PostToolUse, PostToolUseFailure, Stop, SubagentStop.
- `hooks/deps_communs.py` — modifier — `*/.garde-secret-exceptions` dans `PROTEGES`.
- `hooks/garde-deps.py` — modifier — `.garde-secret-exceptions` dans `MOTIFS`, message de `refuse_protege`.
- `hooks/verifie-manifestes.py` — modifier — en `--ci`, enchaîne `garde-secret.py --ci` ; `sensibles` liste aussi `.garde-secret-exceptions`.
- `agents/relecteur.md` — modifier — puces « Secrets » (nouvelle) et « Exceptions ».
- `tests/test_secrets.sh` — créer. `tests/test_hooks.sh` — modifier — appel de `test_secrets.sh`, cas chemin protégé.
- `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — doc, verrouillage, 0.4.0 (nouveau hook = ajout, précédent 0.3.0).

## 4. Étapes

### Décisions
| Contrôle | Signature (`FORTS`) | Générique (`FAIBLES`) | Échec du hook |
|---|---|---|---|
| Pre Read/Grep/Edit/Write/MultiEdit/NotebookEdit : chemin protégé | bloque | — | bloque |
| Pre Edit/Write/MultiEdit/NotebookEdit : contenu écrit | bloque | avertit | bloque |
| Pre Bash : chemin dans la commande, texte de la commande | bloque | — | bloque |
| Pre Bash `git commit`, `git push`, `gh pr create` : scan du dépôt | bloque | avertit | bloque |
| Post Bash/Read/Grep : sortie | masque + alerte | — | sortie intacte |
| PostToolUseFailure : erreur | alerte | — | sortie intacte |
| Stop, SubagentStop : scan du dépôt | bloque une fois, puis avertit | — | passe |
| CI (`--ci`) | bloque | bloque | bloque |

- `onFailure: "block"` sur PreToolUse seul : pas de réseau, donc un échec est un bug ou une entrée anormale ; ailleurs l'option est sans objet (l'outil a déjà tourné). Secours utilisateur : `claude plugin disable kit-perso@kit-perso`.
- Masquage : `hookSpecificOutput.updatedToolOutput` « replaces the tool output before it is sent to the model », tous outils (schéma lu dans le binaire 2.1.314, à prouver en session, étape 11). Les hooks PostToolUse tournent en parallèle sur la sortie d'origine, dernier gagnant : jamais de réécriture identique, ne rien émettre sans secret. Aucun autre hook du kit ne réécrit. PostToolUseFailure n'accepte que `additionalContext` : alerte seulement.
- Le parseur Bash de `garde-deps.py` est réutilisé, sans le dupliquer ni le déplacer : `importlib.util.spec_from_file_location` charge `garde-deps.py` (nom à tiret, `main` gardé), idem `verifie-manifestes.py` pour `git` et `base_par_defaut`. Chargement paresseux : seulement en Bash ou en scan git.
- CI sans toucher au workflow : le job `deps` lance `hooks/verifie-manifestes.py --ci` depuis `main` ; ce script enchaîne `garde-secret.py --ci`. La PR ne peut ni l'altérer ni le retirer, aucune action sur les réglages n'est requise.

### L1 — noyau
1. Motifs, chacun enveloppé en `(?<![A-Za-z0-9])(?:…)` sauf `cle-privee`, compilés une fois. Le groupe est obligatoire : sans lui, le préfixe ne vaut que pour la première alternative et `task-aaa…` passe pour un jeton. Aucun motif ne doit se reconnaître dans sa propre source :
   ```python
   FORTS = (("github", r"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,}"),
            ("gitlab", r"glpat-[A-Za-z0-9_-]{20,}"), ("anthropic", r"sk-ant-[A-Za-z0-9_-]{32,}"),
            ("openai", r"sk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{32,}|sk-[A-Za-z0-9]{40,}"),
            ("aws", r"(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Z])"), ("google", r"AIza[0-9A-Za-z_-]{35}"),
            ("slack", r"xox[abprs]-[0-9A-Za-z-]{20,}|hooks\.slack\.com/services/T[0-9A-Z]+/B[0-9A-Z]+/[0-9A-Za-z]{20,}"),
            ("stripe", r"[sr]k_live_[0-9A-Za-z]{20,}"), ("npm", r"npm_[A-Za-z0-9]{36}"), ("pypi", r"pypi-[A-Za-z0-9_-]{50,}"),
            ("cle-privee", r"-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|\Z)"))
   FAIBLES = (("jwt", r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
              ("url", r"[a-z][a-z0-9+.-]*://[^/\s:@'\"]+:(?P<v>[^/\s:@'\"]{8,})@"),
              ("affectation", r"(?i)(?:pass(?:word|wd|phrase)?|pwd|secret|token|api[_-]?key|access[_-]?key|auth[_-]?key)[\"']?\s*[:=]\s*[\"'](?P<v>[^\"'\s]{12,})[\"']"))
   ```
   Bloc entier pour `cle-privee` : masquer le seul en-tête laisserait la clé visible. `analyse(texte, chemin="")` rend `[(niveau, nom, valeur)]` (valeur = groupe `v` s'il existe). Faux positifs : un `fort` est ignoré s'il contient `EXAMPLE` ou compte moins de 6 caractères distincts ; un `faible` est ignoré si la valeur contient `example|exemple|changeme|change_me|replace|your|xxx|dummy|fake|sample|placeholder|todo` (casse ignorée), commence par `$ { < %`, a une entropie de Shannon < 3,0, ou si `chemin` matche `(^|/)(tests?|__tests__|specs?|fixtures?|docs?|examples?)/|\.(md|example|sample|template)$`.
2. Chemins. `classe(chemin)` rend `"perso"` si `(^|/)(\.ssh|\.gnupg|\.config/gh)(/|$)` ou `(^|/)(\.aws/credentials|\.git-credentials|\.netrc|\.cargo/credentials(\.toml)?|\.docker/config\.json|\.claude/\.credentials\.json)$` ou `^/proc/[^/]+/environ$` ; `"env"` si le nom matche `^(\.env(\..+)?|.+\.env|\.envrc)$` sans finir par `\.(example|sample|template|tmpl|dist|defaults?)$`, ou si un nom à joker (`*?`) couvre `.env` ou `.env.local` (`fnmatch`) ; sinon `None`. Un `.env.example` se lit, mais son contenu reste scanné. `NOM_INTERDIT` au commit : classe `env`, ou `^(id_(rsa|dsa|ecdsa|ed25519)|\.netrc|\.git-credentials)$`, ou `\.(p12|pfx|jks|keystore)$` (binaires, invisibles au scan de contenu).
3. Exceptions. `.garde-secret-exceptions` (racine du dépôt) : `<glob relatif> <empreinte|*> <AAAA-MM-JJ> <raison…>`, `#` = commentaire, ligne invalide = avertissement et ignorée. Empreinte = 12 premiers hex de `sha256(valeur)`, jamais la valeur. Un `*` couvre aussi la lecture de ce chemin. Sans effet hors de la racine ni sur la classe `perso` : un dépôt cloné ne doit pas pouvoir débloquer `~/.ssh`. Lue à la demande, seulement après une détection. Le masquage ignore les exceptions.
4. Scan git `scan(racine, base, cible, ci)` → `(trouvailles, illisibles)`. Commits, un par un, car un secret retiré au commit suivant reste dans l'historique : `git -c core.quotePath=false log -p --no-color --no-ext-diff --no-textconv --no-renames --unified=0 --src-prefix=a/ --dst-prefix=b/ --diff-merges=first-parent --format=%x00%H <base>..<cible>` (`first-parent` : `log -p` n'affiche pas les fusions par défaut). Toutes les lignes commençant par `+` sont analysées, en-têtes compris (une ligne de contenu `++ …` y ressemble) ; `+++ b/<chemin>` met à jour le chemin courant. Sans `--cible`, en plus : `git diff HEAD` (mêmes options, ou arbre vide `VIDE` si pas de commit) et les fichiers de `git ls-files -z -o --exclude-standard`, hors NUL dans les 8 premiers Kio et hors > 1 Mio. Noms : `git log --name-only --format= -z --no-renames --diff-merges=first-parent --diff-filter=ACMR`, `git diff --name-only -z --no-renames HEAD` et la liste des non suivis, testés contre `NOM_INTERDIT`. Base : `base_par_defaut` ; échec git : ignoré en local, blocage en `--ci`.
5. CLI `garde-secret.py [--depot D] [--base R] [--cible R] [--ci]` : `fort` (et `faible` si `--ci`) → stderr `⛔ Bloqué par garde-secret :` puis `- <chemin> [<commit 8>] : <nom> (empreinte <12 hex>)`, `exit 2` ; `faible` local → `⚠ …` sur stdout. **Aucun message ne contient une valeur.** `--ci` : exceptions lues dans `git show <base>:.garde-secret-exceptions`, celles de la cible listées non appliquées, section ajoutée à `$GITHUB_STEP_SUMMARY`, toute exception imprévue = traceback et `exit 2`.

### L2 — PreToolUse
6. `--hook pre` (`tool_name` absent = Bash). Read : `file_path`. Grep : `path` (bloqué aussi s'il vaut `~` ou `~/.config`), `glob`. Edit/Write/MultiEdit/NotebookEdit : `file_path`/`notebook_path`, puis `analyse` de `new_string`, `content`, `edits[].new_string`, `new_source`. Chemin testé brut et résolu (`realpath`, relatif à `cwd`). `fort` non couvert → `exit 2` ; `faible` → JSON `systemMessage` + `additionalContext` (`hookEventName: PreToolUse`), `exit 0`. Écrire `.env` est refusé aussi : Edit renvoie un extrait du fichier. Message : demander à l'utilisateur où placer le secret.
7. Bash, parcours calqué sur `analyse` de `garde-deps.py` : `retire_heredocs`, `sans_commentaires`, `substitutions` (récursion jusqu'à `PROFONDEUR_MAX`, corps de heredoc reçus par un shell inclus), `jetons`, `decoupe`, `sans_prefixe`, `appel_shell`. Avant tout, `analyse(cmd)` : un `fort` dans le texte de la commande bloque. Chemins candidats d'un jeton : `re.findall(r"[~\w./*?$+{}-]+", t)`, ce qui couvre `if=.env`, `HEAD:.env`, `$HOME/.ssh/x`. Un jeton qui contient un blanc n'est pas un chemin (messages `-m`, `--body`), sauf pour `gd.INTERPRETES`. Un jeton qui suit une redirection, en entrée (`<`, pas `<<`) comme en sortie, est toujours testé : `echo x > .env` bloque. Commandes sans contrôle de chemin : `echo printf ls stat test [ [[ cd mkdir which type pwd` (noms et métadonnées, jamais le contenu), `gh`. `git` : testé seulement pour `add show diff log blame cat-file grep archive stash`. `grep egrep fgrep rg ag ack sed awk gawk` : premier argument non-option (le motif) sauté. Commande illisible ou trop profonde : chemins candidats sur le texte brut ; une classe trouvée → bloque, sinon passe.
8. Bloqués sans condition : `gh auth token`, `gh auth status` avec `-t`/`--show-token`, `git credential fill`. Un segment `git commit`, `git push` ou `gh pr create` lance le scan du dépôt de `cwd` (sans `--cible`, donc `git add -A && git commit && git push` est couvert avant la commande) ; `fort` → `exit 2` avec : commits non poussés, retirer le secret puis `git reset --soft <base>` et recommiter ; déjà poussé, prévenir l'utilisateur, le secret est à révoquer. Hors dépôt : ignoré.
9. Script enveloppé : exception imprévue en `--hook pre` → stderr + `exit 2`. `hooks.json`, PreToolUse : matcher `Bash|Read|Grep|Edit|Write|MultiEdit|NotebookEdit`, commande `--hook pre`, `timeout` 15, `onFailure: "block"`.

### L3 — PostToolUse, Stop
10. `--hook post`, PostToolUse : copie récursive de `tool_response` (dict/list conservés, seules les chaînes changent) : chaque `fort` → `[masqué:<nom>:<empreinte>]`. Valeurs connues, masquées de même (les plus longues d'abord) : variables de `os.environ` et lignes `CLE=valeur` de `.env` et `.env.local` de `cwd`, dont le nom matche `(?i)TOKEN|SECRET|PASSW|PASSPHRASE|API_?KEY|PRIVATE_?KEY|CREDENTIAL`, valeur ≥ 8 caractères, ni entièrement numérique, ni commençant par `/`. Le hook lit donc `.env` lui-même, sans jamais en rendre le contenu : la règle vise l'agent. Si rien n'a changé : `exit 0` sans sortie. Sinon JSON `systemMessage` (secret masqué dans la sortie de `<outil>`, à révoquer s'il est réel) + `hookSpecificOutput` {`hookEventName: PostToolUse`, `updatedToolOutput`, `additionalContext`}. PostToolUseFailure (`hook_event_name`) : `analyse` de `error`, alerte seule. Exception imprévue → `exit 0`.
11. Preuve en session, sans fixture : `claude -p --model haiku --plugin-dir . --allowedTools Bash "<prompt>"`, le prompt demandant de lancer une commande Python qui imprime un faux jeton construit par concaténation, puis de recopier sa sortie. La réponse contient `masqué`, pas le jeton. Si l'exécution imbriquée est impossible, le dire au rapport, laisser le critère décoché : c'est à l'utilisateur de le rejouer.
12. `--hook stop` : scan du dépôt de `cwd`, `fort` seul. Blocage → stderr, `exit 2` ; `stop_hook_active` vrai → JSON `systemMessage` de rappel, `exit 0`. Exception imprévue → `exit 0`. `hooks.json` : PostToolUse et PostToolUseFailure, matcher `Bash|Read|Grep`, `--hook post`, `timeout` 15 ; Stop et SubagentStop, `--hook stop`, `timeout` 30.

### L4 — CI et protection
13. `PROTEGES` et `MOTIFS` reçoivent `.garde-secret-exceptions`, `refuse_protege` le cite, `sensibles` aussi. `verifie-manifestes.py`, bloc `__main__` : capturer `SystemExit` de `main()`, puis si `--ci` est dans `sys.argv`, lancer `garde-secret.py` (même dossier) avec les mêmes arguments et sortir avec le maximum des deux codes : un échec de l'un n'empêche pas l'autre de tourner.
14. `relecteur.md` : puce « Secrets » : lancer `python3 "$S" --base main`, `S` trouvé comme `V`, nom `garde-secret.py` ; code 2 bloquant, `⚠` mineur, introuvable mineur « secrets non vérifiés ». La puce « Exceptions » cite `.garde-secret-exceptions`.

### L5 — documentation
15. README : hooks cités, décompte 5 hooks et événements, section `## Contrôle des secrets` (couches, tableau des décisions, résiduels, exceptions), `## Verrouillage` : ajouter `Edit(**/.garde-secret-exceptions)`, `Read(~/.ssh/**)`, `Read(~/.config/gh/**)`, `Read(**/.env)`, `Read(**/.env.local)`, `Read(**/.env.production)` et passer à 13 règles. Pas de `Read(**/.env.*)` : le refus l'emporte sur tout et rendrait `.env.example` illisible. Le paragraphe des chemins protégés cite le nouveau fichier.
16. `plugin.json` en 0.4.0, entrée CHANGELOG `0.4.0 — 2026-10-30`. Clôture et archivage selon `agents/codeur.md` dans le commit de L5.

## 5. Critères d'acceptation
- [ ] `FORTS` et `FAIBLES` : chaque nom a un cas positif et un cas négatif ; `task-` suivi de 50 alphanumériques n'est pas un jeton ; `analyse` ne trouve rien dans `hooks/garde-secret.py` ni dans `docs/specs/`.
- [ ] Jetons de test construits à l'exécution (concaténation, ≥ 6 caractères distincts) ; aucun en clair dans `tests/`, et aucun libellé de test ne les imprime.
- [ ] Bloqués : Read `~/.ssh/config`, `~/.config/gh/hosts.yml`, `/x/.env`, `/x/.env.local`, lien symbolique vers `.env` ; Grep `path` `~/.ssh` ; Write `/x/.env` ; `cat .env`, `cat < .env`, `cat .env*`, `dd if=.env`, `echo x > .env`, `git show HEAD:.env`, `git add .env`, `python3 -c "print(open('.env').read())"`, `bash -c 'cat ~/.ssh/id_x'`, `echo "$(cat .env)"`, `gh auth token`, `git credential fill`.
- [ ] Passent sans sortie : Read `/x/.env.example` ; `git commit -m 'protège .env'`, y compris en heredoc `$(cat <<'EOF' …)` ; `echo .env >> .gitignore` ; `grep .env .gitignore` ; `ls ~/.ssh` ; `git check-ignore .env` ; `gh pr create --body 'voir ~/.ssh/ et .env'`.
- [ ] Write/Edit/MultiEdit/NotebookEdit d'un `fort` → 2 ; d'un `faible` → 0 + avertissement ; `AKIA…EXAMPLE` → 0 ; commande Bash contenant un `fort` → 2.
- [ ] Scan : `fort` dans un commit intermédiaire puis retiré → 2 ; `.env` forcé (`git add -f`) → 2 ; fichier non suivi → 2 ; `.env.example` à `fort` → 2 ; ligne `++ <fort>` → 2 ; rien de neuf → 0 muet ; hors dépôt → 0.
- [ ] Exceptions : `fort` couvert par empreinte → 0 ; `--ci` ignore une exception ajoutée par la cible, la liste et bloque ; une exception ne débloque pas `~/.ssh`.
- [ ] Post : sortie à `fort` → JSON masqué de même forme, sans la valeur ni dans `updatedToolOutput`, ni dans `systemMessage`, ni dans `additionalContext` ; clé privée masquée en entier, `END` compris ; valeur connue de `os.environ` masquée ; sortie saine → stdout vide ; Failure → alerte sans valeur. Étape 11 prouvée en session réelle.
- [ ] Stop bloque une fois puis avertit ; en `--hook pre`, entrée JSON invalide → 2 ; en `--ci`, dépôt invalide → 2.
- [ ] `verifie-manifestes.py --ci` échoue sur une PR à secret sans manifeste touché, et lance garde-secret même si les dépendances bloquent. Écritures de `.garde-secret-exceptions` bloquées par garde-deps (Edit, `echo x >`) ; `git diff` de ce fichier passe.
- [ ] `git diff --stat main...HEAD -- .github/workflows` vide ; README, CHANGELOG, 0.4.0 à jour ; spec archivée.

## 6. Tests
```
bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py && claude plugin validate --strict .
```
`test_secrets.sh` suit `test_manifestes.sh` (dépôts jetables `mktemp -d`, fonctions `ok`/`ko`, sortie 1 si échec, hors réseau) et `test_hooks.sh` l'appelle à la fin. Il pose `HOME` sur un dossier jetable : aucun vrai fichier de secrets n'est lu.

## 7. Questions ouvertes
- **Q1 — CI.** Défaut retenu : le scan passe dans le job `deps` existant, sans modifier `.github/workflows/`. Inconvénient : un secret s'affiche sous le nom de check `tests / deps`. Un job dédié `secrets` serait plus lisible, mais tu devrais coller le YAML toi-même (`Edit(**/.github/workflows/**)` est actif chez toi) et rendre le check obligatoire. Recommandation : garder le défaut.
  **Tranchée : défaut retenu** (scan dans le job `deps` via `verifie-manifestes.py --ci`).
- **Q2 — Lecture par script.** Sans bac à sable système, `python3 script.py` peut lire un fichier protégé : seul le masquage rattrape, pour les formats et valeurs connus, donc la lecture n'est pas strictement non contournable. Le bac à sable de 2.1.314 (`sandbox.filesystem.denyRead`, `sandbox.credentials.files`, non essayés) fermerait le trou, mais `git push` et `gh` ont besoin de `~/.config/gh`. Recommandation : accepter ce résidu ici et traiter le bac à sable à part.
  **Tranchée : résidu accepté**, bac à sable hors périmètre.

## Lots
- [x] L1 — noyau : motifs, chemins, exceptions, scan git, CLI (étapes 1-5)
  Fichiers : hooks/garde-secret.py, tests/test_secrets.sh, tests/test_hooks.sh
  Fait quand : les cas `analyse`, scan et exceptions passent — `bash tests/test_hooks.sh`
- [x] L2 — PreToolUse : chemins, contenu écrit, commandes, scan avant commit et push (étapes 6-9)
  Fichiers : hooks/garde-secret.py, hooks/hooks.json, tests/test_secrets.sh
  Fait quand : listes « bloqués » et « passent » vertes, entrée invalide → 2 — `bash tests/test_hooks.sh`
- [ ] L3 — PostToolUse et Stop : masquage, alerte, scan de fin (étapes 10-12)
  Fichiers : hooks/garde-secret.py, hooks/hooks.json, tests/test_secrets.sh
  Fait quand : masquage et Stop verts, preuve en session faite — `bash tests/test_hooks.sh && claude plugin validate --strict .`
- [ ] L4 — CI via le job `deps`, protection des exceptions, relecteur (étapes 13-14)
  Fichiers : hooks/verifie-manifestes.py, hooks/deps_communs.py, hooks/garde-deps.py, agents/relecteur.md, tests/test_secrets.sh, tests/test_hooks.sh
  Fait quand : `--ci` bloque un secret sans manifeste touché — `bash tests/test_hooks.sh`
- [ ] L5 — documentation, version 0.4.0, clôture (étapes 15-16)
  Fichiers : README.md, CHANGELOG.md, .claude-plugin/plugin.json
  Fait quand : suite complète verte, spec archivée — `bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py && claude plugin validate --strict .`
