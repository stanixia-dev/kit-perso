# Mémoire durable et archivage de l'historique

Statut : en cours
Tickets : #45

## Objectif

Donner une règle que l'utilisateur colle dans son CLAUDE.md, pour que la mémoire automatique de Claude Code (`~/.claude/projects/<projet>/memory/`) ne garde que le durable. À la clôture d'un chantier, l'historique part dans un dossier frère `historique/`, que Claude Code ne charge jamais. La skill `kit-perso:archiver-memoire` fait la copie datée et signale ce qui grossit l'index ; elle ne supprime rien et ne réécrit rien sans l'accord de l'utilisateur.

## Hors périmètre

- Modifier `~/.claude/CLAUDE.md` ou toute mémoire réelle : le kit fournit le texte, l'utilisateur le colle.
- Réécriture ou suppression automatique de mémoires, purge de `historique/`, rotation des archives.
- Hook qui surveille la taille de la mémoire à chaque session, ou job CI.
- Lecture des milestones GitHub : c'est l'orchestrateur qui sait qu'un chantier est clos.

## Conception

**Règle** (bloc à coller, texte exact, dans la section « Mémoire » du README) :

```
## Mémoire
- La mémoire garde le durable : décisions et leur raison, conventions, autorisations explicites (avec date), chantier en cours en 2-3 lignes, backlog court.
- Pas de numéros de PR, de lots ni d'historique de livraison : GitHub (PR, milestones) les garde.
- Une ligne d'index de MEMORY.md tient en 150 caractères au plus ; un fichier mémoire, en 3 Ko au plus.
- À la clôture d'un chantier (milestone fermé) : lance /kit-perso:archiver-memoire, puis remets la mémoire du chantier à 2-3 lignes.
```

**Script** `skills/archiver-memoire/archiver-memoire.py`, stdlib seule, sans réseau :

`archiver-memoire.py [--memoire DIR] [--projet DIR] [--date AAAA-MM-JJ]`

