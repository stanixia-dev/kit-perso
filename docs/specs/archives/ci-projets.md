# CI des projets : modèle de workflow et détection de l'absence de CI

Statut : livrée
Tickets : #16, #17

## Objectif

Fournir aux projets le filet CI du kit (job `deps` fail-closed + job de tests par langage) via un skill `ci-projet` qui génère le workflow hors de la zone protégée ; l'utilisateur le copie et le commite lui-même. Faire signaler par `livrer` (avant le push) et par l'agent `specs` (au démarrage) un dépôt sans CI ou à checks non obligatoires, en distinguant « pas de CI configurée » de « CI configurée mais pas déclenchée ».

## Hors périmètre

- Affaiblir la protection de `**/.github/workflows/` (hooks, `permissions.deny`) : l'agent n'y écrit jamais.
- Modifier les réglages d'un dépôt (visibilité, rulesets, protection) : étapes manuelles de l'utilisateur.
- Mise à jour automatique du SHA du kit dans les projets ; détection des manifestes hors racine (monorepo).
- Toute modification de `.github/workflows/tests.yml` du kit et de `hooks/garde-git.py`.

## Conception

**Source des scripts : checkout de kit-perso (public) à un SHA figé.** Le job `deps` du projet fait un `actions/checkout` avec `repository: stanixia-dev/kit-perso`, `ref: <SHA complet de 40 hex>`, `path: kit`, `persist-credentials: false`, sans `token:` (dépôt public). Le code de la PR est extrait dans un dossier séparé (`pr`). Le SHA est écrit dans le workflow du projet, protégé contre l'agent : changer de version du kit reste un commit de l'utilisateur (relancer le skill, recopier). Si kit-perso redevient privé, le checkout échoue et le job `deps` est rouge (fail-closed) : les PR restent bloquées tant que le check est obligatoire.

