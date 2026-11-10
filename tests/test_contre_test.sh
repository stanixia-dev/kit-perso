#!/usr/bin/env bash
# Tests du contre-test (scripts/contre-test.sh) et contrôles de texte des agents. Lancer depuis n'importe où.
set -u
RACINE=$(cd "$(dirname "$0")/.." && pwd)
C="$RACINE/scripts/contre-test.sh"
ECHECS=0
ok() { echo "OK    $1"; }
ko() { echo "ECHEC $1"; ECHECS=$((ECHECS + 1)); }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
mkdir -p "$TMP/tmpdir"; export TMPDIR="$TMP/tmpdir"
g() { git -c user.name=t -c user.email=t@t "$@"; }

D="$TMP/depot"
mkdir -p "$D/tests"; g -C "$D" init -q -b main
echo 'echo 1' > "$D/f.sh"
echo '[ "$(bash f.sh)" = 1 ]' > "$D/tests/t.sh"
echo 'node_modules/' > "$D/.gitignore"
g -C "$D" add -A; g -C "$D" commit -q -m base
mkdir -p "$D/node_modules"; echo x > "$D/node_modules/marq"
g -C "$D" checkout -q -b b1
echo 'echo 2' > "$D/f.sh"; echo '[ "$(bash f.sh)" = 2 ]' > "$D/tests/t.sh"
g -C "$D" commit -q -am b1
g -C "$D" checkout -q main; g -C "$D" checkout -q -b b2
echo '[ "$(bash f.sh)" = 1 ]' > "$D/tests/t2.sh"; g -C "$D" add -A; g -C "$D" commit -q -m b2
g -C "$D" checkout -q main; g -C "$D" checkout -q -b b3
echo 'echo 3' > "$D/f.sh"; g -C "$D" commit -q -am b3
g -C "$D" checkout -q main
REFS=$(g -C "$D" for-each-ref)

# ct <branche> <args...> : lance le script dans le dépôt jetable ; code dans $CODE, sortie dans $SORTIE
ct() { local b=$1; shift; g -C "$D" checkout -q "$b"; SORTIE=$(cd "$D" && bash "$C" "$@" 2>&1); CODE=$?; }

ct b1 --base main -- bash tests/t.sh
[ "$CODE" = 0 ] && grep -q 'CONTRE-TEST : rouge sur la base' <<<"$SORTIE" && ok "b1 rouge (0)" || ko "b1 rouge ($CODE)"
ct b2 --base main -- bash tests/t2.sh
[ "$CODE" = 1 ] && grep -q 'CONTRE-TEST : vert sur la base' <<<"$SORTIE" && ok "b2 vert (1)" || ko "b2 vert ($CODE)"
ct b3 --base main -- true
[ "$CODE" = 3 ] && ok "b3 aucun fichier de test (3)" || ko "b3 ($CODE)"
ct b1 --base main --fichiers nulle-part/ -- bash tests/t.sh
[ "$CODE" = 3 ] && ok "--fichiers remplace les défauts (3)" || ko "--fichiers ($CODE)"
ct b1 --base inexistante -- bash tests/t.sh
[ "$CODE" = 2 ] && ok "(négatif) ref inconnue (2)" || ko "ref inconnue ($CODE)"
SORTIE=$(cd "$TMP" && bash "$C" --base main -- true 2>&1); CODE=$?
[ "$CODE" = 2 ] && ok "(négatif) hors dépôt (2)" || ko "hors dépôt ($CODE)"
ct b1 --base main --
[ "$CODE" = 2 ] && ok "(négatif) rien après -- (2)" || ko "rien après -- ($CODE)"
ct b1 --base main -- test -e node_modules/marq
[ "$CODE" = 1 ] && ok "node_modules visible dans le clone (marq)" || ko "marq ($CODE)"

g -C "$D" checkout -q main
[ -z "$(ls -A "$TMPDIR")" ] && [ -z "$(g -C "$D" status --porcelain)" ] && [ ! -e "$D/.git/worktrees" ] \
  && [ "$(g -C "$D" for-each-ref)" = "$REFS" ] && ok "propre : rien derrière, dépôt intact" || ko "propre"

# contrôles de texte
t() { grep -qF -- "$2" "$RACINE/$1" && ok "$1 contient $2" || ko "$1 ne contient pas $2"; }
for m in '— test :' '(négatif)' '(non-régression)' '(fumée)' 'Contre-test : non applicable' 'skill `run`'; do t agents/specs.md "$m"; done
for m in 'tests rouges avant : oui/non' "avant l'implémentation"; do t agents/codeur.md "$m"; done
for m in 'scripts/contre-test.sh' 'Contre-test :' '(non-régression)' '(négatif)' '(fumée)' 'merge-base'; do t agents/relecteur.md "$m"; done
t README.md '## Contre-test'

exit $((ECHECS > 0))
