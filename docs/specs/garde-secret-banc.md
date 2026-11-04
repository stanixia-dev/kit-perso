# Spec — garde-secret : scripts de banc épinglés
Statut : en cours
Tickets : #31

## 1. Objectif
Permettre, projet par projet, de lancer une commande de test qui *consomme* des identifiants de banc local (`.banc/*.env`) sans que l'agent les lise ni les voie. L'utilisateur déclare dans `.garde-secret-exceptions` un script du dépôt épinglé par son `sha256` ; le hook n'en laisse passer que l'invocation exacte, et masque les valeurs du banc dans toute sortie.

## 2. Hors périmètre
- Exception générale sur `.banc/*.env` : écartée, elle rouvrirait `cat`/`source` (un `*` de `.garde-secret-exceptions` débloque déjà la lecture).
- Bac à sable système (résidu Q2 de la spec d'origine, `docs/specs/archives/garde-secret.md`).
- `.github/workflows/`, `garde-deps.py`, `deps_communs.py` : inchangés. Aucune dépendance.
- Résidus assumés, à écrire tels quels dans le README :
  - Un script **non déclaré** qui source un `.env` passe déjà le filtre Pre : le hook ne lit pas le contenu des scripts. Seul le masquage le rattrape, pour les valeurs connues affichées en clair.
  - Le code lancé par le script épinglé (`package.json`, config Playwright, tests, `node_modules/.bin`) reste modifiable par l'agent. Il peut donc afficher une valeur encodée ou l'envoyer sur le réseau.
  - **Cibles en 127.0.0.1 : non vérifiable par le hook.** Seul le texte du script épinglé est contrôlé (étape 4), pas ce qu'il lance.
  - Un processus en arrière-plan qui réécrit le script entre le contrôle et l'exécution.

## 3. Conception

### Format (dans `.garde-secret-exceptions`, racine du dépôt)
```
script scripts/captures-banc.sh <sha256 en 64 hex> 2026-11-04 captures Playwright du banc local
masque .banc/*.env 2026-11-04 identifiants jetables du banc local
```
- `script <chemin> <sha256> <AAAA-MM-JJ> <raison…>` : `<chemin>` est relatif à la racine, en `[A-Za-z0-9._/-]+`, sans composant `..` ni `/` initial. `<sha256>` = sortie de `sha256sum <chemin>` (64 hex : 12 hex seraient forgeables par collision de préfixe).
- `masque <glob relatif> <AAAA-MM-JJ> <raison…>` : les valeurs de ces fichiers sont ajoutées aux valeurs connues du masquage.
- Une ligne dont le premier mot est `script` ou `masque` est une **directive**. Elle n'est ni une exception (`couvre` l'ignore) ni une « ligne invalide ».
- Directive `script` à `<chemin>` valide mais empreinte ou date mal formée : le script est déclaré, mais toute exécution est refusée (fail-closed). Chemin invalide ou `masque` mal formée : avertissement, ligne ignorée.
- On réutilise ce fichier, sans en créer un nouveau, car il a déjà toutes les protections : écriture bloquée par garde-deps (Edit/Write/Bash), règle `Edit(**/.garde-secret-exceptions)` du verrouillage, relecteur qui bloque toute ligne ajoutée, CI qui liste sans les appliquer les lignes de la PR.

### Racine
`racine_locale(cwd)` remonte depuis `realpath(cwd)` jusqu'au premier dossier qui contient `.git` (fichier ou dossier). La recherche se fait sans appeler git, pour garder le PostToolUse rapide. Sans `.garde-secret-exceptions` à cette racine, il n'y a aucune directive et le comportement actuel est inchangé.

### Règles PreToolUse
Soit `S` l'ensemble des scripts déclarés. Pour chaque script, `abs = join(realpath(racine), chemin)`, et `nom` est son dernier composant.

**Bash : autorisé** si et seulement si toutes ces conditions sont vraies :
1. `cmd.strip()` vaut exactement `<chemin>` ou `./<chemin>` pour un script de `S`. L'égalité stricte exclut arguments, redirections, pipe, `;`, `&&`, `&`, saut de ligne, préfixe `VAR=`/`env`, interpréteur et substitution.
2. `realpath(cwd) == realpath(racine)`.
3. `realpath(abs) == abs` : aucun composant n'est un lien symbolique, ni `scripts/` ni le script.
4. `abs` est un fichier régulier, et `sha256` de son contenu = empreinte déclarée.
5. Toute URL du script (`[a-z][a-z0-9+.-]*://([^/\s:'"]+)`) a pour hôte `127.0.0.1`, `localhost` ou `[::1]`. C'est un garde-fou contre l'erreur humaine, pas une garantie.