**Préalable (utilisateur, une fois, avant L1)** : l'agent n'a pas le droit de changer la visibilité d'un dépôt.
1. Scanner tout l'historique publié, PR comprises, avec le scanner du kit (aucune dépendance), dans un dossier jetable :
   ```
   git clone -q https://github.com/stanixia-dev/kit-perso.git kp && cd kp
   git fetch -q origin '+refs/pull/*/head:refs/remotes/origin/pr/*'
   for r in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin); do
     python3 hooks/garde-secret.py --ci --base 4b825dc642cb6eb9a060e54bf8d69288fbee4904 --cible "$r" || echo "À TRAITER : $r"; done
   ```
   (`4b825dc…` = arbre vide : `garde-secret` lit alors tous les commits jusqu'à la cible.) Relire aussi tickets et PR (texte public).
2. Rien à traiter : `gh repo edit stanixia-dev/kit-perso --visibility public --accept-visibility-change-consequences`.

**Générateur** `skills/ci-projet/genere-ci.py` (Python stdlib) :
- `--depot <dir>` (défaut `.`), `--sans-tests`, `--ref <sha>`, `--sortie <fichier>` (défaut `<git rev-parse --git-common-dir>/kit-perso/kit-perso.yml`, absolu). Dans `.git` : jamais suivi, ne salit pas `git status` (sinon `livrer` refuse).
- SHA : `--ref` s'il est donné (tests), sinon `git ls-remote https://github.com/stanixia-dev/kit-perso.git refs/heads/main` (= `origin/main` du kit, sans jeton). Refuse (exit 2, rien écrit) : SHA absent ou pas 40 hex, hors dépôt git, `--sortie` sous un dossier `.github` ou dans l'arbre de travail hors `.git`.
- 1re ligne : `# Généré par kit-perso <version de .claude-plugin/plugin.json> (/kit-perso:ci-projet), kit figé à <sha>`.
- Ajoute un job de tests par manifeste détecté à la racine de `--depot` (aucun avec `--sans-tests` ni sans manifeste : message sur stderr, exit 0).
- Imprime sur stdout la commande d'installation (Étape 3), chemins absolus.

**Modèle** `skills/ci-projet/modele-ci.yml` : workflow `name: kit-perso`, déclencheurs `pull_request`, `pull_request_target`, `push: branches: [main]`, `permissions: contents: read` ; marqueurs `__SHA_KIT__` et `# JOBS-TESTS` remplacés par le générateur. `actions/checkout` épinglé au SHA de `.github/workflows/tests.yml` du kit (`3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`), `persist-credentials: false` partout, aucune référence à `secrets.`.

Job `deps` :
- `if: github.event_name == 'pull_request_target'`, `ubuntu-24.04`, `timeout-minutes: 5`, `permissions: contents: read`. Le workflow exécuté est celui de `main` : la PR ne peut ni changer le SHA ni retirer le job.
- Checkout 1 : kit à `__SHA_KIT__` dans `kit`. Checkout 2 : `ref: ${{ github.event.pull_request.head.sha }}`, `path: pr`, `fetch-depth: 0` ; le code de la PR n'est jamais exécuté, seulement lu par git (exceptions lues dans `main` du projet via `--base`).
- `run: python3 kit/hooks/verifie-manifestes.py --ci --depot pr --base "$BASE" --cible HEAD`, `env: BASE: ${{ github.event.pull_request.base.sha }}` (aucun `${{` dans un `run`). `--ci` enchaîne `garde-secret.py --ci` ; tout échec (checkout, réseau, exception) = job rouge.

Jobs de tests (`if: github.event_name != 'pull_request_target'`, checkout simple, `contents: read`, pas de secret) :

| Détection (racine) | Job | Étapes `run` |
|---|---|---|
| `Cargo.toml` | `rust` | `rustup component add rustfmt clippy` ; `cargo fmt --all --check` ; `cargo clippy --all-targets <L> -- -D warnings` ; `cargo test <L>` (`<L>` = `--locked` si `Cargo.lock`) |
| `package.json` | `node` | install : `npm ci` (`package-lock.json`), `corepack pnpm install --frozen-lockfile` (`pnpm-lock.yaml`), `corepack yarn install --frozen-lockfile` (`yarn.lock`), sinon `npm install` ; puis `<pm> run --if-present lint` et `<pm> run --if-present test` |
| `pyproject.toml` ou `requirements*.txt` | `python` | `python3 -m venv .venv && . .venv/bin/activate` puis : `uv.lock` → `pip install uv && uv sync --locked && uv run pytest -q` ; `requirements.txt` → `pip install -r requirements.txt pytest && pytest -q` ; sinon `pip install -e . pytest && pytest -q` |

Ce sont des emplacements par défaut : le skill demande à l'utilisateur de les relire avant de commiter.

**Détection de la CI** (texte commun à `livrer` et `specs`, lecture seule) :
1. `W` : `git ls-tree --name-only origin/main .github/workflows/` filtré sur `*.yml|*.yaml` (dans `livrer`, après `git fetch -q origin main`).
2. `D` : `git grep -q verifie-manifestes origin/main -- .github/workflows` (job `deps` du kit présent).
3. `R` (rulesets) : `gh api repos/{owner}/{repo}/rules/branches/main --jq '[.[] | select(.type == "required_status_checks")] | length'` ; échec → inconnu.
4. `P` (protection classique) : `gh api repos/{owner}/{repo}/branches/main/protection --jq '.required_status_checks.checks | length'` ; échec avec `HTTP 404` sur stderr → 0 (pas de protection) ; autre échec → inconnu.
   Vérifié : `garde-git` admet ces deux GET (exit 0) et refuse `gh api -X PUT …/branches/main/protection` (exit 2). Pas d'ajout à la liste blanche. Piège : un `//` dans `--jq` fait refuser la commande (« un seul endpoint relatif ») ; ne pas en écrire.
   « Checks exigés » = `R` > 0 ou `P` > 0.

Messages (préfixe `CI :`) : `W` vide et aucun check exigé → « ce dépôt n'a aucune CI : rien ne vérifiera la PR. Lance /kit-perso:ci-projet. » ; `W` sans `D` → « workflows présents sans le job deps du kit (/kit-perso:ci-projet --sans-tests) » ; `W` non vide sans check exigé → « checks non obligatoires sur main : Settings > Rules > Rulesets » ; check exigé et `W` vide → « des checks sont exigés mais aucun workflow sur main : la PR restera bloquée » ; `R` ou `P` inconnu → « règles de main illisibles (droits ou réseau) ». `livrer` annonce clairement puis continue, sans demander.

## Fichiers

- `skills/ci-projet/SKILL.md` — créer — skill `/kit-perso:ci-projet [--sans-tests]`, `disable-model-invocation: true`.
- `skills/ci-projet/genere-ci.py` — créer — générateur.
- `skills/ci-projet/modele-ci.yml` — créer — modèle du workflow.
- `tests/test_ci_projet.sh` — créer — tests hors réseau du générateur et des textes.
- `tests/test_hooks.sh` — modifier — appelle `tests/test_ci_projet.sh` (même motif que `test_secrets.sh`) ; cas admis : les deux GET de la Détection ; cas refusé : `gh api -X PUT repos/o/r/branches/main/protection`.
- `skills/livrer/SKILL.md` — modifier — détection avant le push ; message final distinguant les deux cas.
- `agents/specs.md` — modifier — détection au démarrage, ligne `CI :` dans le rapport.
- `README.md` — modifier — section « CI des projets » (préalable public compris), nuance des lignes « CI rattrape », compte des skills.
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — 3.1.0 (MINEUR : ajout d'un skill, `livrer` ne bloque pas davantage).

## Étapes

1. Écrire `modele-ci.yml` et `genere-ci.py` selon la Conception.
2. Écrire `skills/ci-projet/SKILL.md` : (a) lancer `python3 "${CLAUDE_SKILL_DIR}/genere-ci.py" $ARGUMENTS` (ajouter `--sans-tests` si `origin/main` a déjà des workflows) ; échec du `ls-remote` → dire que kit-perso doit être public et joignable, s'arrêter ; (b) montrer les jobs générés à relire ; (c) donner la commande imprimée, à lancer **par l'utilisateur dans un terminal** ; (d) rappeler l'étape post-fusion. Interdit : écrire dans `.github/`, copier soi-même, `git push`.
3. Commande imprimée (`<S>` = sortie absolue, `<v>` = version, `<court>` = 12 premiers hex du SHA) :
   `git switch main && git pull --ff-only && mkdir -p .github/workflows && cp <S> .github/workflows/kit-perso.yml && git add .github/workflows/kit-perso.yml && git commit -m "Ajoute la CI kit-perso <v> (<court>)" && git push origin main`
   Suivie de : « `deps` ne tourne qu'une fois ce workflow sur main. Ensuite : Settings > Rules > Rulesets > New branch ruleset, cible `main`, Require status checks : `deps` + jobs de tests générés. Mise à jour du kit : relancer /kit-perso:ci-projet et recopier. »
4. Écrire `tests/test_ci_projet.sh` et l'appeler depuis `tests/test_hooks.sh`.
5. `livrer` : insérer après l'étape 2 une étape « Contrôle de la CI » (Détection et messages, répétés dans le message final). Étape de suivi : si aucun check, `W` vide → « pas de CI configurée (/kit-perso:ci-projet) » ; sinon → « CI configurée mais pas déclenchée : vérifier `on:` du workflow, Actions activées (Settings > Actions), workflow présent sur main ».
6. `agents/specs.md` : avant d'écrire, faire la Détection (sans `fetch` ; `main` si `origin/main` absent) ; si un message s'applique, l'ajouter en ligne `CI : …` du rapport final (toujours ≤ 10 lignes).
7. README : section « ## CI des projets » (préalable et commandes de la Conception, skill, SHA figé et mise à jour, comportement si le kit redevient privé, commande d'installation, ruleset post-fusion, détection) ; aux points « CI » des contrôles dépendances/secrets et au résiduel `cd x && git push`, préciser « dans un projet, seulement si le workflow kit-perso y est installé » ; intro et ligne Vérification : 3 skills, `/kit-perso:ci-projet`.
8. CHANGELOG 3.1.0 (#16, #17), `plugin.json` 3.1.0.

## Critères d'acceptation

- [x] Dans un dépôt jetable avec `Cargo.toml` + `package.json` + `pyproject.toml` et `--ref <40 hex>`, le générateur produit `kit-perso.yml` avec les jobs `deps`, `rust`, `node`, `python` et ce SHA en `ref:` du checkout `repository: stanixia-dev/kit-perso`.
- [x] Sans manifeste ou avec `--sans-tests` : seul le job `deps`.
- [x] `kit-perso.yml` : `pull_request_target`, `persist-credentials: false` à chaque checkout, checkout de `actions/checkout` épinglé, chemins `kit` et `pr` distincts, ni `secrets.`, ni `token:`, ni `${{` dans une ligne `run:`.
- [x] `--ref` invalide, `--sortie` sous `.github/` ou dans l'arbre de travail : exit 2, rien écrit ; sortie par défaut : `git status --porcelain` reste vide.
- [x] La ligne `run` du job `deps`, lancée hors réseau dans un dossier où `kit` pointe sur le dépôt du kit et `pr` sur un dépôt jetable sans manifeste modifié ni secret, sort 0.
- [x] La commande imprimée contient `git push origin main`, le rappel Rulesets et la mise à jour du kit.
- [x] `garde-git` admet les GET `…/rules/branches/main` et `…/branches/main/protection` avec leurs `--jq`, refuse le PUT ; `hooks/garde-git.py` inchangé.
- [x] `livrer` contient la détection avant `git push` (rulesets et protection classique) et les deux messages « pas de CI configurée » / « CI configurée mais pas déclenchée » ; `specs.md` contient la détection et la ligne `CI :`.
- [x] README (préalable public compris), CHANGELOG et `plugin.json` en 3.1.0 ; `claude plugin validate --strict .` vert.

## Tests

- `bash tests/test_hooks.sh` (appelle `test_manifestes.sh`, `test_secrets.sh`, `test_ci_projet.sh`)
- `bash tests/test_ci_projet.sh`
- `claude plugin validate --strict .`
- Manuel (utilisateur, après le préalable) : `claude --plugin-dir .` dans un projet, `/kit-perso:ci-projet`, vérifier `${CLAUDE_SKILL_DIR}` résolu, le SHA inséré et la commande imprimée.

## Questions ouvertes

Aucune.

## Lots

- [x] L1 — Modèle, générateur et skill ci-projet (étapes 1-4)
  Fichiers : `skills/ci-projet/SKILL.md`, `skills/ci-projet/genere-ci.py`, `skills/ci-projet/modele-ci.yml`, `tests/test_ci_projet.sh`, `tests/test_hooks.sh`
  Fait quand : génération, SHA, refus et ligne `run` du job deps testés hors réseau — `bash tests/test_hooks.sh`
- [x] L2 — Détection de la CI dans livrer et specs (étapes 5-6)
  Fichiers : `skills/livrer/SKILL.md`, `agents/specs.md`, `tests/test_hooks.sh`, `tests/test_ci_projet.sh`
  Fait quand : GET rulesets/protection admis, PUT refusé, textes vérifiés par grep — `bash tests/test_hooks.sh`
- [x] L3 — Documentation et version 3.1.0 (étapes 7-8)
  Fichiers : `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`, `.gitignore`
  Fait quand : README et version à jour, plugin valide — `bash tests/test_hooks.sh && claude plugin validate --strict .`
