#!/usr/bin/env bash
# Tests des hooks par stdin JSON. Lancer depuis n'importe où.
set -u
cd "$(dirname "$0")/.." || exit 1
ECHECS=0
ok() { echo "OK    $1"; }
ko() { echo "ECHEC $1"; ECHECS=$((ECHECS + 1)); }

code_garde() { # $1 = commande
  printf '{"tool_input":{"command":"%s"},"cwd":"/tmp"}' "$1" | python3 hooks/garde-git.py >/dev/null 2>&1
  echo $?
}
sortie_rappel() {
  printf '{"tool_input":{"command":"%s"}}' "$1" | python3 hooks/rappel-clear.py 2>/dev/null
}

[ "$(code_garde 'git push origin main')" = 2 ] && ok "garde-git bloque git push origin main" || ko "garde-git push main"
[ "$(code_garde 'gh pr merge 1')" = 2 ] && ok "garde-git bloque gh pr merge" || ko "garde-git pr merge"
[ "$(code_garde 'git status')" = 0 ] && ok "garde-git laisse passer git status" || ko "garde-git status"
sortie_rappel 'gh pr create --fill' | grep -q '/clear' && ok "rappel-clear après gh pr create" || ko "rappel-clear pr create"
[ -z "$(sortie_rappel 'ls')" ] && ok "rappel-clear muet sur ls" || ko "rappel-clear ls"

exit $((ECHECS > 0))
