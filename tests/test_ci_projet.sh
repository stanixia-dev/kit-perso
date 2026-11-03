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
O="$TMP/o"
D="$O/kit-perso-deps.yml"; T="$O/kit-perso-tests.yml"
python3 "$G" --depot "$TMP/tout" --ref $SHA --sortie "$O" >"$TMP/stdout" 2>/dev/null
[ -f "$D" ] && grep -q "^  deps:" "$D" || ko "job deps manquant"
[ -f "$T" ] && for j in rust node python; do grep -q "^  $j:" "$T" || ko "job $j manquant"; done
grep -q "ref: $SHA" "$D" && grep -q 'repository: stanixia-dev/kit-perso' "$D" && ! grep -q '^  \(rust\|node\|python\):' "$D" && ok "deps seul dans kit-perso-deps.yml, SHA" || ko "SHA ou repository"
grep -q -- '--locked' "$T" && grep -q 'npm install' "$T" && ok "variantes lockfile" || ko "variantes lockfile"
head -1 "$D" | grep -q "^# Généré par kit-perso 3\..* kit figé à $SHA\$" && head -1 "$T" | grep -q '^# Généré par' && ok "1re ligne" || ko "1re ligne"

# propriétés de sécurité : un événement par workflow, pas de if sur l'événement
grep -q '^  pull_request_target:' "$D" && ! grep -q '^  pull_request:' "$D" && ! grep -q '^  push:' "$D" \
  && grep -q '^  pull_request:' "$T" && ! grep -q 'pull_request_target' "$T" && ! grep -q 'github.event_name' "$D" "$T" \
  && ok "un événement par workflow, sans if" || ko "événements des workflows"
for f in "$D" "$T"; do
  n_co=$(grep -c 'uses: actions/' "$f"); n_pc=$(grep -c 'persist-credentials: false' "$f")
  n_pin=$(grep -c 'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' "$f")
  [ "$n_co" = "$n_pc" ] && [ "$n_co" = "$n_pin" ] && ! grep -q 'secrets\.' "$f" && ! grep -q 'token:' "$f" && ! grep -E '^\s*-?\s*run:.*\$\{\{' "$f" >/dev/null \
    && ok "propriétés de sécurité de ${f##*/}" || ko "propriétés de sécurité de ${f##*/}"
  python3 -c 'import sys; sys.exit(1 if "\t" in open(sys.argv[1]).read() else 0)' "$f" && ok "pas de tabulation ${f##*/}" || ko "tabulation ${f##*/}"
done
grep -q 'path: kit' "$D" && grep -q 'path: pr' "$D" && ok "chemins kit et pr distincts" || ko "chemins kit et pr"

grep -q 'git push origin main' "$TMP/stdout" && grep -q 'Rulesets' "$TMP/stdout" && grep -q 'relancer /kit-perso:ci-projet' "$TMP/stdout" \
  && grep -q "cp \"$D\"" "$TMP/stdout" && grep -q "cp \"$T\"" "$TMP/stdout" && grep -q 'git add .github/workflows/kit-perso-deps.yml .github/workflows/kit-perso-tests.yml' "$TMP/stdout" \
  && grep -q 'kit-perso-tests / ' "$TMP/stdout" && ok "commande imprimée" || ko "commande imprimée"

# sans tests (y compris reste d'une génération précédente) et sans manifeste
cp "$T" "$TMP/o/ancien-tests.yml"; rm -f "$T"; cp "$TMP/o/ancien-tests.yml" "$T"
python3 "$G" --depot "$TMP/tout" --ref $SHA --sans-tests --sortie "$TMP/a" >/dev/null 2>&1
mkdepot "$TMP/vide"
python3 "$G" --depot "$TMP/vide" --ref $SHA --sortie "$TMP/b" >/dev/null 2>&1
python3 "$G" --depot "$TMP/tout" --ref $SHA --sans-tests --sortie "$O" >/dev/null 2>&1
for d in "$TMP/a" "$TMP/b" "$O"; do
  grep -q '^  deps:' "$d/kit-perso-deps.yml" && [ ! -e "$d/kit-perso-tests.yml" ] || { ko "seul deps ($d)"; continue; }
