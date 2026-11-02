#!/usr/bin/env bash
# Sondes du bac à sable Bash, à lancer PAR L'AGENT (pas dans un terminal ordinaire) depuis la racine du dépôt.
# N'affiche jamais de contenu ; crée seulement des fichiers uniques `.sonde-$$`, supprimés aussitôt.
# Usage : bash tests/sonde-bac-a-sable.sh [--liste]
set -u
TROUS=0
LIBELLES=(
  "lecture de ~/.ssh impossible"
  "lecture de ~/.config/gh impossible"
  "création refusée dans ~/.claude/"
  "création refusée dans ~/.claude/plugins/"
  "création refusée dans .git/hooks/"
  "ouverture en ajout refusée sur .git/config"
  "création dans .github/workflows/ (résidu Q3)"
  "création dans .claude/ du projet (résidu Q3)"
  "création possible dans le dossier courant (cohérence)"
  "https://api.github.com joignable"
  "https://example.com injoignable"
  "GH_TOKEN et GITHUB_TOKEN absents"
  "code de sortie de rtk git status"
)
if [ "${1:-}" = "--liste" ]; then
  printf '%s\n' "${LIBELLES[@]}"
  exit 0
fi
cd "$(dirname "$0")/.." || exit 1

sortie() { # $1 = OK|TROU|INFO, $2 = libellé
  echo "$1 $2"
  [ "$1" = TROU ] && TROUS=$((TROUS + 1))
  return 0
}

# lit_dossier <dossier> : 0 si un fichier ordinaire s'ouvre, 1 sinon, 2 si le dossier n'existe pas
lit_dossier() {
  python3 -I -c '
import os, sys
d = os.path.expanduser(sys.argv[1])
if not os.path.isdir(d):
    sys.exit(2)
for racine, _, fichiers in os.walk(d):
    for f in fichiers:
        p = os.path.join(racine, f)
        if os.path.isfile(p) and not os.path.islink(p):
            try:
                open(p, "rb").read(1)
                sys.exit(0)
            except OSError:
                pass
sys.exit(1)' "$1" 2>/dev/null
}

# cree_dans <dossier> : 0 si la création (puis suppression) réussit, 1 si refusée, 2 si le dossier n'existe pas
cree_dans() {
  python3 -I -c '
import os, sys
d = os.path.expanduser(sys.argv[1])
if not os.path.isdir(d):
    sys.exit(2)
p = os.path.join(d, ".sonde-" + sys.argv[2])
try:
    open(p, "x").close()
except OSError:
    sys.exit(1)
os.remove(p)' "$1" "$$" 2>/dev/null
}

for d in "~/.ssh" "~/.config/gh"; do
  lit_dossier "$d"; r=$?
  case $r in
    0) sortie TROU "lecture de $d impossible" ;;
    2) sortie INFO "lecture de $d impossible : dossier absent hors du bac à sable" ;;
    *) sortie OK "lecture de $d impossible" ;;
  esac
done

for d in "~/.claude" "~/.claude/plugins" ".git/hooks"; do
  cree_dans "$d"; r=$?
  case $r in
    0) sortie TROU "création refusée dans ${d#\~/}/" ;;
    2) sortie INFO "création refusée dans ${d#\~/}/ : dossier absent" ;;
    *) sortie OK "création refusée dans ${d#\~/}/" ;;
  esac
done

if python3 -I -c 'import sys; open(sys.argv[1], "a").close()' .git/config 2>/dev/null; then
  sortie TROU "ouverture en ajout refusée sur .git/config"
else
  sortie OK "ouverture en ajout refusée sur .git/config"
fi

for d in ".github/workflows" ".claude"; do
  cree_dans "$d"; r=$?
  case $r in
    0) sortie INFO "création possible dans $d/ (résidu Q3, couvert par les hooks et la CI)" ;;
    2) sortie INFO "création dans $d/ : dossier absent" ;;
    *) sortie INFO "création refusée dans $d/" ;;
  esac
done

cree_dans "." && sortie OK "création possible dans le dossier courant (cohérence)" \
  || sortie TROU "création refusée dans le dossier courant (incohérent)"

joignable() { # $1 = URL ; 0 si une réponse HTTP est obtenue
  python3 -I -c '
import sys, urllib.request, urllib.error
try:
    urllib.request.urlopen(sys.argv[1], timeout=10).close()
except urllib.error.HTTPError:
    pass
except Exception:
    sys.exit(1)' "$1" 2>/dev/null
}
joignable https://api.github.com && sortie OK "https://api.github.com joignable" || sortie TROU "https://api.github.com injoignable"
joignable https://example.com && sortie TROU "https://example.com joignable (hors liste blanche)" || sortie OK "https://example.com injoignable"

if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  sortie TROU "GH_TOKEN ou GITHUB_TOKEN défini"
else
  sortie OK "GH_TOKEN et GITHUB_TOKEN absents"
fi

if command -v rtk >/dev/null 2>&1; then
  rtk git status >/dev/null 2>&1; sortie INFO "code de sortie de rtk git status : $?"
else
  sortie INFO "rtk absent"
fi

echo "SONDE : $TROUS trou(s)"
[ "$TROUS" -eq 0 ] || exit 1
