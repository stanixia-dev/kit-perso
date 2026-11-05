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
python3 "$G" --depot "$TMP/tout" --ref $SHA --sortie "$O" 2>/dev/null | grep -q 'Require status checks : `deps`, `rust`, `node`, `python` (' \
  && ok "checks : deps et jobs de tests seulement" || ko "checks listent autre chose que les jobs"
grep -q -- '--locked' "$T" && grep -q 'npm install' "$T" && ok "variantes lockfile" || ko "variantes lockfile"
head -1 "$D" | grep -q "^# Généré par kit-perso 3\..* kit figé à $SHA\$" && head -1 "$T" | grep -q '^# Généré par' && ok "1re ligne" || ko "1re ligne"

# propriétés de sécurité : un événement par workflow, pas de if sur l'événement
grep -q '^  pull_request_target:' "$D" && ! grep -q '^  pull_request:' "$D" && ! grep -q '^  push:' "$D" \
  && grep -q '^  pull_request:' "$T" && ! grep -q 'pull_request_target' "$T" && ! grep -q 'github.event_name' "$D" "$T" \
  && ok "un événement par workflow, sans if" || ko "événements des workflows"
for f in "$D" "$T"; do
  n_co=$(grep -c 'uses: actions/checkout@' "$f"); n_pc=$(grep -c 'persist-credentials: false' "$f")
  n_pin=$(grep -c 'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' "$f")
  n_uses=$(grep -c 'uses:' "$f"); n_pin_tous=$(grep -cE 'uses: [^ ]+@[0-9a-f]{40} # v' "$f")
  [ "$n_co" = "$n_pc" ] && [ "$n_co" = "$n_pin" ] && [ "$n_uses" = "$n_pin_tous" ] && ! grep -q 'secrets\.' "$f" && ! grep -q 'token:' "$f" && ! grep -E '^\s*-?\s*run:.*\$\{\{' "$f" >/dev/null \
    && ok "propriétés de sécurité de ${f##*/}" || ko "propriétés de sécurité de ${f##*/}"
  python3 -c 'import sys; sys.exit(1 if "\t" in open(sys.argv[1]).read() else 0)' "$f" && ok "pas de tabulation ${f##*/}" || ko "tabulation ${f##*/}"
done
# job node : runtime épinglé et contrôlé
sed -n '/^  node:/,/^  [a-z]*:$/p' "$T" > "$TMP/node.yml"
grep -q 'node-version-file: .nvmrc' "$TMP/node.yml" && grep -q 'check-latest: true' "$TMP/node.yml" && grep -q 'package-manager-cache: false' "$TMP/node.yml" \
  && grep -q 'npm_config_engine_strict' "$TMP/node.yml" && grep -q 'uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.0*' "$TMP/node.yml" \
  && grep -q 'ref: '"$SHA" "$TMP/node.yml" && grep -q 'path: .kit-perso' "$TMP/node.yml" \
  && [ "$(grep -c 'persist-credentials: false' "$TMP/node.yml")" = 2 ] \
  && ok "job node : setup-node, engine-strict, checkout du kit" || ko "contenu du job node"
l_run=$(grep -n 'run: python3 .kit-perso/hooks/verifie-runtime.py --ci && rm -rf .kit-perso$' "$TMP/node.yml" | cut -d: -f1)
l_npm=$(grep -n 'run: npm ' "$TMP/node.yml" | head -1 | cut -d: -f1)
[ -n "$l_run" ] && [ -n "$l_npm" ] && [ "$l_run" -lt "$l_npm" ] && ok "verifie-runtime avant npm" || ko "ordre verifie-runtime / npm"
! grep -qE 'uses: actions/setup-node|verifie-runtime' "$D" && ! sed -n '/^  rust:/,/^  node:/p;/^  python:/,$p' "$T" | grep -qE 'setup-node|kit-perso/hooks' \
  && ok "rust et python inchangés" || ko "rust ou python modifiés"
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

