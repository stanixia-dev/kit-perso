# Spec — garde-deps
Statut : en cours

## 1. Objectif
Version 0.3.0 de kit-perso. Un hook `garde-deps` bloque l'ajout d'un paquet (cargo, npm/pnpm/yarn, pip/uv) dont la licence n'est pas permissive, qui a une faille OSV connue, qui est déprécié ou yanked, ou dont la dernière version a plus de 2 ans. Le relecteur applique les mêmes règles aux manifestes du diff ; une CI GitHub minimale lance `tests/test_hooks.sh`, et `livrer` la suit.

## 2. Hors périmètre
- `hooks/garde-git.py`, `hooks/rappel-clear.py`, les agents autres que `relecteur.md` et `.claude-plugin/marketplace.json` (il n'a pas de champ version) ne changent pas.
- Aucune dépendance (Python standard seulement), pas de cache, pas de liste d'exceptions : un paquet refusé, c'est l'utilisateur qui l'ajoute lui-même.
- Pas d'analyse des dépendances transitives ni des lockfiles ; pas de `bun`, `npx`, `pipx`, `go`, `gem`.
- La CI ne lance pas `claude plugin validate` (CLI absente du runner). Seul workflow touché : `.github/workflows/tests.yml`, autorisé explicitement par l'utilisateur.

## 3. Fichiers
- `hooks/garde-deps.py` — créer — hook PreToolUse (L1).
- `hooks/hooks.json` — modifier — 2e entrée `PreToolUse` (L1).
- `tests/fixtures/garde-deps.json` — créer — réponses simulées des registres et d'OSV (L2).
- `tests/test_hooks.sh` — modifier — cas garde-deps (L2).
- `agents/relecteur.md` — modifier — puce « Dépendances » (L3).
- `.github/workflows/tests.yml` — créer — CI (L4).
- `skills/livrer/SKILL.md` — modifier — suivi de la CI (L4).
- `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — doc, entrée et version 0.3.0 (L5).

## 4. Étapes
1. (L1) `hooks/garde-deps.py` : Python ≥ 3.10 (runner CI en 3.12 : pas de `datetime.UTC`, utiliser `timezone.utc`), style et docstring de `garde-git.py`. Lit le JSON de stdin, prend `tool_input.command`. Recopie `segments()` de `garde-git.py` (import impossible proprement à cause du tiret, et garde-git ne change pas) ; analyse aussi la commande passée à `bash|sh|zsh -c`.
2. (L1) Commandes détectées (le reste est ignoré) : `cargo add` (commande entière ignorée si `--git` ou `--path`) ; `npm install|i|add`, `pnpm add`, `yarn add` ; `pip|pip3 install`, `python|python3 -m pip install`, `uv pip install`, `uv add`. Les jetons `-…` sont sautés ; ceux-ci sautent aussi le jeton suivant : cargo `-F --features -p --package --rename --registry --manifest-path --target` ; npm `--registry --prefix -w --workspace --omit --tag` ; pip/uv `-r --requirement -e --editable -c --constraint -i --index-url --extra-index-url -f --find-links -t --target --prefix --group --optional --extra --index --default-index --package`. Ne sont pas des paquets : chemins (`.`, `./`, `../`, `/`, `~`), `file:`, `git+`, `github:`, tout ce qui contient `://`, `nom/depot` sans `@` initial (raccourci GitHub npm), fichiers `.tgz .whl .tar.gz .zip`. Aucun paquet → `exit 0` immédiat, sans réseau (le hook tourne sur chaque commande Bash).
3. (L1) Nom et version visée. npm : `nom` ou `@scope/nom`, puis `@spec` facultatif ; cargo : `nom@spec` ; pip/uv : PEP 508 `nom[extras]<op>spec[;marqueur]`, nom normalisé (minuscules, `[._]+` → `-`). Version exacte : npm/cargo si spec (sans `=` initial) matche `^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$` ; pip/uv si opérateur `==`/`===` sans `*`. Sinon (absente, plage, `^`, `~`, tag) : dernière version du registre.
4. (L1) `recupere(cle, url, corps=None)` : `urllib.request`, en-tête `User-Agent: kit-perso-garde-deps (https://github.com/stanixia-dev/kit-perso)` (exigé par crates.io), délai 4 s par requête, budget total 20 s (`time.monotonic`) au-delà duquel les requêtes restantes sont injoignables. Si `GARDE_DEPS_FIXTURES` est défini : aucune requête, on lit ce fichier JSON `{clé: réponse}` ; clé absente ou fichier illisible = injoignable. Clés : `<registre>-<nom>` et `osv-<registre>-<nom>`, registre ∈ `crates npm pypi`, `/` du nom remplacé par `__`. Toute erreur (HTTP, délai, JSON) = injoignable.
5. (L1) Registres (une requête par paquet) :
   - crates : `https://crates.io/api/v1/crates/<nom>` ; dernière = `crate.max_stable_version` ou `crate.newest_version` ; dans `versions[]` (clé `num`) : `license`, `yanked` ; date = max des `created_at`.
   - npm : `https://registry.npmjs.org/<nom>` (`/` encodé `%2F`) ; dernière = `dist-tags.latest` ; `versions[v].license` (chaîne, `{type}` ou ancien `licenses[0].type`), `versions[v].deprecated` ; date = max de `time[*]` hors `created`/`modified`.
   - pypi : `https://pypi.org/pypi/<nom>/json` ; dernière = `info.version` ; licence de la dernière version (une seule requête : approximation acceptée) = `info.license_expression`, sinon classifiers `License :: …` (plusieurs → reliés par `OR`), sinon `info.license` s'il fait ≤ 40 caractères ; yanked = tous les fichiers de `releases[v]` ont `yanked` vrai ; déprécié = classifier `Development Status :: 7 - Inactive` ; date = max des `upload_time_iso_8601`.
   Version exacte absente du registre → bloque (« version inconnue du registre »).
6. (L1) OSV : POST `https://api.osv.dev/v1/query`, corps `{"package": {"name": nom, "ecosystem": "crates.io"|"npm"|"PyPI"}, "version": v}`. Chaque entrée de `vulns` bloque (cite au plus 3 `id`), sauf si elle a `database_specific.informational` (avis RustSec « unmaintained ») : avertissement.
7. (L1) Licences, comparées sans casse ; `/` (ancien crates) = `OR`, suffixe `+` retiré, `X WITH exception` = `X`. Niveau 0 (ok) : MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, Zlib, 0BSD, Unlicense. Niveau 1 (avertit) : MPL-2.0, LGPL-*. Niveau 2 (bloque) : tout le reste, dont GPL, AGPL, licence absente, non reconnue, `UNLICENSED` npm (≠ Unlicense). Expression avec parenthèses par petit analyseur récursif : `OR` = minimum des branches (on choisit la plus permissive), `AND` = maximum. Classifiers : `MIT License`→MIT, `Apache Software License`→Apache-2.0, `BSD License`→BSD-3-Clause, `ISC License (ISCL)`→ISC, `zlib/libpng License`→Zlib, `The Unlicense (Unlicense)`→Unlicense, `Mozilla Public License 2.0 (MPL 2.0)`→MPL-2.0, contenant `Lesser General Public License`→LGPL-3.0, autres → non reconnue. Alias de `info.license` : `Apache 2.0`, `Apache License 2.0`, `Apache-2` → Apache-2.0 ; `BSD` → BSD-3-Clause.
8. (L1) Bloque aussi : déprécié (npm `deprecated` non vide, pypi Inactive), version visée yanked, date de dernière publication antérieure de plus de 730 jours à aujourd'hui (UTC ; `GARDE_DEPS_AUJOURDHUI=AAAA-MM-JJ` fixe la date pour les tests).
9. (L1) Sortie, après examen de tous les paquets. Au moins un blocage → stderr `⛔ Bloqué par garde-deps :`, une ligne `- <registre> <nom>@<version> : <raison>` par problème, puis `Propose une alternative, ou demande à l'utilisateur d'ajouter lui-même ce paquet s'il l'accepte.` ; `exit 2`. Sinon, s'il y a des avertissements (MPL/LGPL, avis informatif, injoignable → `vérification impossible`) : stdout JSON au format de `rappel-clear.py`, `{"systemMessage": "⚠ garde-deps : …", "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "…"}}`, `exit 0`. Sinon `exit 0` muet. Exception imprévue → `exit 0` (fail-open, comme un registre injoignable).
10. (L1) `hooks/hooks.json` : dans `PreToolUse`, après garde-git, ajoute `{"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/garde-deps.py\"", "timeout": 30}]}`, sans `onFailure` : un hook en échec ne doit pas bloquer.
11. (L2) `tests/fixtures/garde-deps.json` : réponses réduites aux champs lus ; dates récentes 2026-06-01, anciennes 2020-01-01 ; OSV sans faille = `{}`. `tests/test_hooks.sh` : helpers `code_deps`, `sortie_deps` (stdout), `erreur_deps` (stderr) sur le modèle de `code_garde`, préfixés par `GARDE_DEPS_FIXTURES=tests/fixtures/garde-deps.json GARDE_DEPS_AUJOURDHUI=2026-10-29` ; libellés commençant par `garde-deps`. Une assertion par ligne (commande → attendu) :
   - `cargo add bon` (MIT OR Apache-2.0) ; `pnpm add @scope/ok@1.0.0` (ISC) ; `cargo add mixte` (`(GPL-3.0 OR MIT) AND Apache-2.0`) → 0, stdout vide.
   - `npm install gpl-pkg` (GPL-3.0-only) ; `npm i sanslicence` (pas de licence) ; `yarn add prive` (UNLICENSED) ; `npm add deprecie` ; `cargo add colle` (`MIT AND GPL-2.0`) ; `cargo add retire@0.1.0` (yanked) ; `pip install vieux` (dernier upload 2020) → 2.
   - `cargo add faille@1.2.3` (OSV `RUSTSEC-2099-0001`) → 2 et stderr contient `RUSTSEC-2099-0001`.
   - `uv add mpl` (classifier MPL 2.0) → 0 et stdout contient `MPL-2.0` ; `pip3 install inconnu` (aucune clé) → 0 et stdout contient `vérification impossible`.
   - `ls && npm i gpl-pkg` ; `bash -c 'npm i gpl-pkg'` → 2.
   - `npm install` ; `pip install -r requirements.txt` ; `pip install -e .` ; `npm i ./local` ; `cargo add --path ../x` → 0, stdout vide.
12. (L3) `agents/relecteur.md` : avant la puce « Clôture : … », insère telle quelle la puce :
    « - Dépendances : si le diff touche `Cargo.toml`, `package.json`, `pyproject.toml` ou `requirements*.txt`, liste les dépendances ajoutées ou dont la version change (`git diff main...HEAD -- <manifeste>`) et vérifie chacune avec le hook du plugin : `printf '{"tool_input":{"command":"%s"}}' '<commande>' | python3 "$G"`, où `G=$(ls ~/.claude/plugins/cache/kit-perso/kit-perso/*/hooks/garde-deps.py 2>/dev/null | sort -V | tail -1)` (dans le dépôt kit-perso : `hooks/garde-deps.py`) et `<commande>` vaut `cargo add <nom>@<version>`, `npm install <nom>@<version>` (version sans `^ ~ =`) ou `pip install <nom>==<version>` (nom seul si la version n'est pas épinglée par `==`). Code 2 : bloquant, raison sur stderr. Avertissement sur stdout : mineur. Hook introuvable ou `vérification impossible` : mineur « dépendance non vérifiée ». Règles : licence permissive (MIT, Apache-2.0, BSD-2/3-Clause, ISC, Zlib, 0BSD, Unlicense ; MPL-2.0 et LGPL tolérées), aucune faille OSV, ni dépréciée ni yanked, dernière version de moins de 2 ans. »
13. (L4) `.github/workflows/tests.yml` (SHA de la dernière release : `T=$(gh api repos/actions/checkout/releases/latest --jq .tag_name)` puis `gh api repos/actions/checkout/commits/$T --jq .sha`) :
    ```yaml
    name: tests
    on:
      pull_request:
      push:
        branches: [main]
    permissions:
      contents: read
    jobs:
      hooks:
        runs-on: ubuntu-24.04
        timeout-minutes: 5
        steps:
          - uses: actions/checkout@<SHA de 40 caractères> # <tag>
            with:
              persist-credentials: false
          - run: bash tests/test_hooks.sh
    ```
14. (L4) `skills/livrer/SKILL.md` : après l'étape 4, insère l'étape « 5. Suis la CI : `gh pr checks --watch --interval 20` (délai Bash de 10 min). Si gh ne signale aucun check, relance une fois après quelques secondes ; sinon, dis que la CI ne s'est pas déclenchée. Si elle est rouge, donne le check en échec et les 30 dernières lignes de `gh run view <id> --log-failed` (id via `gh run list --branch <branche> -L 1`), sans corriger : l'utilisateur décide. » ; l'ancienne étape 5 devient 6 et commence par « Termine par l'état de la CI, le lien de la PR… ».
15. (L5) `README.md` : intro « hooks (garde-git, garde-deps, rappel-clear) » ; vérification « 3 hooks » ; après « Ajouter un élément », section `## Contrôle des dépendances` (≤ 6 lignes : ce qui bloque, ce qui avertit, fail-open hors réseau, ajout manuel par l'utilisateur, contrôle du relecteur) ; ligne Tests : « hors réseau (réponses simulées dans `tests/fixtures/garde-deps.json`) ; la CI GitHub les lance sur chaque PR et push sur `main`. »
16. (L5) `CHANGELOG.md` : au-dessus de 0.2.0, `## 0.3.0 — <date du jour>` avec 3 puces (hook garde-deps ; contrôle des dépendances par le relecteur ; CI `tests.yml` suivie par `livrer`). `.claude-plugin/plugin.json` : `"version": "0.3.0"`.
17. (L5) Clôture selon `agents/codeur.md` (critères cochés, `Statut : livrée`, `git mv` vers `docs/specs/archives/garde-deps.md`) dans le commit de L5.

## 5. Critères d'acceptation
- [ ] Les trois sorties (blocage sur stderr + `exit 2`, avertissement JSON + `exit 0`, silence) suivent l'étape 9 ; aucune requête réseau si la commande n'ajoute aucun paquet ou si `GARDE_DEPS_FIXTURES` est défini.
- [ ] Les 6 causes de blocage (licence, faille, déprécié, yanked, > 2 ans, version inconnue) et le fail-open (injoignable, exception) sont implémentés.
- [ ] `hooks/hooks.json` déclare garde-deps sans `onFailure` ; `garde-git.py` et `rappel-clear.py` sont inchangés (`git diff --stat main...HEAD`).
- [ ] `tests/test_hooks.sh` contient au moins 19 assertions garde-deps, toutes vertes, sans réseau.
- [ ] `agents/relecteur.md` contient la puce « Dépendances » de l'étape 12.
- [ ] `tests.yml` épingle `actions/checkout` par SHA, `permissions: contents: read` ; `livrer` suit la CI et signale un échec.
- [ ] README, CHANGELOG `## 0.3.0` et `plugin.json` `0.3.0` à jour ; `claude plugin validate --strict .` vert.
- [ ] 5 commits suffixés `(L1)` à `(L5)` ; spec archivée et livrée.

## 6. Tests
```
bash tests/test_hooks.sh && claude plugin validate --strict .
test "$(bash tests/test_hooks.sh | grep -c '^OK    garde-deps')" -ge 19
git diff --stat main...HEAD && git log --oneline main..HEAD
test ! -e docs/specs/garde-deps.md && grep -q '^Statut : livrée$' docs/specs/archives/garde-deps.md && ! grep -q '^- \[ \]' docs/specs/archives/garde-deps.md
```

## 7. Questions ouvertes
1. `OR` = branche la plus permissive : `MIT OR GPL-3.0` passe (sinon, exiger que toutes les licences soient dans la liste). Recommandé : garder.
2. Pas de contournement : un paquet refusé, c'est l'utilisateur qui l'ajoute à la main. Recommandé : garder (sinon Claude pourrait se l'autoriser).
3. Version : le README classe « hook qui bloque davantage » en MAJEUR ; 0.3.0 reste conforme au semver tant qu'on est en 0.x. Recommandé : 0.3.0.
4. Pousser `.github/workflows/` exige la portée `workflow` du jeton gh ; si le push est refusé : `gh auth refresh -s workflow` (c'est l'utilisateur qui le lance).
5. À vérifier à l'usage : est-ce que Claude reçoit bien `additionalContext` en PreToolUse ? Sinon, `systemMessage` informe quand même l'utilisateur. Pour PyPI, la licence lue est celle de la dernière version, et les avis RustSec « unmaintained » ne font qu'avertir.

## Lots
- [x] L1 — Hook garde-deps et déclaration (étapes 1-10)
  Fichiers : hooks/garde-deps.py, hooks/hooks.json
  Fait quand : silencieux hors ajout, fail-open sans réseau — `python3 -m py_compile hooks/garde-deps.py && [ -z "$(printf '{"tool_input":{"command":"ls"}}' | python3 hooks/garde-deps.py)" ] && printf '{"tool_input":{"command":"cargo add serde"}}' | GARDE_DEPS_FIXTURES=/dev/null python3 hooks/garde-deps.py | grep -q 'vérification impossible' && grep -q 'garde-deps.py' hooks/hooks.json && claude plugin validate --strict . && bash tests/test_hooks.sh`
- [x] L2 — Tests hors réseau par fixtures (étape 11)
  Fichiers : tests/test_hooks.sh, tests/fixtures/garde-deps.json
  Fait quand : 19 assertions vertes — `test "$(bash tests/test_hooks.sh | grep -c '^OK    garde-deps')" -ge 19 && bash tests/test_hooks.sh`
- [x] L3 — Contrôle des dépendances par le relecteur (étape 12)
  Fichiers : agents/relecteur.md
  Fait quand : la puce est présente — `grep -q '^- Dépendances :' agents/relecteur.md && grep -q 'requirements\*.txt' agents/relecteur.md && claude plugin validate --strict . && bash tests/test_hooks.sh`
- [x] L4 — CI et suivi dans livrer (étapes 13-14)
  Fichiers : .github/workflows/tests.yml, skills/livrer/SKILL.md
  Fait quand : action épinglée, suivi présent — `grep -Eq 'uses: actions/checkout@[0-9a-f]{40} # ' .github/workflows/tests.yml && grep -q 'bash tests/test_hooks.sh' .github/workflows/tests.yml && grep -q 'gh pr checks --watch' skills/livrer/SKILL.md && claude plugin validate --strict . && bash tests/test_hooks.sh`
- [ ] L5 — Doc, 0.3.0, clôture et archivage (étapes 15-17)
  Fichiers : README.md, CHANGELOG.md, .claude-plugin/plugin.json
  Fait quand : doc et version à jour — `grep -q '^## Contrôle des dépendances' README.md && grep -q '3 hooks' README.md && grep -q '^## 0.3.0' CHANGELOG.md && grep -q '"version": "0.3.0"' .claude-plugin/plugin.json && claude plugin validate --strict . && bash tests/test_hooks.sh`
