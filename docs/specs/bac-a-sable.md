# Spec — bac-a-sable (bac à sable Bash de Claude Code)
Statut : en cours

## 1. Objectif
Faire passer chaque commande Bash de l'agent dans le bac à sable système de Claude Code 2.1.316 (bubblewrap) : sans aucune exception possible, la lecture de `~/.ssh` et de `~/.config/gh` et l'écriture hors du projet (`~/.claude/**`) deviennent impossibles, y compris par un script. Cela ferme les résiduels « script qui lit un fichier protégé » (garde-secret Q2) et « script écrit puis exécuté » (garde-deps-v2) pour ces chemins. `git push` et quelques sous-commandes `gh` restent hors du bac à sable, via une liste d'exclusions étroite que les hooks durcissent.

## 2. Hors périmètre
- Le codeur ne modifie **ni** `~/.claude/settings.json` **ni** `.github/workflows/`. Il livre un fragment de réglages, et l'utilisateur le fusionne à la main, comme pour le Verrouillage.
- Le plugin ne peut pas activer le bac à sable lui-même : le `settings.json` d'un plugin n'accepte que `agent` et `subagentStatusLine` (vérifié dans le binaire 2.1.316, liste `["agent","subagentStatusLine"]`).
- Aucune dépendance Python. Paquet système à installer par l'utilisateur : **`socat`** (absent ; requis, le binaire suggère `apt install bubblewrap socat`). `bubblewrap` 0.12.0 est déjà installé, et `bwrap --unshare-net true` réussit sans privilège (vérifié).
- Podman, masquage `credentials.files` en mode `mask` (injection du jeton par proxy TLS, expérimentale), passage des remotes en HTTPS.
- Écritures dans les fichiers protégés **du projet** (`.github/workflows/`, `.claude/settings*.json`, `.garde-*-exceptions`) : sous Linux, le bac à sable ignore les motifs glob en écriture (« Skipping glob write pattern on Linux »). Ces écritures restent couvertes par les hooks et la CI (voir Q3).

## 3. Fichiers
- `config/bac-a-sable.json` — créer — fragment `{"sandbox": {...}}` à fusionner dans `~/.claude/settings.json`, ou à passer à `claude --settings`.
- `tests/sonde-bac-a-sable.sh` — créer — sondes lancées *par l'agent* pour vérifier le bac à sable ; option `--liste` (n'exécute rien).
- `hooks/garde-git.py` — modifier — durcit les commandes exclues (étape 4).
- `hooks/garde-secret.py` — modifier — résout les arguments de fichier des commandes exclues (étape 5).
- `tests/test_hooks.sh`, `tests/test_secrets.sh` — modifier — cas des étapes 3 à 5.
- `README.md`, `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — étape 6.

## 4. Étapes
1. `config/bac-a-sable.json` (JSON strict, sans commentaire), clés sous `sandbox` :
   - `enabled: true`, `allowUnsandboxedCommands: false` (mode strict : le paramètre `dangerouslyDisableSandbox` est ignoré).
   - `failIfUnavailable: true` : sans cela, une dépendance manquante fait seulement afficher un avertissement, et les commandes tournent hors du bac à sable.
   - `autoAllowBashIfSandboxed: false` (Q1).
   - `excludedCommands` : `git push *`, `gh pr create *`, `gh pr view *`, `gh pr list *`, `gh pr checks *`, `gh pr diff *`, `gh run view *`, `gh run list *`, `gh issue view *`, `gh issue list *`, et chacun préfixé par `rtk ` (le hook rtk réécrit les commandes avant la correspondance).
   - `filesystem.denyRead` : `~/.ssh`, `~/.config/gh`. Ils doublent les règles `Read(...)` du Verrouillage, que le binaire fusionne déjà ; ils protègent même si le Verrouillage n'est pas appliqué.
   - `filesystem.allowWrite` : `~/.cargo/registry`, `~/.cargo/git`, `~/.npm`, `~/.cache`, `~/.local/share/rtk`. Ni `~/.cargo/config.toml`, ni `~/.claude`.
   - `credentials.envVars` : `[{"name":"GH_TOKEN","mode":"deny"},{"name":"GITHUB_TOKEN","mode":"deny"}]` (sans effet si les variables sont absentes).
   - `network.allowedDomains` : `github.com`, `api.github.com`, `*.githubusercontent.com`, `crates.io`, `index.crates.io`, `static.crates.io`, `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`, `api.osv.dev`. Ces domaines servent au relecteur, qui lance `verifie-manifestes.py` en Bash.
   - `network.allowLocalBinding: true` : nécessaire aux tests qui écoutent sur 127.0.0.1, sans effet sur la sortie réseau (espace réseau isolé, pare-feu).
2. `tests/sonde-bac-a-sable.sh` (bash + `python3 -I -c`). Le script n'affiche **jamais** de contenu et ne modifie aucun fichier existant : il crée des fichiers nouveaux et uniques (`.sonde-$$`) puis les supprime. Il affiche une ligne `OK|TROU|INFO <libellé>` par sonde, termine par `SONDE : <n> trou(s)` et sort en 1 s'il trouve un trou. Les sondes :
   - TROU si un fichier ordinaire de `~/.ssh`, puis de `~/.config/gh`, s'ouvre en lecture. Sous Linux, un chemin refusé apparaît comme un tmpfs vide. INFO si le dossier n'existe pas hors du bac à sable.
   - TROU si la création réussit dans `~/.claude/`, `~/.claude/plugins/`, `.git/hooks/`, ou sur `.git/config` ouvert en ajout sans rien écrire.
   - INFO pour la création dans `.github/workflows/` et `.claude/` (Q3).
   - TROU si la création est **refusée** dans le dossier courant (contrôle de cohérence).
   - Réseau, avec `urllib` et un délai de 10 s : TROU si `https://api.github.com` est injoignable ou si `https://example.com` est joignable.
   - TROU si `GH_TOKEN` ou `GITHUB_TOKEN` est défini. INFO pour le code de sortie de `rtk git status`.
   - `--liste` affiche les libellés, n'exécute rien et sort en 0.
