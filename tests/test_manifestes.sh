#!/usr/bin/env bash
# Tests de verifie-manifestes.py sur des dépôts jetables. Lancer depuis n'importe où.
set -u
RACINE=$(cd "$(dirname "$0")/.." && pwd)
V="$RACINE/hooks/verifie-manifestes.py"
FIX="$RACINE/tests/fixtures/garde-deps.json"
ECHECS=0
ok() { echo "OK    $1"; }
ko() { echo "ECHEC $1"; ECHECS=$((ECHECS + 1)); }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
g() { git -c user.name=t -c user.email=t@t "$@"; }

depot() { # $1 = nom ; dépôt avec un commit initial sur main, affiche son chemin
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  echo base > "$d/LISEZMOI"
  git -C "$d" add -A
  g -C "$d" commit -qm init
  echo "$d"
}
valide() { git -C "$1" add -A && g -C "$1" commit -qm "$2"; }

# lance DEPOT [options] ; remplit CODE, SORTIE (stdout) et ERREUR (stderr)
lance() {
  local d=$1; shift
  SORTIE=$(env GARDE_DEPS_FIXTURES="${FIXTURES:-$FIX}" GARDE_DEPS_AUJOURDHUI=2026-10-29 \
    python3 "$V" --depot "$d" "$@" 2>"$TMP/erreur")
  CODE=$?
  ERREUR=$(cat "$TMP/erreur")
}
# hook MODE DEPOT JSON
hook() {
  local mode=$1 d=$2 json=$3
  SORTIE=$(printf '%s' "$json" | env GARDE_DEPS_FIXTURES="${FIXTURES:-$FIX}" GARDE_DEPS_AUJOURDHUI=2026-10-29 \
    python3 "$V" --hook "$mode" 2>"$TMP/erreur")
  CODE=$?
  ERREUR=$(cat "$TMP/erreur")
}

# --- sans manifeste modifié : muet, sans réseau
d=$(depot rien); echo x > "$d/notes.txt"
FIXTURES=/nonexistent lance "$d"
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes muet sans manifeste modifié" || ko "verifie-manifestes sans manifeste"
mkdir -p "$TMP/horsgit"
FIXTURES=/nonexistent lance "$TMP/horsgit"
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes muet hors dépôt git" || ko "verifie-manifestes hors git"

# --- ajout direct non conforme dans chacun des 4 manifestes
ajout_direct() { # $1 = manifeste, $2 = contenu de base, $3 = contenu modifié
  local d; d=$(depot "direct-$1")
  printf '%s' "$2" > "$d/$1"; valide "$d" base
  printf '%s' "$3" > "$d/$1"
  lance "$d"
  [ "$CODE" = 2 ] && grep -q 'Bloqué par garde-deps (manifestes)' <<<"$ERREUR" && grep -q "gpl-pkg@1.0.0 ($1) : licence" <<<"$ERREUR" \
    && ok "verifie-manifestes bloque un ajout direct dans $1" || ko "verifie-manifestes direct $1"
}
ajout_direct Cargo.toml $'[package]\nname = "x"\n\n[dependencies]\n' $'[package]\nname = "x"\n\n[dependencies]\ngpl-pkg = "1.0.0"\n'
ajout_direct package.json '{"dependencies":{}}' '{"dependencies":{"gpl-pkg":"1.0.0"}}'
ajout_direct pyproject.toml $'[project]\nname = "x"\ndependencies = []\n' $'[project]\nname = "x"\ndependencies = ["gpl-pkg==1.0.0"]\n'
ajout_direct requirements.txt $'# deps\n' $'# deps\ngpl-pkg==1.0.0\n'

