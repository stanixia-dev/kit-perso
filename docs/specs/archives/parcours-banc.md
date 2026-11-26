# Spec — banc exigé quand le diff touche des chemins déclarés
Statut : livrée
Tickets : #43

## 1. Objectif
Le projet déclare dans `.garde-secret-exceptions` les chemins qui exigent la suite complète d'un script de banc (directive `exige`). Si le diff de la branche touche un de ces chemins, le relecteur bloque tant que la suite n'a pas tourné, verte, sur le HEAD relu. `livrer` reporte alors `Banc : N réussis / M échecs sur <sha>` dans le corps de la PR. Sans directive, rien ne change.

## 2. Hors périmètre
- Job CI qui lance le banc (option « job `parcours` » de #43, sur un runner homelab, via `ci-projet`) : il touche aux workflows. Suite possible, à décider par l'utilisateur.
- Aucun chemin de projet en dur dans le kit : `web/`, `packages/kit/` ne sont que des exemples dans le README.
- Pas de nouveau fichier de config : `.garde-secret-exceptions` est déjà protégé (hooks, `permissions.deny`, relecteur, CI) et porte les directives de banc.
- Pas de trace d'exécution écrite par un hook. Le résultat vient du rapport du codeur ou d'une exécution par le relecteur. Résiduel assumé, à écrire dans le README : une ligne `Banc :` du codeur n'est pas vérifiable (seul le SHA est comparé au HEAD).
- Pas d'analyse de la sortie du script par le kit : l'agent lit les comptes dans la sortie.
- `garde-git.py`, `garde-deps.py`, `.github/workflows/` : inchangés. Aucune dépendance.

## 3. Conception

### Directive `exige` (dans `.garde-secret-exceptions`)
Exemple (chemins indicatifs, propres au projet) :
```
script scripts/banc.sh <sha256> 2026-11-04 tests e2e du banc local
exige scripts/banc.sh web/* 2026-11-26 interface web
exige scripts/banc.sh packages/kit/* 2026-11-26 composants partagés
```
- Forme : `exige <script> <glob> <AAAA-MM-JJ> <raison…>`.
- `<script>` est le chemin exact d'une directive `script` du même fichier. Sinon : avertissement `⚠`, ligne ignorée.
- `<glob>` : relatif, validé par `chemin_relatif_sur(g, True)`. Il est comparé par `fnmatch.fnmatchcase` au chemin relatif de chaque fichier du diff. `*` couvre aussi `/` : `web/*` couvre tout `web/`. Choix : c'est le plus simple, et une sémantique `**` n'apporte rien ici.
- Ligne mal formée (glob invalide, date invalide, champs manquants) : avertissement, ligne ignorée. Fail-open voulu : une config cassée n'empêche pas de livrer, et le relecteur la signale en mineur.
- Plusieurs lignes : union, par script.
- `"exige"` rejoint `DIRECTIVES` : `lit_exceptions` l'ignore (aujourd'hui, une telle ligne est signalée « invalide »). `--empreintes` ne la lit pas.
- Script déclaré mais empreinte invalide ou périmée : l'exigence tient. Le lancement sera refusé par le hook, donc le relecteur bloquera : c'est à l'utilisateur de mettre l'empreinte à jour.

### Option `--exige` de `garde-secret.py`
`python3 garde-secret.py --exige [--base <ref>] [--depot <dossier>]` :
- Lit les directives dans le fichier de l'arbre de travail (`directives_du_depot`). Prend la liste des fichiers par `git diff --name-only --no-renames <base>...HEAD` ; base par défaut : `base_par_defaut`, comme le mode CLI.
- Pour chaque script exigé, une ligne sur stdout, triée par script : `exige <script> : <k> fichier(s) (<f1>, <f2>, <f3>[, …])`, avec au plus 3 chemins, triés.
- Rien d'exigé (fichier ou directive absents, aucun fichier qui correspond) : une seule ligne `aucun banc exigé`.
- Les avertissements de directives `exige` sont écrits avant, préfixés `⚠ `.
- Code 0 dans ces cas. Code 2 si le dossier n'est pas un dépôt git ou si `git diff` échoue (base inconnue), avec le message sur stderr (comportement par défaut du mode CLI).
- Fonction dédiée `exigences(texte, declares)` → `({script: [glob]}, avert)`, appelée depuis `directives` ou à côté ; `directives` garde sa signature si possible. Choix : moins d'appels à mettre à jour.

### Ligne `Banc :` (rapports)
- Codeur et relecteur, une ligne par script exigé : `Banc : <script> — <N> réussis / <M> échecs sur <sha>`. Si la sortie ne donne pas de comptes : `Banc : <script> — code <c> sur <sha>`. `<sha>` = `git rev-parse HEAD` au moment du lancement, arbre de travail propre (`git status --porcelain` vide).
- Résultat vert : `M` = 0, ou code 0 quand il n'y a pas de comptes.
- Corps de PR (`livrer`) : une seule ligne avec les totaux de tous les scripts exigés, `Banc : <N> réussis / <M> échecs sur <sha court, 7 car.>`. On ne cite pas le chemin du script : garde-secret refuse sa mention dans un heredoc.

