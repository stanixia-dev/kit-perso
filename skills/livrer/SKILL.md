---
name: livrer
description: Pousse la branche claude/<sujet> courante et ouvre la PR avec un corps structuré. À utiliser quand la relecture est OK et que l'utilisateur demande de livrer.
argument-hint: "[chemin de la spec]"
disable-model-invocation: true
---

Livre la branche courante : $ARGUMENTS (chemin de la spec, facultatif).

1. Refuse si `git branch --show-current` ne commence pas par `claude/` ou si `git status --porcelain` n'est pas vide. Explique pourquoi et arrête-toi.
2. Lance les tests/lint du projet ; s'ils échouent, arrête-toi et dis-le.
3. `git push -u origin <branche>`.
4. `gh pr create` avec un titre en français et un corps contenant les sections :
   - Quoi
   - Pourquoi
   - Comment tester
   - Spec (lien vers le chemin donné en argument ; s'il n'existe plus, vers `docs/specs/archives/<même nom>`)

   Termine le corps par la ligne d'attribution demandée par le contexte, si elle existe.
5. Suis la CI : `gh pr checks --watch --interval 20` (délai Bash de 10 min). Si gh ne signale aucun check, relance une fois après quelques secondes ; sinon, dis que la CI ne s'est pas déclenchée. Si elle est rouge, donne le check en échec et les 30 dernières lignes de `gh run view <id> --log-failed` (id via `gh run list --branch <branche> -L 1`), sans corriger : l'utilisateur décide.
6. Termine par l'état de la CI, le lien de la PR, un résumé en 3 lignes et le rappel de faire `/clear`. Ne commence pas d'autre tâche.

Interdit : `--force`, `gh pr merge`, tout push sur `main`.