3. Ajouter dans `tests/test_hooks.sh` :
   - un contrôle de `config/bac-a-sable.json`, avec `python3 -I` : clés et valeurs de l'étape 1, chaque exclusion qui commence par `git push` ou `gh pr|run|issue` (avec ou sans `rtk `), aucun `allowWrite` sous `~/.claude`, `~/.ssh` ou `~/.config/gh`, ni égal à `~/.cargo` ;
   - `bash -n` et `--liste` sur la sonde.
4. `garde-git.py` bloque :
   a. `git push` qui porte `--receive-pack` ou `--exec` (avec `=` ou en argument séparé) : le programme désigné s'exécuterait en local, hors du bac à sable ;
   b. `git push …` ou `gh …` précédé d'une affectation (`X=… git push`, `env X=… gh pr create`), par exemple `GIT_SSH_COMMAND`. Le message dit pourquoi ;
   c. ces deux règles valent aussi dans `bash -c` et derrière `rtk`, comme les règles existantes.
5. `garde-secret.py --hook pre`, sur les commandes exclues (`git push`, `gh pr|run|issue …`) : chaque argument et chaque valeur `--opt=val` qui désigne un fichier existant est résolu par `os.path.realpath`, relativement au dossier suivi. La commande est refusée si la cible est un chemin protégé (`classe_chemin`). Exemple : `gh pr create --body-file lien`, où `lien` pointe vers `~/.ssh/id_x`.
6. Documentation :
   - README : nouvelle section `## Bac à sable (à appliquer par l'utilisateur)` après Verrouillage. Elle donne les prérequis (`socat`), la fusion de `config/bac-a-sable.json` dans `~/.claude/settings.json`, la sonde, ce qui est couvert ou non (projet : Q3 ; `.env` : glob développé au démarrage, non vérifié), les exclusions et leur durcissement, et le retour arrière (`"enabled": false` dans `~/.claude/settings.json`).
   - README, Verrouillage : remplacer « Piste non retenue… » par un renvoi à la nouvelle section.
   - README, résiduels des secrets : préciser ceux que le bac à sable ferme (script lisant `~/.ssh` ou `~/.config/gh`, `gh gist create`, qui échoue sans jeton dans le bac à sable), retirer « Le bac à sable système n'est pas utilisé ».
   - `plugin.json` en **1.0.0** : majeur, puisque les hooks bloquent davantage (règle du README). Entrée `1.0.0 — <date>` au CHANGELOG. Clôture et archivage dans le commit de L3.

## 5. Critères d'acceptation
- [ ] `config/bac-a-sable.json` passe le contrôle de l'étape 3, et le contrôle échoue si l'on retire `allowUnsandboxedCommands` ou si l'on ajoute `~/.claude` à `allowWrite`.
- [ ] `bash tests/sonde-bac-a-sable.sh --liste` sort en 0 sans rien créer ; `git status` reste propre.
- [ ] Bloqués : `git push --receive-pack=x origin b`, `git push --exec x origin b`, `GIT_SSH_COMMAND=x git push origin b`, `env A=1 gh pr create`, `bash -c 'X=1 git push origin b'`, `rtk git push --receive-pack=x origin b`.
- [ ] Passent toujours : `git push -u origin claude/x`, `gh pr create --fill`, `gh pr checks --watch --interval 20`.
- [ ] Refusés : `gh pr create --body-file l`, où `l` est un lien vers un fichier de `$HOME/.ssh` (HOME jetable), et `--body-file=l`. Accepté : `gh pr create --body-file notes.md`.
- [ ] README : section Bac à sable présente, « Piste non retenue » retirée, résiduels à jour ; version 1.0.0 et CHANGELOG cohérents ; `claude plugin validate --strict .` vert.
- [ ] Manuel (utilisateur, après installation de `socat`) : la sonde lancée par l'agent sous `--settings config/bac-a-sable.json` affiche `SONDE : 0 trou(s)`.
- [ ] Manuel (utilisateur, fragment fusionné) : dans une session, `git push` et `gh pr view` fonctionnent, et `python3 -c` qui lit `~/.ssh/known_hosts` échoue.

