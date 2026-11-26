# kit-perso

Plugin Claude Code personnel de stanixia-dev, qui sert aussi de marketplace. Il regroupe les agents (specs, codeur, relecteur, explorateur), les hooks (garde-git, garde-deps, verifie-manifestes, garde-secret, rappel-clear) et les skills (livrer, ticket, ci-projet, archiver-memoire) à installer une fois pour tous les projets, au lieu de les recopier dans chaque `~/.claude`.

## Installation

En une ligne depuis le terminal (portée utilisateur, tous projets) :

```
claude plugin install kit-perso --marketplace stanixia-dev/kit-perso
```

Ou en deux temps dans une session :

```
/plugin marketplace add stanixia-dev/kit-perso
/plugin install kit-perso@kit-perso
```

Vérification : `claude plugin details kit-perso@kit-perso` liste 4 agents, 4 skills, 5 hooks (PreToolUse, PostToolUse, PostToolUseFailure, Stop, SubagentStop). Les agents s'appellent `kit-perso:codeur`, etc. ; les skills `/kit-perso:livrer`, `/kit-perso:ticket`, `/kit-perso:ci-projet` et `/kit-perso:archiver-memoire`.

## Mise à jour

Toute modification livrée exige une montée de version dans `.claude-plugin/plugin.json` (seule source de la version, semver) et une entrée dans `CHANGELOG.md` : sans montée, `update` ne récupère rien.

- MAJEUR : renommage/suppression d'un agent, skill ou hook, ou hook qui bloque davantage.
- MINEUR : ajout.
- CORRECTIF : correction sans changement de comportement attendu.

Sur la machine, après fusion :

```
claude plugin marketplace update kit-perso && claude plugin update kit-perso@kit-perso
```

puis redémarrer Claude Code. Pour développer sans installer : `claude --plugin-dir <chemin du dépôt>`.

## Ajouter un élément

- Skill : `skills/<nom-kebab-fr>/SKILL.md`, `name` = nom du dossier, `description` en français (ce qu'il fait + « À utiliser quand… »), `disable-model-invocation: true` dès qu'il y a un effet de bord (push, suppression, réseau), sauf `livrer` : l'orchestrateur la lance de lui-même après une relecture OK, pour que les projets avancent sans manipulation (push refusé hors `claude/*` par la skill, `main` bloqué par `garde-git`, secrets par `garde-secret` ; la fusion reste à l'utilisateur). Fichiers annexes dans le même dossier.
- Agent : `agents/<nom>.md` avec `name`, `description`, `model`, `effort`, `tools` (liste minimale) ; rapport final borné en lignes.
- Hook : script dans `hooks/`, déclaré dans `hooks/hooks.json` via `${CLAUDE_PLUGIN_ROOT}`, cas ajouté à `tests/test_hooks.sh`.
- Chaque ajout : montée MINEURE, entrée au CHANGELOG, et `claude plugin validate --strict .` vert.

## Contrôle des dépendances

Règles appliquées à chaque paquet ajouté ou modifié (cargo, npm/pnpm/yarn, pip/uv/poetry) : bloque une licence non permissive (hors MIT, Apache-2.0, BSD, ISC, Zlib, 0BSD, Unlicense, CC0-1.0, OFL-1.1), une faille OSV connue, un paquet déprécié ou yanked, une dernière publication de plus de 2 ans. Avertit pour MPL/LGPL, les avis RustSec informatifs et les registres injoignables.
Un paquet refusé, c'est l'utilisateur qui l'ajoute lui-même s'il l'accepte. Le relecteur lance `hooks/verifie-manifestes.py --base main` sur le diff.

Trois couches, de la plus rapide à la plus sûre :

1. **Hook Bash `garde-deps` (PreToolUse)** : filtre rapide qui lit la commande (`cargo add`, `npm i`, `pip install`…, y compris dans `bash -c`, heredocs, substitutions). Il se contourne (script écrit puis exécuté, chemin obfusqué) : ce n'est pas la barrière.
2. **Contrôle par résultat en local (PostToolUse, Stop, SubagentStop)** : `hooks/verifie-manifestes.py` compare les manifestes (`Cargo.toml`, `package.json`, `pyproject.toml`, `requirements*.txt`) et lockfiles (`Cargo.lock`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `uv.lock`, `poetry.lock`) à `main` et applique les règles aux paquets ajoutés, quelle que soit la façon dont ils sont arrivés. Sans manifeste modifié, il sort aussitôt, sans réseau. Stop bloque une fois puis avertit (`stop_hook_active`).
3. **CI, job `deps / deps`** (nom dans ce dépôt ; dans un projet, seulement si les workflows kit-perso y sont installés, check `kit-perso-deps / deps`, voir « CI des projets ») : même script en `--ci`, lancé en `pull_request_target` : le workflow est celui de `main`, la PR ne peut donc ni le modifier ni le retirer, et aucun code de la PR n'est exécuté (ses manifestes sont lus comme données par git). Ce job ne tourne qu'une fois la PR qui l'introduit fusionnée dans `main`.

