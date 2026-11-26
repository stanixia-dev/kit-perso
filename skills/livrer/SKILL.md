---
name: livrer
description: Pousse la branche claude/<sujet> courante et ouvre la PR avec un corps structuré. À utiliser seulement quand le relecteur a rendu OK sur le HEAD courant (pas après un correctif non relu) ; l'orchestrateur la lance alors de lui-même.
argument-hint: "[chemin de la spec]"
---

Livre la branche courante : $ARGUMENTS (chemin de la spec, facultatif).

1. Invoquée sans demande de l'utilisateur et sans relecture OK du HEAD courant : arrête-toi et dis-le. Refuse aussi si `git branch --show-current` ne commence pas par `claude/` ou si `git status --porcelain` n'est pas vide. Explique pourquoi et arrête-toi.
2. Lance les tests/lint du projet ; s'ils échouent, arrête-toi et dis-le.
3. Contrôle de la CI (lecture seule ; ne bloque pas : annonce clairement le résultat puis continue, sans demander) :
   - `git fetch -q origin main`, puis `W` = `git ls-tree --name-only origin/main .github/workflows/` filtré sur `*.yml|*.yaml`.
   - `D` : `git grep -q verifie-manifestes origin/main -- .github/workflows` (job `deps` du kit présent).
   - `R` (rulesets) : `gh api repos/{owner}/{repo}/rules/branches/main --jq '[.[] | select(.type == "required_status_checks")] | length'` ; échec avec `HTTP 403` et `Upgrade to GitHub Pro` sur stderr = plan gratuit (voir `G`) ; autre échec = inconnu.
   - `P` (protection classique) : `gh api repos/{owner}/{repo}/branches/main/protection --jq '.required_status_checks.checks | length'` ; échec avec `HTTP 404` sur stderr = 0 (pas de protection) ; échec avec `HTTP 403` et `Upgrade to GitHub Pro` = plan gratuit (voir `G`) ; autre échec = inconnu. Pas de `//` dans `--jq`.
   - `G` : `R` ou `P` a répondu 403 « Upgrade to GitHub Pro ». Ce n'est pas une erreur : la valeur concernée compte 0 (pas « inconnu »).
   - « Checks exigés » = `R` > 0 ou `P` > 0. Messages (préfixe `CI :`) :
     - `W` vide et aucun check exigé : « ce dépôt n'a aucune CI : rien ne vérifiera la PR. Lance /kit-perso:ci-projet. »
     - `W` non vide sans `D` : « workflows présents sans le job deps du kit (/kit-perso:ci-projet --sans-tests) »
     - `W` non vide sans check exigé : « checks non obligatoires sur main : Settings > Rules > Rulesets »
     - check exigé et `W` vide : « des checks sont exigés mais aucun workflow sur main : la PR restera bloquée »
     - `G` : « plan gratuit : checks obligatoires indisponibles » (remplace « checks non obligatoires sur main » ; ne produit pas « règles illisibles »)
     - `R` ou `P` inconnu (hors `G`) : « règles de main illisibles (droits ou réseau) »

   Répète ces messages dans le message final.
4. `git push -u origin <branche>`.
5. `gh pr create` avec un titre en français et un corps contenant les sections :
   - Quoi
   - Pourquoi
   - Comment tester
   - Spec (lien vers le chemin donné en argument ; s'il n'existe plus, vers `docs/specs/archives/<même nom>`)

   - Tickets, seulement si la spec porte une ligne `Tickets : #a, #b` : une ligne `Closes #a` par ticket si la spec est archivée (PR qui la termine), sinon `Refs #a`

   Termine le corps par la ligne d'attribution demandée par le contexte, si elle existe.
6. Suis la CI via l'API REST (pas la commande `gh pr checks` en mode suivi, incompatible avec un jeton à droits fins) et sans `sleep` long au premier plan. Lance la boucle en arrière-plan (`run_in_background` ou Monitor), puis attends sa fin :
   ```
   B=$(git branch --show-current); C=$(git rev-parse HEAD); T=$(date +%s)
   until [ "$(gh run list --branch "$B" --commit "$C" --json status --jq 'length > 0 and all(.[]; .status == "completed")')" = true ] \
       || { [ $(( $(date +%s) - T )) -gt 300 ] && [ "$(gh run list --branch "$B" --commit "$C" --json status --jq '[.[] | select(.status != "completed") | .status] | unique == ["queued"]')" = true ]; } \
       || [ $(( $(date +%s) - T )) -gt 600 ]; do sleep 20; done
   gh run list --branch "$B" --commit "$C" --json status,conclusion,name,databaseId,createdAt
   ```
   La boucle attend tant qu'aucun run n'apparaît (plafond 10 min). Commande de revérification : `gh run list --branch "$B" --commit "$C" --json status,conclusion,name,databaseId,createdAt`.
   - Aucun run à la sortie : si `W` était vide, dis « pas de CI configurée (/kit-perso:ci-projet) », et sinon « CI configurée mais pas déclenchée : vérifier `on:` du workflow, Actions activées (Settings > Actions), workflow présent sur main ».
   - Sortie après plus de 5 min avec tous les runs non terminés en `queued` : dis « runner occupé ou hors ligne » et rends la main, avec la commande de revérification.
   - Plafond de 10 min atteint avec des runs encore en cours : dis « CI toujours en cours après 10 min » et rends la main, avec la commande de revérification.
   - Rouge (`conclusion` autre que `success`, `skipped` ou `neutral`, donc aussi `cancelled`, `timed_out`, `action_required`) : donne le check en échec et les 30 dernières lignes de `gh run view <databaseId> --log-failed`, sans corriger : l'utilisateur décide.
7. Termine par l'état de la CI (avec les messages `CI :` du contrôle), le lien de la PR, un résumé en 3 lignes et le rappel de faire `/clear`. Ne commence pas d'autre tâche.

Interdit : `--force`, `gh pr merge`, tout push sur `main`.
