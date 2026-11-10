# kit-perso

Plugin Claude Code personnel de stanixia-dev, qui sert aussi de marketplace. Il regroupe les agents (specs, codeur, relecteur, explorateur), les hooks (garde-git, garde-deps, verifie-manifestes, garde-secret, rappel-clear) et les skills (livrer, ticket, ci-projet) à installer une fois pour tous les projets, au lieu de les recopier dans chaque `~/.claude`.

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

Vérification : `claude plugin details kit-perso@kit-perso` liste 4 agents, 3 skills, 5 hooks (PreToolUse, PostToolUse, PostToolUseFailure, Stop, SubagentStop). Les agents s'appellent `kit-perso:codeur`, etc. ; les skills `/kit-perso:livrer`, `/kit-perso:ticket` et `/kit-perso:ci-projet`.

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

**Après la fusion des workflows** : `deps` ne tourne qu'une fois les workflows sur `main`. Ensuite, Settings > Rules > Rulesets > New branch ruleset, cible `main`, Require status checks : `deps` et les jobs de tests générés (`rust`, `node`, `python`) ; ce sont les noms de jobs, affichés dans la PR `kit-perso-deps / deps` et `kit-perso-tests / rust`, etc.

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
| Pre Bash : script de banc | laisse passer l'invocation exacte d'un script déclaré et intact ; refuse toute autre mention | — | passe |
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

Pour lancer une commande de test qui consomme des identifiants de banc local (`.banc/*.env`) sans que l'agent les lise, l'utilisateur déclare dans `.garde-secret-exceptions` deux directives (un premier mot `script` ou `masque` ; ce ne sont ni des exceptions ni des lignes invalides) :

```
script scripts/captures-banc.sh <sha256> 2026-11-04 captures Playwright du banc local
masque .banc/*.env 2026-11-04 identifiants jetables du banc local
```

- `script <chemin> <sha256> <AAAA-MM-JJ> <raison>` : chemin relatif à la racine (`[A-Za-z0-9._/-]+`, sans `..`), empreinte complète de 64 hex donnée par `sha256sum <chemin>`. Empreinte ou date mal formée : exécution refusée.
- `masque <glob> <AAAA-MM-JJ> <raison>` : les valeurs de ces fichiers (clés au nom de secret : `PASSW`, `TOKEN`…, comme pour `.env`) rejoignent les valeurs masquées dans toute sortie.