- Dossier mémoire `M` : `--memoire`, sinon dérivé de `--projet` (par défaut le cwd). Racine = dossier parent de `git rev-parse --path-format=absolute --git-common-dir` si le dossier est dans un dépôt git (tous les worktrees partagent donc la même mémoire), sinon le dossier lui-même en chemin absolu réel. Puis `M = ~/.claude/projects/<re.sub(r"[^A-Za-z0-9]", "-", racine)>/memory`. La skill passe `--memoire` quand le chemin de `MEMORY.md` figure dans son contexte : la dérivation imite Claude Code et peut diverger (réglage `autoMemoryDirectory`).
- Refus (code 2, message sur stderr, rien d'écrit) : `M` ne s'appelle pas `memory` (pour que l'archive reste à côté de lui et ne soit jamais chargée) ; `--date` mal formée ; échec d'écriture.
- Mémoire absente : `M` inexistant, ou ne contenant aucun fichier ordinaire (recherche récursive). Code 1, `aucune mémoire à <M>` sur stderr, `historique/` n'est pas créé.
- Archive : `A = <parent de M>/historique/<date>-memoire/` (`--date`, sinon la date du jour). Si `A` existe déjà, le script essaie `<date>-memoire-2`, puis `-3`, et ainsi de suite ; il n'écrase jamais rien. Copie par `shutil.copytree(M, A, symlinks=True)` : les liens restent des liens, aucun contenu extérieur n'est copié. Une copie de dossier plutôt qu'un fichier concaténé : on restaure par un simple `cp -r`, sans format à analyser.
- `M` n'est jamais modifié (le script ne fait aucune écriture sous `M`).
- Signalements, calculés sur `M` (pas sur la copie) :
  - chaque ligne de `M/MEMORY.md` qui dépasse 150 caractères (`len` sur la ligne décodée en UTF-8 sans le saut de ligne : un accent compte pour 1) ;
  - chaque fichier ordinaire de `M` (récursif) de plus de 3072 octets ;
  - `MEMORY.md` absent (la copie a quand même lieu).
- Sortie standard (code 0, avec ou sans signalement), une information par ligne :
  ```
  Mémoire : <M>
  Archive : <A> (<n> fichiers)
  Ligne d'index trop longue : MEMORY.md:<n> (<c> caractères) « <60 premiers caractères>… »
  Fichier trop gros : <chemin relatif à M> (<o> octets > 3072)
  MEMORY.md absent
  Rien à signaler.
  ```
  La ligne `Rien à signaler.` n'apparaît que s'il n'y a aucun signalement.

**Skill** `skills/archiver-memoire/SKILL.md` : `name: archiver-memoire`, `argument-hint: "[--memoire <dossier>]"`. Elle reste invocable par le modèle, pour que l'orchestrateur la lance de lui-même à la fermeture d'un milestone : elle n'écrit qu'une copie et rien d'autre sans confirmation. Étapes de la skill :
1. Lancer `python3 "${CLAUDE_SKILL_DIR}/archiver-memoire.py" $ARGUMENTS`, avec `--memoire <dossier de MEMORY.md>` si ce chemin figure dans le contexte. Code 1 : dire « pas de mémoire pour ce projet » et s'arrêter. Code 2 : afficher le message et s'arrêter.
2. Montrer le rapport tel quel.
3. Proposer la réécriture : le chantier clos réduit à 2-3 lignes, les lignes d'index et les fichiers signalés raccourcis au durable, sans numéro de PR ni historique de lots. Montrer l'ancien et le nouveau texte, puis n'écrire dans `memory/` qu'après un « oui » explicite de l'utilisateur.
4. Rapport final : chemin de l'archive, fichiers réécrits, signalements restants.

Interdit à la skill : supprimer un fichier de `memory/` ou de `historique/` sans confirmation, déplacer ou renommer une archive, citer `historique/` dans `MEMORY.md`.

## Fichiers

- `skills/archiver-memoire/archiver-memoire.py` — créer — script décrit ci-dessus.
- `skills/archiver-memoire/SKILL.md` — créer — skill décrite ci-dessus (description en français, « À utiliser quand un chantier se clôt ou que MEMORY.md grossit »).
- `tests/test_archiver_memoire.sh` — créer — tests hors réseau, `HOME` jetable, style `ok`/`ko` de `tests/test_ci_projet.sh`.
- `tests/test_hooks.sh` — modifier — appeler `tests/test_archiver_memoire.sh` (même forme que les autres, préfixe `archiver-memoire: `) ; vérifier que `garde-deps` et `garde-git` admettent `python3 ~/.claude/plugins/cache/k/3.8.0/skills/archiver-memoire/archiver-memoire.py --memoire ~/.claude/projects/-x/memory`.
- `README.md` — modifier — l'intro et la ligne « Vérification » passent à 4 skills et citent `/kit-perso:archiver-memoire` ; nouvelle section « Mémoire » après « Tickets » : bloc de règle à coller dans `~/.claude/CLAUDE.md`, emplacement de l'archive, comportement de la skill en 3 lignes, ligne `Tests :`.
- `CHANGELOG.md` — modifier — entrée `## 3.8.0 — <date>` citant #45.
- `.claude-plugin/plugin.json` — modifier — `3.8.0`.

## Étapes

1. Écrire `tests/test_archiver_memoire.sh` (tous les cas des critères), puis le brancher dans `tests/test_hooks.sh` ; le lancer : rouge.
2. Écrire `archiver-memoire.py` jusqu'à ce que `bash tests/test_archiver_memoire.sh` passe.
3. Écrire `SKILL.md` ; `claude plugin validate --strict .` vert.
4. README (section « Mémoire », compte des skills), CHANGELOG, `plugin.json` en 3.8.0 ; `bash tests/test_hooks.sh` vert. Clôture et archivage de la spec selon `agents/codeur.md`.

## Critères d'acceptation

- [ ] Copie intégrale : `historique/<date>-memoire/` est identique à `memory/` (`diff -r`, sous-dossier et lien symbolique compris), et `memory/` reste inchangé (mêmes empreintes avant et après) — test : `bash tests/test_archiver_memoire.sh` (cas « copie intégrale »)
- [ ] Une archive existe déjà à la même date : le script crée `-2`, puis `-3`, sans toucher aux archives existantes — test : `bash tests/test_archiver_memoire.sh` (cas « même date »)
- [ ] (négatif) Mémoire absente (dossier inexistant, ou vide, ou ne contenant que des sous-dossiers vides) : code 1, `aucune mémoire` sur stderr, pas de `historique/` — test : `bash tests/test_archiver_memoire.sh` (cas « mémoire absente »)
- [ ] (négatif) `--memoire` dont le dernier composant n'est pas `memory`, ou `--date 2026-13-01` / `--date x` : code 2, rien d'écrit — test : `bash tests/test_archiver_memoire.sh` (cas « refus »)
- [ ] Une ligne d'index de 151 caractères est signalée avec son numéro ; une ligne de 150 caractères accentués ne l'est pas — test : `bash tests/test_archiver_memoire.sh` (cas « ligne d'index »)
- [ ] Un fichier de 3073 octets est signalé ; un fichier de 3072 octets ne l'est pas ; sans signalement, `Rien à signaler.` — test : `bash tests/test_archiver_memoire.sh` (cas « taille »)
- [ ] `MEMORY.md` absent mais un autre fichier présent : la copie a lieu et `MEMORY.md absent` est signalé — test : `bash tests/test_archiver_memoire.sh` (cas « index absent »)
- [ ] Sans `--memoire` : le dossier mémoire est dérivé du dépôt (le même depuis un worktree et un sous-dossier), et d'un dossier hors git, `/tmp/a.b` donnant `-tmp-a-b` — test : `bash tests/test_archiver_memoire.sh` (cas « dérivation »)
- [ ] (non-régression) La commande de la skill depuis le cache du plugin n'est bloquée ni par `garde-deps` ni par `garde-git` — test : `bash tests/test_hooks.sh`
- [ ] Le plugin se valide avec 4 skills, et le README contient le bloc de règle exact de la section Conception — test : `claude plugin validate --strict . && grep -q 'Une ligne d.index de MEMORY.md tient en 150 caractères au plus' README.md`
- [ ] La skill n'écrit dans `memory/` qu'après un « oui » de l'utilisateur et ne supprime rien — test : manuel (lancer `/kit-perso:archiver-memoire` dans un projet de test, répondre « non » : `memory/` est inchangé)
- [ ] `plugin.json` en 3.8.0, CHANGELOG à jour, aucun nom de projet propre dans le kit — test : manuel (`grep -rni hive skills agents hooks README.md` ne renvoie rien de nouveau)

## Tests

```
bash tests/test_archiver_memoire.sh
bash tests/test_hooks.sh
claude plugin validate --strict .
```

## Questions ouvertes

- Version : la branche `claude/parcours-banc` vise 3.7.0 et modifie aussi le README (« Scripts de banc », section « Brief du codeur » renommée), le CHANGELOG et `plugin.json`. Cette spec vise 3.8.0. Si elle est fusionnée la première, il faudra la ramener à 3.7.0 et rebaser l'autre branche ; les conflits sur le haut du CHANGELOG et sur `plugin.json` sont certains.

## Lots

- [ ] L1 — Script d'archivage et ses tests (étapes 1-2)
  Fichiers : `skills/archiver-memoire/archiver-memoire.py`, `tests/test_archiver_memoire.sh`, `tests/test_hooks.sh`
  Fait quand : tous les cas du script passent — `bash tests/test_hooks.sh`
- [ ] L2 — Skill, règle dans le README, version 3.8.0 (étapes 3-4)
  Fichiers : `skills/archiver-memoire/SKILL.md`, `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json`
  Fait quand : plugin valide et règle présente — `claude plugin validate --strict . && bash tests/test_hooks.sh`
