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

# --- lockfile illisible : reporté même s'il a déjà servi à résoudre une version
d=$(depot lockillisible); printf '{"dependencies":{}}' > "$d/package.json"; valide "$d" base
printf '{"dependencies":{"bon":"1.0.0"}}' > "$d/package.json"; printf 'pas du json' > "$d/package-lock.json"
lance "$d"
[ "$CODE" = 0 ] && grep -q 'package-lock.json illisible' <<<"$SORTIE" && ok "verifie-manifestes avertit d'un lockfile illisible" || ko "verifie-manifestes lock illisible"
git -C "$d" checkout -q -b claude/lock; valide "$d" ajout
lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 2 ] && grep -q 'package-lock.json illisible' <<<"$ERREUR" && ok "verifie-manifestes --ci bloque sur un lockfile illisible" || ko "verifie-manifestes ci lock illisible"

# --- dépendances hors registre : avertissement en local, blocage en --ci, sauf exception
hors_registre() { # $1 = manifeste, $2 = contenu, $3 = nom attendu
  local d; d=$(depot "hors-$1-$3")
  git -C "$d" checkout -q -b claude/hors
  printf '%s' "$2" > "$d/$1"; valide "$d" ajout
  lance "$d" --base main --cible HEAD
  [ "$CODE" = 0 ] && grep -q "$3 ($1) : dépendance hors registre, à valider" <<<"$SORTIE" || { ko "verifie-manifestes hors registre $1 $3 (local)"; return; }
  lance "$d" --ci --base main --cible HEAD
  [ "$CODE" = 2 ] && grep -q "$3 ($1) : dépendance hors registre, à valider" <<<"$ERREUR" && ok "verifie-manifestes signale $3 hors registre ($1)" || ko "verifie-manifestes hors registre $1 $3 (ci)"
}
hors_registre package.json '{"dependencies":{"a-gh":"github:u/a","b-git":"git+https://x.io/b.git","c-url":"https://x.io/c.tgz","d-file":"file:../d","e-sh":"u/e"}}' a-gh
hors_registre package.json '{"dependencies":{"b-git":"git+https://x.io/b.git"}}' b-git
hors_registre package.json '{"dependencies":{"c-url":"https://x.io/c.tgz"}}' c-url
hors_registre package.json '{"dependencies":{"d-file":"file:../d"}}' d-file
hors_registre Cargo.toml $'[dependencies]\nx-git = { git = "https://x.io/x.git" }\n' x-git
hors_registre Cargo.toml $'[dependencies]\nx-path = { path = "../x" }\n' x-path
hors_registre requirements.txt $'p-url @ https://x.io/p.whl\n' p-url
hors_registre requirements.txt $'git+https://x.io/q.git#egg=q-git\n-e git+https://x.io/r.git#egg=r-git\n' q-git
hors_registre pyproject.toml $'[project]\nname = "x"\ndependencies = ["s-at @ git+https://x.io/s.git"]\n' s-at
hors_registre pyproject.toml $'[tool.poetry.dependencies]\nt-git = { git = "https://x.io/t.git" }\n' t-git
hors_registre pyproject.toml $'[tool.uv.sources]\nu-url = { url = "https://x.io/u.whl" }\n' u-url
d=$(depot hors-ok); git -C "$d" checkout -q -b claude/ok
mkdir -p "$d/pkg"
printf '{"workspaces":["pkg"],"dependencies":{"pkg":"workspace:*","l":"file:./pkg"}}' > "$d/package.json"
printf '[dependencies]\nloc = { path = "pkg" }\n' > "$d/Cargo.toml"; valide "$d" ajout
lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes ignore workspace: et chemins internes au dépôt" || ko "verifie-manifestes hors registre interne"
git -C "$d" checkout -q main
printf 'npm d-file * 2026-10-01 dépôt interne validé\n' > "$d/.garde-deps-exceptions"; valide "$d" "exception"
git -C "$d" checkout -q -b claude/exc
printf '{"dependencies":{"d-file":"file:../d"}}' > "$d/package.json"; valide "$d" ajout
lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 0 ] && grep -q 'dépendance hors registre.*exception du 2026-10-01' <<<"$SORTIE" && ok "verifie-manifestes accepte une exception pour une dépendance hors registre" || ko "verifie-manifestes hors registre exception"

