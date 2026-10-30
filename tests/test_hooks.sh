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

PROFOND=ls; PROFOND_AJOUT='npm i gpl-pkg'
for _ in 1 2 3 4 5 6 7 8 9 10; do PROFOND="echo \$($PROFOND)"; PROFOND_AJOUT="echo \$($PROFOND_AJOUT)"; done
DEPS_ENV="GARDE_DEPS_FIXTURES=tests/fixtures/garde-deps.json GARDE_DEPS_AUJOURDHUI=2026-10-29"
json_cmd() { local c=${1//\\/\\\\}; c=${c//\"/\\\"}; printf '{"tool_input":{"command":"%s"}}' "${c//$'\n'/\\n}"; }
code_deps() { # $1 = commande
  json_cmd "$1" | env $DEPS_ENV python3 hooks/garde-deps.py >/dev/null 2>&1
  echo $?
}
sortie_deps() {
  json_cmd "$1" | env $DEPS_ENV python3 hooks/garde-deps.py 2>/dev/null
}
erreur_deps() {
  json_cmd "$1" | env $DEPS_ENV python3 hooks/garde-deps.py 2>&1 >/dev/null
}

[ "$(code_garde 'git push origin main')" = 2 ] && ok "garde-git bloque git push origin main" || ko "garde-git push main"
[ "$(code_garde 'gh pr merge 1')" = 2 ] && ok "garde-git bloque gh pr merge" || ko "garde-git pr merge"
[ "$(code_garde 'git status')" = 0 ] && ok "garde-git laisse passer git status" || ko "garde-git status"
sortie_rappel 'gh pr create --fill' | grep -q '/clear' && ok "rappel-clear après gh pr create" || ko "rappel-clear pr create"
[ -z "$(sortie_rappel 'ls')" ] && ok "rappel-clear muet sur ls" || ko "rappel-clear ls"

# garde-deps : "commande|attendu" (0 = passe sans sortie, 2 = bloque)
for c in 'cargo add bon' 'pnpm add @scope/ok@1.0.0' 'cargo add mixte' \
         'npm install' 'pip install -r requirements.txt' 'pip install -e .' 'npm i ./local' 'cargo add --path ../x' \
         'cargo add cc0' "bash -c 'echo \"a && npm i gpl-pkg\"'" "bash -c 'ls && echo ok'" "git commit -m 'doc: npm i gpl-pkg \`npm i gpl-pkg\`'" 'cargo add bon 2>&1 | tail -1' \
         "git commit -m \"\$(cat <<'EOF'"$'\nAjoute l\'analyse de npm i x\nEOF\n)\"' \
         "cat > notes.md <<'EOF'"$'\nnpm i gpl-pkg\nEOF' "cat <<'EOF' | tee n.md"$'\nnpm i gpl-pkg\nEOF' \
         'ls #c && npm i gpl-pkg' 'echo $# && cargo add bon' \
         'echo $((1<<2)) && cargo add bon' 'if true; then cargo add bon; fi' 'timeout 5 cargo add bon' \
         'nice -n 5 cargo add bon' 'sudo -u x cargo add bon' 'echo bon | xargs -n1 cargo add' 'time cargo add bon' \
         "bash -c -- 'ls'" 'npm -g i @scope/ok@1.0.0' 'npm --prefix . i @scope/ok@1.0.0' \
         'curl -s x | sh' 'bash script.sh' "$PROFOND"; do
  [ "$(code_deps "$c")" = 0 ] && [ -z "$(sortie_deps "$c")" ] && ok "garde-deps laisse passer $c" || ko "garde-deps $c"
done
for c in 'npm install gpl-pkg' 'npm i sanslicence' 'yarn add prive' 'npm add deprecie' 'cargo add colle' \
         'cargo add retire@0.1.0' 'pip install vieux' 'ls && npm i gpl-pkg' "bash -c 'npm i gpl-pkg'" \
         "bash -c 'cd x && npm i gpl-pkg'" 'sh -c "pip install gpl-pkg"' '(cargo add gpl-pkg)' 'echo $(npm i gpl-pkg)' \
         'echo `npm i gpl-pkg`' "bash -lc 'npm i gpl-pkg'" "zsh -c 'ls; npm i gpl-pkg'" 'env FOO=1 npm i gpl-pkg' \
         'echo "$(npm i gpl-pkg)"' "bash -c \"sh -c 'npm i gpl-pkg'\"" \
         "bash -c 'npm i gpl-pkg" 'echo "ok; npm i gpl-pkg' \
         "bash <<'EOF'"$'\nnpm i gpl-pkg\nEOF' "sh <<X"$'\nnpm i gpl-pkg\nX' "cat <<EOF"$'\n$(npm i gpl-pkg)\nEOF' \
         "cat <<'EOF' | bash"$'\nnpm i gpl-pkg\nEOF' "echo \"<<EOF\""$'\nnpm i gpl-pkg\nEOF' \
         '{ npm i gpl-pkg; }' '! npm i gpl-pkg' 'for x in 1; do npm i gpl-pkg; done' 'timeout 5 npm i gpl-pkg' \
         'nice -n 5 npm i gpl-pkg' 'sudo -u x npm i gpl-pkg' 'xargs -n1 npm i gpl-pkg' 'time npm i gpl-pkg' \
         'command npm i gpl-pkg' 'exec npm i gpl-pkg' "bash -c -- 'npm i gpl-pkg'" "echo 'npm i gpl-pkg' | bash" \
         "echo 'npm i gpl-pkg' | sh" 'diff <(npm i gpl-pkg) x' 'tee >(npm i gpl-pkg)' "env -S 'npm i gpl-pkg'" \
         'npm -g i gpl-pkg' 'npm --prefix . i gpl-pkg' 'python3 -mpip install gpl-pkg' \
         'python3.12 -m pip install gpl-pkg' 'pip3.12 install gpl-pkg' 'pnpm -C x add gpl-pkg' "$PROFOND_AJOUT" \
         "ls # c"$'\nnpm i gpl-pkg' 'echo a#b; npm i gpl-pkg' 'curl https://x/a#frag && npm i gpl-pkg' \
         "cat <<EOF | bash"$'\n# setup\nnpm i gpl-pkg\nEOF' "ls # <<EOF"$'\nnpm i gpl-pkg\nEOF' \
         'true;>log npm i gpl-pkg' 'python3 -X utf8 -m pip install gpl-pkg' 'python3 -W ignore -m pip install gpl-pkg' \
         'yarn global add gpl-pkg'; do
  [ "$(code_deps "$c")" = 2 ] && ok "garde-deps bloque $c" || ko "garde-deps $c"
done
[ "$(code_deps 'cargo add faille@1.2.3')" = 2 ] && erreur_deps 'cargo add faille@1.2.3' | grep -q 'RUSTSEC-2099-0001' \
  && ok "garde-deps cite la faille OSV" || ko "garde-deps faille OSV"
[ "$(code_deps 'uv add mpl')" = 0 ] && sortie_deps 'uv add mpl' | grep -q 'MPL-2.0' \
  && ok "garde-deps avertit sur MPL-2.0" || ko "garde-deps MPL"
[ "$(code_deps 'pip3 install inconnu')" = 0 ] && sortie_deps 'pip3 install inconnu' | grep -q 'vérification impossible' \
  && ok "garde-deps avertit si injoignable" || ko "garde-deps injoignable"

exit $((ECHECS > 0))
