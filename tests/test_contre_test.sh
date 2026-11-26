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
for r in sous sous2 "avec espace" a/b/c/d target/x; do mkdir -p "$D/$r"; echo s > "$D/$r/f"; done
g -C "$D" add -A; g -C "$D" commit -q -m base
mkdir -p "$D/node_modules"; echo x > "$D/node_modules/marq"
for r in sous "avec espace" a/b/c/d sous2 sous2/node_modules/x target/x ignore; do
  mkdir -p "$D/$r/node_modules"; echo y > "$D/$r/node_modules/marq"
done
mkdir -p "$D/node_modules/z/node_modules"
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
ct b1 --base main -- test -e sous/node_modules/marq
[ "$CODE" = 1 ] && ok "node_modules de sous-dossier visible dans le clone" || ko "sous/marq ($CODE)"
ct b1 --base main -- test -e "avec espace/node_modules/marq"
[ "$CODE" = 1 ] && ok "node_modules dans un dossier à espace lié" || ko "espace ($CODE)"
for c in ignore/node_modules a/b/c/d/node_modules target/x/node_modules; do
  ct b1 --base main -- test ! -e "$c"
  [ "$CODE" = 1 ] && ok "(négatif) $c absent du clone" || ko "$c présent ($CODE)"
done
# liens du clone : ni double lien (sous2/node_modules/x, node_modules/z), ni lien dans target/
ct b1 --base main -- bash -c "find . -path ./.git -prune -o -type l -print | LC_ALL=C sort | tr '\\n' '|'; echo"
grep -qxF "./avec espace/node_modules|./node_modules|./sous/node_modules|./sous2/node_modules|" <<<"$(sed -n 2p <<<"$SORTIE")" \
  && ok "(négatif) seuls les node_modules attendus sont liés" || ko "liens du clone : $SORTIE"
touch "$D/Cargo.toml"
(unset CARGO_TARGET_DIR; ct b1 --base main -- bash -c 'echo "CTD=$CARGO_TARGET_DIR"'; \
  grep -qxF "CTD=$D/target/contre-test" <<<"$SORTIE") && ok "Cargo : cible dédiée target/contre-test" || ko "cible Cargo"
(export CARGO_TARGET_DIR=/x/y; ct b1 --base main -- bash -c 'echo "CTD=$CARGO_TARGET_DIR"'; \
  grep -qxF "CTD=/x/y" <<<"$SORTIE") && ok "Cargo : CARGO_TARGET_DIR préexistant conservé" || ko "cible Cargo préexistante"
rm "$D/Cargo.toml"

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