# --- requirements/*.txt et fichiers inclus par -r / -c (sans boucle)
d=$(depot reqdir); mkdir -p "$d/requirements"
printf '# rien\n' > "$d/requirements/dev.txt"; valide "$d" base
printf 'gpl-pkg==1.0.0\n' > "$d/requirements/dev.txt"
lance "$d"
[ "$CODE" = 2 ] && grep -q 'gpl-pkg@1.0.0 (requirements/dev.txt)' <<<"$ERREUR" && ok "verifie-manifestes suit requirements/*.txt" || ko "verifie-manifestes requirements/"
d=$(depot reqinc); mkdir -p "$d/deps"
printf -- '-r deps/base.in\n-c deps/contrainte.in\n' > "$d/requirements.txt"
printf '# rien\n' > "$d/deps/base.in"; printf 'bon==1.0.0\n-r base.in\n-r ../requirements.txt\n' > "$d/deps/contrainte.in"; valide "$d" base
printf 'gpl-pkg==1.0.0\n-r contrainte.in\n' > "$d/deps/base.in"
lance "$d"
[ "$CODE" = 2 ] && grep -q 'gpl-pkg@1.0.0 (requirements.txt)' <<<"$ERREUR" && ok "verifie-manifestes suit les fichiers inclus par -r/-c sans boucle" || ko "verifie-manifestes -r"

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

# --- mode --ci : strict, exceptions de la base seulement, résumé Markdown
d=$(depot ci)
git -C "$d" checkout -q -b claude/ci
printf '{"dependencies":{"gpl-pkg":"1.0.0"}}' > "$d/package.json"
printf 'npm gpl-pkg 1.0.0 2026-10-01 ajoutée par la PR\n' > "$d/.garde-deps-exceptions"
mkdir -p "$d/.github/workflows"; printf 'name: x\n' > "$d/.github/workflows/t.yml"
valide "$d" "ajout"
RESUME="$TMP/resume.md"; : > "$RESUME"
GITHUB_STEP_SUMMARY="$RESUME" lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 2 ] && grep -q 'licence non permissive' <<<"$ERREUR" && grep -q "non appliquée tant qu'elle n'est pas sur main" "$RESUME" \
  && ok "verifie-manifestes --ci ignore et liste une exception ajoutée par la cible" || ko "verifie-manifestes ci exception cible"
grep -q 'gpl-pkg@1.0.0' "$RESUME" && grep -q '.github/workflows/t.yml' "$RESUME" && grep -q '.garde-deps-exceptions' "$RESUME" \
  && ok "verifie-manifestes --ci écrit le résumé (paquets, workflows, exceptions)" || ko "verifie-manifestes ci résumé"
git -C "$d" checkout -q main
printf 'npm gpl-pkg 1.0.0 2026-10-01 acceptée sur main\n' > "$d/.garde-deps-exceptions"; valide "$d" "exception sur main"
git -C "$d" checkout -q -b claude/ci2
printf '{"dependencies":{"gpl-pkg":"1.0.0"}}' > "$d/package.json"; valide "$d" "ajout 2"
lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 0 ] && grep -q 'exception du 2026-10-01 : acceptée sur main' <<<"$SORTIE" && ok "verifie-manifestes --ci applique une exception de la base" || ko "verifie-manifestes ci exception base"
printf '{"dependencies":{"gpl-pkg":"1.0.0","bon":"1.0.0"}}' > "$d/package.json"; valide "$d" "ajout 3"
FIXTURES=/nonexistent lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 2 ] && grep -q 'vérification impossible' <<<"$ERREUR" && ok "verifie-manifestes --ci bloque si le registre est injoignable" || ko "verifie-manifestes ci injoignable"
FIXTURES=/nonexistent lance "$d" --base main --cible HEAD
[ "$CODE" = 0 ] && grep -q 'vérification impossible' <<<"$SORTIE" && ok "verifie-manifestes avertit seulement hors --ci si le registre est injoignable" || ko "verifie-manifestes fail-open"
lance "$d" --ci --base inexistant --cible HEAD
[ "$CODE" = 2 ] && grep -q 'Traceback' <<<"$ERREUR" && ok "verifie-manifestes --ci bloque sur erreur imprévue" || ko "verifie-manifestes ci imprévue"
lance "$d" --base inexistant --cible HEAD
[ "$CODE" = 2 ] && grep -q 'Traceback' <<<"$ERREUR" && ok "verifie-manifestes CLI bloque sur erreur imprévue" || ko "verifie-manifestes CLI imprévue"
d=$(depot depublie); git -C "$d" checkout -q -b claude/depublie
printf '{"dependencies":{"depublie":"1.0.0"}}' > "$d/package.json"; valide "$d" ajout
lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 2 ] && grep -q 'vérification impossible' <<<"$ERREUR" && ok "verifie-manifestes --ci bloque sur une réponse de registre mal formée" || ko "verifie-manifestes ci mal formée"
lance "$d" --base main --cible HEAD
[ "$CODE" = 0 ] && grep -q 'vérification impossible' <<<"$SORTIE" && ok "verifie-manifestes avertit sur une réponse de registre mal formée" || ko "verifie-manifestes mal formée"
lance "$TMP/horsgit" --ci
[ "$CODE" = 2 ] && ok "verifie-manifestes --ci bloque hors dépôt git" || ko "verifie-manifestes ci hors git"
grep -q 'pull_request_target' "$RACINE/.github/workflows/deps.yml" && ok "deps.yml déclenche deps en pull_request_target" || ko "deps.yml pull_request_target"
! grep -qE 'pull_request_target|^ *if:' "$RACINE/.github/workflows/tests.yml" && ok "tests.yml : un seul type d'événement PR, sans if:" || ko "tests.yml mélange les événements"

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

