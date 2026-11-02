# kit-perso

Plugin Claude Code personnel de stanixia-dev, qui sert aussi de marketplace. Il regroupe les agents (specs, codeur, relecteur, explorateur), les hooks (garde-git, garde-deps, verifie-manifestes, garde-secret, rappel-clear) et les skills (livrer) à installer une fois pour tous les projets, au lieu de les recopier dans chaque `~/.claude`.

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

Vérification : `claude plugin details kit-perso@kit-perso` liste 4 agents, 1 skill, 5 hooks (PreToolUse, PostToolUse, PostToolUseFailure, Stop, SubagentStop). Les agents s'appellent `kit-perso:codeur`, etc. ; le skill `/kit-perso:livrer`.

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

- Skill : `skills/<nom-kebab-fr>/SKILL.md`, `name` = nom du dossier, `description` en français (ce qu'il fait + « À utiliser quand… »), `disable-model-invocation: true` dès qu'il y a un effet de bord (push, suppression, réseau). Fichiers annexes dans le même dossier.
- Agent : `agents/<nom>.md` avec `name`, `description`, `model`, `effort`, `tools` (liste minimale) ; rapport final borné en lignes.
- Hook : script dans `hooks/`, déclaré dans `hooks/hooks.json` via `${CLAUDE_PLUGIN_ROOT}`, cas ajouté à `tests/test_hooks.sh`.
- Chaque ajout : montée MINEURE, entrée au CHANGELOG, et `claude plugin validate --strict .` vert.

## Contrôle des dépendances

Règles appliquées à chaque paquet ajouté ou modifié (cargo, npm/pnpm/yarn, pip/uv/poetry) : bloque une licence non permissive (hors MIT, Apache-2.0, BSD, ISC, Zlib, 0BSD, Unlicense, CC0-1.0), une faille OSV connue, un paquet déprécié ou yanked, une dernière publication de plus de 2 ans. Avertit pour MPL/LGPL, les avis RustSec informatifs et les registres injoignables.
Un paquet refusé, c'est l'utilisateur qui l'ajoute lui-même s'il l'accepte. Le relecteur lance `hooks/verifie-manifestes.py --base main` sur le diff.

Trois couches, de la plus rapide à la plus sûre :

1. **Hook Bash `garde-deps` (PreToolUse)** : filtre rapide qui lit la commande (`cargo add`, `npm i`, `pip install`…, y compris dans `bash -c`, heredocs, substitutions). Il se contourne (script écrit puis exécuté, chemin obfusqué) : ce n'est pas la barrière.
2. **Contrôle par résultat en local (PostToolUse, Stop, SubagentStop)** : `hooks/verifie-manifestes.py` compare les manifestes (`Cargo.toml`, `package.json`, `pyproject.toml`, `requirements*.txt`) et lockfiles (`Cargo.lock`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `uv.lock`, `poetry.lock`) à `main` et applique les règles aux paquets ajoutés, quelle que soit la façon dont ils sont arrivés. Sans manifeste modifié, il sort aussitôt, sans réseau. Stop bloque une fois puis avertit (`stop_hook_active`).
3. **CI, job `tests / deps`** : même script en `--ci`, lancé en `pull_request_target` : le workflow est celui de `main`, la PR ne peut donc ni le modifier ni le retirer, et aucun code de la PR n'est exécuté (ses manifestes sont lus comme données par git). Ce job ne tourne qu'une fois la PR qui l'introduit fusionnée dans `main`.

Les dépendances **transitives** (lockfiles) ne sont examinées que par OSV (une seule requête par lot) et donnent un avertissement, jamais un blocage : licence et âge ne sont pas vérifiés, trop de requêtes.
Hors réseau, les couches locales sont *fail-open* (avertissement « vérification impossible ») ; la CI est *fail-closed* (registre injoignable, fichier illisible ou erreur imprévue = blocage ; une relance coûte peu).

Tests : `bash tests/test_hooks.sh` (appelle `tests/test_manifestes.sh`), hors réseau (réponses simulées dans `tests/fixtures/garde-deps.json`, dépôts git jetables) ; la CI GitHub les lance sur chaque PR et push sur `main`.

### Exceptions

`.garde-deps-exceptions` (racine du dépôt) autorise un paquet refusé : une ligne `<registre> <nom> <version|*> <AAAA-MM-JJ> <raison>` (`crates`, `npm` ou `pypi`), `#` pour un commentaire. En local, le blocage devient un avertissement `(exception du … : …)`. En CI, seules les exceptions déjà sur `main` comptent ; celles qu'ajoute la PR sont listées dans le résumé du job, non appliquées. Ajouter une exception = commit de l'utilisateur sur `main`, puis relancer la CI de la PR.

## Contrôle des secrets

Applique les règles « Secrets » du CLAUDE.md global : l'agent ne lit pas `~/.ssh/`, `~/.config/gh/` ni les `.env`, n'affiche et n'écrit aucun token ou mot de passe, n'en commite aucun. `hooks/garde-secret.py` n'a aucune dépendance. Aucun de ses messages ne contient une valeur : seulement le chemin, le commit, le type de secret et une empreinte (12 premiers hex de `sha256`).

Le filtre de commandes reste une aide ; les barrières sont le **masquage de la sortie** et le **scan du résultat git** :

1. **PreToolUse** (`--hook pre`, `onFailure: "block"`) : refuse l'accès à un chemin protégé (Read, Grep, Edit, Write, MultiEdit, NotebookEdit, et chaque chemin cité dans une commande Bash, y compris dans `bash -c`, heredocs et substitutions), un secret dans le contenu écrit ou dans le texte d'une commande, `gh auth token` et `git credential fill`. Avant `git commit`, `git push` et `gh pr create`, il scanne le dépôt.
2. **PostToolUse** (Bash, Read, Grep, BashOutput, TaskOutput) : remplace chaque secret reconnu par `[masqué:<type>:<empreinte>]` dans la sortie (`updatedToolOutput`), ainsi que les valeurs de `os.environ` et des `.env` du dossier dont le nom évoque un secret. PostToolUseFailure : alerte seule.
3. **Stop, SubagentStop** : scan du dépôt, bloque une fois puis avertit.
4. **CI** : `verifie-manifestes.py --ci` (job `tests / deps`) enchaîne `garde-secret.py --ci`, depuis `main` : la PR ne peut ni l'altérer ni le retirer. Le secret s'affiche donc sous le nom de check `deps`.

Le scan lit chaque commit un par un (un secret retiré au commit suivant reste dans l'historique), plus la copie de travail et les fichiers non suivis. Il refuse aussi des noms de fichiers (`.env`, `id_rsa`, `.p12`…).

| Contrôle | Signature | Générique | Échec du hook |
|---|---|---|---|
| Pre : chemin protégé | bloque | — | bloque |
| Pre : contenu écrit | bloque | avertit | bloque |
| Pre Bash : chemin ou texte de la commande | bloque | — | bloque |
| Pre Bash : scan avant commit, push, PR | bloque | avertit ; scan incomplet (budget de 10 s) : avertit, mais bloque `git push` et `gh pr create` | bloque |
| Post : sortie | masque + alerte | — | sortie intacte |
| Stop, SubagentStop | bloque une fois, puis avertit | — | passe |
| CI (`--ci`) | bloque | bloque | bloque |

Signature : formats connus (GitHub, GitLab, Anthropic, OpenAI, AWS, Google, Slack, Stripe, npm, PyPI, clés privées). Générique : JWT, URL à mot de passe, affectation `password = "…"`, écartés dans la doc et les tests.

Résiduels assumés : un script qui lit un fichier protégé et transforme la valeur avant de l'afficher ; un mot de passe sans signature, absent des valeurs connues ; la sortie d'une commande en échec, non réécrivable (alerte seule) ; `cd x && git push` (le scan local vise le dossier courant, CI et Stop rattrapent) ; un chemin contenant un blanc ; un jeton encodé en UTF-16 (les motifs lisent du texte UTF-8) ; `gh gist create` d'un fichier non protégé qui contient un secret hors signature. Le bac à sable système n'est pas utilisé. Purge d'historique et révocation : à la charge de l'utilisateur. Secours : `claude plugin disable kit-perso@kit-perso`.

Tests : `bash tests/test_secrets.sh` (appelé par `tests/test_hooks.sh`), `HOME` jetable, jetons construits à l'exécution.

### Exceptions de secrets

`.garde-secret-exceptions` (racine du dépôt) : une ligne `<glob relatif> <empreinte|*> <AAAA-MM-JJ> <raison>`, `#` pour un commentaire. L'empreinte est celle affichée par le message de blocage, jamais la valeur ; `*` couvre tout le chemin, lecture comprise. Sans effet hors de la racine du dépôt ni sur `~/.ssh` et autres identifiants personnels. En CI, seules les exceptions déjà sur `main` comptent ; celles de la PR sont listées dans le résumé, non appliquées. Le fichier est protégé contre les écritures de l'agent.

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

À faire **après** la fusion de la PR qui introduit le contrôle (sinon elle n'aurait pas pu modifier les workflows). Sur GitHub, rendre le check `tests / deps` obligatoire sur `main` (Settings, Branches ou Rulesets, « Require status checks ») : réglage du dépôt, à faire à la main.

Pas de `Read(**/.env.*)` : un refus l'emporte sur tout et rendrait `.env.example` illisible.

Piste non retenue ici : le bac à sable Bash de Claude Code (`sandbox.enabled: true`, `allowUnsandboxedCommands: false`) appliquerait ces règles `deny` aux écritures Bash au niveau du système, ce qui couvrirait les contournements locaux résiduels ; à vérifier sur la version installée.

## Flux avec lots

À utiliser quand la spec se découpe en lots testables séparément ; sinon, le flux reste inchangé. Le format est l'item 8 de `agents/specs.md`.

- Un lot = un commit vert sur `claude/<sujet>`, coché dans la spec ; une seule PR ; un seul relecteur, à la fin.
- Avec `> Coupure PR` : livrer la première PR, attendre que l'utilisateur la fusionne, faire `/clear`, puis créer `claude/<sujet>-2` depuis `main` à jour ; le codeur reprend aux lots non cochés (les cases cochées sont arrivées dans `main` avec la fusion).

## Clôture et archivage

Toute spec porte sous son titre `Statut : en cours`. Dans le commit de son dernier lot (ou son dernier commit, sans lots), le codeur coche les critères d'acceptation remplis, passe la ligne à `Statut : livrée` et déplace la spec dans `docs/specs/archives/`. Avec `> Coupure PR`, seule la dernière PR archive. Le relecteur vérifie statut, cases et emplacement ; `livrer` lie la spec archivée.

## Bascule depuis ~/.claude

1. Installer le plugin (voir ci-dessus) et vérifier avec `claude plugin details`.
2. Supprimer le doublon des agents et de `rappel-clear` :
   `mkdir -p ~/.claude/sauvegarde-kit-perso && mv ~/.claude/agents/*.md ~/.claude/hooks/rappel-clear.py ~/.claude/sauvegarde-kit-perso/`, puis retirer l'entrée `rappel-clear` de `~/.claude/settings.json`.
3. Garder `garde-git` dans `~/.claude` (fichier et entrée de `settings.json`) comme filet si le plugin est désactivé : il ne fait que lire son entrée et bloquer, donc l'exécuter deux fois est sans danger. Garder aussi `rtk hook claude`.
4. Redémarrer Claude Code ; `git push origin main` doit être bloqué.
5. Mettre à jour la table d'orchestration de `~/.claude/CLAUDE.md` avec les noms `kit-perso:<agent>`.

Retour arrière : `claude plugin disable kit-perso@kit-perso`, puis remettre les fichiers de `~/.claude/sauvegarde-kit-perso/` et l'entrée `rappel-clear` de `settings.json`.