Si les conditions 1 à 5 sont vraies, `pre` rend 0 sans sortie et ne lance pas `bash_chemins`. Si 1 est vraie mais qu'une des conditions 2 à 5 échoue, refus avec le motif : « lance-le depuis la racine », « lien symbolique », « script modifié depuis sa déclaration : demande à l'utilisateur de le relire et de mettre à jour l'empreinte », « cible non locale `<hôte>` ».

**Bash : refusé**, avec le message « script de banc déclaré : lance-le seul, tel quel, depuis la racine (`<chemin>`) ; pour le lire, utilise l'outil Read », dès que la commande n'est pas la forme exacte et qu'elle :
- contient `nom` comme mot entier (regex `(?<![\w.-])<nom échappé>(?![\w.-])` sur le texte brut), ce qui couvre `bash`, `sh -x`, `source`, `.`, `bash -c '…'`, `cd scripts && ./x`, `cat`, `sed -i`, `ln -s`, `cp` ;
- ou contient un candidat (`candidats(cmd)`, après `developpe`) dont le `realpath` relatif à `cwd` vaut `abs`, ce qui couvre un lien symbolique vers le script sous un autre nom.

**Edit/Write/MultiEdit/NotebookEdit** : un chemin dont le `realpath` vaut un `abs` de `S` est refusé : « script de banc épinglé : modification réservée à l'utilisateur ».

Les refus existants restent : `cat`/`grep`/`source`/`.`/`echo >` sur `.banc/*.env` (classe `env`), et Read, Grep et Write de ces fichiers.

### Masquage (PostToolUse)
`valeurs_connues(cwd)` lit en plus les fichiers de `racine` qui correspondent à chaque glob `masque` (`glob.glob(g, root_dir=racine)`, fichiers réguliers seulement). L'analyse est la même que pour `.env` (même regex `CLE=valeur`, guillemets, commentaire de fin, filtre `NOM_SECRET`, ≥ 8 caractères). `BANC_ADMIN_PASSWORD` est donc masqué, pas `BANC_ADMIN_USER`. Il faut factoriser l'analyse ligne à ligne en `valeurs_env(fichier, ajoute)`.

## 4. Fichiers
- `hooks/garde-secret.py` — modifier — `racine_locale`, `directives(texte)`, `lit_exceptions` qui saute les directives, contrôle Bash et écriture des scripts déclarés, `masque` dans `valeurs_connues`.
- `tests/test_secrets.sh` — modifier — cas des sections 6 et 7.
- `README.md` — modifier — sous-section « Scripts de banc » sous « Exceptions de secrets », résidus.
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — 3.2.0 (ajout de fonctionnalité, précédente 3.1.4).