# --- workspaces npm : leurs paquets ne sont jamais cherchés sur le registre
d=$(depot workspaces); git -C "$d" checkout -q -b claude/ws
mkdir -p "$d/packages/client" "$d/packages/sans-nom" "$d/packages/vide"
printf '{"name":"@hive/client","version":"1.0.0"}' > "$d/packages/client/package.json"
printf '{"version":"1.0.0"}' > "$d/packages/sans-nom/package.json"
printf '{"workspaces":["packages/*"],"dependencies":{"@hive/client":"*"}}' > "$d/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"name":"r"},"node_modules/@hive/client":{"resolved":"packages/client","link":true},"packages/client":{"name":"@hive/client","version":"1.0.0"}}}' > "$d/package-lock.json"
valide "$d" "monorepo"
lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes ignore un workspace npm (tableau, manifeste et lockfile)" || ko "verifie-manifestes workspace tableau: $CODE $ERREUR"
printf '{"workspaces":{"packages":["packages/*"]},"dependencies":{"@hive/client":"*"}}' > "$d/package.json"; valide "$d" "forme objet"
lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "verifie-manifestes ignore un workspace npm (forme objet)" || ko "verifie-manifestes workspace objet: $CODE $ERREUR"
printf '{"workspaces":["packages/*"],"dependencies":{"@hive/client":"*","@hive/autre":"*"}}' > "$d/package.json"; valide "$d" "hors workspace"
lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 2 ] && grep -q '@hive/autre' <<<"$ERREUR" && ! grep -q '@hive/client' <<<"$ERREUR" \
  && ok "verifie-manifestes vérifie toujours un paquet hors workspace" || ko "verifie-manifestes hors workspace: $CODE $ERREUR"