done
ok "--sans-tests et sans manifeste : seul deps (reste ancien supprimé)"

# refus
refuse() { # $1 = libellé, reste = arguments ; vérifie exit 2 et rien d'écrit
  local l=$1; shift
  python3 "$G" "$@" >/dev/null 2>&1; local c=$?
  [ "$c" = 2 ] && ok "refus : $l" || ko "refus : $l (exit $c)"
}
refuse "ref invalide" --depot "$TMP/tout" --ref abc --sortie "$TMP/r1"
[ ! -e "$TMP/r1" ] && ok "rien écrit (ref invalide)" || ko "écrit malgré ref invalide"
refuse "ref majuscules" --depot "$TMP/tout" --ref "${SHA^^}" --sortie "$TMP/r1"
refuse "sortie sous .github" --depot "$TMP/tout" --ref $SHA --sortie "$TMP/x/.github/workflows"
[ ! -e "$TMP/x" ] && ok "rien écrit (.github)" || ko "écrit sous .github"
refuse "sortie dans l'arbre" --depot "$TMP/tout" --ref $SHA --sortie "$TMP/tout/kp"
[ ! -e "$TMP/tout/kp" ] && ok "rien écrit (arbre)" || ko "écrit dans l'arbre"
mkdir -p "$TMP/horsgit"
refuse "hors dépôt git" --depot "$TMP/horsgit" --ref $SHA --sortie "$TMP/r2"

# sortie par défaut : status propre
python3 "$G" --depot "$TMP/tout" --ref $SHA >/dev/null 2>&1
[ -f "$TMP/tout/.git/kit-perso/kit-perso-deps.yml" ] && [ -z "$(g -C "$TMP/tout" status --porcelain)" ] && ok "sortie par défaut dans .git, status propre" || ko "sortie par défaut"

# ligne run du job deps, hors réseau : kit = dépôt du kit, pr = dépôt jetable
mkdir -p "$TMP/ci"; ln -s "$RACINE" "$TMP/ci/kit"
mkdepot "$TMP/ci/pr" README2
CMD=$(grep -m1 'run: python3 kit/hooks/verifie-manifestes.py' "$D" | sed 's/.*run: //')
( cd "$TMP/ci" && BASE=$(git -C pr rev-parse HEAD) && eval "$CMD" ) >/dev/null 2>&1 \
  && ok "ligne run du job deps sort 0" || ko "ligne run du job deps"

# textes de détection de la CI (livrer, specs)
L="$RACINE/skills/livrer/SKILL.md"; S="$RACINE/agents/specs.md"
for f in "$L" "$S"; do
  n=${f#"$RACINE"/}
  grep -q 'rules/branches/main' "$f" && grep -q 'branches/main/protection' "$f" && grep -q 'HTTP 404' "$f" && grep -q 'aucune CI' "$f" \
    && grep -q 'job deps du kit' "$f" && grep -q 'checks non obligatoires' "$f" && grep -q 'illisibles' "$f" \
    && ok "détection de la CI dans $n" || ko "détection de la CI dans $n"
done
grep -q 'CI :' "$S" && ok "specs : ligne CI :" || ko "specs : ligne CI :"
grep -q 'pas de CI configurée' "$L" && grep -q 'CI configurée mais pas déclenchée' "$L" && ok "livrer : deux messages de suivi" || ko "livrer : messages de suivi"
[ "$(grep -n 'Contrôle de la CI' "$L" | cut -d: -f1)" -lt "$(grep -n 'git push -u' "$L" | cut -d: -f1)" ] && ok "livrer : détection avant le push" || ko "livrer : ordre"

exit $((ECHECS > 0))
