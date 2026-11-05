# Spec — Runtime Node épinglé et contrôlé
Statut : en cours
Tickets : #34

## 1. Objectif
Le job `node` généré par `/kit-perso:ci-projet` doit utiliser une branche majeure de Node fixée par le projet (`.nvmrc`), avec le dernier correctif de cette branche, et appliquer `engines`. Un contrôle bloquant, en CI et dans un hook local, refuse un Node plus ancien que la dernière version de sécurité de sa branche (index `https://nodejs.org/dist/index.json`, champ `security`).

## 2. Hors périmètre
- **Rust** (`rust-toolchain.toml`, `rustup update`, contrôle de `rustc`) : spec séparée `rust-runtime`, à écrire après cette livraison. L'index Rust n'a pas d'équivalent au champ `security`, donc la règle de blocage reste à trancher. `verifie-runtime.py` est nommé de façon générique pour accueillir ce mode plus tard.
- Branches majeures en fin de vie (EOL) : l'index ne les signale pas, donc une branche EOL passe le contrôle.
- Cohérence entre `.nvmrc` et `engines` : c'est `engine-strict` qui l'impose. Pas d'évaluation des plages semver.
- `.github/workflows/` du kit lui-même, `garde-deps.py`, `deps_communs.py`, `verifie-manifestes.py` : inchangés. Aucune dépendance (stdlib).
- Résidus assumés, à écrire dans le README :
  - Le hook contrôle le `node` trouvé dans le `PATH` du hook. Un `nvm use` fait dans la commande, ou un chemin absolu vers un autre binaire, lui échappe.
  - La détection se fait sur le texte de la commande : `make test`, `./node_modules/.bin/x` ou un script qui lance npm ne sont pas vus.
  - Yarn Berry ignore `engine-strict`.
  - Le job de tests tourne en `pull_request`, donc une PR peut modifier ce workflow. L'agent ne peut pas (garde-deps protège `.github/workflows/`), et le job `deps` reste la barrière qui ne se contourne pas.

## 3. Conception

### Script `hooks/verifie-runtime.py` (stdlib, autonome : n'importe rien du kit)
Il vit dans `hooks/`, comme les autres contrôles, et la CI du projet le récupère par le checkout du kit au SHA figé. Il est autonome pour pouvoir tourner seul dans le job `node`.
- **Version utilisée** : `node --version` via `shutil.which("node")` (délai de 5 s), au format `^v(\d+)\.(\d+)\.(\d+)` (suffixe toléré, ignoré). Si `node` est introuvable ou illisible : hook → 0 en silence ; CLI et `--ci` → 2.
- **Index** : `GET https://nodejs.org/dist/index.json`, avec un `User-Agent` kit-perso. On en tire `corriges = {majeure: max(version)}` sur les entrées où `security` est vrai et dont `version` correspond à `^v\d+\.\d+\.\d+$`. Un index qui n'est pas une liste, ou d'où `corriges` sort vide, compte comme injoignable. Variable de test `KIT_PERSO_NODE_INDEX=<fichier>` : lit ce fichier au lieu du réseau, et un fichier absent compte comme injoignable (même principe que `GARDE_DEPS_FIXTURES`).
- **Règle** : la version `V`, de majeure `M`, est vulnérable si `M ∈ corriges` et `V < corriges[M]` (comparaison de tuples). Si `M` n'a aucune version de sécurité (nouvelle branche, branche impaire), le contrôle passe.
- **Message de blocage** : « Node vX.Y.Z vulnérable : la branche M est corrigée en vA.B.C (nodejs.org, champ security). Demande à l'utilisateur de mettre à jour (`nvm install M && nvm alias default M`) ». En cas de succès, le CLI et `--ci` impriment « Node vX.Y.Z : à jour (branche M corrigée en vA.B.C) ».

### Modes
| Mode | Réseau | Cache | Index injoignable |
|---|---|---|---|
| `--ci` | 2 essais, 10 s chacun | aucun | sortie 2, « index Node injoignable » (fail-closed) |
| CLI (défaut) | 1 essai, 4 s | lu et écrit | cache périmé s'il existe, sinon sortie 2 |
| `--hook pre` | 1 essai, 4 s | lu et écrit | cache périmé s'il existe, sinon 0 avec `systemMessage` « contrôle du runtime Node impossible (index injoignable) » (fail-open) |

Le mode hook est fail-open, comme les autres couches locales : sur la devbox filtrée, il ne doit pas bloquer tout `npm` hors ligne. La CI reste la barrière.

