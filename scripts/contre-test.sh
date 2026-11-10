#!/usr/bin/env bash
# Contre-test : rejoue les fichiers de test nouveaux ou modifiés de la branche sur le code de base.
# Usage : contre-test.sh [--base <ref>] [--fichiers <pathspec>]... -- <commande> [args...]
# Sorties : 0 rouge sur la base (attendu) ; 1 vert sur la base ; 2 erreur ; 3 aucun fichier de test.
set -u
erreur() { echo "contre-test : erreur : $1" >&2; exit 2; }

BASE=main; PATHSPECS=(); PERSO=0
while [ $# -gt 0 ]; do
  case $1 in
    --base) [ $# -ge 2 ] || erreur "--base sans valeur"; BASE=$2; shift 2 ;;
    --fichiers) [ $# -ge 2 ] || erreur "--fichiers sans valeur"; PERSO=1; PATHSPECS+=("$2"); shift 2 ;;
    --) shift; break ;;
    *) erreur "argument inconnu : $1" ;;
  esac
done
[ $# -gt 0 ] || erreur "commande absente après --"
command -v "$1" >/dev/null 2>&1 || erreur "commande introuvable : $1"
if [ "$PERSO" = 0 ]; then
  PATHSPECS=(':(glob)**/tests/**' ':(glob)**/test/**' ':(glob)**/__tests__/**' ':(glob)**/spec/**'
    ':(glob)**/*_test.*' ':(glob)**/test_*' ':(glob)**/*.test.*' ':(glob)**/*.spec.*')
fi

R=$(git rev-parse --show-toplevel 2>/dev/null) || erreur "hors d'un dépôt git"
H=$(git -C "$R" rev-parse HEAD 2>/dev/null) || erreur "HEAD introuvable"
B=$(git -C "$R" merge-base "$BASE" HEAD 2>/dev/null) || erreur "ref inconnue : $BASE"

FICHIERS=()
while IFS= read -r -d '' f; do FICHIERS+=("$f"); done < <(git -C "$R" diff -z --name-only --diff-filter=AMR "$B" "$H" -- "${PATHSPECS[@]}")
if [ ${#FICHIERS[@]} -eq 0 ]; then
  echo "contre-test : aucun fichier de test nouveau ou modifié"; exit 3
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/contre-test.XXXXXX") || erreur "dossier temporaire impossible"
trap 'rm -rf "$T"' EXIT
trap 'exit 2' INT TERM
git clone -q --shared --no-checkout "$R" "$T/d" 2>/dev/null || erreur "clone impossible"
git -C "$T/d" checkout -q --detach "$B" 2>/dev/null || erreur "checkout de la base impossible"
git -C "$T/d" checkout -q "$H" -- "${FICHIERS[@]}" 2>/dev/null || erreur "checkout des fichiers de test impossible"

for d in node_modules .venv; do
  [ -e "$R/$d" ] && ln -s "$R/$d" "$T/d/$d"
done
if [ -f "$R/Cargo.toml" ] && [ -z "${CARGO_TARGET_DIR:-}" ]; then
  export CARGO_TARGET_DIR="$R/target"
fi

echo "contre-test : base ${B:0:9} ; fichiers : ${FICHIERS[*]}"
(cd "$T/d" && "$@"); RC=$?
if [ "$RC" -ne 0 ]; then
  echo "CONTRE-TEST : rouge sur la base (code $RC)"; exit 0
fi
echo "CONTRE-TEST : vert sur la base"; exit 1
