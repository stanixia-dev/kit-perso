# kit-perso

Plugin Claude Code personnel de stanixia-dev, qui sert aussi de marketplace. Il regroupe les agents (specs, codeur, relecteur, explorateur), les hooks de garde-fous git (garde-git, rappel-clear) et les skills (livrer) à installer une fois pour tous les projets, au lieu de les recopier dans chaque `~/.claude`.

## Installation

En une ligne (portée utilisateur, tous projets) :

```
/plugin install kit-perso --marketplace stanixia-dev/kit-perso
```

Ou en deux temps :

```
/plugin marketplace add stanixia-dev/kit-perso
/plugin install kit-perso@kit-perso
```

Vérification : `claude plugin details kit-perso@kit-perso` liste 4 agents, 1 skill, 2 hooks. Les agents s'appellent `kit-perso:codeur`, etc. ; le skill `/kit-perso:livrer`.

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

Tests : `bash tests/test_hooks.sh`.

## Bascule depuis ~/.claude

1. Installer le plugin (voir ci-dessus) et vérifier avec `claude plugin details`.
2. Supprimer le doublon des agents et de `rappel-clear` :
   `mkdir -p ~/.claude/sauvegarde-kit-perso && mv ~/.claude/agents/*.md ~/.claude/hooks/rappel-clear.py ~/.claude/sauvegarde-kit-perso/`, puis retirer l'entrée `rappel-clear` de `~/.claude/settings.json`.
3. Garder `garde-git` dans `~/.claude` (fichier et entrée de `settings.json`) comme filet si le plugin est désactivé : il ne fait que lire son entrée et bloquer, donc l'exécuter deux fois est sans danger. Garder aussi `rtk hook claude`.
4. Redémarrer Claude Code ; `git push origin main` doit être bloqué.
5. Mettre à jour la table d'orchestration de `~/.claude/CLAUDE.md` avec les noms `kit-perso:<agent>`.

Retour arrière : `claude plugin disable kit-perso@kit-perso`, puis remettre les fichiers de `~/.claude/sauvegarde-kit-perso/` et l'entrée `rappel-clear` de `settings.json`.
