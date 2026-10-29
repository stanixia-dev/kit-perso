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

DEPS_ENV="GARDE_DEPS_FIXTURES=tests/fixtures/garde-deps.json GARDE_DEPS_AUJOURDHUI=2026-10-29"
code_deps() { # $1 = commande
  printf '{"tool_input":{"command":"%s"}}' "$1" | env $DEPS_ENV python3 hooks/garde-deps.py >/dev/null 2>&1
  echo $?
}
sortie_deps() {
  printf '{"tool_input":{"command":"%s"}}' "$1" | env $DEPS_ENV python3 hooks/garde-deps.py 2>/dev/null
}
erreur_deps() {
  printf '{"tool_input":{"command":"%s"}}' "$1" | env $DEPS_ENV python3 hooks/garde-deps.py 2>&1 >/dev/null
}

[ "$(code_garde 'git push origin main')" = 2 ] && ok "garde-git bloque git push origin main" || ko "garde-git push main"
[ "$(code_garde 'gh pr merge 1')" = 2 ] && ok "garde-git bloque gh pr merge" || ko "garde-git pr merge"
[ "$(code_garde 'git status')" = 0 ] && ok "garde-git laisse passer git status" || ko "garde-git status"
sortie_rappel 'gh pr create --fill' | grep -q '/clear' && ok "rappel-clear après gh pr create" || ko "rappel-clear pr create"
[ -z "$(sortie_rappel 'ls')" ] && ok "rappel-clear muet sur ls" || ko "rappel-clear ls"

# garde-deps : "commande|attendu" (0 = passe sans sortie, 2 = bloque)
for c in 'cargo add bon' 'pnpm add @scope/ok@1.0.0' 'cargo add mixte' \
         'npm install' 'pip install -r requirements.txt' 'pip install -e .' 'npm i ./local' 'cargo add --path ../x'; do
  [ "$(code_deps "$c")" = 0 ] && [ -z "$(sortie_deps "$c")" ] && ok "garde-deps laisse passer $c" || ko "garde-deps $c"
done
for c in 'npm install gpl-pkg' 'npm i sanslicence' 'yarn add prive' 'npm add deprecie' 'cargo add colle' \
         'cargo add retire@0.1.0' 'pip install vieux' 'ls && npm i gpl-pkg' "bash -c 'npm i gpl-pkg'"; do
  [ "$(code_deps "$c")" = 2 ] && ok "garde-deps bloque $c" || ko "garde-deps $c"
done
[ "$(code_deps 'cargo add faille@1.2.3')" = 2 ] && erreur_deps 'cargo add faille@1.2.3' | grep -q 'RUSTSEC-2099-0001' \
  && ok "garde-deps cite la faille OSV" || ko "garde-deps faille OSV"
[ "$(code_deps 'uv add mpl')" = 0 ] && sortie_deps 'uv add mpl' | grep -q 'MPL-2.0' \
  && ok "garde-deps avertit sur MPL-2.0" || ko "garde-deps MPL"
[ "$(code_deps 'pip3 install inconnu')" = 0 ] && sortie_deps 'pip3 install inconnu' | grep -q 'vérification impossible' \
  && ok "garde-deps avertit si injoignable" || ko "garde-deps injoignable"

exit $((ECHECS > 0))
