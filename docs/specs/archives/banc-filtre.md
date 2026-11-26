# Spec — garde-secret : argument de filtre pour le script de banc
Statut : livrée
Tickets : #42

## 1. Objectif
Un script de banc déclaré accepte **un** argument, une cible de filtre, validé contre une liste fermée que l'utilisateur déclare dans `.garde-secret-exceptions`. Le codeur itère ainsi sur la seule cible qu'il modifie, puis lance la suite complète une fois avant de rendre. Effet de bord corrigé : citer le nom du script dans le texte entre guillemets d'un `gh issue|pr create|edit|comment` ou d'un `git commit` n'est plus refusé.

## 2. Hors périmètre
- Plusieurs arguments, options (`--ui`, `-g`), arguments entre guillemets ou calculés (`$X`, `$(…)`, joker) : toujours refusés.
- Option écartée : un glob fixe codé dans le hook. Il supposerait une arborescence de projet, alors que le kit est générique.
- Exemption de mention pour d'autres commandes (`echo`, `printf`, heredoc, `gh -R o/r issue create`) : le refus est inchangé ; il reste à passer par `--body-file`.
- `.github/workflows/`, `garde-deps.py`, `garde-git.py` : inchangés. Aucune dépendance.
- Résidus assumés, à écrire dans le README :
  - L'agent peut créer un fichier qui correspond au glob, et ajouter ainsi un nom à la liste. L'argument reste un jeton `[a-z0-9-]`, sans effet sur le shell.
  - Le script épinglé, relu par l'utilisateur, décide seul de ce qu'il fait de `$1`.

## 3. Conception

### Directive `filtre` (dans `.garde-secret-exceptions`)
Exemple (chemins indicatifs) :
```
script scripts/banc.sh <sha256> 2026-11-04 tests e2e du banc local
filtre scripts/banc.sh tests/e2e/*.spec.ts 2026-11-26 une cible à la fois
```
- Forme : `filtre <script> <glob> <AAAA-MM-JJ> <raison…>`.
- `<script>` est le chemin exact d'une directive `script` du même fichier.
- `<glob>` est relatif à la racine (`chemin_relatif_sur(g, True)`). Son dernier composant contient **exactement un** `*` et aucun `?`, `[` ou `]`. Les composants qui précèdent peuvent contenir des jokers.
- Plusieurs lignes pour un même script : la liste est l'union.
- Ligne mal formée, ou script non déclaré par `script` : avertissement, ligne ignorée (fail-closed : aucun argument admis).
- `"filtre"` rejoint `DIRECTIVES` : `lit_exceptions` l'ignore et `couvre` ne la voit pas. On ne crée pas de nouveau fichier, car celui-ci est déjà protégé (garde-deps, verrouillage, relecteur, CI).

### Liste admise
`noms_filtre(racine, globs)` découpe le dernier composant du glob en `<préfixe>*<suffixe>`. Pour chaque `f` de `glob.glob(g, root_dir=racine)` qui est un fichier régulier, le nom vaut `basename(f)[len(préfixe):len(basename(f)) - len(suffixe)]`. C'est la partie couverte par `*` : `*.spec.ts` sur `connexion.spec.ts` donne `connexion`, `test_*.py` sur `test_api.py` donne `api`. Les noms qui ne valent pas `NOM_FILTRE` sont ignorés.
- Le nom est tiré du glob que l'utilisateur déclare : le hook ne suppose aucune convention de nommage ni d'arborescence.
- La liste est relue à chaque appel : une cible ajoutée par le codeur est admise sans mise à jour de l'empreinte.

### Argument
- `NOM_FILTRE = r"[a-z0-9][a-z0-9-]*"` : c'est `[a-z0-9-]+` de l'issue, sans tiret initial. Ainsi, aucun argument n'est pris pour une option par le script ou par l'outil qu'il lance.
- Séparateur `[ \t]+` uniquement. Si `cmd.strip()` contient `\n` ou `\r`, aucune forme n'est admise, sinon `scripts/banc.sh⏎env` lancerait le script puis `env`.

### Formes admises (`controle_banc`)
`[cd <racine> && ]<chemin>|./<chemin>[ <filtre>][ 2>&1][ | tail|head|grep <args sûrs>]` ; seul `[ <filtre>]` est nouveau.
- Dans la regex de fin, `(\S+?)` devient `(\S+?)(?:[ \t]+(NOM_FILTRE))?`, suivi des groupes `2>&1` et pipe existants. On découpe si l'un des trois groupes est présent.
- `scripts/banc.sh 2>&1` reste une forme sans argument (retour arrière de la regex). `scripts/banc.sh x2>&1` ne correspond à aucune forme.