# --- ajout conforme, dépendance inchangée (aucun lookup), version résolue modifiée
d=$(depot conforme)
printf '[dependencies]\nbon = "1.0.0"\n' > "$d/Cargo.toml"; valide "$d" base
printf '[dependencies]\nbon = "1.0.0"\n\n[profile.dev]\nopt-level = 1\n' > "$d/Cargo.toml"
FIXTURES=/nonexistent lance "$d"
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes ignore une dépendance inchangée" || ko "verifie-manifestes inchangée"
printf '[dependencies]\nbon = "1.0.0"\nmixte = "1.0.0"\n' > "$d/Cargo.toml"
lance "$d"
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes laisse passer un ajout conforme" || ko "verifie-manifestes conforme"
d=$(depot resolu)
printf '[dependencies]\nfaille = "1"\n' > "$d/Cargo.toml"
printf '[[package]]\nname = "faille"\nversion = "1.0.0"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n' > "$d/Cargo.lock"
valide "$d" base
printf '[[package]]\nname = "faille"\nversion = "1.2.3"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n' > "$d/Cargo.lock"
lance "$d"
[ "$CODE" = 2 ] && grep -q 'faille@1.2.3' <<<"$ERREUR" && ok "verifie-manifestes examine la version résolue par le lockfile" || ko "verifie-manifestes version résolue"

# --- transitifs à faille dans chacun des 6 lockfiles : avertissement, exit 0
transitif() { # $1 = lockfile, $2 = contenu, $3 = identifiant de faille attendu
  local d; d=$(depot "trans-$1")
  printf '%s' "$2" > "$d/$1"
  lance "$d"
  [ "$CODE" = 0 ] && grep -q "$3" <<<"$SORTIE" && [ -z "$ERREUR" ] \
    && ok "verifie-manifestes avertit d'une faille transitive dans $1" || ko "verifie-manifestes transitif $1"
}
transitif Cargo.lock $'[[package]]\nname = "faille"\nversion = "1.2.3"\nsource = "registry+https://github.com/rust-lang/crates.io-index"\n' RUSTSEC-2099-0001
transitif package-lock.json '{"lockfileVersion":3,"packages":{"":{"name":"x"},"node_modules/a/node_modules/trou":{"version":"1.0.0"}}}' GHSA-trou-npm
transitif pnpm-lock.yaml $'lockfileVersion: \'9.0\'\n\npackages:\n\n  trou@1.0.0:\n    resolution: {integrity: x}\n\nsnapshots:\n\n  trou@1.0.0: {}\n' GHSA-trou-npm
transitif yarn.lock $'# yarn lockfile v1\n\n\ntrou@^1.0.0:\n  version "1.0.0"\n  resolved "x"\n' GHSA-trou-npm
transitif uv.lock $'[[package]]\nname = "trou"\nversion = "1.0.0"\nsource = { registry = "https://pypi.org/simple" }\n' PYSEC-2099-0002
transitif poetry.lock $'[[package]]\nname = "trou"\nversion = "1.0.0"\n' PYSEC-2099-0002
d=$(depot local)
printf '[[package]]\nname = "faille"\nversion = "1.2.3"\n' > "$d/Cargo.lock"
lance "$d"
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes ignore un paquet Cargo.lock sans registre" || ko "verifie-manifestes source locale"

# --- fichier illisible : avertissement
d=$(depot illisible); printf 'ceci [n est pas du toml' > "$d/pyproject.toml"
lance "$d"
[ "$CODE" = 0 ] && grep -q 'pyproject.toml illisible' <<<"$SORTIE" && ok "verifie-manifestes avertit d'un fichier illisible" || ko "verifie-manifestes illisible"

# --- exceptions de l'utilisateur
d=$(depot exceptions)
printf '{"dependencies":{"gpl-pkg":"1.0.0"}}' > "$d/package.json"
printf '# accord du 2026-10-01\nnpm gpl-pkg 1.0.0 2026-10-01 licence acceptée pour ce prototype\nligne invalide\n' > "$d/.garde-deps-exceptions"
lance "$d"
[ "$CODE" = 0 ] && grep -q 'gpl-pkg@1.0.0 (package.json) : licence non permissive.*(exception du 2026-10-01 : licence acceptée pour ce prototype)' <<<"$SORTIE" \
  && grep -q 'ligne 3 invalide' <<<"$SORTIE" && ok "verifie-manifestes transforme un blocage couvert en avertissement" || ko "verifie-manifestes exception"