Les dépendances **transitives** (lockfiles) ne sont examinées que par OSV (une seule requête par lot) et donnent un avertissement, jamais un blocage : licence et âge ne sont pas vérifiés, trop de requêtes.
Hors réseau, les couches locales sont *fail-open* (avertissement « vérification impossible ») ; la CI est *fail-closed* (registre injoignable, fichier illisible ou erreur imprévue = blocage ; une relance coûte peu). En CLI (`--base`), une erreur imprévue sort en 2 avec la trace.

Tests : `bash tests/test_hooks.sh` (appelle `tests/test_manifestes.sh`), hors réseau (réponses simulées dans `tests/fixtures/garde-deps.json`, dépôts git jetables) ; la CI GitHub les lance sur chaque PR et push sur `main`.

### Exceptions

`.garde-deps-exceptions` (racine du dépôt) autorise un paquet refusé : une ligne `<registre> <nom> <version|*> <AAAA-MM-JJ> <raison>` (`crates`, `npm` ou `pypi`), `#` pour un commentaire. En local, le blocage devient un avertissement `(exception du … : …)`. En CI, seules les exceptions déjà sur `main` comptent ; celles qu'ajoute la PR sont listées dans le résumé du job, non appliquées. Ajouter une exception = commit de l'utilisateur sur `main`, puis relancer la CI de la PR.

## CI des projets