## 6. Tests
- `bash tests/test_hooks.sh` (inclut `test_secrets.sh` et `test_manifestes.sh`), hors réseau.
- `claude plugin validate --strict .`
- Manuel, depuis la racine du dépôt :
  `claude --settings config/bac-a-sable.json -p --allowedTools "Bash(bash tests/sonde-bac-a-sable.sh)" "Lance exactement : bash tests/sonde-bac-a-sable.sh, puis recopie sa sortie telle quelle."`
  Sans `socat`, Claude Code doit refuser de démarrer (« sandbox required but unavailable ») : c'est le comportement attendu de `failIfUnavailable`.

**Non vérifié sur 2.1.316 (la sonde ou l'usage tranchera)** :
- la résolution de `./` dans les réglages utilisateur ;
- le fait que les règles de `--allowedTools` et `allow` suffisent à lancer une commande exclue sans invite (en `-p` ou dans un sous-agent ; le binaire dit qu'une exclusion « exempts a command only where a permission prompt can approve ») ;
- la correspondance des exclusions précédées d'une affectation de variable (d'où l'étape 4b) ;
- la protection d'office de `.git/hooks`, `.git/config` et `.claude/` dans le projet ;
- ripgrep et le filtre seccomp, fournis par le binaire (onglet Dependencies de `/sandbox`) ; si « Illegal instruction » (pas d'AVX), le signaler ;
- les écritures de rtk dans `~/.local/share/rtk`.

## 7. Questions ouvertes
- **Q1 — Approbation automatique.** *Tranchée : recommandation retenue.* Avec `autoAllowBashIfSandboxed: true` (défaut), toute commande qui tourne dans le bac à sable passe sans invite, ce qui change ton modèle de permissions. Recommandation : `false`, pour garder le comportement actuel.
- **Q2 — Podman.** *Tranchée : recommandation retenue.* En mode strict, l'agent ne peut plus lancer podman : l'espace de noms imbriqué et `newuidmap` setuid sont probablement refusés par bwrap. Une exclusion `podman *` rouvrirait le trou (`-v ~/.ssh:/k`). Recommandation : pas d'exclusion ; tu lances podman avec le préfixe `!`.
- **Q3 — Fichiers protégés du projet.** *Tranchée : recommandation retenue.* Sous Linux, les globs d'écriture sont ignorés. Il faudrait un `.claude/settings.json` par dépôt, avec des chemins `./…`, à écrire par toi. Recommandation : accepter ce résidu, que couvrent les hooks et la CI (`pull_request_target` depuis `main`), et le documenter.
- **Q4 — Démarrage bloquant.** *Tranchée : recommandation retenue.* Avec `failIfUnavailable: true`, Claude Code ne démarre pas tant que `socat` manque ou si bwrap casse après une mise à jour. Recommandation : `true`, en installant `socat` avant de fusionner le fragment. Secours : `"enabled": false`.
- **Q5 — Liste `gh`.** *Tranchée : recommandation retenue.* Seules les sous-commandes citées tournent hors du bac à sable ; `gh api`, `gh gist` et `gh repo` échoueront faute de jeton. Recommandation : liste étroite, que tu élargis toi-même dans `~/.claude/settings.json` au besoin.

## Lots
- [x] L1 — fragment de réglages et sonde (étapes 1-3)
  Fichiers : config/bac-a-sable.json, tests/sonde-bac-a-sable.sh, tests/test_hooks.sh
  Fait quand : contrôle du fragment et `--liste` verts — `bash tests/test_hooks.sh`
- [x] L2 — durcissement des commandes exclues (étapes 4-5)
  Fichiers : hooks/garde-git.py, hooks/garde-secret.py, tests/test_hooks.sh, tests/test_secrets.sh
  Fait quand : cas bloqués, acceptés et refusés du §5 verts — `bash tests/test_hooks.sh`
- [ ] L3 — README, CHANGELOG, version 1.0.0, clôture (étape 6)
  Fichiers : README.md, CHANGELOG.md, .claude-plugin/plugin.json
  Fait quand : tests verts et validation stricte — `bash tests/test_hooks.sh && claude plugin validate --strict .`