### Règles par acteur
- **Codeur** : avant de rendre, lance `--exige --base main`. Pour chaque script exigé, il lance la suite complète (`<script>` sans argument, forme admise `<script> 2>&1 | tail -n 40`) une fois, après son dernier commit, l'arbre propre. Cette exécution remplace la « suite complète » de la règle `filtre`. Il met la ligne `Banc :` dans son rapport. Si la suite est rouge, il le dit au rapport, sans masquer et sans commiter de contournement. Si le lancement est refusé (empreinte, banc injoignable), il cite le refus au rapport.
- **Orchestrateur** : il recopie les lignes `Banc :` du rapport du codeur dans le brief du relecteur. La consigne est portée par le `description:` du relecteur, que l'orchestrateur lit, et par le README.
- **Relecteur** : lance `python3 "$S" --exige --base main`.
  - `aucun banc exigé` : rien à faire, pas de ligne `Banc :`.
  - Un `⚠` d'une directive `exige` : mineur « directive exige ignorée : … ».
  - Pour chaque script exigé : il prend la ligne `Banc :` du brief si `git rev-parse <sha>` vaut `git rev-parse HEAD`. Si la ligne manque ou si le SHA diffère, il lance lui-même la suite complète sur HEAD, arbre propre. Choix : un relancement coûte moins qu'un aller-retour vers le codeur.
  - Lancement impossible (refus du hook, banc injoignable) : bloquant « banc exigé non lancé sur <HEAD> : <raison> ».
  - Résultat rouge : bloquant « banc rouge sur <HEAD> : M échecs », avec les noms des cas en échec s'ils sont dans la sortie.
  - Le rapport du relecteur porte toujours la ligne `Banc :` retenue (celle du brief ou la sienne).
- **livrer** : après l'étape 2 (tests), lance `--exige --base main`.
  - `aucun banc exigé` : pas de section Banc dans la PR.
  - Sinon, il reprend les lignes `Banc :` du rapport de relecture OK sur le HEAD courant. Il s'arrête et le dit (« banc exigé sans résultat de relecture sur <HEAD> ») si une ligne manque, si son SHA diffère de HEAD, ou si elle est rouge.
  - Section « Banc » du corps de la PR, après « Comment tester » : la ligne de totaux.

### Cas limites
| Cas | Résultat |
|---|---|
| Pas de `.garde-secret-exceptions`, ou aucune ligne `exige` | `aucun banc exigé` ; aucun blocage, aucune section |
| Diff hors des globs déclarés | `aucun banc exigé` |
| `exige` vers un script non déclaré, ou ligne mal formée | `⚠` + ligne ignorée ; mineur au relecteur |
| Ligne `Banc :` absente du brief | le relecteur lance la suite lui-même |
| SHA de la ligne différent du HEAD (correctif après le rapport) | le relecteur relance sur HEAD |
| Script refusé par le hook (empreinte périmée) ou banc arrêté | bloquant « non lancé » ; l'utilisateur met à jour ou démarre le banc |
| Suite rouge | bloquant au relecteur ; `livrer` refuse |
| Base inconnue pour `--exige` | code 2 ; le relecteur le signale en mineur « exigence de banc non vérifiée » et ne bloque pas |

## 4. Fichiers
- `hooks/garde-secret.py` — modifier — `DIRECTIVES` (+ `exige`), `exigences`, option `--exige` dans `main`/`commande`, docstring d'en-tête (modes).
- `tests/test_secrets.sh` — modifier — section « banc exigé » (cas de la section 6).
- `tests/test_hooks.sh` — modifier — garde-fou : le dépôt du kit ne change pas pendant les tests.
- `agents/relecteur.md` — modifier — `description:` (recopier les lignes `Banc :` du codeur dans le brief), puce « Banc exigé », ligne `Banc :` dans le format du rapport.
- `agents/codeur.md` — modifier — puce « Banc exigé », ligne `Banc :` dans le rapport final.
- `skills/livrer/SKILL.md` — modifier — contrôle `--exige` après l'étape 2, section « Banc » du corps.
- `README.md` — modifier — « Scripts de banc » : directive `exige` (exemple présenté comme tel), `--exige`, résiduel. Section « Brief du codeur » renommée « Briefs », avec la ligne `Banc :` du brief du relecteur.
- `CHANGELOG.md`, `.claude-plugin/plugin.json` — modifier — 3.7.0 (fonctionnalité ajoutée, précédente 3.6.2).