Le skill `/kit-perso:ci-projet [--sans-tests]` (invocation par l'utilisateur seul) génère deux workflows pour un projet : `kit-perso-deps.yml` (job `deps` fail-closed, mêmes contrôles que ci-dessus, uniquement en `pull_request_target`) et `kit-perso-tests.yml` (uniquement en `pull_request` et `push` sur `main` : un job de tests par manifeste détecté à la racine (`Cargo.toml` : `rust` ; `package.json` : `node` ; `pyproject.toml` ou `requirements*.txt` : `python`) ; `--sans-tests` ne génère que le premier. Deux fichiers, car dans un même workflow chaque événement créerait un check du même nom, sauté, que GitHub compte comme réussi : un check obligatoire serait satisfait sans rien vérifier. Ce sont des emplacements par défaut : à relire avant de commiter. L'agent n'écrit jamais dans `.github/` : les fichiers sont générés dans `.git/kit-perso/` (jamais suivis) et c'est l'utilisateur qui lance, dans un terminal, la commande imprimée (copie, `git add`, commit, `git push origin main`).

**Préalable (utilisateur, une fois) : kit-perso doit être public.** Le job `deps` du projet récupère les scripts du kit par `actions/checkout` sans jeton. L'agent ne change pas la visibilité d'un dépôt. 1. Scanner tout l'historique publié, PR comprises, dans un dossier jetable :

```
git clone -q https://github.com/stanixia-dev/kit-perso.git kp && cd kp
git fetch -q origin '+refs/pull/*/head:refs/remotes/origin/pr/*'
for r in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin); do
  python3 hooks/garde-secret.py --ci --base 4b825dc642cb6eb9a060e54bf8d69288fbee4904 --cible "$r" || echo "À TRAITER : $r"; done
```

(`4b825dc…` est l'arbre vide : le scan lit alors tous les commits jusqu'à la cible.) Relire aussi tickets et PR, qui deviennent publics. 2. Rien à traiter : `gh repo edit stanixia-dev/kit-perso --visibility public --accept-visibility-change-consequences`.

**SHA figé.** Le workflow du projet porte le SHA complet du kit (`ref:` du checkout de `stanixia-dev/kit-perso`, ligne d'en-tête `# Généré par kit-perso <version>…`). Il est protégé contre l'agent comme tout `.github/workflows/` : changer de version du kit est un commit de l'utilisateur (relancer le skill, recopier). Si kit-perso redevient privé, le checkout échoue et le job `deps` est rouge : les PR restent bloquées tant que le check est obligatoire.

**Runtime Node.** Le job `node` lit la branche majeure dans `.nvmrc` (`actions/setup-node` avec `check-latest: true`, donc le dernier correctif de cette branche), impose `engines` (`npm_config_engine_strict`) et lance `verifie-runtime.py --ci` (checkout du kit au SHA figé, supprimé avant le lint et les tests). Le skill génère aussi `.nvmrc` (première suite de chiffres de `engines.node`, sinon `lts/*` avec un avis) et `.npmrc` (`engine-strict=true`), seulement s'ils n'existent pas dans le projet (`cp -n`) ; un `.npmrc` existant n'est pas lu, un avis rappelle d'y ajouter `engine-strict=true`.

**CI rapide (`.kit-perso-ci`).** Fichier facultatif à la racine du projet, lu par le générateur seulement (jamais en CI, jamais avec `--sans-tests`) :

```
# commentaire
runs-on self-hosted linux x64 homelab
chemins rust crates/** Cargo.toml Cargo.lock
chemins node ui/** package.json package-lock.json
```

`runs-on <label>…` (au plus une ligne ; défaut `ubuntu-24.04`) s'applique à tous les jobs de `kit-perso-tests.yml`, `filtre` et `resume` compris ; `deps` reste sur `ubuntu-24.04`. `chemins <job> <motif>…` déclare les chemins d'un job (`rust`, `node`, `python` ; `*` traverse les `/`). Un fichier invalide est refusé (sortie 2, rien d'écrit). Sans fichier : aucun filtre, tous les jobs tournent.

- **Filtre fail-safe.** Avec au moins une ligne `chemins`, un job `filtre` décide ; un job filtré a `needs: filtre` et un `if`. Il saute un job seulement si c'est prouvé : une PR qui ne touche que `ui/**` saute `rust`. Un fichier qui n'est dans aucun chemin déclaré (doc, workflow, config racine), un push sur `main`, un diff vide ou une base incohérente lancent tous les jobs. Il n'y a pas de liste « ignorés » : une PR qui ne touche que la doc lance tout.
- **`resume`.** Toujours généré avec les tests (`if: !cancelled()`) : rouge si un job a échoué ou été annulé, ou si `filtre` a échoué ; vert si les jobs sont verts ou sautés. Le check à exiger est `deps` + `resume` (un ruleset qui exige déjà `rust` reste valable : un job sauté par `if` compte comme réussi).
- **Concurrence.** `kit-perso-tests.yml` annule l'exécution précédente de la même ref ; sur `main`, seul le dernier push est testé. Pas de `concurrency` dans `deps` (en `pull_request_target`, `github.ref` est la même branche de base pour toutes les PR).
- **Cache, runner hébergé** : `actions/cache` épinglé par SHA. rust : `~/.cargo/registry`, `~/.cargo/git/db` et `target`, clé sur `Cargo.lock` ; node (avec `package-lock.json`) : `~/.npm`, clé sur le lockfile. Un cache écrit par une PR n'est lisible que par cette PR, `main` n'en restaure jamais un ; `npm ci` et `--locked` vérifient de toute façon les sommes du lockfile.
- **Cache, runner auto-hébergé** (label `self-hosted`) : pas d'`actions/cache`, qui ferait envoyer et retélécharger `target/` par Internet à chaque exécution (quota de 10 Go par dépôt) alors que le disque du runner garde tout. `~/.cargo/registry` et `~/.npm` persistent dans le HOME du runner ; `target/` est effacé par le checkout, donc le job rust écrit `CARGO_TARGET_DIR=<_work/dépôt>/kit-perso-target` (dossier propre au runner et au dépôt, non nettoyé). Le code d'une PR peut y écrire, mais il s'exécute déjà sur la machine avec les droits du runner : pas de surface nouvelle. Ce dossier grossit : nettoyage manuel (`cargo sweep --time 14` dans le projet, ou `rm -rf` du dossier `kit-perso-target`).
- **2e runner.** Ajouter un runner auto-hébergé : l'installer avec le label voulu (Settings > Actions > Runners), puis mettre ce label dans `runs-on` de `.kit-perso-ci`, relancer le skill et recopier. Deux runners au même label se partagent la file, mais chacun a son propre `_work` : le répertoire persistant n'est donc pas partagé, le premier passage sur un runner repart d'un `target/` vide.

**Après la fusion des workflows** : `deps` ne tourne qu'une fois les workflows sur `main`. Ensuite, Settings > Rules > Rulesets > New branch ruleset, cible `main`, Require status checks : `deps` et `resume` ; ce sont les noms de jobs, affichés dans la PR `kit-perso-deps / deps` et `kit-perso-tests / resume`.

**Détection.** `livrer` (avant le push) et l'agent `specs` (au démarrage) signalent, en lecture seule, un dépôt sans workflow, sans le job `deps` du kit ou dont les checks de `main` ne sont pas obligatoires (rulesets et protection classique). Ils distinguent « pas de CI configurée » de « CI configurée mais pas déclenchée ». `livrer` annonce et continue, sans bloquer.

Tests : `bash tests/test_ci_projet.sh` (appelé par `tests/test_hooks.sh`), hors réseau (`--ref <sha>`).

## Contrôle du runtime

`hooks/verifie-runtime.py` refuse un Node plus ancien que la dernière version de sécurité de sa branche majeure (index `https://nodejs.org/dist/index.json`, champ `security`). Une branche sans version de sécurité passe ; une branche en fin de vie aussi (l'index ne la signale pas, ticket séparé). Rust n'est pas couvert (spec future).

- `--ci` : 2 essais de 10 s, aucun cache ; index injoignable ou `node` absent : sortie 2 (fail-closed).
- CLI (`python3 hooks/verifie-runtime.py`) : 1 essai de 4 s, cache lu et écrit ; index injoignable sans cache : sortie 2.
- `--hook pre` (PreToolUse Bash) : ne s'active que si la commande contient `node`, `npm`, `npx`, `pnpm`, `yarn` ou `corepack` (mot entier : `node_modules` ne compte pas) ; Node vulnérable : commande refusée (faux positifs acceptés, `nvm` passe pour réparer). Fail-open : `node` introuvable ou index injoignable sans cache donnent sortie 0 (avertissement dans le second cas).
- Cache : `$CLAUDE_PLUGIN_DATA/node-corriges.json` (sinon `~/.claude/plugins/data/kit-perso/`), valable 6 h, au plus un essai réseau toutes les 15 min ; périmé, il reste utilisé avec la mention « nodejs.org injoignable ». Désactivé hors de `~/.claude/plugins/` (dossier protégé en écriture par garde-deps). Avec `KIT_PERSO_NODE_INDEX` défini, le vrai cache (sous le `~/.claude/plugins` de la base de comptes, pas `$HOME`) n'est ni lu ni écrit : un index de test ne peut pas l'empoisonner. Une préversion (`-rc`) compte comme inférieure à la version finale. Le hook reconnaît aussi `nodejs`, `pnpx` et `yarnpkg`.

Résidus assumés :
- le hook contrôle le `node` du `PATH` du hook : un `nvm use` dans la commande ou un chemin absolu vers un autre binaire lui échappe ;
- la détection porte sur le texte de la commande : `make test`, `./node_modules/.bin/x` ou un script qui lance npm ne sont pas vus ;
- Yarn Berry ignore `engine-strict` ;
- le job de tests tourne en `pull_request` : une PR peut modifier ce workflow. L'agent ne peut pas (garde-deps protège `.github/workflows/`) et le job `deps` reste la barrière.

Tests : `bash tests/test_runtime.sh` (appelé par `tests/test_hooks.sh`), hors réseau (`KIT_PERSO_NODE_INDEX`).

## Contrôle des secrets

Applique les règles « Secrets » du CLAUDE.md global : l'agent ne lit pas `~/.ssh/`, `~/.config/gh/` ni les `.env`, n'affiche et n'écrit aucun token ou mot de passe, n'en commite aucun. `hooks/garde-secret.py` n'a aucune dépendance. Aucun de ses messages ne contient une valeur : seulement le chemin, le commit, le type de secret et une empreinte (12 premiers hex de `sha256`).

Le filtre de commandes reste une aide ; les barrières sont le **masquage de la sortie** et le **scan du résultat git** :

1. **PreToolUse** (`--hook pre`, `onFailure: "block"`) : refuse l'accès à un chemin protégé (Read, Grep, Edit, Write, MultiEdit, NotebookEdit, et chaque chemin cité dans une commande Bash, y compris dans `bash -c`, heredocs et substitutions), un secret dans le contenu écrit ou dans le texte d'une commande, `gh auth token` et `git credential fill`. Avant `git commit`, `git push` et `gh pr create`, il scanne le dépôt.
2. **PostToolUse** (Bash, Read, Grep, BashOutput, TaskOutput) : remplace chaque secret reconnu par `[masqué:<type>:<empreinte>]` dans la sortie (`updatedToolOutput`), ainsi que les valeurs de `os.environ` et des `.env` du dossier dont le nom évoque un secret. PostToolUseFailure : alerte seule.
3. **Stop, SubagentStop** : scan du dépôt, bloque une fois puis avertit.
4. **CI** (dans un projet, seulement si les workflows kit-perso y sont installés) : `verifie-manifestes.py --ci` (job `deps / deps` dans ce dépôt, `kit-perso-deps / deps` dans un projet) enchaîne `garde-secret.py --ci`, depuis `main` : la PR ne peut ni l'altérer ni le retirer. Le secret s'affiche donc sous le nom de check `deps`.

Le scan lit chaque commit un par un (un secret retiré au commit suivant reste dans l'historique), plus la copie de travail et les fichiers non suivis. Il refuse aussi des noms de fichiers (`.env`, `id_rsa`, `.p12`…).

| Contrôle | Signature | Générique | Échec du hook |
|---|---|---|---|
| Pre : chemin protégé | bloque | — | bloque |
| Pre : contenu écrit | bloque | avertit | bloque |
| Pre Bash : chemin ou texte de la commande | bloque | — | bloque |
| Pre Bash : script de banc | laisse passer l'invocation admise (au plus une cible de filtre déclarée) d'un script déclaré et intact ; refuse toute autre mention hors texte de `gh issue\|pr` / `git commit` | — | passe |
| Pre Bash : scan avant commit, push, PR | bloque | avertit ; scan incomplet (budget de 10 s) : avertit, mais bloque `git push` et `gh pr create` | bloque |
| Post : sortie | masque + alerte | — | sortie intacte |
| Stop, SubagentStop | bloque une fois, puis avertit | — | passe |
| CI (`--ci`) | bloque | bloque | bloque |

Signature : formats connus (GitHub, GitLab, Anthropic, OpenAI, AWS, Google, Slack, Stripe, npm, PyPI, clés privées). Générique : JWT, URL à mot de passe, affectation `password = "…"`, écartés dans la doc et les tests.

Résiduels assumés : un script qui lit un fichier protégé et transforme la valeur avant de l'afficher ; un mot de passe sans signature, absent des valeurs connues ; la sortie d'une commande en échec, non réécrivable (alerte seule) ; `cd x && git push` (le scan local vise le dossier courant ; Stop rattrape, la CI aussi dans un projet, seulement si les workflows kit-perso y sont installés) ; un jeton encodé en UTF-16 (les motifs lisent du texte UTF-8) ; `gh gist create` d'un fichier non protégé qui contient un secret hors signature. Purge d'historique et révocation : à la charge de l'utilisateur. Secours : `claude plugin disable kit-perso@kit-perso`.

Tests : `bash tests/test_secrets.sh` (appelé par `tests/test_hooks.sh`), `HOME` jetable, jetons construits à l'exécution.

### Exceptions de secrets

`.garde-secret-exceptions` (racine du dépôt) : une ligne `<glob relatif> <empreinte|*> <AAAA-MM-JJ> <raison>`, `#` pour un commentaire. L'empreinte est celle affichée par le message de blocage, jamais la valeur ; `*` couvre tout le chemin, lecture comprise. Sans effet hors de la racine du dépôt ni sur `~/.ssh` et autres identifiants personnels. En CI, seules les exceptions déjà sur `main` comptent ; celles de la PR sont listées dans le résumé, non appliquées. Le fichier est protégé contre les écritures de l'agent.

### Scripts de banc

Pour lancer une commande de test qui consomme des identifiants de banc local (`.banc/*.env`) sans que l'agent les lise, l'utilisateur déclare dans `.garde-secret-exceptions` cinq directives (un premier mot `script`, `masque`, `filtre`, `depend` ou `exige` ; ce ne sont ni des exceptions ni des lignes invalides) :

```
script scripts/captures-banc.sh <sha256> 2026-11-04 captures Playwright du banc local
masque .banc/*.env 2026-11-04 identifiants jetables du banc local
filtre scripts/captures-banc.sh tests/e2e/*.spec.ts 2026-11-26 une cible à la fois
depend scripts/captures-banc.sh tests/e2e/session.ts <sha256> 2026-11-26 lancé par le script
depend scripts/captures-banc.sh tests/e2e/lib <sha256> 2026-11-26 modules importés (dossier)
depend scripts/captures-banc.sh package.json <sha256> 2026-11-26 commande npm run
exige scripts/captures-banc.sh web/* 2026-11-26 interface web
exige scripts/captures-banc.sh packages/kit/* 2026-11-26 composants partagés
```

(les globs `tests/e2e/*.spec.ts`, `web/*` et `packages/kit/*` ne sont que des exemples : le kit ne contient aucun chemin de projet.)

- `script <chemin> <sha256> <AAAA-MM-JJ> <raison>` : chemin relatif à la racine (`[A-Za-z0-9._/-]+`, sans `..`), empreinte complète de 64 hex donnée par `sha256sum <chemin>`. Empreinte ou date mal formée : exécution refusée.
- `masque <glob> <AAAA-MM-JJ> <raison>` : les valeurs de ces fichiers (clés au nom de secret : `PASSW`, `TOKEN`…, comme pour `.env`) rejoignent les valeurs masquées dans toute sortie.
- `filtre <script> <glob> <AAAA-MM-JJ> <raison>` : `<script>` est le chemin d'une directive `script` du même fichier ; le dernier composant du glob contient exactement un `*` et aucun `?`, `[` ou `]`. Le nom d'une cible est la partie couverte par le `*` (`*.spec.ts` sur `connexion.spec.ts` donne `connexion`) ; seuls les noms qui valent `[a-z0-9][a-z0-9-]*` sont admis. Plusieurs lignes pour un même script : union. La liste est relue à chaque appel. Ligne mal formée ou script non déclaré : avertissement, aucun argument admis. Le nom est passé au script en `$1` (à citer `"$1"` dans le script).

- `depend <script> <chemin> <sha256> <AAAA-MM-JJ> <raison>` : fichiers ou dossiers dont dépend un script déclaré (`<script>` est le chemin d'une directive `script` du même fichier, sinon la ligne est ignorée avec un avertissement). `<chemin>` : relatif, sans joker. Fichier : `sha256sum <chemin>` ; dossier : empreinte d'arbre (parcours sans exclusion, liens symboliques et fichiers spéciaux refusés, 1000 fichiers au plus), donnée par `--empreintes`. Plusieurs lignes par script, toutes vérifiées au lancement ; ligne mal formée : exécution refusée. Un script sans `depend` se comporte comme avant. L'agent garde le droit d'éditer les dépendances ; c'est le lancement qui est refusé tant que l'empreinte diverge (le message nomme les fichiers).

- `exige <script> <glob> <AAAA-MM-JJ> <raison>` : si le diff de la branche (`git diff --name-only --no-renames <base>...HEAD`) touche un fichier qui correspond au glob (`fnmatch` sur le chemin relatif ; `*` couvre aussi `/`, donc `web/*` couvre tout `web/`), le relecteur exige que la suite complète de `<script>` (directive `script` du même fichier, sinon la ligne est ignorée avec un avertissement) ait tourné, verte, sur le HEAD relu. Plusieurs lignes par script : union. Ligne mal formée : avertissement, ligne ignorée (le relecteur la signale en mineur). Sans directive `exige`, rien ne change.
  - `python3 hooks/garde-secret.py --exige [--base <ref>] [--depot <dossier>]` liste les scripts exigés et les premiers fichiers concernés, ou `aucun banc exigé` ; code 2 si la base est inconnue ou si ce n'est pas un dépôt git.
  - Le codeur lance la suite après son dernier commit et met au rapport `Banc : <script> — <N> réussis / <M> échecs sur <sha>`. L'orchestrateur recopie ces lignes dans le brief du relecteur ; si la ligne manque ou si son SHA diffère du HEAD, le relecteur relance la suite lui-même. Lancement impossible : bloquant « banc exigé non lancé » ; suite rouge : bloquant « banc rouge », sans échappatoire (une suite rouge sur `main` bloque toute PR qui touche les globs). `livrer` refuse s'il n'a pas de ligne verte sur le HEAD, et ajoute à la PR une section Banc : `Banc : <N> réussis / <M> échecs sur <sha court>`.
  - Limite : aucun hook n'écrit de trace d'exécution ; la ligne `Banc :` du codeur n'est pas vérifiable (seul son SHA est comparé au HEAD), seule une exécution par le relecteur l'est. Suite possible, non faite : un job CI qui lance le banc sur un runner dédié.

Flux de mise à jour des dépendances : l'agent modifie une dépendance, le lancement est refusé ; l'utilisateur relit le diff, lance `python3 hooks/garde-secret.py --empreintes [--depot <dossier>]` (affiche les lignes `script` et `depend` à jour, signale les chemins absents et les scripts sans `depend`, code 1 s'il y a un écart, n'écrit jamais le fichier) et recopie les lignes. Conseils : épingler la fermeture des imports et le `package.json` des commandes `npm run` ; pour Python, épingler le dossier et lancer avec `PYTHONDONTWRITEBYTECODE=1` (un `.pyc` planté peut remplacer un `.py` épinglé).

Flux : l'agent écrit le script ; l'utilisateur le relit, calcule l'empreinte et l'ajoute ; toute modification du script oblige à mettre l'empreinte à jour. Le hook ne laisse passer que l'invocation `[cd <racine> && ]scripts/banc.sh|./scripts/banc.sh[ <filtre>][ 2>&1][ | tail|head|grep <args sûrs>]` (arguments du filtre de lecture sans `$ ` ; & | > <`, aucun saut de ligne, préfixe ni interpréteur), où `<filtre>` est au plus un nom de cible déclaré par `filtre`, séparé par des espaces ou tabulations ; depuis la racine du dépôt, sans lien symbolique, si l'empreinte correspond et si toute URL du script vise `127.0.0.1`, `localhost` ou `[::1]`. Toute autre commande Bash qui cite le script est refusée (`cat` compris : l'outil Read reste permis) ; Edit et Write du script sont refusés ; la lecture directe de `.banc/*.env` reste bloquée.

Mention tolérée : citer le nom du script dans le texte entre guillemets simples, ou doubles sans `$`, backtick ni `\`, d'un `gh issue|pr create|edit|comment` ou d'un `git commit` n'est pas refusé, à condition que le reste de la commande n'ait ni `; & | < > ( ) $ ` \ #` ni saut de ligne et ne cite pas le script. Un segment entre guillemets doit être séparé par un blanc : `--body="…"`, `-m"…"` ou `'banc.sh'x` sont refusés (écrire `--body "…"`, `-m "…"`). Les autres commandes (`echo`, `printf`, heredoc, `gh -R o/r issue create`) restent refusées : passer par `--body-file`.

Résiduels assumés : l'agent peut créer un fichier qui correspond au glob d'un `filtre` et ajouter ainsi un nom à la liste (l'argument reste un jeton `[a-z0-9-]`, sans effet sur le shell) ; le script épinglé, relu par l'utilisateur, décide seul de ce qu'il fait de `$1` ; un script non déclaré qui source un `.env` passe le filtre Pre (le hook ne lit pas les scripts), seul le masquage rattrape les valeurs connues affichées en clair ; ce qui n'est pas déclaré par `depend` (`node_modules`, environnement, interpréteur, fichiers oubliés) reste modifiable par l'agent, qui peut lui faire afficher une valeur encodée ou l'envoyer sur le réseau ; les cibles en `127.0.0.1` ne sont pas vérifiables (seul le texte du script épinglé est contrôlé) ; le script et ses dépendances peuvent être remplacés après le contrôle, avant ou pendant l'exécution (processus en arrière-plan, `mv` ou `git checkout` du dossier, et bash relit le script pendant qu'il s'exécute) ; une mention indirecte du script par variable (`f=scripts/banc.sh; bash $f`) n'est pas détectée.

## Verrouillage (à appliquer par l'utilisateur)

Les hooks protègent déjà les réglages Claude (`~/.claude/settings*.json`, `**/.claude/settings*.json`), `~/.claude/hooks/` et `~/.claude/plugins/`, `**/.github/workflows/`, `**/.garde-deps-exceptions` et `**/.garde-secret-exceptions` contre les écritures de l'agent (Edit, Write, MultiEdit, NotebookEdit, et les commandes Bash qui écrivent ou redirigent vers ces chemins, `claude plugin disable|uninstall` compris). Un hook se désactive depuis les réglages : pour verrouiller aussi cela, ajouter ce bloc à `~/.claude/settings.json` (13 règles `permissions.deny` ; `Edit(...)` couvre aussi l'outil Write) :

```json
{
  "permissions": {
    "deny": [
      "Edit(~/.claude/settings.json)",
      "Edit(~/.claude/settings.local.json)",
      "Edit(~/.claude/hooks/**)",
      "Edit(~/.claude/plugins/**)",
      "Edit(**/.claude/settings*.json)",
      "Edit(**/.github/workflows/**)",
      "Edit(**/.garde-deps-exceptions)",
      "Edit(**/.garde-secret-exceptions)",
      "Read(~/.ssh/**)",
      "Read(~/.config/gh/**)",
      "Read(**/.env)",
      "Read(**/.env.local)",
      "Read(**/.env.production)"
    ]
  }
}
```

À faire **après** la fusion de la PR qui introduit le contrôle (sinon elle n'aurait pas pu modifier les workflows). Sur GitHub, rendre les checks `deps / deps` et `tests / hooks` obligatoires sur `main` (Settings, Branches ou Rulesets, « Require status checks ») : réglage du dépôt, à faire à la main.

Pas de `Read(**/.env.*)` : un refus l'emporte sur tout et rendrait `.env.example` illisible.


## Briefs

- Le brief de l'orchestrateur au codeur, avec ou sans lots (`Objectif`, `Branche`, `Fichiers`, `Contraintes`, `Fait quand`) peut porter une ligne `Autorisations : <ce que l'utilisateur a explicitement autorisé, avec la date>` (`aucune` sinon), reportée de la mémoire de l'orchestrateur ; elle n'autorise pas à contourner un hook ou un refus : si une action reste refusée, le codeur s'arrête et le signale au rapport.
- Le brief de l'orchestrateur au relecteur reprend les lignes `Banc : <script> — … sur <sha>` du rapport du codeur, quand il y en a (voir « Scripts de banc »).

## Flux avec lots

À utiliser quand la spec se découpe en lots testables séparément ; sinon, le flux reste inchangé. Le format est l'item Lots de `agents/specs.md`.

- Un lot = un ou plusieurs commits verts suffixés `(L<n>)` sur `claude/<sujet>`, case cochée dans le dernier ; une seule PR ; un seul relecteur, à la fin. Un fichier imprévu mais nécessaire est ajouté à la ligne `Fichiers :` du lot (mineur pour le relecteur) ; les lockfiles et la config d'outil touchés sont listés d'avance.
- `> Coupure PR` se place là où une PR doit s'arrêter (obligatoire au-delà de 5 lots) ; si le brief arrête le codeur avant la prochaine coupure, il l'ajoute après le dernier lot traité. Le relecteur ignore le brief : le périmètre de la PR vient des cases et des coupures de la spec à HEAD.
- Avec `> Coupure PR` : livrer la première PR, attendre que l'utilisateur la fusionne, faire `/clear`, puis créer `claude/<sujet>-2` depuis `main` à jour ; le codeur reprend aux lots non cochés (les cases cochées sont arrivées dans `main` avec la fusion).

## Clôture et archivage

Toute spec porte sous son titre `Statut : en cours`. Dans le commit de son dernier lot (ou son dernier commit, sans lots), le codeur coche les critères d'acceptation remplis, passe la ligne à `Statut : livrée` et déplace la spec dans `docs/specs/archives/`. Avec `> Coupure PR`, seule la dernière PR archive. Le relecteur vérifie statut, cases et emplacement ; `livrer` lie la spec archivée.

Le statut n'a que deux valeurs, `en cours` et `livrée`. La validation de la spec est le feu vert de l'utilisateur à l'orchestrateur, pas un état : on n'écrit ni `validée` ni date. Le relecteur bloque toute autre valeur.

## Contre-test

Chaque critère d'acceptation se termine par `— test : <commande>` ; `(négatif)`, `(non-régression)` et `(fumée)` précisent sa nature (voir `agents/specs.md`). Le codeur écrit les tests d'abord et les voit échouer (`tests rouges avant : oui/non` au rapport).
Le relecteur lance `scripts/contre-test.sh [--base <ref>] [--fichiers <pathspec>]... -- <commande>` : il rejoue les fichiers de test nouveaux ou modifiés sur la `merge-base`, dans un clone jetable. Sorties : 0 rouge sur la base (attendu), 1 vert (les tests ne prouvent rien), 2 erreur, 3 aucun fichier de test.
En Rust, la base se compile dans `target/contre-test` (sauf `CARGO_TARGET_DIR` déjà défini), pour ne pas polluer le `target/` partagé ; en npm, les `node_modules` non suivis des sous-dossiers (workspaces) sont liés dans le clone comme celui de la racine.
Exceptions : cas `(non-régression)`, `Contre-test : non applicable (raison)` (refactor, doc). Limites : tests écrits dans le fichier source (non séparables) ; base qui échoue pour une raison d'environnement (contre-test non concluant).

## Tickets

Si la spec répond à des tickets du dépôt, elle porte sous le statut la ligne `Tickets : #9, #10`. `livrer` ajoute alors au corps de la PR une section « Tickets » : `Closes #n` pour la PR qui termine la spec (archivée), `Refs #n` pour les autres ; GitHub ferme les tickets à la fusion.

Le skill `/kit-perso:ticket "<constat>"` (invocation par l'utilisateur seul, effet de bord public) ouvre un ticket du dépôt courant, ou commente un des tickets dont l'utilisateur est l'auteur (`--author @me`) en cas de doublon. Corps en quatre lignes : **Constat**, **Proposition**, **Source**, **Reproduire**.

`garde-git` n'admet de `gh issue` que `view`, `list`, `ls`, `status`, `create`, `new`, `comment` et `edit` (milestone seul : `--milestone`, `--remove-milestone`) (liste blanche : une sous-commande future est bloquée). Fermer, modifier, supprimer, rouvrir ou transférer un ticket reste à l'utilisateur. `create`, `new`, `comment` et `edit` refusent `-R`/`--repo` (sauf vers un dépôt `stanixia-dev/<nom>`, constante `PROPRIETAIRES_TICKETS`), `--edit-last`, `--delete-last` et toute URL (autre dépôt) ; `view` et `list` avec `-R` restent admis.

`garde-git` normalise les options de `gh` (`-R`/`--repo` avant ou entre les sous-commandes) et bloque, pour `git push`, `-c`/`--config-env`/`--exec-path` (configuration à la volée), `--all`/`--branches`, une refspec avec `*`, `HEAD` ou `@` quand la branche courante est `main`, ainsi que les abréviations d'options dangereuses (`--force-w`, `--del`, `--no-veri`…) ; `-c alias.*` est bloqué pour toute sous-commande.

Milestones : `gh api repos/{owner}/{repo}/milestones -f title=v1` (créer), `gh api -X PATCH repos/{owner}/{repo}/milestones/3 -f state=closed` (fermer), `gh issue edit <n> -m v1`, `gh pr edit <n> --milestone v1`.

`garde-git` bloque aussi `gh repo set-default` et `gh alias set|import`, et `create` refuse `--parent`, `--blocking` et `--blocked-by`.

Résiduels : `git config alias.x …` puis `git x` (l'alias n'est pas résolu) ; `git -C <dépôt>` ou `--git-dir` vers un dépôt dont la configuration exécute du code (hooks, `core.sshCommand`) ; `cd` vers un autre dépôt avant `gh issue create` ; `gh api` : lecture libre, écriture limitée aux milestones de tout dépôt accessible au jeton ; l'auteur du ticket commenté n'est pas vérifié par un hook (règle du skill).

## Mémoire

La mémoire automatique de Claude Code (`~/.claude/projects/<projet>/memory/`) ne doit garder que le durable. Le kit fournit la règle, que l'utilisateur colle dans son `~/.claude/CLAUDE.md` (le kit n'y touche pas) :

```
## Mémoire
- La mémoire garde le durable : décisions et leur raison, conventions, autorisations explicites (avec date), chantier en cours en 2-3 lignes, backlog court.
- Pas de numéros de PR, de lots ni d'historique de livraison : GitHub (PR, milestones) les garde.
- Une ligne d'index de MEMORY.md tient en 150 caractères au plus ; un fichier mémoire, en 3 Ko au plus.
- À la clôture d'un chantier (milestone fermé) : lance /kit-perso:archiver-memoire, puis remets la mémoire du chantier à 2-3 lignes.
```

L'archive est une copie du dossier `memory/` dans `historique/<date>-memoire/` (suffixe `-2`, `-3`… si elle existe), à côté de `memory/` : Claude Code ne la charge jamais, on restaure par un `cp -r`. Le dossier mémoire est celui du dépôt (partagé entre worktrees) ; `--memoire` est prioritaire et le dossier doit s'appeler `memory`.

Le skill `/kit-perso:archiver-memoire` (invocable par le modèle : il n'écrit qu'une copie) lance le script, montre les lignes d'index de plus de 150 caractères et les fichiers de plus de 3 Ko, puis propose une réécriture au durable.
Il n'écrit dans `memory/` qu'après un « oui » explicite et ne supprime rien.

Tests : `bash tests/test_archiver_memoire.sh` (appelé par `tests/test_hooks.sh`), `HOME` et dossiers mémoire jetables.

## Cache du plugin

`~/.claude/plugins/cache/kit-perso/kit-perso/` garde une copie de chaque version installée ; elles s'accumulent (disque de 58 Go sur la devbox). Nettoyage manuel, à faire par l'utilisateur (le dossier est protégé contre l'agent) : lister, repérer la version active (`claude plugin list`), puis supprimer seulement les dossiers des anciennes versions.

```bash
ls ~/.claude/plugins/cache/kit-perso/kit-perso/
claude plugin list                      # version active de kit-perso
rm -rf ~/.claude/plugins/cache/kit-perso/kit-perso/<ancienne-version>
```

Une version à la fois, jamais la version active ni un `rm -rf` sur `~/.claude` ou sur le dossier parent ; relancer Claude Code ensuite pour vérifier.

## Bascule depuis ~/.claude

1. Installer le plugin (voir ci-dessus) et vérifier avec `claude plugin details`.
2. Supprimer le doublon des agents et de `rappel-clear` :
   `mkdir -p ~/.claude/sauvegarde-kit-perso && mv ~/.claude/agents/*.md ~/.claude/hooks/rappel-clear.py ~/.claude/sauvegarde-kit-perso/`, puis retirer l'entrée `rappel-clear` de `~/.claude/settings.json`.
3. Garder `garde-git` dans `~/.claude` (fichier et entrée de `settings.json`) comme filet si le plugin est désactivé : il ne fait que lire son entrée et bloquer, donc l'exécuter deux fois est sans danger. Garder aussi `rtk hook claude`.
4. Redémarrer Claude Code ; `git push origin main` doit être bloqué.
5. Mettre à jour la table d'orchestration de `~/.claude/CLAUDE.md` avec les noms `kit-perso:<agent>`.

Retour arrière : `claude plugin disable kit-perso@kit-perso`, puis remettre les fichiers de `~/.claude/sauvegarde-kit-perso/` et l'entrée `rappel-clear` de `settings.json`.
