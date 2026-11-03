#!/usr/bin/env bash
# Tests hors réseau du générateur ci-projet. Lancer depuis n'importe où.
set -u
RACINE=$(cd "$(dirname "$0")/.." && pwd)
G="$RACINE/skills/ci-projet/genere-ci.py"
ECHECS=0
ok() { echo "OK    $1"; }
ko() { echo "ECHEC $1"; ECHECS=$((ECHECS + 1)); }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
g() { git -c user.name=t -c user.email=t@t "$@"; }
SHA=0123456789abcdef0123456789abcdef01234567

mkdepot() { # $1 = dossier ; manifestes suivants
  local d=$1; shift
  mkdir -p "$d"; g -C "$d" init -q -b main
  for f in "$@"; do echo "x" > "$d/$f"; done
  echo base > "$d/README"; g -C "$d" add -A; g -C "$d" commit -q -m init
}

mkdepot "$TMP/tout" Cargo.toml Cargo.lock package.json pyproject.toml
OUT="$TMP/o/kit-perso.yml"
python3 "$G" --depot "$TMP/tout" --ref $SHA --sortie "$OUT" >"$TMP/stdout" 2>/dev/null
[ -f "$OUT" ] && for j in deps rust node python; do grep -q "^  $j:" "$OUT" || { ko "job $j manquant"; }; done
grep -q "ref: $SHA" "$OUT" && grep -q 'repository: stanixia-dev/kit-perso' "$OUT" && ok "jobs deps/rust/node/python et SHA" || ko "SHA ou repository"
grep -q -- '--locked' "$OUT" && grep -q 'npm install' "$OUT" && ok "variantes lockfile" || ko "variantes lockfile"
head -1 "$OUT" | grep -q "^# Généré par kit-perso 3\..* kit figé à $SHA\$" && ok "1re ligne" || ko "1re ligne"

# propriétés de sécurité
n_co=$(grep -c 'uses: actions/' "$OUT"); n_pc=$(grep -c 'persist-credentials: false' "$OUT")
n_pin=$(grep -c 'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' "$OUT")
[ "$n_co" = "$n_pc" ] && [ "$n_co" = "$n_pin" ] && grep -q 'pull_request_target' "$OUT" && grep -q 'path: kit' "$OUT" && grep -q 'path: pr' "$OUT" \
  && ! grep -q 'secrets\.' "$OUT" && ! grep -q 'token:' "$OUT" && ! grep -E '^\s*-?\s*run:.*\$\{\{' "$OUT" >/dev/null \
  && ok "propriétés de sécurité du workflow" || ko "propriétés de sécurité du workflow"
python3 - "$OUT" <<'PY' && ok "YAML plausible (pas de tabulation)" || ko "tabulation"
import sys; sys.exit(1 if "\t" in open(sys.argv[1]).read() else 0)
PY

grep -q 'git push origin main' "$TMP/stdout" && grep -q 'Rulesets' "$TMP/stdout" && grep -q 'relancer /kit-perso:ci-projet' "$TMP/stdout" \
  && grep -q "cp \"$OUT\"" "$TMP/stdout" && ok "commande imprimée" || ko "commande imprimée"

# sans tests
python3 "$G" --depot "$TMP/tout" --ref $SHA --sans-tests --sortie "$TMP/o/a.yml" >/dev/null 2>&1
mkdepot "$TMP/vide"
python3 "$G" --depot "$TMP/vide" --ref $SHA --sortie "$TMP/o/b.yml" >/dev/null 2>&1
for f in a b; do
  grep -q '^  deps:' "$TMP/o/$f.yml" && ! grep -qE '^  (rust|node|python):' "$TMP/o/$f.yml" || { ko "seul deps ($f)"; continue; }
done
grep -qE '^  (rust|node|python):' "$TMP/o/a.yml" "$TMP/o/b.yml" || ok "--sans-tests et sans manifeste : seul deps"

# refus
refuse() { # $1 = libellé, reste = arguments ; vérifie exit 2 et rien d'écrit
  local l=$1; shift
  python3 "$G" "$@" >/dev/null 2>&1; local c=$?
  [ "$c" = 2 ] && ok "refus : $l" || ko "refus : $l (exit $c)"
}
refuse "ref invalide" --depot "$TMP/tout" --ref abc --sortie "$TMP/r1.yml"
[ ! -e "$TMP/r1.yml" ] && ok "rien écrit (ref invalide)" || ko "écrit malgré ref invalide"
refuse "ref majuscules" --depot "$TMP/tout" --ref "${SHA^^}" --sortie "$TMP/r1.yml"
refuse "sortie sous .github" --depot "$TMP/tout" --ref $SHA --sortie "$TMP/x/.github/workflows/k.yml"
[ ! -e "$TMP/x" ] && ok "rien écrit (.github)" || ko "écrit sous .github"
refuse "sortie dans l'arbre" --depot "$TMP/tout" --ref $SHA --sortie "$TMP/tout/k.yml"
[ ! -e "$TMP/tout/k.yml" ] && ok "rien écrit (arbre)" || ko "écrit dans l'arbre"
mkdir -p "$TMP/horsgit"
refuse "hors dépôt git" --depot "$TMP/horsgit" --ref $SHA --sortie "$TMP/r2.yml"

# sortie par défaut : status propre
python3 "$G" --depot "$TMP/tout" --ref $SHA >/dev/null 2>&1
[ -f "$TMP/tout/.git/kit-perso/kit-perso.yml" ] && [ -z "$(g -C "$TMP/tout" status --porcelain)" ] && ok "sortie par défaut dans .git, status propre" || ko "sortie par défaut"

# ligne run du job deps, hors réseau : kit = dépôt du kit, pr = dépôt jetable
mkdir -p "$TMP/ci"; ln -s "$RACINE" "$TMP/ci/kit"
mkdepot "$TMP/ci/pr" README2
CMD=$(grep -m1 'run: python3 kit/hooks/verifie-manifestes.py' "$OUT" | sed 's/.*run: //')
( cd "$TMP/ci" && BASE=$(git -C pr rev-parse HEAD) && eval "$CMD" ) >/dev/null 2>&1 \
  && ok "ligne run du job deps sort 0" || ko "ligne run du job deps"

exit $((ECHECS > 0))