Flux : l'agent écrit le script ; l'utilisateur le relit, calcule l'empreinte et l'ajoute ; toute modification du script oblige à mettre l'empreinte à jour. Le hook ne laisse passer que la commande exacte `scripts/banc.sh` ou `./scripts/banc.sh` (aucun argument, redirection, pipe, préfixe ni interpréteur), depuis la racine du dépôt, sans lien symbolique, si l'empreinte correspond et si toute URL du script vise `127.0.0.1`, `localhost` ou `[::1]`. Toute autre commande Bash qui cite le script est refusée (`cat` compris : l'outil Read reste permis) ; Edit et Write du script sont refusés ; la lecture directe de `.banc/*.env` reste bloquée.

Résiduels assumés : un script non déclaré qui source un `.env` passe le filtre Pre (le hook ne lit pas les scripts), seul le masquage rattrape les valeurs connues affichées en clair ; le code lancé par le script épinglé (`package.json`, config Playwright, tests, `node_modules/.bin`) reste modifiable par l'agent, qui peut lui faire afficher une valeur encodée ou l'envoyer sur le réseau ; les cibles en `127.0.0.1` ne sont pas vérifiables (seul le texte du script épinglé est contrôlé) ; le script peut être remplacé avant ou pendant l'exécution (processus en arrière-plan, `mv` ou `git checkout` du dossier, et bash relit le script pendant qu'il s'exécute) ; une mention indirecte du script par variable (`f=scripts/banc.sh; bash $f`) n'est pas détectée.

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


## Flux avec lots

À utiliser quand la spec se découpe en lots testables séparément ; sinon, le flux reste inchangé. Le format est l'item Lots de `agents/specs.md`.

- Un lot = un ou plusieurs commits verts suffixés `(L<n>)` sur `claude/<sujet>`, case cochée dans le dernier ; une seule PR ; un seul relecteur, à la fin. Un fichier imprévu mais nécessaire est ajouté à la ligne `Fichiers :` du lot (mineur pour le relecteur) ; les lockfiles et la config d'outil touchés sont listés d'avance.
- `> Coupure PR` se place là où une PR doit s'arrêter (obligatoire au-delà de 5 lots) ; si le brief arrête le codeur avant la prochaine coupure, il l'ajoute après le dernier lot traité. Le relecteur ignore le brief : le périmètre de la PR vient des cases et des coupures de la spec à HEAD.
- Avec `> Coupure PR` : livrer la première PR, attendre que l'utilisateur la fusionne, faire `/clear`, puis créer `claude/<sujet>-2` depuis `main` à jour ; le codeur reprend aux lots non cochés (les cases cochées sont arrivées dans `main` avec la fusion).

## Clôture et archivage

Toute spec porte sous son titre `Statut : en cours`. Dans le commit de son dernier lot (ou son dernier commit, sans lots), le codeur coche les critères d'acceptation remplis, passe la ligne à `Statut : livrée` et déplace la spec dans `docs/specs/archives/`. Avec `> Coupure PR`, seule la dernière PR archive. Le relecteur vérifie statut, cases et emplacement ; `livrer` lie la spec archivée.

Le statut n'a que deux valeurs, `en cours` et `livrée`. La validation de la spec est le feu vert de l'utilisateur à l'orchestrateur, pas un état : on n'écrit ni `validée` ni date. Le relecteur bloque toute autre valeur.

## Tickets

Si la spec répond à des tickets du dépôt, elle porte sous le statut la ligne `Tickets : #9, #10`. `livrer` ajoute alors au corps de la PR une section « Tickets » : `Closes #n` pour la PR qui termine la spec (archivée), `Refs #n` pour les autres ; GitHub ferme les tickets à la fusion.

Le skill `/kit-perso:ticket "<constat>"` (invocation par l'utilisateur seul, effet de bord public) ouvre un ticket du dépôt courant, ou commente un des tickets dont l'utilisateur est l'auteur (`--author @me`) en cas de doublon. Corps en quatre lignes : **Constat**, **Proposition**, **Source**, **Reproduire**.

`garde-git` n'admet de `gh issue` que `view`, `list`, `ls`, `status`, `create`, `new`, `comment` et `edit` (milestone seul : `--milestone`, `--remove-milestone`) (liste blanche : une sous-commande future est bloquée). Fermer, modifier, supprimer, rouvrir ou transférer un ticket reste à l'utilisateur. `create`, `new`, `comment` et `edit` refusent `-R`/`--repo` (sauf vers un dépôt `stanixia-dev/<nom>`, constante `PROPRIETAIRES_TICKETS`), `--edit-last`, `--delete-last` et toute URL (autre dépôt) ; `view` et `list` avec `-R` restent admis.

`garde-git` normalise les options de `gh` (`-R`/`--repo` avant ou entre les sous-commandes) et bloque, pour `git push`, `-c`/`--config-env`/`--exec-path` (configuration à la volée), `--all`/`--branches`, une refspec avec `*`, `HEAD` ou `@` quand la branche courante est `main`, ainsi que les abréviations d'options dangereuses (`--force-w`, `--del`, `--no-veri`…) ; `-c alias.*` est bloqué pour toute sous-commande.

Milestones : `gh api repos/{owner}/{repo}/milestones -f title=v1` (créer), `gh api -X PATCH repos/{owner}/{repo}/milestones/3 -f state=closed` (fermer), `gh issue edit <n> -m v1`, `gh pr edit <n> --milestone v1`.

`garde-git` bloque aussi `gh repo set-default` et `gh alias set|import`, et `create` refuse `--parent`, `--blocking` et `--blocked-by`.

Résiduels : `git config alias.x …` puis `git x` (l'alias n'est pas résolu) ; `git -C <dépôt>` ou `--git-dir` vers un dépôt dont la configuration exécute du code (hooks, `core.sshCommand`) ; `cd` vers un autre dépôt avant `gh issue create` ; `gh api` : lecture libre, écriture limitée aux milestones de tout dépôt accessible au jeton ; l'auteur du ticket commenté n'est pas vérifié par un hook (règle du skill).

## Bascule depuis ~/.claude

1. Installer le plugin (voir ci-dessus) et vérifier avec `claude plugin details`.
2. Supprimer le doublon des agents et de `rappel-clear` :
   `mkdir -p ~/.claude/sauvegarde-kit-perso && mv ~/.claude/agents/*.md ~/.claude/hooks/rappel-clear.py ~/.claude/sauvegarde-kit-perso/`, puis retirer l'entrée `rappel-clear` de `~/.claude/settings.json`.
3. Garder `garde-git` dans `~/.claude` (fichier et entrée de `settings.json`) comme filet si le plugin est désactivé : il ne fait que lire son entrée et bloquer, donc l'exécuter deux fois est sans danger. Garder aussi `rtk hook claude`.
4. Redémarrer Claude Code ; `git push origin main` doit être bloqué.
5. Mettre à jour la table d'orchestration de `~/.claude/CLAUDE.md` avec les noms `kit-perso:<agent>`.

Retour arrière : `claude plugin disable kit-perso@kit-perso`, puis remettre les fichiers de `~/.claude/sauvegarde-kit-perso/` et l'entrée `rappel-clear` de `settings.json`.