printf 'npm gpl-pkg 2.0.0 2026-10-01 autre version\nnpm autre * 2026-10-01 autre paquet\n' > "$d/.garde-deps-exceptions"
lance "$d"
[ "$CODE" = 2 ] && ok "verifie-manifestes ignore une exception d'une autre version ou d'un autre paquet" || ko "verifie-manifestes exception hors sujet"
printf 'npm gpl-pkg * 2026-10-01 toutes versions\n' > "$d/.garde-deps-exceptions"
lance "$d"
[ "$CODE" = 0 ] && grep -q 'exception du 2026-10-01 : toutes versions' <<<"$SORTIE" && ok "verifie-manifestes accepte une exception pour toutes les versions" || ko "verifie-manifestes exception *"
# garde-deps lit la même exception en remontant de cwd jusqu'à .git
mkdir -p "$d/sous/dossier"
sortie_garde() { printf '{"tool_input":{"command":"npm i gpl-pkg"},"cwd":"%s"}' "$1" \
  | env GARDE_DEPS_FIXTURES="$FIX" GARDE_DEPS_AUJOURDHUI=2026-10-29 python3 "$RACINE/hooks/garde-deps.py" 2>&1; }
sortie_garde "$d/sous/dossier" | grep -q 'exception du 2026-10-01 : toutes versions' && ok "garde-deps applique .garde-deps-exceptions du dépôt" || ko "garde-deps exception"
rm "$d/.garde-deps-exceptions"
sortie_garde "$d/sous/dossier" | grep -q 'Bloqué' && ok "garde-deps bloque sans exception" || ko "garde-deps sans exception"

# --- --base / --cible
d=$(depot refs)
git -C "$d" checkout -q -b claude/x
printf '{"dependencies":{"gpl-pkg":"1.0.0"}}' > "$d/package.json"; valide "$d" ajout
lance "$d" --base main --cible HEAD
[ "$CODE" = 2 ] && grep -q 'npm gpl-pkg@1.0.0 (package.json)' <<<"$ERREUR" && ok "verifie-manifestes compare --base à --cible" || ko "verifie-manifestes base/cible"
lance "$d"
[ "$CODE" = 2 ] && ok "verifie-manifestes prend main comme base par défaut" || ko "verifie-manifestes base par défaut"
lance "$d" --base HEAD
[ "$CODE" = 0 ] && ok "verifie-manifestes muet quand base = cible" || ko "verifie-manifestes base = HEAD"

# --- hook stop : bloque, puis avertit si stop_hook_active
d=$(depot stop); printf '{"dependencies":{"gpl-pkg":"1.0.0"}}' > "$d/package.json"
hook stop "$d" "{\"cwd\":\"$d\"}"
[ "$CODE" = 2 ] && grep -q 'gpl-pkg' <<<"$ERREUR" && ok "verifie-manifestes --hook stop bloque" || ko "verifie-manifestes stop bloque"
hook stop "$d" "{\"cwd\":\"$d\",\"stop_hook_active\":true}"
[ "$CODE" = 0 ] && grep -q 'paquet non conforme encore présent' <<<"$SORTIE" && ok "verifie-manifestes --hook stop avertit si stop_hook_active" || ko "verifie-manifestes stop actif"

# --- hook post : ignore un Edit hors manifeste, ne répète pas un même état
d=$(depot post)
FIXTURES=/nonexistent hook post "$d" "{\"cwd\":\"$TMP/horsgit\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$d/README.md\"}}"
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes --hook post ignore un Edit hors manifeste" || ko "verifie-manifestes post hors manifeste"
printf '{"lockfileVersion":3,"packages":{"node_modules/trou":{"version":"1.0.0"}}}' > "$d/package-lock.json"
J="{\"cwd\":\"$d\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$d/package-lock.json\"}}"
hook post "$d" "$J"
[ "$CODE" = 0 ] && grep -q '"hookEventName": "PostToolUse"' <<<"$SORTIE" && grep -q 'GHSA-trou-npm' <<<"$SORTIE" \
  && ok "verifie-manifestes --hook post avertit en JSON" || ko "verifie-manifestes post avertit"
hook post "$d" "$J"
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes --hook post ne répète pas un même état" || ko "verifie-manifestes post répète"
hook post "$d" "{\"cwd\":\"$d\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}"
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes --hook post muet après Bash sans changement" || ko "verifie-manifestes post bash"

exit $((ECHECS > 0))