## 5. Étapes
1. `directives(texte)` rend `(scripts, masques, avertissements)` : `scripts` est une liste `(chemin, sha256 | None)` et `masques` une liste de globs. `lit_exceptions` ignore les lignes dont le premier mot est `script` ou `masque`. Vérification : les cas « directives » de la section 7.
2. `racine_locale(cwd)`, et lecture de `.garde-secret-exceptions` à cette racine (absent : rien).
3. Dans `pre`, branche Bash, après le refus d'un `fort` dans le texte : appel de `controle_banc(cmd, cwd)`, qui applique les règles « autorisé » et « refusé » de la section 3. Vérification : les cas Bash de la section 7.
4. Dans `pre`, branche écriture : refus d'un script déclaré, avant `controle_chemin`.
5. `valeurs_connues` : globs `masque`, via `valeurs_env` factorisée. Vérification : les cas de masquage.
6. README : format des deux directives, commande `sha256sum`, flux (le codeur écrit le script, l'utilisateur le relit puis le déclare ; toute modification oblige à mettre l'empreinte à jour), et les résidus de la section 2. Une ligne dans le tableau des décisions : « Pre Bash : script de banc ».
7. CHANGELOG `## 3.2.0 — <date de livraison>` (une entrée qui cite #31), `plugin.json` en `3.2.0`. Clôture et archivage selon `agents/codeur.md`.

## 6. Critères d'acceptation
- [ ] Dépôt jetable avec `scripts/banc.sh` exécutable (il source `.banc/identifiants.env` et cite `https://127.0.0.1:8443`) et des directives `script` et `masque` valides : `scripts/banc.sh` et `./scripts/banc.sh` → 0 sans sortie.
- [ ] Toutes les commandes Bash « refusées » de la section 7 → 2, et aucun message ne contient une valeur du banc.
- [ ] Script modifié d'un octet → 2 (empreinte) ; empreinte mal formée → 2 ; script qui cite `https://exemple.org` → 2.
- [ ] Edit et Write de `scripts/banc.sh` → 2 ; Edit d'un autre fichier → 0.
- [ ] Sortie qui contient la valeur de `BANC_ADMIN_PASSWORD`, depuis la racine ou un sous-dossier → masquée (`valeur-connue`) ; `BANC_ADMIN_USER` intact ; sans directive `masque` → non masquée.
- [ ] Directives absentes des avertissements « ligne invalide » ; une directive ne couvre aucun chemin (`couvre` faux).
- [ ] Sans `.garde-secret-exceptions`, `bash tests/test_hooks.sh` est inchangé (pas de régression).
- [ ] README, CHANGELOG et 3.2.0 à jour ; `git diff --stat main...HEAD -- .github/workflows` vide.

## 7. Tests
Commande du projet :
```
bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py && claude plugin validate --strict .
```
Cas à ajouter dans `test_secrets.sh` (helpers `hk`, `po`, `bloque`, `passe`). Le dépôt est créé par `depot`, `cwd` = racine sauf mention, et les valeurs du banc sont construites par concaténation.
- **Autorisés** : `scripts/banc.sh` ; `./scripts/banc.sh` ; ` scripts/banc.sh ` (blancs de bord).
- **Refusés (forme)** : `bash scripts/banc.sh`, `sh -x scripts/banc.sh`, `source scripts/banc.sh`, `. scripts/banc.sh`, `scripts/banc.sh --x`, `scripts/banc.sh | tee o`, `scripts/banc.sh > o`, `scripts/banc.sh; env`, `scripts/banc.sh && env`, `scripts/banc.sh &`, `X=1 scripts/banc.sh`, `env scripts/banc.sh`, `scripts/../scripts/banc.sh`, `"$PWD"/scripts/banc.sh`, `bash -c 'scripts/banc.sh'`, `cd scripts && ./banc.sh`, `cat scripts/banc.sh`, `sed -i s/a/b/ scripts/banc.sh`.
- **Refusés (contexte)** : `cwd` = sous-dossier + `../scripts/banc.sh` ; lien `l -> scripts/banc.sh` puis `./l` ; `scripts` remplacé par un lien vers une copie ; script modifié ; empreinte de 12 hex ; URL non locale dans le script.
- **Écriture** : Edit et Write sur `scripts/banc.sh` → 2 ; Write sur `scripts/autre.sh` → 0.
- **Non-régression banc** (directives présentes) : `cat .banc/identifiants.env`, `source .banc/identifiants.env`, `grep P .banc/identifiants.env`, `echo x > .banc/identifiants.env`, Read de `.banc/identifiants.env` → 2.
- **Masquage** : `po` avec une sortie qui contient le mot de passe du banc → `updatedToolOutput` masqué, sans la valeur nulle part ; même chose avec `cwd` = sous-dossier ; sans directive `masque` → sortie vide.
- **Directives** : `lit_exceptions` sur un texte qui mêle exceptions et directives → aucune directive parmi les exceptions, aucun avertissement pour elles ; chemin `../x.sh` → avertissement.
- **Protection de la config** (garde-deps, déjà couvert dans `test_hooks.sh`) : ajouter `echo 'script x.sh <64 hex> 2026-11-04 r' >> .garde-secret-exceptions` → 2.

## 8. Décisions (questions closées par l'utilisateur)
- **Q1 (tranchée : défaut retenu) — Arguments.** Le défaut retenu interdit tout argument : une variante = un script déclaré de plus. On pourrait autoriser des arguments fixes déclarés dans la directive, mais c'est plus de surface pour peu de gain. Recommandation : garder le défaut.
- **Q2 (tranchée : défaut retenu) — Mention en Bash.** Le défaut retenu refuse toute commande Bash qui cite le script hors forme exacte, `cat` et `git log -- scripts/banc.sh` compris. L'outil Read et `git diff main...HEAD` restent possibles. On pourrait plutôt exempter une liste de commandes de lecture, mais ce serait plus de code et plus de contournements. Recommandation : garder le défaut.
- **Q3 (tranchée : défaut retenu) — Filtre du masquage.** Le défaut retenu applique le même filtre de nom que `.env` (`PASSW`, `TOKEN`…) : les identifiants et les URL restent lisibles. On pourrait masquer toutes les valeurs ≥ 8 caractères des fichiers `masque`, ce qui couvre une clé mal nommée mais masque aussi les URL du banc. Recommandation : garder le défaut.

## Lots
- [x] L1 — directives et contrôle PreToolUse (étapes 1-4)
  Fichiers : hooks/garde-secret.py, tests/test_secrets.sh
  Fait quand : cas autorisés, refusés, écriture, non-régression et directives verts — `bash tests/test_hooks.sh`
- [ ] L2 — masquage, doc, version 3.2.0, clôture (étapes 5-7)
  Fichiers : hooks/garde-secret.py, tests/test_secrets.sh, README.md, CHANGELOG.md, .claude-plugin/plugin.json
  Fait quand : cas de masquage verts, suite complète verte — `bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py && claude plugin validate --strict .`
