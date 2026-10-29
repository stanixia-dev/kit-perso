# kit-perso

Plugin Claude Code personnel de stanixia-dev, qui sert aussi de marketplace. Il regroupe les agents (specs, codeur, relecteur, explorateur), les hooks (garde-git, garde-deps, rappel-clear) et les skills (livrer) à installer une fois pour tous les projets, au lieu de les recopier dans chaque `~/.claude`.

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

Vérification : `claude plugin details kit-perso@kit-perso` liste 4 agents, 1 skill, 3 hooks. Les agents s'appellent `kit-perso:codeur`, etc. ; le skill `/kit-perso:livrer`.

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

Le hook `garde-deps` examine les ajouts directs de paquets (cargo, npm/pnpm/yarn, pip/uv) et bloque : licence non permissive (hors MIT, Apache-2.0, BSD, ISC, Zlib, 0BSD, Unlicense, CC0-1.0), faille OSV connue, paquet déprécié ou version yanked, dernière publication de plus de 2 ans.
Il avertit pour MPL/LGPL, les avis RustSec informatifs et les registres injoignables (fail-open hors réseau).
Un paquet refusé, c'est l'utilisateur qui l'ajoute lui-même s'il l'accepte. Le relecteur applique les mêmes règles aux manifestes du diff.

Tests : `bash tests/test_hooks.sh`, hors réseau (réponses simulées dans `tests/fixtures/garde-deps.json`) ; la CI GitHub les lance sur chaque PR et push sur `main`.

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
