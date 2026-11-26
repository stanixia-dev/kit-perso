# Spec — garde-secret : empreintes des fichiers exécutés par un script de banc
Statut : livrée
Tickets : #33

## 1. Objectif
Une directive `script` n'épingle que le script shell. Le code qu'il lance avec les identifiants (`package.json`, `.ts` appelé, modules importés) reste modifiable par l'agent sans que l'utilisateur le revoie. Nouvelle directive `depend` : l'utilisateur déclare les fichiers ou dossiers dont dépend un script, chacun avec son empreinte. Le lancement est refusé dès qu'une empreinte diverge, avec un message qui nomme le fichier. Un mode `--empreintes` affiche les lignes à recopier, sans jamais écrire le fichier.

## 2. Hors périmètre
- Analyse automatique des imports ou du script (option de l'issue « refuser un script qui exécute un fichier non épinglé ») : écartée. Il faudrait un résolveur par langage (alias TS, `exports`, `require`/`import()` dynamiques, `npm run -w`), ce qui est contraire à un kit générique. Elle serait contournable et donnerait une fausse assurance. Avec une déclaration explicite, l'utilisateur sait exactement ce qu'il a relu.
- Mention du nom du script dans `gh issue|pr` / `git commit` (2e point de l'issue) : déjà traitée en 3.5.0 (#42), inchangée.
- Edit/Write d'une dépendance : **permis**, car l'agent développe ces fichiers. Le contrôle se fait au lancement. Seul le script reste protégé en écriture.
- Contrôle d'URL locale (`hote_non_local`) sur les dépendances : non, il ferait des faux positifs (URL en commentaire).
- `node_modules`, variables d'environnement héritées, `.npmrc`, interpréteur : non épinglables, résidu documenté.
- `.github/workflows/`, `garde-deps.py` : inchangés (garde-deps protège déjà `.garde-secret-exceptions`). Aucune dépendance Python hors stdlib.

## 3. Conception

### Directive `depend` (dans `.garde-secret-exceptions`)
```
script scripts/banc.sh <sha256> 2026-11-04 tests e2e du banc
depend scripts/banc.sh outils/session.ts <sha256> 2026-11-26 lancé par le script
depend scripts/banc.sh outils/lib <sha256> 2026-11-26 modules importés (dossier)
depend scripts/banc.sh package.json <sha256> 2026-11-26 commande npm run
```
- Forme : `depend <script> <chemin> <sha256> <AAAA-MM-JJ> <raison…>` (`split(None, 5)`).
- `<script>` est le chemin exact d'une directive `script` du même fichier. S'il n'est pas déclaré : avertissement, ligne ignorée (il n'y a rien à protéger).
- `<chemin>` : `chemin_relatif_sur(c)` (pas de joker, pas de `/` final). C'est un fichier ou un dossier, et le type est lu au contrôle. Un fichier remplacé par un dossier change donc l'empreinte.
- `<sha256>` : 64 hex. Pour un fichier, c'est `sha256sum <chemin>`. Pour un dossier, c'est l'empreinte d'arbre ci-dessous, donnée par `--empreintes`.
- **Fail-closed** : une ligne `depend` qui nomme un script déclaré mais dont le chemin, l'empreinte ou la date est mal formé donne un avertissement. Toute exécution de ce script est alors refusée.
- Plusieurs lignes par script : toutes sont vérifiées.
- `"depend"` rejoint `DIRECTIVES` : `lit_exceptions` et `couvre` l'ignorent.
- **Compatibilité** : un `script` sans `depend` se comporte exactement comme aujourd'hui (aucune migration). Les directives `script`, `masque` et `filtre` sont inchangées.
- L'agent ne peut pas mettre à jour une empreinte : `.garde-secret-exceptions` est protégé en écriture (Edit, Write, Bash par garde-deps, règle `deny`, relecteur, CI qui liste les lignes ajoutées sans les appliquer). `--empreintes` ne fait qu'afficher.

### Empreinte d'arbre (dossier)
`empreinte_arbre(abs)` parcourt le dossier avec `os.walk(abs, followlinks=False)`, sans aucune exclusion.
- Un lien symbolique (fichier ou dossier) ou un fichier non régulier rend une erreur (fail-closed). Au-delà de 1000 fichiers, c'est aussi une erreur, pour borner la durée du hook.
- Le résultat est `sha256` de la concaténation triée (par chemin relatif, en ordre `bytes`) de `os.fsencode(rel_posix) + b"\0" + sha256(contenu).hexdigest().encode() + b"\n"`.
- Un dossier vide est valide.
- Pas d'exclusion de `__pycache__` : un `.pyc` planté peut remplacer un `.py` épinglé. Le README conseille d'épingler le dossier et de lancer avec `PYTHONDONTWRITEBYTECODE=1`.

### Contrôle (dans `controle_banc`)
Pour le script reconnu, l'ordre des contrôles est : racine, lien, empreinte du script, URL, **dépendances** (nouveau), argument de filtre. Pour chaque `depend` du script :
1. Ligne mal formée : refus « dépendance mal déclarée (ligne N de .garde-secret-exceptions) : exécution de `<script>` refusée ».
2. `abs = join(r, chemin)` ; `realpath(abs) != abs` : refus « dépendance `<chemin>` derrière un lien symbolique ».
3. Fichier absent ou illisible, ou erreur d'arbre : le chemin est ajouté à une liste avec un motif (`absent`, `lien ou fichier spécial`, `plus de 1000 fichiers`). Une empreinte différente l'ajoute à la même liste avec le motif `modifié`.

Si la liste n'est pas vide, un seul refus nomme tous les chemins en cause :
```
⛔ Bloqué par garde-secret : dépendance de scripts/banc.sh modifiée depuis sa déclaration : outils/session.ts (modifié), outils/lib (absent).
Demande à l'utilisateur de relire ces fichiers puis de mettre à jour les empreintes ; lignes à jour : python3 <chemin absolu de garde-secret.py> --empreintes --depot <racine>
```
Le chemin vient de `os.path.abspath(__file__)`. Le message de script modifié reçoit la même seconde ligne, et garde la sous-chaîne « modifié ».

### Mode `--empreintes` (CLI, réservé à l'utilisateur, sans effet de bord)
`python3 hooks/garde-secret.py --empreintes [--depot <dossier>]` :
- `racine_locale` du dépôt ; lecture de `.garde-secret-exceptions` (absent : « aucune directive », code 0) ;
- pour chaque ligne `script` ou `depend` dont le chemin est valide, calcul de l'empreinte actuelle ;
- empreinte qui diffère, ou ligne mal formée : affiche `ligne N : <ligne réécrite>`, avec la nouvelle empreinte, la date du jour et la raison conservée (`<raison>` si elle manque) ;
- chemin absent ou arbre en erreur : `ligne N : <chemin> : <motif>` ;
- script sans aucune `depend` : `<script> : aucune dépendance déclarée` (information, sans effet sur le code de sortie) ;
- code 0 si tout est à jour (« empreintes à jour »), sinon 1. Le fichier n'est jamais écrit : l'utilisateur recopie lui-même.

La branche se place dans `main()`/`commande()` avant le scan git. L'agent peut lancer ce mode sans risque, car il n'affiche que des empreintes de fichiers du dépôt.

## 4. Fichiers
- `hooks/garde-secret.py` — modifier :
  - `depend` dans `DIRECTIVES` ;
  - `directives` rend `(scripts, masques, filtres, deps, avert)`, avec `deps = {script: [(n, chemin|None, sha|None)]}`, et `directives_du_depot` suit (mettre à jour les 3 appelants) ;
  - `empreinte_arbre`, `empreinte_chemin` (fichier ou dossier) ;
  - contrôle des dépendances dans `controle_banc` ;
  - option `--empreintes`.
- `tests/test_secrets.sh` — modifier — dépaquetage de `m.directives` (5 éléments) et cas de la section 7.
- `tests/test_hooks.sh` — modifier — une commande Bash d'écriture d'une ligne `depend` dans `.garde-secret-exceptions`, refusée par garde-deps.
- `README.md` — modifier — « Scripts de banc » : directive `depend`, `--empreintes`, flux de mise à jour, résidus mis à jour.
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — 3.6.0 (précédente 3.5.1).

## 5. Étapes
1. Analyse de `depend` dans `directives` (nouveau tuple, fail-closed, script non déclaré ignoré) et mise à jour des appelants et de la suite `directives` des tests. Vérification : cas « directives » de la section 7.
2. `empreinte_chemin(abs)` : `sha256` du contenu pour un fichier régulier, `empreinte_arbre` pour un dossier, erreur (motif) dans les autres cas.
3. Contrôle des dépendances dans `controle_banc`, et message commun de mise à jour. Vérification : cas Bash de la section 7.
4. `--empreintes`. Vérification : cas CLI de la section 7.
5. README :
   - format de `depend` et exemple générique (script, fichier lancé, dossier importé, `package.json` du `npm run`) ;
   - flux : l'agent modifie une dépendance, le lancement est refusé, l'utilisateur relit le diff, lance `--empreintes` et recopie les lignes ;
   - conseils : épingler la fermeture des imports et le `package.json` des commandes `npm run`, `PYTHONDONTWRITEBYTECODE=1` ;
   - résidus : la phrase « le code lancé par le script épinglé reste modifiable » devient « ce qui n'est pas déclaré par `depend` (`node_modules`, environnement, interpréteur, fichiers oubliés) reste modifiable ».
6. CHANGELOG `## 3.6.0 — <date de livraison>` (une entrée qui cite #33), `plugin.json` en `3.6.0`. Clôture et archivage selon `agents/codeur.md`.

## 6. Critères d'acceptation
- [x] Dépôt `banc` avec `depend scripts/banc.sh outils/a.ts`, `depend scripts/banc.sh outils/lib` (dossier de 2 fichiers) et des empreintes justes : `scripts/banc.sh` → 0 sans sortie — test : `bash tests/test_secrets.sh` (« depend : dépendances intactes »)
- [x] (négatif) `outils/a.ts` modifié d'un octet → 2, message qui contient `outils/a.ts`, `modifié` et `--empreintes` — test : `bash tests/test_secrets.sh` (« depend : fichier modifié »)
- [x] (négatif) Dans `outils/lib` : fichier ajouté, fichier supprimé ou fichier modifié → 2, le message nomme `outils/lib` — test : `bash tests/test_secrets.sh` (« depend : dossier ajout|suppression|modif »)
- [x] (négatif) Dépendance absente → 2 (`absent`) ; lien symbolique dans `outils/lib` → 2 ; `outils/a.ts` remplacé par un lien → 2 — test : `bash tests/test_secrets.sh` (« depend : absent|lien interne|lien »)
- [x] (négatif) `depend` à empreinte de 12 hex ou à date invalide, pour un script déclaré → 2 (fail-closed) ; même ligne pour un script non déclaré → avertissement, aucun effet — test : `bash tests/test_secrets.sh` (« depend : mal formée »)
- [x] (négatif) Deux dépendances modifiées → un seul refus qui nomme les deux — test : `bash tests/test_secrets.sh` (« depend : plusieurs »)
- [x] (négatif) Dossier de 1001 fichiers → 2 (`plus de 1000 fichiers`) — test : `bash tests/test_secrets.sh` (« depend : arbre trop grand »)
- [x] (négatif) Ligne `depend` écrite par Bash dans `.garde-secret-exceptions` → 2 (garde-deps) — test : `bash tests/test_hooks.sh`
- [x] Edit et Write de `outils/a.ts` → 0 ; Edit de `scripts/banc.sh` → 2 — test : `bash tests/test_secrets.sh` (« depend : écriture »)
- [x] `--empreintes` : tout à jour → code 0 ; dépendance modifiée → code 1 et une ligne `ligne N : depend scripts/banc.sh outils/a.ts <nouvelle empreinte> <date du jour> …`. Le fichier `.garde-secret-exceptions` reste identique (comparaison `sha256sum` avant et après). Recopier la ligne affichée rend `scripts/banc.sh` → 0 — test : `bash tests/test_secrets.sh` (« depend : --empreintes »)
- [x] (non-régression) Sans ligne `depend`, tous les cas « banc » et « filtre » existants sont inchangés ; `depend` n'apparaît ni dans les exceptions ni dans les « ligne invalide » — test : `bash tests/test_secrets.sh`
- [x] README, CHANGELOG et 3.6.0 à jour ; `git diff --stat main...HEAD -- .github/workflows` vide — test : `bash tests/test_hooks.sh && claude plugin validate --strict .`

## 7. Tests
Commande du projet :
```
bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py && claude plugin validate --strict .
```
Cas dans `test_secrets.sh` (helpers `banc`, `hk`, `bloque`, `passe`, `sans_secret`). Une fonction `banc_dep <nom>` part de `banc` et ajoute `outils/a.ts`, `outils/lib/{x,y}.ts` et les 2 lignes `depend` (empreinte d'arbre obtenue par `--empreintes` sur une ligne à empreinte factice, ou recalculée en Python dans le test).
- **Directives** (bloc `python3 - "$S"`) : `depend` hors des exceptions et des avertissements « invalide » ; `deps` pour une ligne valide ; `(n, chemin, None)` pour une empreinte de 12 hex ; avertissement pour un script non déclaré ; chemin `../x` → `(n, None, None)`.
- **Bash** : les cas des critères ci-dessus, chacun suivi de `sans_secret … "$BV"` pour les refus.
- **CLI** : `python3 "$S" --empreintes --depot "$d"` (code et sortie), avant et après modification.

## 8. Questions ouvertes
- **Q1 — `depend` obligatoire ?** Par défaut, un `script` sans `depend` reste admis, par compatibilité. L'oubli de déclarer une dépendance reste alors silencieux. L'alternative serait d'exiger au moins une ligne `depend` (ou `depend <script> aucune …`) par script, mais toutes les déclarations existantes casseraient. Recommandation : garder le défaut ; `--empreintes` signale déjà chaque script sans `depend`.

## Lots
- [x] L1 — directive `depend` et contrôle au lancement (étapes 1-3)
  Fichiers : hooks/garde-secret.py, tests/test_secrets.sh, tests/test_hooks.sh
  Fait quand : cas « directives », « depend » (Bash, écriture) et non-régression verts — `bash tests/test_hooks.sh`
- [x] L2 — `--empreintes`, doc, version 3.6.0, clôture (étapes 4-6)
  Fichiers : hooks/garde-secret.py, tests/test_secrets.sh, README.md, CHANGELOG.md, .claude-plugin/plugin.json
  Fait quand : cas CLI verts, suite complète verte — `bash tests/test_hooks.sh && python3 -m py_compile hooks/*.py && claude plugin validate --strict .`