### Hook local (PreToolUse Bash)
- Nouvelle entrée de `hooks/hooks.json` sous `PreToolUse`, avec le matcher `Bash` : `python3 "${CLAUDE_PLUGIN_ROOT}/hooks/verifie-runtime.py" --hook pre`, timeout 15, sans `onFailure` (un plantage reste fail-open).
- **Chemin rapide** : si `tool_input.command` ne contient pas un des mots `node|npm|npx|pnpm|yarn|corepack`, le hook sort en 0 sans lancer de processus, sans réseau et sans lire le cache. Le mot est cherché avec la regex `(?<![\w.-])(…)(?![\w.-])`, donc `node_modules` et `nodejs.org` ne déclenchent rien.
- Si la version est vulnérable, le hook sort en 2 avec le message sur stderr, et la commande est refusée. `nvm` ne déclenche pas le hook, pour que l'utilisateur puisse réparer.
- Le hook est placé en PreToolUse plutôt qu'en Stop pour empêcher l'exécution du runtime vulnérable, au lieu de la signaler après coup.

### Cache (modes hook et CLI)
- Fichier : `$CLAUDE_PLUGIN_DATA/node-corriges.json`, sinon `~/.claude/plugins/data/kit-perso/node-corriges.json`. Si le `realpath` du dossier n'est pas sous `~/.claude/plugins/`, le cache est désactivé : ce dossier est déjà protégé en écriture par garde-deps (`PROTEGES`), donc l'agent ne peut pas forger un cache.
- Format : `{"lu": <epoch du dernier index lu>, "essai": <epoch du dernier essai réseau>, "corriges": {"24": "24.22.1", …}}`. Un fichier illisible ou mal formé compte comme absent. L'écriture est atomique (fichier temporaire puis `os.replace`).
- Logique :
  1. Si `maintenant - lu < 6 h`, on utilise le cache.
  2. Sinon, si `maintenant - essai < 15 min`, on n'essaie pas le réseau : cache périmé s'il existe, sinon le cas « injoignable ».
  3. Sinon, on lit l'index. En cas de succès, on écrit `lu = essai = maintenant`. En cas d'échec, on écrit seulement `essai`, sans toucher `corriges` ni `lu`.
- Un cache périmé utilisé ajoute au message (blocage ou succès) « (index du AAAA-MM-JJ, nodejs.org injoignable) ».

### Gabarit CI généré (job `node` de `kit-perso-tests.yml`)
Ordre des étapes :
1. Checkout du projet (inchangé).
2. `actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0`, avec `node-version-file: .nvmrc`, `check-latest: true` et `package-manager-cache: false`. On désactive le cache pour éviter un cache partagé entre PR et `main` et garder un résultat déterministe.
3. Checkout du kit : `repository: stanixia-dev/kit-perso`, `ref: <SHA du kit>`, `path: .kit-perso`, `persist-credentials: false`.
4. `run: python3 .kit-perso/hooks/verifie-runtime.py --ci && rm -rf .kit-perso`. On supprime le dossier pour que le lint et les tests du projet ne voient pas les fichiers du kit (checkout forcément sous le workspace).
5. Installation, lint et tests (inchangés).

Le job reçoit aussi `env: npm_config_engine_strict: "true"`, qui impose `engines` à npm et pnpm même si l'utilisateur n'a pas copié `.npmrc`. Les jobs `rust` et `python` ne changent pas.

