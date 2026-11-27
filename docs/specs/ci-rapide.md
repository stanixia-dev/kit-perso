# CI rapide générée par ci-projet

Statut : en cours
Tickets : #47

## Objectif

Raccourcir la CI générée par `/kit-perso:ci-projet` : cache Cargo et npm, jobs de tests sautés quand la PR ne touche pas leurs chemins, annulation des exécutions obsolètes d'une même branche. Un job `resume` toujours présent sert de check exigé stable. Le README documente l'ajout d'un 2e runner auto-hébergé. Le job `deps` suit lui aussi la ligne `runs-on` de `.kit-perso-ci` (lot L5).

## Hors périmètre

- Workflows du kit lui-même (`.github/workflows/` de kit-perso).
- `deps` : ni `concurrency` ni cache ; contenu de `modele-deps.yml` inchangé hors la ligne `runs-on`.
- Avec `--sans-tests` (ou sans manifeste), `.kit-perso-ci` n'est toujours pas lu : `deps` reste sur `ubuntu-24.04` (voir Questions ouvertes).
- Cache pnpm, yarn et Python ; cache de `node_modules`.
- Liste de chemins « ignorés » (ex. docs seules) : une PR qui ne touche que la doc lance tous les jobs.
- Nettoyage automatique du répertoire persistant (documenté seulement).
- Filtre par défaut déduit des manifestes : sans déclaration, aucun filtre (comportement actuel).

## Conception