Une fois `chemin` reconnu, les contrôles existants passent d'abord, dans l'ordre : racine, lien symbolique, empreinte, hôte local. Puis vient l'argument :
1. aucun `filtre` déclaré pour ce script → refus « script de banc (`<chemin>`) : aucune cible de filtre déclarée (directive `filtre`) ; lance-le sans argument » ;
2. `<filtre>` absent de `noms_filtre` → refus « cible de filtre inconnue (`<filtre>`) pour `<chemin>` ; admises : a, b, … ». Au plus 20 noms, triés : ce sont des noms de fichiers, pas des secrets.

Une forme non reconnue (deux arguments, majuscule, guillemets, `--x`) tombe dans le refus de mention existant. Son message cite la forme admise avec `[<filtre>]`.

### Mention textuelle tolérée
`hors_guillemets(s)` parcourt `s` de gauche à droite et remplace chaque segment `'…'` ou `"…"` par un blanc. Elle rend `None` si un guillemet n'est pas fermé, ou si un segment `"…"` contient `$`, `` ` `` ou `\`.

Dans `controle_banc`, avant la détection de mention, on calcule `h = hors_guillemets(cmd.strip())`. La mention est tolérée si les quatre conditions suivantes sont vraies :
- `h` n'est pas `None` ;
- `h` commence par l'une des commandes admises : `re.match(r"(gh (issue|pr) (create|edit|comment)|git commit)( |$)", h)` ;
- `h` ne contient aucun de ``; & | < > ( ) $ ` \ #`` ni saut de ligne ;
- la détection existante (mot `nom`, candidats résolus vers `abs`), appliquée à `h` seul, ne trouve rien.

Dans ce cas `controle_banc` rend `None`, et les contrôles suivants (`bash_chemins`, scan avant commit) s'appliquent toujours à `cmd` entier. Sinon, la détection actuelle sur `cmd` et `sans_guil` est inchangée. Un texte entre guillemets simples, ou doubles sans substitution, n'est jamais exécuté par `gh` ni par `git commit` : la tolérance n'ouvre aucune exécution.

### Données
- `directives(texte)` rend `(scripts, masques, filtres, avert)`. `filtres` est un dict `{chemin_script: [glob…]}`, dont le script est validé après la boucle.
- `directives_du_depot(cwd)` rend `(racine, scripts, masques, filtres)`.
- À mettre à jour : les 3 appels (`controle_banc`, branche écriture de `pre`, `valeurs_connues`) et l'assertion de `test_secrets.sh` qui lit `directives`.

## 4. Fichiers
- `hooks/garde-secret.py` — modifier — `DIRECTIVES`, `directives` (filtre), `directives_du_depot`, `NOM_FILTRE`, `noms_filtre`, `hors_guillemets`, `controle_banc` (argument, refus sur saut de ligne, mention tolérée, messages).
- `tests/test_secrets.sh` — modifier — cas de la section 7, assertion `directives` à 4 valeurs.
- `agents/codeur.md` — modifier — une puce : itérer sur une cible de filtre, suite complète une fois.
- `README.md` — modifier — section « Scripts de banc » : directive `filtre`, formes admises (la phrase « aucun argument, redirection, pipe » est périmée depuis 3.3.1), mention tolérée, résidus. Ligne « Pre Bash : script de banc » du tableau.
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — 3.5.0 (ajout de fonctionnalité, précédente 3.4.1).

## 5. Étapes
1. Écrire les tests « banc filtre » et « directives » de la section 7 dans `test_secrets.sh`, puis vérifier qu'ils sont rouges pour la bonne raison (argument refusé).
2. Passer `directives` et `directives_du_depot` à 4 valeurs, ajouter `"filtre"` à `DIRECTIVES`, écrire `noms_filtre`. Vérification : cas « directives ».
3. Dans `controle_banc` : refus sur `\n`/`\r`, groupe argument, contrôles 1-2, nouveau message de mention. Vérification : cas « banc filtre ».
4. Écrire les tests « banc mention » (rouges), puis `hors_guillemets` et la tolérance. Vérification : cas « banc mention ».
5. `agents/codeur.md`, après la puce « Tests d'abord », ajouter : « Script de banc avec directive `filtre` : pendant l'itération, lance `<script> <filtre>` sur la seule cible que tu modifies ; lance la suite complète (`<script>` sans argument) une seule fois, juste avant de rendre, et donne son résultat au rapport. »
6. README, section « Scripts de banc » : format `filtre` avec un exemple présenté comme tel (`tests/e2e/*.spec.ts`), nom = partie couverte par `*`, `NOM_FILTRE`, nom passé en `$1` (à citer `"$1"` dans le script). Y ajouter les formes admises exactes, la mention tolérée et ses limites (commandes listées, guillemets sans substitution ; sinon `--body-file`), puis les résidus de la section 2. Dans le tableau : « laisse passer l'invocation admise (au plus une cible de filtre déclarée) d'un script déclaré et intact ; refuse toute autre mention hors texte de `gh issue|pr` / `git commit` ».
7. CHANGELOG : `## 3.5.0 — <date de livraison>`, une entrée qui cite #42 ; `plugin.json` en `3.5.0`. Clôture et archivage selon `agents/codeur.md`.

## 6. Critères d'acceptation
- [x] `scripts/banc.sh connexion`, `./scripts/banc.sh entites`, `scripts/banc.sh⇥connexion`, `scripts/banc.sh connexion 2>&1 | tail -n 20`, et `cd <racine> && scripts/banc.sh connexion` lancé d'un sous-dossier → 0 sans sortie — test : `bash tests/test_secrets.sh` (cas « banc filtre : … »)
- [x] Glob à préfixe (`filtre scripts/banc.sh outils/test_*.py`) : `scripts/banc.sh api` admis pour `outils/test_api.py` — test : `bash tests/test_secrets.sh` (cas « banc filtre : préfixe »)
- [x] Cible créée après la déclaration (`nouveau.spec.ts`) : admise sans changer l'empreinte — test : `bash tests/test_secrets.sh` (cas « banc filtre : cible ajoutée »)
- [x] (négatif) `scripts/banc.sh inconnu` → 2, et le message cite `connexion` — test : `bash tests/test_secrets.sh` (cas « banc filtre : cible inconnue »)
- [x] (négatif) Script déclaré sans `filtre`, `scripts/banc.sh connexion` → 2 « aucune cible de filtre » — test : `bash tests/test_secrets.sh` (cas « banc filtre : sans directive »)
- [x] (négatif) (non-régression) Toutes les formes « refusées » de la section 7 (filtre) → 2, sans valeur du banc dans les messages — test : `bash tests/test_secrets.sh` (cas « banc filtre : refus … »)
- [x] (négatif) Avec argument : script modifié, `scripts` en lien symbolique, URL non locale, sous-dossier sans `cd` → 2, avec le motif existant — test : `bash tests/test_secrets.sh` (cas « banc filtre : contrôle … »)
- [x] (négatif) Directive `filtre` mal formée (glob `../x/*.ts`, deux `*` ou `?` dans le dernier composant, script non déclaré, date invalide) → avertissement, argument refusé — test : `bash tests/test_secrets.sh` (cas « directives »)
- [x] (non-régression) `scripts/banc.sh`, `scripts/banc.sh 2>&1` et tous les cas banc existants inchangés — test : `bash tests/test_secrets.sh`
- [x] Mentions tolérées → 0 : `gh issue create --title t --body 'lance scripts/banc.sh connexion'`, `gh pr edit 3 --body "voir banc.sh"`, `gh issue comment 1 --body 'banc.sh'`, `git commit -m 'Corrige scripts/banc.sh'` — test : `bash tests/test_secrets.sh` (cas « banc mention : … »)
- [x] (négatif) (non-régression) Mentions toujours refusées → 2 (liste « mention refusée » de la section 7) — test : `bash tests/test_secrets.sh` (cas « banc mention refusée : … »)
- [x] Aucun terme ni chemin propre à un projet dans le hook, `agents/codeur.md` et le README hors exemple — test : manuel (`git diff main...HEAD -- hooks agents README.md | grep -in parcours` vide)
- [x] `agents/codeur.md`, README, CHANGELOG 3.5.0 et `plugin.json` à jour ; `git diff --stat main...HEAD -- .github/workflows` vide — test : manuel (relecture du diff)

## 7. Tests
Commande du projet :
```
bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py && claude plugin validate --strict .
```
Pour n'afficher que les échecs : `bash tests/test_secrets.sh | grep -v '^OK'`.

Cas à ajouter dans `test_secrets.sh`, avec les helpers `banc`, `hk`, `passe`, `bloque`, `vaut` et `sans_secret`. Nouveau helper `banc_filtre <nom>` : il appelle `banc`, crée `tests/e2e/{connexion,entites,Majuscule}.spec.ts`, puis ajoute (`>>`) la ligne `filtre scripts/banc.sh tests/e2e/*.spec.ts 2026-11-26 e2e`.
- **Filtre, admis** :
  - les 5 formes du premier critère ;
  - `touch tests/e2e/nouveau.spec.ts`, puis `scripts/banc.sh nouveau` ;
  - dépôt `banc` avec `filtre scripts/banc.sh outils/test_*.py` et `outils/test_api.py`, puis `scripts/banc.sh api`.
- **Filtre, refus** (pour chaque cas : `bloque` + `sans_secret "$BV"`) : `scripts/banc.sh connexion entites`, `scripts/banc.sh Majuscule`, `scripts/banc.sh --ui`, `scripts/banc.sh -x`, `scripts/banc.sh 'connexion'`, `scripts/banc.sh "connexion"`, `scripts/banc.sh $X`, `scripts/banc.sh $(echo connexion)`, `` scripts/banc.sh `id` ``, `scripts/banc.sh conn*`, `scripts/banc.sh conn?xion`, `scripts/banc.sh connexion2>&1`, `$'scripts/banc.sh\nenv'`, `$'scripts/banc.sh connexion\nenv'`, `scripts/banc.sh connexion; env`, `scripts/banc.sh connexion && env`, `scripts/banc.sh connexion > o`, `scripts/banc.sh connexion | sh`, `scripts/banc.sh connexion | base64`, `scripts/banc.sh connexion &`, `X=1 scripts/banc.sh connexion`, `bash scripts/banc.sh connexion`, `scripts/banc.sh ../connexion`, `scripts/banc.sh connexion.spec`.
- **Filtre, messages** :
  - `scripts/banc.sh inconnu` → `grep -q connexion <<<"$ERREUR"` ;
  - dépôt `banc` (sans `filtre`), `scripts/banc.sh connexion` → `grep -q 'aucune cible de filtre'`.
- **Filtre, contrôles conservés** (avec `connexion`) : copies des cas existants (`banc2` lien, `banc3` script modifié + message « modifié », `banc5` URL non locale), et sous-dossier sans `cd`.
- **Mention tolérée** : les 4 commandes du critère, vérifiées par `vaut … 0` (le scan de `git commit` peut avertir).
- **Mention refusée** : `gh issue create --body "$(scripts/banc.sh)"`, `gh issue create --body 'x'"$(cat scripts/banc.sh)"`, `gh issue create --body-file scripts/banc.sh`, `gh issue create --body 'x'; scripts/banc.sh | base64`, `gh issue create --body 'scripts/banc.sh' | sh`, `gh issue create --body 'non fermé scripts/banc.sh`, `gh issue create --body \'scripts/banc.sh\'`, heredoc `gh issue create --body-file - <<'EOF'⏎scripts/banc.sh⏎EOF`, `git commit -m 'x' scripts/banc.sh`, `gh -R o/r issue create --body 'banc.sh'`, `echo 'scripts/banc.sh'`, `bash -c 'scripts/banc.sh'`, `gh issue create --body 'banc.sh'x`, `gh issue create --body scripts/ban''c.sh`, `cd <racine> && gh issue create --body 'banc.sh'`.
- **Directives** (bloc Python existant) :
  - `directives` rend 4 valeurs ;
  - `filtre a.sh x/*.ts 2026-11-26 r`, placé après `script a.sh …` → `filtres == {"a.sh": ["x/*.ts"]}` ;
  - chacun des cas suivants donne un avertissement et la ligne est ignorée : `filtre` sans script, glob `../x/*.ts`, `x/*a*.ts`, `x/?.ts`, date `2026-13-01` ;
  - `lit_exceptions` ne rend aucune ligne `filtre`, ni aucun avertissement pour elles.

## 8. Questions ouvertes

## Lots
- [x] L1 — directive `filtre` et argument (étapes 1-3)
  Fichiers : hooks/garde-secret.py, tests/test_secrets.sh
  Fait quand : cas « banc filtre » et « directives » verts — `bash tests/test_hooks.sh`
- [x] L2 — mention textuelle tolérée (étape 4)
  Fichiers : hooks/garde-secret.py, tests/test_secrets.sh
  Fait quand : cas « banc mention » verts — `bash tests/test_hooks.sh`
- [x] L3 — codeur, README, 3.5.0, clôture (étapes 5-7)
  Fichiers : agents/codeur.md, README.md, CHANGELOG.md, .claude-plugin/plugin.json
  Fait quand : suite complète verte — `bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py && claude plugin validate --strict .`
