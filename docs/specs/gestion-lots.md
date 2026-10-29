# Spec — gestion de lots
Statut : en cours

## 1. Objectif
Permettre de découper une spec en lots livrés l'un après l'autre sur la même branche : un lot = un commit vert, coché dans la spec. Il reste une seule PR et un seul passage du relecteur. Une petite spec n'a pas de section Lots et le flux actuel ne change pas. Toute spec, avec ou sans lots, porte un statut (`en cours` → `livrée`), se clôture dans le dernier commit du codeur et part alors dans `docs/specs/archives/`.

## 2. Hors périmètre
- Pas de nouveau fichier de suivi ni de nouvel agent : l'état des lots, ce sont les cases à cocher de la spec.
- `skills/livrer/` ne change que pour lier la spec archivée (L6).
- `agents/explorateur.md`, `hooks/`, `tests/` et `~/.claude/CLAUDE.md` ne changent pas (l'utilisateur adaptera lui-même sa table d'orchestration s'il le veut). La spec existante `docs/specs/plugin-kit-perso.md` est clôturée et archivée en L6 (étape 17).
- Le relecteur ne rejoue pas les tests commit par commit : il est en lecture seule, et c'est le codeur qui garantit qu'un commit est vert.

## 3. Fichiers
- `agents/specs.md` — modifier — ajoute l'item 8 « Lots » (facultatif) au format de spec ; ligne de statut, sujet hors archives, « Fait quand » sans chemin de spec (L5-L6).
- `agents/codeur.md` — modifier — ajoute la règle « un lot = un commit coché » ; puces Clôture (L5) et Archivage (L6).
- `agents/relecteur.md` — modifier — ajoute la vérification lot par lot et une ligne par lot dans le rapport ; puce Clôture (L5), spec retrouvée dans `archives/` (L6).
- `skills/livrer/SKILL.md` — modifier — lien vers la spec archivée (L6).
- `README.md` — modifier — ajoute une section `## Flux avec lots`, puis `## Clôture et archivage` (L6).
- `CHANGELOG.md` — modifier — ajoute l'entrée 0.2.0, complétée en L6 (0.2.0 n'est pas publiée : pas de 0.3.0).
- `.claude-plugin/plugin.json` — modifier — passe `version` à `0.2.0` (c'est la seule source de la version, voir le README ; sans montée, `update` ne récupère rien).

## 4. Étapes
Les blocs `~~~~` se recopient tels quels, sans l'indentation de la liste.
1. `agents/specs.md` : après l'item 7, avant « Choisis la solution… », insère exactement ce texte :
   ~~~~
   8. **Lots** (facultatif) — seulement si le travail se découpe en au moins 2 étapes testables séparément ; sinon, omets la section. Sous le titre `## Lots`, chaque lot tient en 3 lignes :
      ```
      - [ ] L1 — <objectif> (étapes 1-2)
        Fichiers : <chemins>
        Fait quand : <critère> — `<commande de test>`
      ```
      Après chaque lot, les tests du projet doivent passer. Au-delà de 5 lots, insère la ligne `> Coupure PR` entre deux lots (5 lots au plus par PR).
   ~~~~
2. `agents/codeur.md` : avant « Si la spec est ambiguë… », insère cette puce :
   ~~~~
   - Si la spec a une section `## Lots` : traite dans l'ordre les lots non cochés, jusqu'à la prochaine ligne `> Coupure PR` (ou ceux que le brief désigne). Pour chaque lot : implémente-le, lance sa commande « Fait quand » et les tests du projet, coche le lot (`- [ ]` → `- [x]`) dans la spec, puis fais un seul commit (code + spec) dont le message finit par `(L<n>)`. Si un lot échoue, arrête-toi sans commiter et explique pourquoi.
   ~~~~
   Puis, dans la ligne « Rapport final », remplace « commits créés » par « commits créés (une ligne par lot s'il y en a) ».
3. `agents/relecteur.md` : après la puce « Relance les tests… », insère cette puce :
   ~~~~
   - Si la spec a une section `## Lots` : les lots de la PR sont ceux cochés `- [x]` dans la spec à HEAD mais pas dans `main` (ou absents de `main`), hors blocs de code. Pour chacun, retrouve son commit (`git log --oneline main..HEAD`, suffixe `(L<n>)`), vérifie avec `git show --stat <commit>` qu'il ne touche que les fichiers du lot et la spec, puis relance sa commande « Fait quand ». Sont admis sans lot : un commit qui ne touche que la spec, et un correctif après relecture suffixé `(L<n>)` du lot corrigé. Sont bloquants : un lot non coché avant la prochaine `> Coupure PR`, tout autre commit sans lot, un lot sans commit, un fichier hors lot.
   ~~~~
   Puis, dans la ligne « Rapport », ajoute après « verdict (OK / À corriger), » le texte « une ligne `L<n> — OK / À corriger` par lot s'il y en a, ».
4. `README.md` : après la section « Ajouter un élément », ajoute `## Flux avec lots` (≤ 10 lignes) :
   - quand l'utiliser (spec découpable en lots testables séparément ; sinon, flux inchangé) et où se trouve le format (item 8 de `agents/specs.md`) ;
   - un lot = un commit vert sur `claude/<sujet>`, coché dans la spec ; une seule PR ; un seul relecteur, à la fin ;
   - avec `> Coupure PR` : livrer la première PR, attendre que l'utilisateur la fusionne, faire `/clear`, puis créer `claude/<sujet>-2` depuis `main` à jour ; le codeur reprend aux lots non cochés (les cases cochées sont arrivées dans `main` avec la fusion).
5. `CHANGELOG.md` : au-dessus de 0.1.0, ajoute :
   ~~~~
   ## 0.2.0 — <date du jour>

   - Gestion de lots : section facultative `## Lots` dans les specs, un commit par lot, relecture lot par lot.
   ~~~~
6. `.claude-plugin/plugin.json` : `"version": "0.2.0"`.
7. Applique la section Lots ci-dessous à cette spec : un commit par lot, et coche chaque lot.

Étapes 8 à 16 : le texte entre « » s'insère tel quel (sans les guillemets) ; une « puce » est une ligne qui commence par `- `.
8. (L5) `agents/specs.md` : remplace la ligne « Format de la spec (≤ 120 lignes) : » par « Format de la spec (≤ 120 lignes), avec sous le titre la ligne `Statut : en cours` (le codeur la passe à `Statut : livrée` à la clôture) : ».
9. (L5) `agents/codeur.md` : avant « Si la spec est ambiguë… », insère la puce « Clôture : dans le commit qui coche le dernier lot de la spec (ou, sans `## Lots`, dans ton dernier commit), coche aussi les critères d'acceptation remplis et remplace `Statut : en cours` par `Statut : livrée` (ajoute la ligne sous le titre si elle manque). Si un critère n'est pas rempli, laisse-le décoché, garde `Statut : en cours` et signale-le. »
10. (L5) `agents/relecteur.md` : avant « Ne signale que ce qui compte… », insère la puce « Clôture : si la PR termine la spec (aucun lot non coché, ou pas de `## Lots`), la spec doit porter `Statut : livrée` sous son titre et tous ses critères d'acceptation cochés, hors blocs de code ; sinon, `Statut : en cours`. Un écart, ou un critère coché mais non rempli, est bloquant. »
11. (L6) `agents/specs.md` : à la fin de la ligne « Écris uniquement dans `docs/specs/<sujet>.md`… », ajoute « Choisis un `<sujet>` absent de `docs/specs/archives/`. » ; à la fin du paragraphe « Après chaque lot… » de l'item 8, ajoute « Les commandes « Fait quand » ne citent pas le chemin de la spec : elle est archivée au dernier lot. »
12. (L6) `agents/codeur.md` : après la puce « Clôture… », insère la puce « Archivage : dans ce même commit, si la spec passe à `livrée`, après les tests et la mise à jour des cases et du statut, fais `mkdir -p docs/specs/archives && git mv docs/specs/<sujet>.md docs/specs/archives/<sujet>.md`, puis `git add` le nouveau chemin et commite. Avec `> Coupure PR`, seule la PR du dernier lot archive. Si le chemin de spec reçu n'existe plus, cherche-la dans `docs/specs/archives/`. »
13. (L6) `agents/relecteur.md` : remplace la puce « Examine `git diff main...HEAD` et la spec fournie. » par la puce « Examine `git diff main...HEAD` et la spec fournie : si son chemin n'existe plus, elle est dans `docs/specs/archives/` ; dans `main`, lis-la à son ancien chemin (`git show main:docs/specs/<sujet>.md`). » Puis, à la fin de la puce « Clôture… », ajoute « Si la PR termine la spec, elle doit être à HEAD dans `docs/specs/archives/` (ce renommage compte comme une modification de la spec) ; sinon, dans `docs/specs/`. »
14. (L6) `skills/livrer/SKILL.md` : remplace « Spec (lien vers le chemin donné en argument, s'il existe) » par « Spec (lien vers le chemin donné en argument ; s'il n'existe plus, vers `docs/specs/archives/<même nom>`) ».
15. (L6) `README.md` : après la section `## Flux avec lots`, ajoute :
   ~~~~
   ## Clôture et archivage

   Toute spec porte sous son titre `Statut : en cours`. Dans le commit de son dernier lot (ou son dernier commit, sans lots), le codeur coche les critères d'acceptation remplis, passe la ligne à `Statut : livrée` et déplace la spec dans `docs/specs/archives/`. Avec `> Coupure PR`, seule la dernière PR archive. Le relecteur vérifie statut, cases et emplacement ; `livrer` lie la spec archivée.
   ~~~~
16. (L6) `CHANGELOG.md` : sous la puce de 0.2.0, sans changer ni la version ni la date, ajoute la puce « Clôture et archivage des specs : ligne `Statut : en cours` → `Statut : livrée`, critères cochés et déplacement dans `docs/specs/archives/` au dernier commit. »
17. (L6) Clôture de cette spec, dans le commit de L6 et dans cet ordre : a) étapes 11-16 ; b) commande « Fait quand » de L6 ; c) coche L6 et tous les critères de la section 5 (ceux sur le log, le diff et l'archivage se cochent par anticipation : le relecteur les vérifie avec la section 6), et remplace `Statut : en cours` par `Statut : livrée` ; d) `mkdir -p docs/specs/archives && git mv docs/specs/gestion-lots.md docs/specs/archives/gestion-lots.md`, puis ajoute `Statut : livrée` sous le titre de `docs/specs/plugin-kit-perso.md` et `git mv` vers `docs/specs/archives/plugin-kit-perso.md` ; e) `git add` des fichiers du lot et des deux specs archivées, commit suffixé `(L6)` ; f) dernière commande de la section 6. Aucun « Fait quand » ne cite la spec : tous restent valides après le déplacement.

## 5. Critères d'acceptation
- [ ] `agents/specs.md` contient l'item 8 avec le gabarit à 3 lignes et la règle `> Coupure PR` au-delà de 5 lots.
- [ ] `agents/codeur.md` impose : un commit par lot, suffixe `(L<n>)`, case cochée dans le même commit, arrêt sans commit si un lot échoue.
- [ ] `agents/relecteur.md` délimite les lots de la PR par le diff de la spec, liste les 4 cas bloquants et ajoute une ligne par lot au rapport.
- [ ] Une spec sans `## Lots` ne déclenche aucune règle de lots : chaque ajout de L1-L3 commence par « Si la spec a une section `## Lots` » ou porte la mention « facultatif » ; seules la clôture et l'archivage (L5-L6) valent pour toute spec.
- [ ] `agents/specs.md` impose `Statut : en cours` sous le titre, un sujet absent de `docs/specs/archives/` et des « Fait quand » sans chemin de spec ; `skills/livrer/SKILL.md` lie la spec archivée quand le chemin donné n'existe plus.
- [ ] `agents/codeur.md` clôture dans le dernier commit (critères remplis cochés, `Statut : livrée`, ligne ajoutée si absente) et archive dans ce même commit par `git mv`, seulement dans la dernière PR.
- [ ] `agents/relecteur.md` retrouve la spec dans `docs/specs/` ou `archives/`, et bloque si statut, cases et emplacement ne concordent pas.
- [ ] README (`## Flux avec lots`, `## Clôture et archivage`), CHANGELOG (`## 0.2.0` à 2 puces, pas de `## 0.3.0`) et `plugin.json` (`0.2.0`) sont à jour.
- [ ] `git log --oneline main..HEAD` montre 6 commits suffixés `(L1)` à `(L6)`, plus le correctif `042b624` suffixé `(L3)` ; seuls les commits qui ne touchent que la spec n'ont pas de suffixe, et les 6 lots ci-dessous sont cochés.
- [ ] Les fichiers listés en Hors périmètre sont inchangés : `git diff --stat main...HEAD` ne liste que les 7 fichiers de la section 3, `docs/specs/archives/gestion-lots.md` et le déplacement de `plugin-kit-perso.md` vers `docs/specs/archives/`.
- [ ] Cette spec est clôturée et archivée : la dernière commande de la section 6 réussit.

## 6. Tests
```
bash tests/test_hooks.sh && claude plugin validate --strict .
git diff --stat main...HEAD
git log --oneline main..HEAD
test ! -e docs/specs/gestion-lots.md && grep -q '^Statut : livrée$' docs/specs/archives/gestion-lots.md && ! grep -q '^- \[ \]' docs/specs/archives/gestion-lots.md
```

## 7. Questions ouvertes
(aucune)

## Lots
- [x] L1 — Ajouter le format Lots à l'agent specs (étape 1)
  Fichiers : agents/specs.md
  Fait quand : l'item 8 est présent — `grep -q '^8\. \*\*Lots\*\*' agents/specs.md && grep -q 'Coupure PR' agents/specs.md && bash tests/test_hooks.sh`
- [x] L2 — Ajouter la règle des lots au codeur (étape 2)
  Fichiers : agents/codeur.md
  Fait quand : la règle est présente — `grep -q '(L<n>)' agents/codeur.md && grep -q 'une ligne par lot' agents/codeur.md && bash tests/test_hooks.sh`
- [x] L3 — Ajouter la vérification lot par lot au relecteur (étape 3)
  Fichiers : agents/relecteur.md
  Fait quand : la vérification est présente — `grep -q 'git show --stat' agents/relecteur.md && grep -q 'L<n> — OK' agents/relecteur.md && bash tests/test_hooks.sh`
- [x] L4 — Documenter la fonctionnalité et passer en 0.2.0 (étapes 4-6)
  Fichiers : README.md, CHANGELOG.md, .claude-plugin/plugin.json
  Fait quand : la doc et la version sont à jour — `grep -q '^## Flux avec lots' README.md && grep -q '^## 0.2.0' CHANGELOG.md && grep -q '"version": "0.2.0"' .claude-plugin/plugin.json && claude plugin validate --strict .`
- [ ] L5 — Clôturer les specs : statut et critères cochés au dernier commit (étapes 8-10)
  Fichiers : agents/specs.md, agents/codeur.md, agents/relecteur.md
  Fait quand : la clôture est présente — `grep -q 'Statut : en cours' agents/specs.md && grep -q '^- Clôture :' agents/codeur.md && grep -q '^- Clôture :' agents/relecteur.md && bash tests/test_hooks.sh`
- [ ] L6 — Archiver les specs, documenter, puis clôturer et archiver cette spec (étapes 11-17)
  Fichiers : agents/specs.md, agents/codeur.md, agents/relecteur.md, skills/livrer/SKILL.md, README.md, CHANGELOG.md, docs/specs/plugin-kit-perso.md
  Fait quand : l'archivage est en place — `test "$(grep -l 'docs/specs/archives/' agents/specs.md agents/codeur.md agents/relecteur.md skills/livrer/SKILL.md | wc -l)" = 4 && grep -q '^## Clôture et archivage' README.md && grep -q 'archives' CHANGELOG.md && ! grep -q '^## 0.3' CHANGELOG.md && claude plugin validate --strict . && bash tests/test_hooks.sh`