### Fichiers générés à côté des workflows (seulement avec le job `node`)
- `.nvmrc` est généré seulement si le projet n'en a pas. Son contenu est la première suite de chiffres de `engines.node` de `package.json` (`>=26` donne `26`, `^22.12.0` donne `22`). Sans `engines.node`, ou si `package.json` est illisible ou n'est pas du JSON, il vaut `lts/*` (alias accepté par nvm et setup-node), et un avis sur stderr conseille de fixer `engines.node`.
- `.npmrc` contenant `engine-strict=true\n` est généré seulement s'il est absent. S'il existe, le script ne le lit pas (il peut contenir un jeton) et affiche sur stderr « `.npmrc` existe : ajoute `engine-strict=true` si absent (la CI l'impose déjà) ».
- Commande imprimée : `cp -n "<sortie>/.nvmrc" .nvmrc` (et de même pour `.npmrc`), placé avant le `git add`. Les fichiers générés sont ajoutés après les workflows : `git add .github/workflows/kit-perso-deps.yml .github/workflows/kit-perso-tests.yml .nvmrc .npmrc`. `-n` protège un fichier créé entre la génération et la copie.
- Un fichier généré lors d'un passage précédent, mais qui existe maintenant dans le projet, est supprimé de la sortie, comme c'est déjà fait pour `kit-perso-tests.yml`.

## 4. Fichiers
- `hooks/verifie-runtime.py` — créer — script décrit en section 3.
- `hooks/hooks.json` — modifier — entrée PreToolUse Bash `verifie-runtime.py --hook pre`.
- `tests/test_runtime.sh` — créer — cas de la section 7.
- `tests/fixtures/node-index.json` — créer — mini-index (voir section 7).
- `tests/test_hooks.sh` — modifier — appelle `tests/test_runtime.sh`, sur le modèle des autres suites.
- `skills/ci-projet/genere-ci.py` — modifier — étapes `uses:` avant les `run`, `env` de job, SHA du kit transmis à `jobs_tests`, `.nvmrc` et `.npmrc`, commande imprimée.
- `skills/ci-projet/SKILL.md` — modifier — étape 2 : montrer aussi `.nvmrc` et `.npmrc` générés et l'avis sur `.npmrc`.
- `tests/test_ci_projet.sh` — modifier — compte des checkouts, épinglage de tous les `uses:`, cas de la section 7.
- `README.md` — modifier — « CI des projets » : paragraphe « Runtime Node ». Nouvelle sous-section « Contrôle du runtime » : modes, cache, fail-open/fail-closed, résidus de la section 2.
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — version 3.3.0 (fonctionnalité ; la précédente est 3.2.0).

## 5. Étapes
1. Écrire `verifie-runtime.py` : version, index, règle, modes CLI et `--ci`, sans cache. Vérification : cas « règle » et « CI » de la section 7.
2. Ajouter le cache et le mode `--hook pre`, avec le chemin rapide. Ajouter l'entrée dans `hooks.json`. Vérification : cas « hook » et « cache ».
3. Créer `test_runtime.sh` et la fixture, et l'appeler depuis `test_hooks.sh`.
4. `genere-ci.py` : faire accepter à `job()` des étapes `uses:` (blocs YAML) avant les `run` et un `env` de job. Le job `node` reçoit les étapes 2 à 4 du gabarit. Vérification : cas « ci-projet » d'épinglage et de contenu du job `node` (contrôles par `grep`, pas de dépendance YAML).
5. `genere-ci.py` : `.nvmrc`, `.npmrc`, avis, suppression des restes, commande imprimée. Vérification : cas « ci-projet ».
6. Mettre à jour `SKILL.md`, le README, le CHANGELOG (`## 3.3.0 — <date de livraison>`, une entrée qui cite #34), et passer `plugin.json` en 3.3.0. Clôture et archivage selon `agents/codeur.md`.

## 6. Critères d'acceptation
- [ ] Avec la fixture et un faux `node` : v24.22.0 et v26.12.0 donnent 2 avec un message qui cite la version corrigée ; v24.22.1, v24.23.0, v27.0.0 et v22.23.4 donnent 0.
- [ ] `--ci` avec l'index injoignable, ou sans `node` dans le `PATH`, donne 2. Le mode hook dans les mêmes cas donne 0 (avertissement `systemMessage` quand l'index est injoignable).
- [ ] Hook, commande `ls -la` ou `cat node_modules/x/package.json` : 0, et le faux `node` n'est pas lancé (pas de fichier témoin).
- [ ] Hook, `npm ci` avec un Node vulnérable : 2. Avec `nvm install 24` : 0.
- [ ] Cache frais écrit au premier appel, puis index absent : le blocage se fait quand même, sans essai réseau. Cache périmé (`lu` ancien) avec l'index absent : blocage, message « nodejs.org injoignable ». Cache mal formé : traité comme absent. `CLAUDE_PLUGIN_DATA` hors de `~/.claude/plugins/` : aucun fichier écrit.
- [ ] `kit-perso-tests.yml` : chaque ligne `uses:` est épinglée sur 40 hex suivis de ` # v`. Les checkouts ont tous `persist-credentials: false`. Le job `node` contient `node-version-file: .nvmrc`, `check-latest: true`, `package-manager-cache: false`, `npm_config_engine_strict`, et `run: python3 .kit-perso/hooks/verifie-runtime.py --ci && rm -rf .kit-perso` avant `npm`. Aucun `token:`, `secrets.` ni `${{` dans un `run`.
- [ ] `.nvmrc` : `{"engines":{"node":">=26"}}` donne `26`, `package.json` qui ne contient que « x » donne `lts/*` avec un avis. Un `.nvmrc` ou un `.npmrc` existant dans le projet n'est ni lu (`.npmrc`), ni généré, ni copié par la commande. Sans `package.json`, aucun des deux n'est généré.
- [ ] La commande imprimée contient `cp -n` pour chaque fichier généré, et `git add` liste les workflows puis ces fichiers.
- [ ] `git diff --stat main...HEAD -- .github/workflows` est vide ; README, CHANGELOG et 3.3.0 sont à jour.

## 7. Tests
Commande du projet :
```
bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py skills/ci-projet/*.py && claude plugin validate --strict .
```
- **Fixture** `tests/fixtures/node-index.json` : `v27.0.0` (security false), `v26.12.1` (true), `v26.12.0` (false), `v24.23.0` (false), `v24.22.1` (true), `v24.22.0` (false), `v22.23.4` (true). Les autres champs de l'index réel (`date`, `files`, `lts`) sont présents et ignorés.
- **Faux node** : `$TMP/bin/node` affiche `$VERSION_NODE` et crée `$TMP/temoin` ; `PATH="$TMP/bin:$PATH"`, `HOME=$TMP/home` et `CLAUDE_PLUGIN_DATA=$HOME/.claude/plugins/data/kit-perso`.
- **Règle et CI** : chaque version de la fixture en CLI et en `--ci`. `KIT_PERSO_NODE_INDEX=$TMP/absent` avec `--ci` donne 2. `PATH` sans node avec `--ci` donne 2.
- **Hook** : JSON `{"tool_input":{"command":…},"cwd":…}` sur stdin, avec les commandes `ls -la`, `cat node_modules/x/package.json`, `curl nodejs.org`, `npm ci`, `bash -c 'npx tsc'`, `nvm install 24`.
- **Cache** : écrit après un appel réussi ; fichier construit à la main avec un `lu` vieux de 7 h et un `essai` vieux de 1 h, index absent ; `essai` récent, sans tentative (fixture présente mais ignorée : le résultat suit le cache) ; JSON invalide ; `CLAUDE_PLUGIN_DATA=$TMP/ailleurs`.
- **ci-projet** (`test_ci_projet.sh`) : le compte `n_co` porte sur `uses: actions/checkout@`, plus une vérification d'épinglage de tous les `uses:`. Dépôt avec `package.json` qui déclare `engines` : la sortie contient `.nvmrc` = `26` et `.npmrc` = `engine-strict=true`. Dépôt avec `.nvmrc` et `.npmrc` commités : ni l'un ni l'autre dans la sortie ni dans la commande, plus l'avis `.npmrc`. Les tests existants restent verts.

## 8. Décisions
- **Q1 — Blocage local** : le hook bloque (faux positifs acceptés, y compris `grep node src/`). Sur la devbox, tant que Node est vulnérable, toute commande npm de l'agent est bloquée jusqu'à `nvm install 24`.
- **Q2 — Branches EOL** : hors périmètre ; ticket séparé à créer plus tard (lecture de `schedule.json`, date `end`).
- **Q3 — Rust** : hors de ce lot. Règle future, à noter seulement : avertir en local, bloquer en CI.
- **Q4 — `.nvmrc` sans `engines.node`** : `lts/*` avec un avis sur stderr.
- SHA de `actions/setup-node` v7.1.0 vérifié (`949feb2413d6458794dcd2491c4babbbce0c15c1`, commit).

## Lots
- [ ] L1 — contrôle du runtime et hook local (étapes 1-3)
  Fichiers : hooks/verifie-runtime.py, hooks/hooks.json, tests/test_runtime.sh, tests/fixtures/node-index.json, tests/test_hooks.sh
  Fait quand : cas règle, CI, hook et cache verts — `bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py`
- [ ] L2 — gabarit CI, .nvmrc/.npmrc, doc, 3.3.0, clôture (étapes 4-6)
  Fichiers : skills/ci-projet/genere-ci.py, skills/ci-projet/SKILL.md, tests/test_ci_projet.sh, README.md, CHANGELOG.md, .claude-plugin/plugin.json
  Fait quand : cas ci-projet verts, suite complète verte — `bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py skills/ci-projet/*.py && claude plugin validate --strict .`
