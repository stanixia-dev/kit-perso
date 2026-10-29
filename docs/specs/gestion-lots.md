# Spec — gestion de lots

## 1. Objectif
Permettre de découper une spec en lots livrés l'un après l'autre sur la même branche : un lot = un commit vert, coché dans la spec. Il reste une seule PR et un seul passage du relecteur. Une petite spec n'a pas de section Lots et le flux actuel ne change pas.

## 2. Hors périmètre
- Pas de nouveau fichier de suivi ni de nouvel agent : l'état des lots, ce sont les cases à cocher de la spec.
- `skills/livrer/` n'est pas modifié : il pousse la branche et renvoie à la spec, où les lots sont visibles. Cela suffit.
- `agents/explorateur.md`, `hooks/`, `tests/` et `~/.claude/CLAUDE.md` ne changent pas (l'utilisateur adaptera lui-même sa table d'orchestration s'il le veut).
- Le relecteur ne rejoue pas les tests commit par commit : il est en lecture seule, et c'est le codeur qui garantit qu'un commit est vert.

## 3. Fichiers
- `agents/specs.md` — modifier — ajoute l'item 8 « Lots » (facultatif) au format de spec.
- `agents/codeur.md` — modifier — ajoute la règle « un lot = un commit coché ».
- `agents/relecteur.md` — modifier — ajoute la vérification lot par lot et une ligne par lot dans le rapport.
- `README.md` — modifier — ajoute une section `## Flux avec lots`.
- `CHANGELOG.md` — modifier — ajoute l'entrée 0.2.0.
- `.claude-plugin/plugin.json` — modifier — passe `version` à `0.2.0` (c'est la seule source de la version, voir le README ; sans montée, `update` ne récupère rien).

## 4. Étapes
Les blocs `~~~~` se recopient tels quels, sans l'indentation de la liste.
1. `agents/specs.md` : après l'item 7, avant « Choisis la solution… », insère exactement ce texte :
   ~~~~
   8. **Lots** (facultatif) — seulement si le travail se découpe en au moins 2 étapes testables séparément ; sinon, omets la section. Sous le titre `## Lots`, chaque lot tient en 3 lignes :
      ```
      - [x] L1 — <objectif> (étapes 1-2)
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
   - Si la spec a une section `## Lots` : les lots de la PR sont ceux que `git diff main...HEAD -- <spec>` fait passer à `- [x]`. Pour chacun, retrouve son commit (`git log --oneline main..HEAD`, suffixe `(L<n>)`), vérifie avec `git show --stat <commit>` qu'il ne touche que les fichiers du lot et la spec, puis relance sa commande « Fait quand ». Sont bloquants : un lot non coché avant la prochaine `> Coupure PR`, un commit sans lot, un lot sans commit, un fichier hors lot.
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

## 5. Critères d'acceptation
- [ ] `agents/specs.md` contient l'item 8 avec le gabarit à 3 lignes et la règle `> Coupure PR` au-delà de 5 lots.
- [ ] `agents/codeur.md` impose : un commit par lot, suffixe `(L<n>)`, case cochée dans le même commit, arrêt sans commit si un lot échoue.
- [ ] `agents/relecteur.md` délimite les lots de la PR par le diff de la spec, liste les 4 cas bloquants et ajoute une ligne par lot au rapport.
- [ ] Une spec sans `## Lots` ne déclenche aucune des nouvelles règles : chaque ajout commence par « Si la spec a une section `## Lots` » ou porte la mention « facultatif ».
- [ ] README (`## Flux avec lots`), CHANGELOG (`## 0.2.0`) et `plugin.json` (`0.2.0`) sont à jour.
- [ ] `git log --oneline main..HEAD` montre 4 commits suffixés `(L1)` à `(L4)`, et les 4 lots ci-dessous sont cochés.
- [ ] Les fichiers listés en Hors périmètre sont inchangés : `git diff --stat main...HEAD` ne liste que les 6 fichiers de la section 3 et cette spec.

## 6. Tests
```
bash tests/test_hooks.sh && claude plugin validate --strict .
git diff --stat main...HEAD
git log --oneline main..HEAD
```

## 7. Questions ouvertes
(aucune)

## Lots
- [x] L1 — Ajouter le format Lots à l'agent specs (étape 1)
  Fichiers : agents/specs.md
  Fait quand : l'item 8 est présent — `grep -q '^8\. \*\*Lots\*\*' agents/specs.md && grep -q 'Coupure PR' agents/specs.md && bash tests/test_hooks.sh`
- [ ] L2 — Ajouter la règle des lots au codeur (étape 2)
  Fichiers : agents/codeur.md
  Fait quand : la règle est présente — `grep -q '(L<n>)' agents/codeur.md && grep -q 'une ligne par lot' agents/codeur.md && bash tests/test_hooks.sh`
- [ ] L3 — Ajouter la vérification lot par lot au relecteur (étape 3)
  Fichiers : agents/relecteur.md
  Fait quand : la vérification est présente — `grep -q 'git show --stat' agents/relecteur.md && grep -q 'L<n> — OK' agents/relecteur.md && bash tests/test_hooks.sh`
- [ ] L4 — Documenter la fonctionnalité et passer en 0.2.0 (étapes 4-6)
  Fichiers : README.md, CHANGELOG.md, .claude-plugin/plugin.json
  Fait quand : la doc et la version sont à jour — `grep -q '^## Flux avec lots' README.md && grep -q '^## 0.2.0' CHANGELOG.md && grep -q '"version": "0.2.0"' .claude-plugin/plugin.json && claude plugin validate --strict .`
