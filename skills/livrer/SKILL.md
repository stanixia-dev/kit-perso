---
name: livrer
description: Pousse la branche claude/<sujet> courante et ouvre la PR avec un corps structuré. À utiliser quand la relecture est OK et que l'utilisateur demande de livrer.
argument-hint: "[chemin de la spec]"
disable-model-invocation: true
---

Livre la branche courante : $ARGUMENTS (chemin de la spec, facultatif).

1. Refuse si `git branch --show-current` ne commence pas par `claude/` ou si `git status --porcelain` n'est pas vide. Explique pourquoi et arrête-toi.
2. Lance les tests/lint du projet ; s'ils échouent, arrête-toi et dis-le.
3. Contrôle de la CI (lecture seule ; ne bloque pas : annonce clairement le résultat puis continue, sans demander) :
   - `git fetch -q origin main`, puis `W` = `git ls-tree --name-only origin/main .github/workflows/` filtré sur `*.yml|*.yaml`.
   - `D` : `git grep -q verifie-manifestes origin/main -- .github/workflows` (job `deps` du kit présent).
   - `R` (rulesets) : `gh api repos/{owner}/{repo}/rules/branches/main --jq '[.[] | select(.type == "required_status_checks")] | length'` ; échec = inconnu.
   - `P` (protection classique) : `gh api repos/{owner}/{repo}/branches/main/protection --jq '.required_status_checks.checks | length'` ; échec avec `HTTP 404` sur stderr = 0 (pas de protection) ; autre échec = inconnu. Pas de `//` dans `--jq`.
   - « Checks exigés » = `R` > 0 ou `P` > 0. Messages (préfixe `CI :`) :
     - `W` vide et aucun check exigé : « ce dépôt n'a aucune CI : rien ne vérifiera la PR. Lance /kit-perso:ci-projet. »
     - `W` non vide sans `D` : « workflows présents sans le job deps du kit (/kit-perso:ci-projet --sans-tests) »
     - `W` non vide sans check exigé : « checks non obligatoires sur main : Settings > Rules > Rulesets »
     - check exigé et `W` vide : « des checks sont exigés mais aucun workflow sur main : la PR restera bloquée »
     - `R` ou `P` inconnu : « règles de main illisibles (droits ou réseau) »

   Répète ces messages dans le message final.
4. `git push -u origin <branche>`.
5. `gh pr create` avec un titre en français et un corps contenant les sections :
   - Quoi
   - Pourquoi
   - Comment tester
   - Spec (lien vers le chemin donné en argument ; s'il n'existe plus, vers `docs/specs/archives/<même nom>`)

   - Tickets, seulement si la spec porte une ligne `Tickets : #a, #b` : une ligne `Closes #a` par ticket si la spec est archivée (PR qui la termine), sinon `Refs #a`

   Termine le corps par la ligne d'attribution demandée par le contexte, si elle existe.
6. Suis la CI : `gh pr checks --watch --interval 20` (délai Bash de 10 min). Si gh ne signale aucun check, relance une fois après quelques secondes ; sinon, si `W` était vide, dis « pas de CI configurée (/kit-perso:ci-projet) », et sinon « CI configurée mais pas déclenchée : vérifier `on:` du workflow, Actions activées (Settings > Actions), workflow présent sur main ». Si elle est rouge, donne le check en échec et les 30 dernières lignes de `gh run view <id> --log-failed` (id via `gh run list --branch <branche> -L 1`), sans corriger : l'utilisateur décide.
7. Termine par l'état de la CI (avec les messages `CI :` du contrôle), le lien de la PR, un résumé en 3 lignes et le rappel de faire `/clear`. Ne commence pas d'autre tâche.

Interdit : `--force`, `gh pr merge`, tout push sur `main`.
