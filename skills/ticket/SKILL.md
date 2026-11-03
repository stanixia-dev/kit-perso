---
name: ticket
description: Ouvre ou complète un ticket GitHub du dépôt courant au format standard. À utiliser quand l'utilisateur demande de signaler un problème ou un retour.
argument-hint: "<constat à signaler>"
disable-model-invocation: true
---

Signale dans un ticket du dépôt courant : $ARGUMENTS (le constat).

1. Vérifie l'accès avec `gh issue list -L 1` ; en cas d'échec, dis-le et arrête-toi.
2. Un ticket par problème. Cherche un doublon parmi tes propres tickets : `gh issue list --author @me --state open --search "<mots-clés>"`. Doublon : `gh issue comment <n> --body-file <f>` ; sinon `gh issue create --title "<titre>" --body-file <f>`.
3. Titre en français, 70 caractères au plus, qui nomme le problème, pas la solution.
4. Écris le corps dans un fichier du scratchpad (jamais de secret), une ligne par rubrique :
   - `**Constat** : <faits, fichier:ligne>`
   - `**Proposition** : <changement, ou « à définir »>`
   - `**Source** : <dépôt#n, commit ou PR d'origine>`
   - `**Reproduire** : <commande ou étapes, ou « non reproductible »>`

   Termine le corps par la ligne d'attribution demandée par le contexte, si elle existe.
5. Termine par les liens des tickets créés ou commentés.

Interdit : `-R`/`--repo`, toute autre sous-commande que `list`, `view`, `create`, `comment`, commenter un ticket dont l'utilisateur n'est pas l'auteur.