# négatifs : chaque cas doit rester bloqué en --ci
LOCK_LIEN='{"lockfileVersion":3,"packages":{"":{"name":"r"},"node_modules/evil-pkg":{"resolved":"packages/evil","link":true},"packages/evil":{"name":"evil-pkg","version":"1.0.0"}}}'
ws_negatif() { # $1 = description ; $2 = motif attendu dans l'erreur
  valide "$d" "cas"
  lance "$d" --ci --base main --cible HEAD
  [ "$CODE" = 2 ] && grep -q "$2" <<<"$ERREUR" && ok "verifie-manifestes workspace : $1" || ko "verifie-manifestes workspace $1 : $CODE $ERREUR"
}
nouveau_ws() { # $1 = nom du dépôt ; crée un monorepo avec le membre evil-pkg
  d=$(depot "$1"); git -C "$d" checkout -q -b claude/neg
  mkdir -p "$d/packages/evil"
  printf '{"name":"evil-pkg","version":"1.0.0"}' > "$d/packages/evil/package.json"
}
nouveau_ws ws-alias
printf '{"workspaces":["packages/*"],"dependencies":{"x":"npm:evil-pkg@2.0.0"}}' > "$d/package.json"; printf '%s' "$LOCK_LIEN" > "$d/package-lock.json"
ws_negatif "un alias npm: reste vérifié" evil-pkg
nouveau_ws ws-version
printf '{"workspaces":["packages/*"],"dependencies":{"evil-pkg":"^9.0.0"}}' > "$d/package.json"
ws_negatif "sans preuve link dans le lockfile" evil-pkg
nouveau_ws ws-version-lien
printf '{"workspaces":["packages/*"],"dependencies":{"evil-pkg":"^9.0.0"}}' > "$d/package.json"; printf '%s' "$LOCK_LIEN" > "$d/package-lock.json"
ws_negatif "lien prouvé mais spec différent de la version du membre" evil-pkg
nouveau_ws ws-spec-egal
printf '{"workspaces":["packages/*"],"dependencies":{"evil-pkg":"^1.0.0"}}' > "$d/package.json"; printf '%s' "$LOCK_LIEN" > "$d/package-lock.json"
valide "$d" "spec égal"
lance "$d" --ci --base main --cible HEAD
[ "$CODE" = 0 ] && ok "verifie-manifestes workspace : spec égal à la version du membre exempté" || ko "verifie-manifestes workspace spec égal : $CODE $ERREUR"
nouveau_ws ws-racine-membre
mkdir -p "$d/packages/a/x"
printf '{"workspaces":["packages/*"]}' > "$d/package.json"
printf '{"name":"a","workspaces":["x"],"dependencies":{"evil-pkg":"*"}}' > "$d/packages/a/package.json"
printf '{"name":"evil-pkg","version":"1.0.0"}' > "$d/packages/a/x/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"name":"a"},"node_modules/evil-pkg":{"resolved":"x","link":true}}}' > "$d/packages/a/package-lock.json"
ws_negatif "une racine membre d'une autre racine est écartée" evil-pkg
nouveau_ws ws-copie
mkdir -p "$d/packages/a"
printf '{"workspaces":["packages/*"]}' > "$d/package.json"
printf '{"name":"a","version":"1.0.0","dependencies":{"evil-pkg":"*"}}' > "$d/packages/a/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"name":"r"},"node_modules/evil-pkg":{"resolved":"packages/evil","link":true},"packages/evil":{"name":"evil-pkg","version":"1.0.0"},"packages/a/node_modules/evil-pkg":{"version":"9.0.0"}}}' > "$d/package-lock.json"
ws_negatif "une copie non-link imbriquée annule la preuve" evil-pkg
nouveau_ws ws-autre
mkdir -p "$d/autre"
printf '{"workspaces":["packages/*"]}' > "$d/package.json"; printf '%s' "$LOCK_LIEN" > "$d/package-lock.json"
printf '{"dependencies":{"evil-pkg":"*"}}' > "$d/autre/package.json"
ws_negatif "un manifeste hors de la racine n'est pas exempté" evil-pkg
nouveau_ws ws-fausse
mkdir -p "$d/z/q"
printf '{"workspaces":["*"]}' > "$d/z/package.json"; printf '{"name":"evil-pkg"}' > "$d/z/q/package.json"
rm -r "$d/packages"
printf '{"workspaces":["packages/*"],"dependencies":{"evil-pkg":"*"}}' > "$d/package.json"; printf '%s' "$LOCK_LIEN" > "$d/package-lock.json"
ws_negatif "une fausse racine imbriquée n'exempte pas la vraie" evil-pkg
nouveau_ws ws-transitif
printf '{"workspaces":["packages/*"]}' > "$d/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"name":"r"},"node_modules/evil-pkg":{"resolved":"packages/evil","link":true},"packages/evil":{"name":"evil-pkg","version":"1.0.0"},"node_modules/a":{"version":"1.0.0"},"node_modules/a/node_modules/trou":{"version":"1.0.0"}}}' > "$d/package-lock.json"
valide "$d" "cas"
lance "$d" --ci --base main --cible HEAD
grep -q 'GHSA-trou-npm' <<<"$SORTIE$ERREUR" && ok "verifie-manifestes workspace : un transitif imbriqué reste vérifié par OSV" || ko "verifie-manifestes workspace transitif imbriqué : $CODE $ERREUR"

exit $((ECHECS > 0))