**Configuration déclarée** : `.kit-perso-ci` à la racine du projet, lue par `genere-ci.py` à la génération seulement (jamais en CI), et seulement si au moins un job de tests est généré (donc jamais avec `--sans-tests`). On choisit une déclaration plutôt qu'une détection : un filtre déduit (extensions, workspaces) peut sauter un job concerné (fichier inclus par `include_str!`, `tsconfig` racine…) et donner un vert à tort.
```
# commentaire ; lignes vides permises
runs-on self-hosted linux x64 homelab
chemins rust crates/** Cargo.toml Cargo.lock
chemins node ui/** package.json package-lock.json
```
- `runs-on <label>…` : au plus une ligne, labels `[A-Za-z0-9._-]+`. Un label : `runs-on: <label>` ; plusieurs : `runs-on: [a, b]`. Défaut `ubuntu-24.04`. S'applique à tous les jobs de `kit-perso-tests.yml` et, depuis L5, au job `deps` de `kit-perso-deps.yml`.
- `chemins <job> <motif>…` : `<job>` parmi les jobs générés (`rust`, `node`, `python`), une ligne par job au plus, au moins un motif. Motif `[A-Za-z0-9._/*?-]+`, sans `/` initial, comparé par `fnmatch.fnmatchcase` (`*` traverse les `/` : `crates/**` vaut `crates/*`).
- Refus (sortie 2, rien d'écrit, message `genere-ci : .kit-perso-ci ligne N : …`) : directive inconnue, `runs-on` en double ou vide, label ou motif invalide, `chemins` sans motif, job non généré ou en double.
- stderr résume : runs-on, mode de cache (`actions/cache` ou `répertoire persistant`), filtres par job ou « aucun filtre ».

**Mode de cache** = « auto-hébergé » si le label `self-hosted` figure dans `runs-on`, sinon « hébergé ».
- Hébergé : `actions/cache` épinglé par SHA (`# vX.Y.Z`), après le checkout du projet.
  - rust, avant `rustup` : `path` = `~/.cargo/registry/index`, `~/.cargo/registry/cache`, `~/.cargo/git/db`, `target` ; `key: cargo-${{ runner.os }}-${{ hashFiles('Cargo.lock') }}` ; `restore-keys: cargo-${{ runner.os }}-`.
  - node, seulement avec `package-lock.json`, entre `verifie-runtime` et `npm ci` : `path: ~/.npm`, `key: npm-${{ runner.os }}-${{ hashFiles('package-lock.json') }}`, `restore-keys: npm-${{ runner.os }}-`. `package-manager-cache: false` reste sur setup-node (un seul mécanisme, clé explicite).
  - Pourquoi on revient sur « pas de cache » (spec node-runtime) : le cache écrit par une PR n'est lisible que par cette PR, `main` ne restaure jamais un cache de PR, et `npm ci` / `--locked` vérifient les sommes du lockfile.
- Auto-hébergé : **répertoire persistant**, pas `actions/cache`. L'absence d'AVX ne départage pas (actions/cache tourne sur le Node du runner, sans binaire natif). Mais actions/cache envoie et retélécharge `target/` (centaines de Mo à plusieurs Go) par Internet à chaque exécution, dans un quota de 10 Go par dépôt, alors que le disque du runner garde déjà tout. `~/.cargo/registry` et `~/.npm` persistent d'eux-mêmes dans le HOME du runner : rien à générer. Seul `target/` est effacé par `actions/checkout` (`clean: true`). Le job rust reçoit donc, juste après le checkout, l'étape `run: echo "CARGO_TARGET_DIR=$(dirname "$GITHUB_WORKSPACE")/kit-perso-target" >> "$GITHUB_ENV"` : le dossier `_work/<dépôt>/` est propre à chaque runner et au dépôt, et n'est pas nettoyé. Le code d'une PR peut y écrire, mais il s'exécute déjà sur la machine avec les droits du runner, donc pas de nouvelle surface. À écrire dans le README.

**Concurrence** (dans `modele-tests.yml`, au niveau du workflow) : `concurrency: { group: kit-perso-tests-${{ github.ref }}, cancel-in-progress: true }`. Le préfixe empêche un autre workflow d'annuler celui-ci. Rien dans `deps` : en `pull_request_target`, `github.ref` est la branche de base, toutes les PR partageraient le groupe. Sur `main`, un push annule l'exécution du push précédent : seul le dernier `main` est testé.

**Job `filtre`** (généré seulement si au moins une ligne `chemins`, placé en premier) : checkout du projet (`fetch-depth: 2`, `persist-credentials: false`), puis checkout du kit au SHA figé dans `.kit-perso` (comme le job node), puis l'étape `id: decide` avec `env: BASE: ${{ github.event.pull_request.base.sha }}` et `FILTRES: '<JSON {job: [motifs]}>'` (constante du générateur), et `run: python3 .kit-perso/skills/ci-projet/filtre-chemins.py`. Il a `outputs: <job>: ${{ steps.decide.outputs.<job> }}` par job filtré et `timeout-minutes: 5`. Un job filtré reçoit `needs: filtre` et `if: ${{ needs.filtre.outputs.<job> == 'true' }}`. Un job sans ligne `chemins` n'a ni `needs` ni `if` et tourne toujours.

**`filtre-chemins.py`** (stdlib, nouveau, dans `skills/ci-projet/`). Il lit `BASE`, `FILTRES` et `GITHUB_OUTPUT`, et ajoute une ligne `<job>=true|false` par job à `$GITHUB_OUTPUT`. Il imprime une ligne par job : `<job> : lancé (<raison>)` ou `<job> : sauté`. Règle **fail-safe** : sauter un job seulement si c'est prouvé.
1. Tout à `true` si `BASE` est vide (push sur `main`), si `git rev-parse HEAD^1` échoue ou diffère de `BASE`, si `git diff --name-only --no-renames -z HEAD^1 HEAD` échoue, ou si la liste des fichiers est vide.
2. Sinon, `J` vaut `true` s'il existe un fichier modifié qui correspond à un motif de `J`, ou qui ne correspond à aucun motif d'aucun job (fichier non classé, ex. workflow, config racine, doc).
3. Sortie 2 avec message si `FILTRES` n'est pas un objet JSON `{str: [str, …]}` non vide, ou si `GITHUB_OUTPUT` est absent. `filtre` est alors rouge, donc `resume` aussi.

**Job `resume`** (toujours généré s'il y a au moins un job de tests, placé en dernier, sans checkout ni `${{` dans un `run`) :
```
  resume:
    if: ${{ !cancelled() }}
    needs: [filtre, rust, node]      # filtre seulement s'il existe
    runs-on: <runs-on>
    timeout-minutes: 5
    permissions:
      contents: read
    steps:
      - if: ${{ contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') }}
        run: exit 1
      - run: echo "jobs de tests verts ou sautés par le filtre"
```
Un job sauté n'est que la conséquence de la sortie de `filtre`, et un échec de `filtre` fait échouer `resume`. Un ruleset qui exige déjà `rust` ou `node` reste valable, car GitHub compte un job sauté par `if` comme réussi. Le check à exiger devient `deps` + `resume`.

**`deps` sur le runner déclaré (L5)**. `modele-deps.yml` porte `runs-on: __RUNS_ON__`, que `genere-ci.py` remplace par `runs_on(cfg)` à côté de `__SHA_KIT__`. `cfg` vaut `CFG_DEFAUT` sans `.kit-perso-ci` ou sans job de tests, donc `ubuntu-24.04` par défaut, comme avant. Le reste du job est inchangé. Sur un runner auto-hébergé, `deps` tourne alors sans minutes GitHub et sans VM à démarrer. En mode auto-hébergé, stderr ajoute la ligne `genere-ci : runner auto-hébergé : deps (pull_request_target) y tourne aussi ; à réserver à un dépôt privé (README « CI rapide »).`
- Sécurité (à reprendre dans le README) : `pull_request_target` exécute le workflow de `main` et le kit au SHA figé. Le code de la PR est seulement lu par git (`diff`, `show`, `ls-files`), jamais exécuté. Les deux checkouts ont `persist-credentials: false` : aucun jeton ne reste dans `kit/.git` ni dans `pr/.git` sur le disque persistant. Le job a `contents: read` et n'utilise aucun secret.
- Limite : sur un dépôt public, `pull_request_target` lance `deps` pour toute PR de fork, sans approbation. N'importe qui peut donc occuper le runner (5 min par PR). GitHub déconseille de toute façon les runners auto-hébergés sur un dépôt public.
- Limite : un runner persistant garde l'état d'une exécution à l'autre. Le code d'une PR exécuté par `kit-perso-tests` sur ce runner (mêmes droits) peut laisser de quoi fausser un `deps` suivant (ex. `pr/.git/config`, `PATH`). Sur `ubuntu-24.04`, chaque exécution part d'une VM neuve. Le verdict de `deps` ne vaut donc que ce que vaut le runner (voir Questions ouvertes).

**Cas limites** :
- Rust seul ou web seul : un job + `resume`. Une ligne `chemins` fait toujours lancer le job (tout fichier est classé dans ce job ou non classé) : le filtre est inutile mais sans danger.
- Mixte sans `.kit-perso-ci` : pas de `filtre`, tous les jobs, puis `resume`.
- Mixte avec `chemins` : une PR qui ne touche que `ui/**` saute `rust`. Une PR qui ne touche aucun chemin filtré (README, workflow) lance tout. Un diff vide lance tout.

## Fichiers

- `skills/ci-projet/genere-ci.py` — modifier — lecture et validation de `.kit-perso-ci`, `runs-on` paramétré, étapes de cache selon le mode, jobs `filtre` et `resume`, `needs`/`if`, résumé stderr, message des checks (`deps`, `resume`). L5 : remplacement de `__RUNS_ON__` dans `deps`, avertissement stderr en mode auto-hébergé.
- `skills/ci-projet/modele-deps.yml` — modifier (L5) — `runs-on: ubuntu-24.04` devient `runs-on: __RUNS_ON__`, rien d'autre.
- `skills/ci-projet/filtre-chemins.py` — créer — décision par job (ci-dessus).
- `skills/ci-projet/modele-tests.yml` — modifier — bloc `concurrency`.
- `skills/ci-projet/SKILL.md` — modifier — étape 2 : `.kit-perso-ci` et résumé stderr à montrer ; étape 4 : checks `deps` et `resume`.
- `tests/test_ci_projet.sh` — modifier — cas ci-dessous ; adapter le cas « checks » à `deps`, `resume`. L5 : le cas « runs-on auto-hébergé » ne vérifie plus `deps` sur `ubuntu-24.04` ; cas « deps : … » ajoutés.
- `README.md` — modifier — « CI des projets » : `.kit-perso-ci` (format, exemple générique), cache et sécurité par mode, filtre fail-safe, `resume`, concurrence, croissance du répertoire persistant (nettoyage manuel, ex. `cargo sweep --time 14` ou `rm -rf` du dossier `kit-perso-target`), paragraphe « 2e runner ». L5 : `runs-on` s'applique aussi à `deps` (sauf `--sans-tests`), puce « `deps` sur runner auto-hébergé » (sécurité et deux limites ci-dessus).
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — 3.9.0 (L3), puis 3.10.0 (L5, mineur : comportement nouveau du générateur).

## Étapes

1. `modele-tests.yml` : ajouter `concurrency`. Vérif : cas « concurrency ».
2. `genere-ci.py` : lire et valider `.kit-perso-ci` (refus listés), `runs-on` paramétré pour les jobs de tests. Vérif : cas « runs-on » et « refus .kit-perso-ci ».
3. Épingler `actions/cache` : `gh api repos/actions/cache/releases/latest --jq .tag_name`, puis `gh api repos/actions/cache/git/ref/tags/<tag> --jq '.object.type + " " + .object.sha'` (si `tag`, déréférencer avec `gh api repos/actions/cache/git/tags/<sha> --jq .object.sha`). Constante `CACHE` à côté de `CHECKOUT`. Étapes de cache des deux modes. Vérif : cas « cache ».
4. `filtre-chemins.py` et ses cas de test (dépôt jetable avec un commit de fusion `--no-ff`, `GITHUB_OUTPUT` dans `$TMP`). Vérif : cas « filtre : … ».
5. Générer `filtre`, `needs`/`if`, `resume` et le nouveau message des checks. Vérif : cas « structure » et « checks ».
6. README, SKILL.md, CHANGELOG, version. Clôture selon `agents/codeur.md`.
7. (L5) `modele-deps.yml` : `__RUNS_ON__`. `genere-ci.py` : `.replace("__RUNS_ON__", runs_on(cfg))` et avertissement stderr si `hebergeur(cfg) == "auto-hébergé"`. Tests : inverser l'assertion `deps` du cas « runs-on auto-hébergé » et ajouter les cas « deps : … » ci-dessous. Vérif : `bash tests/test_ci_projet.sh`.
8. (L5) README (l. 84 et 93, nouvelle puce sécurité), CHANGELOG 3.10.0, `plugin.json` 3.10.0. Vérif : `bash tests/test_hooks.sh`.

## Critères d'acceptation

Noms de cas = libellés `ok` de `bash tests/test_ci_projet.sh`.
- [x] `kit-perso-tests.yml` a `concurrency` (groupe `kit-perso-tests-${{ github.ref }}`, `cancel-in-progress: true`), `kit-perso-deps.yml` n'en a pas — test : `bash tests/test_ci_projet.sh` (concurrency dans tests, absente de deps)
- [x] Sans `.kit-perso-ci` : jobs de tests sur `ubuntu-24.04`, pas de job `filtre`, ni `needs` ni `if` sur rust/node/python, `resume` présent — test : `bash tests/test_ci_projet.sh` (sans config : aucun filtre, resume présent)
- [x] Mode hébergé : `actions/cache` épinglé (40 hex + `# v`) dans rust (chemins cargo + `target`, clé sur `Cargo.lock`) et dans node avec `package-lock.json` seulement — test : `bash tests/test_ci_projet.sh` (cache hébergé rust et npm)
- [x] `runs-on self-hosted …` : tous les jobs de tests sur la liste de labels, aucun `actions/cache`, étape `CARGO_TARGET_DIR` après le checkout du job rust — test : `bash tests/test_ci_projet.sh` (runs-on auto-hébergé, répertoire persistant)
- [x] Mixte avec `chemins rust` et `chemins node` : `filtre` en premier, `FILTRES` JSON exact, jobs filtrés avec `needs: filtre` et `if` ; `resume` dernier avec `if: ${{ !cancelled() }}` et `needs` listant `filtre` et tous les jobs — test : `bash tests/test_ci_projet.sh` (structure mixte filtrée)
- [x] Rust seul et web seul : un job + `resume` dont `needs` ne liste que ce job (et `filtre` si déclaré) — test : `bash tests/test_ci_projet.sh` (structure rust seul, structure web seul)
- [x] Le message imprimé demande les checks `deps`, `resume` — test : `bash tests/test_ci_projet.sh` (checks : deps et resume)
- [x] Le filtre saute `rust` pour une PR qui ne touche que des fichiers `node`, et lance les deux pour un fichier non classé — test : `bash tests/test_ci_projet.sh` (filtre : node seul saute rust ; filtre : fichier non classé lance tout)
- [x] Le filtre lance tout si `BASE` est vide, si `HEAD^1` ≠ `BASE` ou si le diff est vide — test : `bash tests/test_ci_projet.sh` (filtre : push lance tout ; filtre : base différente lance tout ; filtre : diff vide lance tout)
- [x] (négatif) `FILTRES` invalide ou `GITHUB_OUTPUT` absent : sortie 2, rien d'ajouté à la sortie — test : `bash tests/test_ci_projet.sh` (filtre : FILTRES invalide refusé)
- [x] (négatif) `.kit-perso-ci` avec directive inconnue, `runs-on` double, motif invalide ou job non généré : sortie 2, rien d'écrit — test : `bash tests/test_ci_projet.sh` (refus .kit-perso-ci : …)
- [x] (négatif, non-régression) `--sans-tests` ignore un `.kit-perso-ci` invalide (seul `deps`, sortie 0) — test : `bash tests/test_ci_projet.sh` (sans tests : config non lue)
- [x] (non-régression) Propriétés de sécurité (un événement par workflow, actions épinglées, `persist-credentials: false` sur chaque checkout, pas de `${{` dans un `run`, pas de `secrets.`), job node et ligne run de `deps` inchangés — test : `bash tests/test_ci_projet.sh` (propriétés de sécurité…, job node…, ligne run du job deps sort 0)
- [x] (non-régression) Toute la suite du kit passe — test : `bash tests/test_hooks.sh`
- [ ] (L5) `runs-on self-hosted linux x64 homelab` : `kit-perso-deps.yml` a `runs-on: [self-hosted, linux, x64, homelab]`, ne contient ni `ubuntu-24.04` ni `__RUNS_ON__`, et ne diffère du `deps` par défaut que par cette ligne (donc ni `concurrency`, ni `actions/cache`, toujours deux `persist-credentials: false`) ; stderr contient `deps (pull_request_target) y tourne aussi` — test : `bash tests/test_ci_projet.sh` (deps : runner déclaré)
- [ ] (L5) `runs-on ubuntu-latest` : `deps` a `runs-on: ubuntu-latest` et stderr n'a pas l'avertissement auto-hébergé — test : `bash tests/test_ci_projet.sh` (deps : un seul label, sans avertissement)
- [ ] (L5, non-régression) Sans `.kit-perso-ci` : `deps` a `runs-on: ubuntu-24.04` et aucun `__RUNS_ON__` — test : `bash tests/test_ci_projet.sh` (deps : défaut ubuntu-24.04)
- [ ] (L5, négatif, non-régression) `--sans-tests` avec un `.kit-perso-ci` valide `runs-on self-hosted …` : config non lue, `deps` sur `ubuntu-24.04`, sortie 0 — test : `bash tests/test_ci_projet.sh` (sans tests : deps sur ubuntu-24.04 malgré runs-on)
- [ ] (L5, négatif, non-régression) Label invalide dans `runs-on` : sortie 2, ni `kit-perso-deps.yml` ni `kit-perso-tests.yml` écrits — test : `bash tests/test_ci_projet.sh` (refus .kit-perso-ci : label invalide)
- [ ] (L5) README : la phrase « `deps` reste sur `ubuntu-24.04` » a disparu ; la puce sur `deps` auto-hébergé cite `persist-credentials: false`, « dépôt privé » et « fork » — test : `bash tests/test_ci_projet.sh` (README : deps suit runs-on)
- [ ] Sur un projet réel, après copie par l'utilisateur : une PR qui ne touche que les chemins `node` affiche `rust` sauté et `resume` vert ; deux pushs rapprochés annulent la 1re exécution ; `deps` tourne sur le runner auto-hébergé (nom du runner dans l'étape « Set up job » du job `deps`) — test : manuel (onglet Checks de la PR)

## Tests

```
bash tests/test_ci_projet.sh
bash tests/test_hooks.sh
```

## Questions ouvertes

- `filtre` et `resume` (quelques secondes) tournent sur le `runs-on` déclaré. Sur un runner unique, ils attendent dans la même file. Les mettre sur `ubuntu-24.04` évite d'attendre mais consomme des minutes GitHub sur un dépôt privé. Recommandation : garder le `runs-on` déclaré.
- (L5) Intégrité de `deps` sur runner persistant : le code d'une PR qui tourne dans `kit-perso-tests` sur la même machine peut fausser un `deps` suivant, ce qui n'est pas possible sur `ubuntu-24.04`. Recommandation : accepter et documenter pour un dépôt privé dont tu es le seul auteur de PR. Sinon, il faudrait une directive séparée (ex. `runs-on-deps`), hors de cette spec.
- (L5) `--sans-tests` : `.kit-perso-ci` reste ignoré, donc `deps` reste sur `ubuntu-24.04`. Le lire pour `runs-on` seul obligerait à ignorer les lignes `chemins` sans valider leur job. Recommandation : laisser ainsi, et l'écrire dans le README.

## Lots

- [x] L1 — Concurrence, `.kit-perso-ci` (runs-on) et cache des deux modes (étapes 1-3)
  Fichiers : `skills/ci-projet/modele-tests.yml`, `skills/ci-projet/genere-ci.py`, `tests/test_ci_projet.sh`
  Fait quand : cas concurrency, runs-on, cache et refus verts — `bash tests/test_ci_projet.sh`
- [x] L2 — Filtre par chemins et job `resume` (étapes 4-5)
  Fichiers : `skills/ci-projet/filtre-chemins.py`, `skills/ci-projet/genere-ci.py`, `tests/test_ci_projet.sh`
  Fait quand : cas filtre, structure et checks verts — `bash tests/test_ci_projet.sh`
- [x] L3 — Documentation, version, clôture (étape 6)
  Fichiers : `README.md`, `skills/ci-projet/SKILL.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`, `tests/test_ci_projet.sh`
  Fait quand : suite complète verte — `bash tests/test_hooks.sh`

> Coupure PR

- [ ] L5 — `deps` sur le `runs-on` déclaré, doc et version 3.10.0 (étapes 7-8)
  Fichiers : `skills/ci-projet/modele-deps.yml`, `skills/ci-projet/genere-ci.py`, `tests/test_ci_projet.sh`, `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`
  Fait quand : cas « deps : … », « sans tests : deps sur ubuntu-24.04 malgré runs-on », « refus .kit-perso-ci : label invalide » et « README : deps suit runs-on » verts, suite complète verte — `bash tests/test_ci_projet.sh && bash tests/test_hooks.sh`

> Coupure PR

- [ ] L4 — Validation manuelle sur un projet réel, après fusion de L5 (critère d'acceptation manuel)
  Fichiers : `docs/specs/ci-rapide.md` (cocher le critère manuel, `Statut : livrée`, `git mv` vers `docs/specs/archives/`)
  Fait quand : l'utilisateur confirme dans l'onglet Checks d'une PR du projet que `rust` est sauté, `resume` vert, qu'un 2e push annule la 1re exécution et que `deps` a tourné sur le runner auto-hébergé
