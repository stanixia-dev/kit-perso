# Spec — plugin Claude Code « kit-perso »
Statut : livrée

## 1. Objectif
Faire du dépôt `stanixia-dev/kit-perso` à la fois un plugin Claude Code et sa propre marketplace, pour centraliser agents, skills et hooks personnels et les installer sur tout projet via `/plugin marketplace add stanixia-dev/kit-perso` puis `/plugin install kit-perso@kit-perso`. On y migre les 4 agents et les 2 hooks de `~/.claude`, on ajoute un skill d'exemple et une convention d'ajout.

## 2. Hors périmètre
- `~/.claude/CLAUDE.md` reste où il est (le format plugin ne charge pas de CLAUDE.md) ; le hook `rtk hook claude` reste dans `~/.claude/settings.json` (outil propre à la devbox).
- Pas de dossier `commands/` : les skills s'invoquent aussi en `/kit-perso:<nom>`, une seule convention suffit.
- Pas de MCP, d'icône, de CI (`.github/workflows/`), de mise à jour automatique en arrière-plan, de publication publique.
- Le codeur ne touche **pas** à `~/.claude` : la bascule (section 4-B) est faite à la main par l'utilisateur après fusion.

## 3. Fichiers (tous dans `/home/dev/projects/kit-perso`)
- `.claude-plugin/plugin.json` — créer — manifeste du plugin (seule source de la version).
- `.claude-plugin/marketplace.json` — créer — marketplace à un plugin, `source: "./"`.
- `agents/{codeur,explorateur,relecteur,specs}.md` — créer — copies **octet pour octet** de `~/.claude/agents/*.md`.
- `hooks/garde-git.py`, `hooks/rappel-clear.py` — créer — copies octet pour octet de `~/.claude/hooks/`.
- `hooks/hooks.json` — créer — déclaration des 2 hooks via `${CLAUDE_PLUGIN_ROOT}`.
- `skills/livrer/SKILL.md` — créer — skill d'exemple.
- `tests/test_hooks.sh` — créer — tests des 2 hooks par stdin JSON.
- `.gitignore` — créer — `__pycache__/`, `*.pyc`, `.env`, `.env.*`.
- `CHANGELOG.md` — créer — une section par version (`## 0.1.0 — <date>`).
- `README.md` — modifier — présentation (≥ 40 mots, exigé par `validate`), installation, mise à jour, conventions, bascule, retour arrière.

## 4-A. Étapes (codeur, branche `claude/plugin-kit-perso`)
1. `.claude-plugin/plugin.json` exactement :
   ```json
   {"name": "kit-perso", "version": "0.1.0",
    "description": "Agents, skills et hooks personnels : flux specs → codeur → relecteur, garde-fous git.",
    "author": {"name": "stanixia-dev"}, "repository": "https://github.com/stanixia-dev/kit-perso",
    "license": "UNLICENSED"}
   ```
2. `.claude-plugin/marketplace.json` :
   ```json
   {"$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
    "name": "kit-perso", "description": "Marketplace personnelle de stanixia-dev (un seul plugin).",
    "owner": {"name": "stanixia-dev"},
    "plugins": [{"name": "kit-perso", "source": "./",
                 "description": "Agents, skills et hooks personnels."}]}
   ```
   Pas de `version` dans l'entrée : une seule source de vérité (`plugin.json`). `source: "./"` et ce couple de manifestes passent `claude plugin validate --strict` (vérifié sur maquette).
3. Copier les 4 agents et les 2 scripts Python avec `cp` (aucune modification ; frontmatter `model`/`effort`/`tools` acceptés tels quels). Une fois installés, ils s'appellent `kit-perso:codeur`, etc.
4. `hooks/hooks.json` (reprend `~/.claude/settings.json`, sans le hook rtk) :
   ```json
   {"hooks": {
     "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command",
       "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/garde-git.py\"", "timeout": 10, "onFailure": "block"}]}],
     "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command",
       "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/rappel-clear.py\"", "timeout": 10}]}]}}
   ```
5. `skills/livrer/SKILL.md` — frontmatter : `name: livrer`, `description:` (FR : « Pousse la branche claude/<sujet> courante et ouvre la PR… À utiliser quand la relecture est OK »), `argument-hint: "[chemin de la spec]"`, `disable-model-invocation: true` (effet de bord : push). Corps (≤ 25 lignes) : refuser si la branche n'est pas `claude/*` ou si l'arbre n'est pas propre ; lancer les tests du projet ; `git push -u origin <branche>` ; `gh pr create` avec titre en français et corps « Quoi / Pourquoi / Comment tester / Spec » + ligne d'attribution ; finir par le lien de la PR, un résumé en 3 lignes et le rappel `/clear`. Jamais de `--force`, `gh pr merge`, push sur `main`.
6. `tests/test_hooks.sh` (bash, `set -u`, chemins relatifs à la racine du dépôt, affiche `OK`/`ECHEC` par cas, code de sortie ≠ 0 si un cas échoue) :
   - garde-git, stdin `{"tool_input":{"command":"git push origin main"},"cwd":"/tmp"}` → code 2 ;
   - garde-git, `gh pr merge 1` → code 2 ; `git status` → code 0 ;
   - rappel-clear, `gh pr create --fill` → stdout contient `/clear` ; `ls` → stdout vide.
7. `README.md` : à quoi sert le kit ; installation en une ligne `/plugin install kit-perso --marketplace stanixia-dev/kit-perso` et variante en deux temps (`/plugin marketplace add stanixia-dev/kit-perso` puis `/plugin install kit-perso@kit-perso`) ; procédure de mise à jour (4-C) ; conventions (section 5) ; bascule et retour arrière (4-B). Rien de secret, pas d'adresse e-mail.
8. Commits atomiques (manifestes ; agents ; hooks + tests ; skill ; README/CHANGELOG/.gitignore). Ne pas pousser.