## 5. Étapes
1. Écrire dans `tests/test_secrets.sh` la section « banc exigé » (cas de la section 6) : dépôts jetables avec `main` et une branche `claude/x`, réutiliser le helper `banc`. Vérifier qu'elle est rouge pour la bonne raison (`--exige` inconnu, ligne `exige` signalée invalide).
2. `garde-secret.py` : ajouter `exige` à `DIRECTIVES`, écrire `exigences` et l'option `--exige`. Vérification : `bash tests/test_secrets.sh` vert.
3. `agents/codeur.md` : puce « Banc exigé » après celle du script de banc avec `filtre`, et ajout de « lignes `Banc :` » au rapport final.
4. `agents/relecteur.md` : `description:`, puce « Banc exigé » après « Relance les tests », et ligne `Banc :` dans le format du rapport, après `Contre-test :`.
5. `skills/livrer/SKILL.md` : nouvelle étape entre 2 et 3 (renumérotation), qui repère `S` comme le relecteur, et section « Banc » à l'étape `gh pr create`.
6. README : directive, option, exemple, tableau des cas limites résumé en 3 lignes, résiduel de la section 2, ligne `Banc :` du brief du relecteur. Mentionner le job CI comme suite possible.
7. CHANGELOG `## 3.7.0 — <date>` citant #43, `plugin.json` en `3.7.0`. Clôture et archivage selon `agents/codeur.md`.

## 6. Critères d'acceptation
- [x] Un diff qui touche `web/a.ts`, avec `exige scripts/banc.sh web/* …`, donne `exige scripts/banc.sh : 1 fichier(s) (web/a.ts)` et le code 0 — test : `bash tests/test_secrets.sh` (cas « exige : chemin couvert »)
- [x] Deux lignes `exige` pour un même script : union ; plus de 3 fichiers donnent `, …` — test : `bash tests/test_secrets.sh` (cas « exige : union »)
- [x] `web/*` couvre `web/sous/b.ts` — test : `bash tests/test_secrets.sh` (cas « exige : sous-dossier »)
- [x] Un diff hors glob donne `aucun banc exigé` et le code 0 — test : `bash tests/test_secrets.sh` (cas « exige : hors glob »)
- [x] (négatif) Pas de `.garde-secret-exceptions` → `aucun banc exigé`, code 0 — test : `bash tests/test_secrets.sh` (cas « exige : sans fichier »)
- [x] (négatif) `exige` vers un script non déclaré, glob `../x` ou date invalide → ligne `⚠` et `aucun banc exigé`, code 0 — test : `bash tests/test_secrets.sh` (cas « exige : ligne ignorée … »)
- [x] (négatif) `--exige --base inconnue` → code 2 — test : `bash tests/test_secrets.sh` (cas « exige : base inconnue »)
- [x] (négatif) Une ligne `exige` valide n'est plus signalée « invalide » par `garde-secret.py --base main` — test : `bash tests/test_secrets.sh` (cas « exige : pas une exception »)
- [x] (non-régression) Le script de banc déclaré, sans `exige`, se lance comme avant ; `--empreintes` est inchangé — test : `bash tests/test_secrets.sh` (cas « script de banc : … », « depend : --empreintes … »)
- [x] (non-régression) Suite complète du kit verte — test : `bash tests/test_hooks.sh`
- [x] Relecteur : `--exige`, ligne du brief acceptée si son SHA = HEAD, sinon relancement ; bloquants « non lancé » et « rouge » ; mineur sur `⚠` ; ligne `Banc :` au rapport ; consigne de recopie dans `description:` — test : manuel (relire `agents/relecteur.md` contre la section 3)
- [x] Codeur : suite complète exigée après le dernier commit, ligne `Banc :` au rapport, refus ou rouge signalés — test : manuel (relire `agents/codeur.md`)
- [x] livrer : pas de section sans exigence ; arrêt si une ligne manque, si le SHA diffère ou si elle est rouge ; ligne de totaux sans chemin de script — test : manuel (relire `skills/livrer/SKILL.md`)
- [x] README et CHANGELOG à jour, `plugin.json` en 3.7.0, aucun chemin de projet hors exemple — test : manuel (`grep -n "web/\|packages/kit" agents skills hooks -r` ne renvoie rien)

## 7. Tests
```bash
bash tests/test_secrets.sh | grep -v '^OK'
bash tests/test_hooks.sh | grep -v '^OK'
```

## 8. Questions ouvertes
- Ligne `Banc :` absente ou périmée : le relecteur relance-t-il lui-même la suite (recommandé, choix de cette spec), ou bloque-t-il directement comme le propose #43 ?
- Suite déjà rouge sur `main` : toute PR qui touche les globs est bloquée. On garde ce choix (recommandé), ou on ajoute une échappatoire ?
- Vocabulaire générique : directive `exige` et ligne « Banc : … » au lieu de « Parcours banc : … » (« parcours » est un terme de Hive). À confirmer.
