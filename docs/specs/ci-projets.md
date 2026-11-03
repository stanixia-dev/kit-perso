# CI des projets : modèle de workflow et détection de l'absence de CI

Statut : en cours
Tickets : #16, #17

## Objectif

Fournir aux projets le filet CI du kit (job `deps` fail-closed + job de tests par langage) via un skill `ci-projet` qui génère le workflow hors de la zone protégée ; l'utilisateur le copie et le commite lui-même. Faire signaler par `livrer` (avant le push) et par l'agent `specs` (au démarrage) un dépôt sans CI ou à checks non obligatoires, en distinguant « pas de CI configurée » de « CI configurée mais pas déclenchée ».

## Hors périmètre

- Affaiblir la protection de `**/.github/workflows/` (hooks, `permissions.deny`) : l'agent n'y écrit jamais.
- Créer ou modifier un ruleset (réglage du dépôt, étape manuelle de l'utilisateur).
- Mise à jour automatique des copies de scripts dans les projets ; détection des manifestes hors racine (monorepo).
- Détection de la protection de branche « classique » (seuls les rulesets sont lus).
- Toute modification de `.github/workflows/tests.yml` du kit.

## Conception

**Source des scripts dans un projet tiers : copie figée dans `.github/workflows/kit-perso/`.**
kit-perso est privé : un checkout du kit depuis un autre dépôt exigerait un jeton en secret dans un job `pull_request_target`. La copie évite tout secret, est protégée contre l'agent par les hooks existants (`**/.github/workflows/**`), apparaît dans le résumé CI (`sensibles()` liste `.github/workflows/`), et GitHub n'interprète que les `.yml`/`.yaml` à la racine de `workflows/` (sous-dossier ignoré). Fichiers copiés tels quels depuis `hooks/` : `verifie-manifestes.py`, `deps_communs.py`, `garde-secret.py` (s'importent entre eux par chemin relatif).

**Générateur** `skills/ci-projet/genere-ci.py` (Python stdlib, sans réseau) :
- `--depot <dir>` (défaut `.`), `--sans-tests`, `--sortie <dir>` (défaut `<git rev-parse --git-common-dir>/kit-perso/ci`, absolu). Dans `.git` : jamais suivi, ne salit pas `git status` (sinon `livrer` refuse).
- Refuse (exit 2, message) : hors dépôt git, `--sortie` dont un composant est `.github` ou sous l'arbre de travail hors `.git`.
- Vide puis écrit `<sortie>/kit-perso.yml` et `<sortie>/kit-perso/{3 scripts}` (copies octet à octet de `hooks/`, trouvés via `__file__/../../hooks`).
- Lit la version dans `.claude-plugin/plugin.json` du kit et l'écrit en 1re ligne : `# Généré par kit-perso <version> (/kit-perso:ci-projet) — ne pas éditer les scripts kit-perso/`.
- Détecte les manifestes à la racine de `--depot` et ajoute un job de tests par langage (aucun avec `--sans-tests`, ni sans manifeste : message sur stderr, exit 0).
- Imprime sur stdout la commande d'installation (voir Étape 3), chemins absolus.

**Modèle** `skills/ci-projet/modele-ci.yml` : workflow `name: kit-perso`, déclencheurs `pull_request`, `pull_request_target`, `push: branches: [main]`, `permissions: contents: read` ; ligne marqueur `# JOBS-TESTS` remplacée par les jobs. `actions/checkout` épinglé au même SHA que `.github/workflows/tests.yml` du kit (`3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`), toujours `persist-credentials: false`. Aucune référence à `secrets.`.

Job `deps` (repris du job `deps` du kit) :
- `if: github.event_name == 'pull_request_target'`, `ubuntu-24.04`, `timeout-minutes: 5`, `permissions: contents: read`.
- Checkout 1 : base (défaut de `pull_request_target` = `main` du projet) → les scripts exécutés sont ceux de `main`, la PR ne peut ni les altérer ni retirer le job.
- Checkout 2 : `ref: ${{ github.event.pull_request.head.sha }}`, `path: pr`, `fetch-depth: 0` ; le code de la PR n'est jamais exécuté, seulement lu par git.
- `run: python3 .github/workflows/kit-perso/verifie-manifestes.py --ci --depot pr --base "$BASE" --cible HEAD` avec `env: BASE: ${{ github.event.pull_request.base.sha }}` (SHA jamais interpolé dans `run`). `--ci` enchaîne `garde-secret.py --ci` ; tout échec (script absent, réseau, exception) = job rouge : fail-closed.

Jobs de tests (`if: github.event_name != 'pull_request_target'`, checkout simple, `contents: read`, pas de secret) :

| Détection (racine) | Job | Étapes `run` |
|---|---|---|
| `Cargo.toml` | `rust` | `rustup component add rustfmt clippy` ; `cargo fmt --all --check` ; `cargo clippy --all-targets <L> -- -D warnings` ; `cargo test <L>` (`<L>` = `--locked` si `Cargo.lock`) |
| `package.json` | `node` | install : `npm ci` (`package-lock.json`), `corepack pnpm install --frozen-lockfile` (`pnpm-lock.yaml`), `corepack yarn install --frozen-lockfile` (`yarn.lock`), sinon `npm install` ; puis `<pm> run --if-present lint` et `<pm> run --if-present test` |
| `pyproject.toml` ou `requirements*.txt` | `python` | `python3 -m venv .venv && . .venv/bin/activate` puis : `uv.lock` → `pip install uv && uv sync --locked && uv run pytest -q` ; `requirements.txt` → `pip install -r requirements.txt pytest && pytest -q` ; sinon `pip install -e . pytest && pytest -q` |

Ces jobs sont des emplacements par défaut : le skill demande à l'utilisateur de les relire avant de commiter.

**Détection de la CI** (texte commun à `livrer` et `specs`, commandes en lecture) :
1. `W` : `git ls-tree --name-only origin/main .github/workflows/` filtré sur `*.yml|*.yaml` (dans `livrer`, après `git fetch -q origin main`).
2. `D` : `git grep -q verifie-manifestes origin/main -- .github/workflows` (job `deps` du kit présent).
3. `R` : `gh api repos/{owner}/{repo}/rules/branches/main --jq '[.[] | select(.type == "required_status_checks")] | length'` ; échec → « inconnu ». GET : déjà admis par `garde-git` (`verifie_api` : lecture libre), aucune modification de la liste blanche.

Messages (préfixe `CI :`) : `W` vide et `R` = 0 → « ce dépôt n'a aucune CI : rien ne vérifiera la PR. Lance /kit-perso:ci-projet. » ; `W` sans `D` → « workflows présents sans le job deps du kit (/kit-perso:ci-projet --sans-tests) » ; `W` non vide et `R` = 0 → « checks non obligatoires sur main : Settings > Rules > Rulesets » ; `R` > 0 et `W` vide → « un ruleset exige des checks mais aucun workflow sur main : la PR restera bloquée » ; `R` inconnu → « rulesets illisibles (droits ou réseau) ». Annonce seulement, ne bloque pas.

## Fichiers

- `skills/ci-projet/SKILL.md` — créer — skill `/kit-perso:ci-projet [--sans-tests]`, `disable-model-invocation: true`.
- `skills/ci-projet/genere-ci.py` — créer — générateur décrit en Conception.
- `skills/ci-projet/modele-ci.yml` — créer — modèle du workflow.
- `tests/test_ci_projet.sh` — créer — tests hors réseau du générateur et des textes.
- `tests/test_hooks.sh` — modifier — appelle `tests/test_ci_projet.sh` (même motif que `test_secrets.sh`) ; cas admis `gh api repos/{owner}/{repo}/rules/branches/main --jq '…'`.
- `skills/livrer/SKILL.md` — modifier — étape de détection avant le push ; message final distinguant les deux cas.
- `agents/specs.md` — modifier — détection au démarrage, ligne `CI :` dans le rapport.
- `README.md` — modifier — section « CI des projets », nuance des lignes « CI rattrape », compte des skills.
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — 3.1.0 (MINEUR : ajout d'un skill, `livrer` ne bloque pas davantage).

## Étapes

1. Écrire `modele-ci.yml` et `genere-ci.py` selon la Conception.
2. Écrire `skills/ci-projet/SKILL.md` : (a) lancer `python3 "${CLAUDE_SKILL_DIR}/genere-ci.py" $ARGUMENTS` (ajouter `--sans-tests` si `origin/main` a déjà des workflows) ; (b) montrer à l'utilisateur les jobs générés à relire ; (c) lui donner la commande imprimée, à lancer **lui-même dans un terminal** ; (d) rappeler l'étape post-fusion. Interdit : écrire dans `.github/`, copier soi-même, `git push`.
3. Commande imprimée par le générateur (`<S>` = sortie absolue, `<v>` = version) :
   `git switch main && git pull --ff-only && mkdir -p .github/workflows && cp -r <S>/. .github/workflows/ && git add .github/workflows && git commit -m "Ajoute la CI kit-perso <v>" && git push origin main`
   Suivie de : « `deps` ne tourne qu'une fois ce workflow sur main. Ensuite : Settings > Rules > Rulesets > New branch ruleset, cible `main`, Require status checks : `deps` + jobs de tests générés. »
4. Écrire `tests/test_ci_projet.sh` et l'appeler depuis `tests/test_hooks.sh`.
5. `livrer` : insérer après l'étape 2 une étape « Contrôle de la CI » (Détection, messages ci-dessus, répétés dans le message final). Étape de suivi : si aucun check, `W` vide → « pas de CI configurée (/kit-perso:ci-projet) » ; sinon → « CI configurée mais pas déclenchée : vérifier `on:` du workflow, Actions activées (Settings > Actions), workflow présent sur main ».
6. `agents/specs.md` : avant d'écrire, faire la Détection (sans `fetch`, Bash en lecture seule ; `main` si `origin/main` absent) ; si un message s'applique, l'ajouter en ligne `CI : …` du rapport final (rapport toujours ≤ 10 lignes).
7. README : section « ## CI des projets » (skill, emplacement des copies et pourquoi, commande, ruleset post-fusion, détection) ; aux points « CI » des contrôles dépendances/secrets et au résiduel `cd x && git push`, préciser « dans un projet, seulement si le workflow kit-perso y est installé » ; intro et ligne Vérification : 3 skills, `/kit-perso:ci-projet`.
8. CHANGELOG 3.1.0 (#16, #17), `plugin.json` 3.1.0.

## Critères d'acceptation

- [ ] Dans un dépôt jetable avec `Cargo.toml` + `package.json` + `pyproject.toml`, le générateur produit `kit-perso.yml` avec les jobs `deps`, `rust`, `node`, `python` et les 3 scripts identiques (`cmp`) à `hooks/`.
- [ ] Sans manifeste ou avec `--sans-tests` : seul le job `deps`.
- [ ] `kit-perso.yml` : contient `pull_request_target`, `persist-credentials: false` à chaque checkout, le SHA épinglé du kit, ni `secrets.` ni `${{` dans une ligne `run:`.
- [ ] `--sortie` sous `.github/` ou dans l'arbre de travail : exit 2, rien écrit ; sortie par défaut : `git status --porcelain` reste vide.
- [ ] Les scripts copiés tournent seuls : `python3 <S>/kit-perso/verifie-manifestes.py --ci --depot <repo> --base <sha> --cible HEAD` sort 0 sur un dépôt jetable sans manifeste modifié ni secret, hors réseau.
- [ ] La commande imprimée contient `git push origin main` et le rappel Rulesets.
- [ ] `garde-git` admet `gh api repos/{owner}/{repo}/rules/branches/main --jq …` ; aucune modification de `hooks/garde-git.py`.
- [ ] `livrer` contient la détection avant `git push` et les deux messages « pas de CI configurée » / « CI configurée mais pas déclenchée » ; `specs.md` contient la détection et la ligne `CI :`.
- [ ] README, CHANGELOG et `plugin.json` en 3.1.0 ; `claude plugin validate --strict .` vert.

## Tests

- `bash tests/test_hooks.sh` (appelle `test_manifestes.sh`, `test_secrets.sh`, `test_ci_projet.sh`)
- `bash tests/test_ci_projet.sh`
- `claude plugin validate --strict .`
- Manuel (utilisateur) : `claude --plugin-dir .` dans un projet, `/kit-perso:ci-projet`, vérifier `${CLAUDE_SKILL_DIR}` résolu et la commande imprimée.

## Questions ouvertes

1. Source des scripts : copie figée dans `.github/workflows/kit-perso/` (recommandé, sans secret) ; alternatives : rendre kit-perso public et faire un checkout du kit à SHA figé (pas de copie), ou jeton en secret `pull_request_target` (déconseillé).
2. Quand aucune CI n'est détectée, `livrer` annonce et continue (recommandé) ou s'arrête et demande confirmation ?
3. La protection de branche classique (hors rulesets) n'est pas lue (`branches/main/protection` exige les droits admin) : un projet protégé ainsi verra « checks non obligatoires ». Acceptable ?

## Lots

- [ ] L1 — Modèle, générateur et skill ci-projet (étapes 1-4)
  Fichiers : `skills/ci-projet/SKILL.md`, `skills/ci-projet/genere-ci.py`, `skills/ci-projet/modele-ci.yml`, `tests/test_ci_projet.sh`, `tests/test_hooks.sh`
  Fait quand : génération, copies, refus de sortie et exécution hors réseau des scripts copiés testés — `bash tests/test_hooks.sh`
- [ ] L2 — Détection de la CI dans livrer et specs (étapes 5-6)
  Fichiers : `skills/livrer/SKILL.md`, `agents/specs.md`, `tests/test_hooks.sh`, `tests/test_ci_projet.sh`
  Fait quand : cas `gh api …/rules/branches/main` admis et textes vérifiés par grep — `bash tests/test_hooks.sh`
- [ ] L3 — Documentation et version 3.1.0 (étapes 7-8)
  Fichiers : `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`
  Fait quand : README et version à jour, plugin valide — `bash tests/test_hooks.sh && claude plugin validate --strict .`