## 4-B. Bascule sur la devbox (utilisateur, après fusion de la PR)
1. `claude plugin marketplace add stanixia-dev/kit-perso` puis `claude plugin install kit-perso@kit-perso` (portée utilisateur). Dépôt privé : utilise les identifiants git/gh déjà configurés, aucun token à écrire.
2. Vérifier : `claude plugin details kit-perso@kit-perso` liste 4 agents, 1 skill, 2 hooks.
3. Seulement ensuite, supprimer le doublon des agents et de `rappel-clear` : `mkdir -p ~/.claude/sauvegarde-kit-perso && mv ~/.claude/agents/*.md ~/.claude/hooks/rappel-clear.py ~/.claude/sauvegarde-kit-perso/`, puis retirer de `~/.claude/settings.json` l'entrée `rappel-clear` (garder `rtk hook claude` et **`garde-git`**, qui reste dans `~/.claude` comme filet de sécurité ; `~/.claude/hooks/garde-git.py` n'est pas déplacé). Les hooks tournent deux fois pour garde-git : sans danger (blocage idempotent, sans effet de bord).
4. Redémarrer Claude Code ; demander `git push origin main` → doit être bloqué par garde-git.
5. Mettre à jour la table d'orchestration de `~/.claude/CLAUDE.md` avec `kit-perso:<agent>` (décision 2, faite par l'utilisateur, hors PR).
- Retour arrière : `claude plugin disable kit-perso@kit-perso`, remettre les fichiers de `~/.claude/sauvegarde-kit-perso/` et l'entrée `rappel-clear` de `settings.json`.

## 4-C. Mise à jour et versionnage
- Semver dans `plugin.json` uniquement. MAJEUR : renommage/suppression d'un agent, skill ou hook, ou hook qui bloque davantage ; MINEUR : ajout ; CORRECTIF : correction sans changement de comportement attendu.
- **Toute modification livrée exige une montée de version** : la copie installée est rangée par version dans le cache (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>`), sans montée `update` ne récupère rien. Ajouter l'entrée correspondante dans `CHANGELOG.md`.
- Sur la devbox après fusion : `claude plugin marketplace update kit-perso && claude plugin update kit-perso@kit-perso`, puis redémarrer Claude Code.
- Développement sans installer : `claude --plugin-dir /home/dev/projects/kit-perso` (session seule ; agents/hooks en double tant que la bascule 4-B n'est pas faite).

## 5. Conventions d'ajout (à recopier dans le README)
- Skill : `skills/<nom-kebab-fr>/SKILL.md`, `name` = nom du dossier, `description` en français (ce qu'il fait + « À utiliser quand… »), `disable-model-invocation: true` dès qu'il y a un effet de bord (push, suppression, réseau). Fichiers annexes dans le même dossier.
- Agent : `agents/<nom>.md` avec `name`, `description`, `model`, `effort`, `tools` (liste minimale) ; rapport final borné en lignes.
- Hook : script dans `hooks/`, déclaré dans `hooks/hooks.json` via `${CLAUDE_PLUGIN_ROOT}`, cas ajouté à `tests/test_hooks.sh`.
- Chaque ajout : montée MINEURE + CHANGELOG + `claude plugin validate --strict .` vert.

## 6. Critères d'acceptation
- [ ] `claude plugin validate --strict .` et `claude plugin validate --strict .claude-plugin/plugin.json` sortent en code 0.
- [ ] `bash tests/test_hooks.sh` sort en code 0, 5 cas `OK`.
- [ ] Agents et scripts identiques aux originaux (`cmp` silencieux, cf. Tests).
- [ ] `hooks/hooks.json` ne contient ni `$HOME` ni `/home/dev` ; aucun fichier du dépôt ne contient de token, mot de passe ou e-mail personnel.
- [ ] Aucun dossier `commands/`, aucun `__pycache__` suivi par git ; `~/.claude` inchangé.
- [ ] README ≥ 40 mots avec la ligne `/plugin install kit-perso --marketplace stanixia-dev/kit-perso`.

## 7. Tests
```bash
cd /home/dev/projects/kit-perso
claude plugin validate --strict . && claude plugin validate --strict .claude-plugin/plugin.json
bash tests/test_hooks.sh
for f in agents/*.md; do cmp "$f" ~/.claude/agents/"$(basename "$f")"; done
for f in garde-git rappel-clear; do cmp hooks/$f.py ~/.claude/hooks/$f.py; done
grep -rnE '\$HOME|/home/dev' hooks/hooks.json; git grep -nIiE '(token|password|passwd|api[_-]?key)\s*[:=]|@[a-z0-9-]+\.[a-z]{2,}' | grep -v 'noreply@anthropic.com'   # attendus : aucune sortie
git status --porcelain --ignored | grep -E '__pycache__|\.env' ; test ! -d commands   # pas de sortie, code 0
```

## 8. Décisions
1. **garde-git** : inclus dans le plugin ET conservé dans `~/.claude` (hooks + `settings.json`) comme filet si le plugin est désactivé. Le hook ne fait que lire stdin et bloquer (code 2) : aucun effet de bord, l'exécuter deux fois est sans danger. La bascule ne le retire donc pas.
2. **Noms namespacés** : après la bascule, l'utilisateur met la table de `~/.claude/CLAUDE.md` à `kit-perso:<agent>` (hors de cette PR).
3. **Skill d'exemple** : `livrer` (push + PR).
4. **Portée** : installation utilisateur (tous projets).
5. **Tags de version** : aucun pour l'instant.