# .nvmrc et .npmrc générés
python3 "$G" --depot "$TMP/tout" --ref $SHA --sortie "$TMP/n0" >"$TMP/stdout0" 2>"$TMP/err0"
[ "$(cat "$TMP/n0/.nvmrc" 2>/dev/null)" = "lts/*" ] && [ "$(cat "$TMP/n0/.npmrc" 2>/dev/null)" = "engine-strict=true" ] \
  && grep -q "cp -n \"$TMP/n0/.nvmrc\" .nvmrc" "$TMP/stdout0" && grep -q "cp -n \"$TMP/n0/.npmrc\" .npmrc" "$TMP/stdout0" \
  && grep -q 'git add .github/workflows/kit-perso-deps.yml .github/workflows/kit-perso-tests.yml .nvmrc .npmrc ' "$TMP/stdout0" \
  && ok ".nvmrc (lts/*) et .npmrc générés, cp -n, git add" || ko ".nvmrc/.npmrc par défaut"
grep -q 'engines.node' "$TMP/err0" && ok "avis sans engines.node" || ko "avis sans engines.node"
mkdepot "$TMP/eng"; echo '{"engines":{"node":">=26"}}' > "$TMP/eng/package.json"; g -C "$TMP/eng" add -A; g -C "$TMP/eng" commit -q -m e
python3 "$G" --depot "$TMP/eng" --ref $SHA --sortie "$TMP/n1" >/dev/null 2>"$TMP/err"
[ "$(cat "$TMP/n1/.nvmrc")" = 26 ] && [ ! -s "$TMP/err" ] && ok ".nvmrc = 26 depuis engines" || ko ".nvmrc depuis engines"
echo '{"engines":{"node":"^22.12.0"}}' > "$TMP/eng/package.json"
python3 "$G" --depot "$TMP/eng" --ref $SHA --sortie "$TMP/n1" >/dev/null 2>&1
[ "$(cat "$TMP/n1/.nvmrc")" = 22 ] && ok ".nvmrc = 22 depuis ^22.12.0" || ko ".nvmrc ^22.12.0"
# .nvmrc et .npmrc existants : ni lus, ni générés, ni copiés, restes supprimés
mkdepot "$TMP/ex" package.json; echo 20 > "$TMP/ex/.nvmrc"; echo '//registre:_authToken=SECRETFACTICE' > "$TMP/ex/.npmrc"
mkdir -p "$TMP/n2"; echo old > "$TMP/n2/.nvmrc"; echo old > "$TMP/n2/.npmrc"
python3 "$G" --depot "$TMP/ex" --ref $SHA --sortie "$TMP/n2" >"$TMP/stdout2" 2>"$TMP/err2"
[ ! -e "$TMP/n2/.nvmrc" ] && [ ! -e "$TMP/n2/.npmrc" ] && ! grep -q 'nvmrc\|npmrc' "$TMP/stdout2" && grep -q 'engine-strict=true' "$TMP/err2" && ! grep -q SECRETFACTICE "$TMP/err2" "$TMP/stdout2" \
  && ok ".nvmrc/.npmrc existants : ni générés ni copiés, avis, restes supprimés" || ko ".nvmrc/.npmrc existants"
# sans package.json ou sans tests : aucun des deux
mkdepot "$TMP/py" pyproject.toml
python3 "$G" --depot "$TMP/py" --ref $SHA --sortie "$TMP/n3" >/dev/null 2>&1
python3 "$G" --depot "$TMP/tout" --ref $SHA --sans-tests --sortie "$TMP/n4" >/dev/null 2>&1
[ ! -e "$TMP/n3/.nvmrc" ] && [ ! -e "$TMP/n3/.npmrc" ] && [ ! -e "$TMP/n4/.nvmrc" ] && ok "sans job node : pas de .nvmrc ni .npmrc" || ko "fichiers sans job node"

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
