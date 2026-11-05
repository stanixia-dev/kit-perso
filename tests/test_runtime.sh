#!/usr/bin/env bash
# Tests de verifie-runtime.py, hors réseau (index simulé). Lancer depuis n'importe où.
set -u
RACINE=$(cd "$(dirname "$0")/.." && pwd)
V="$RACINE/hooks/verifie-runtime.py"
IDX="$RACINE/tests/fixtures/node-index.json"
ECHECS=0
ok() { echo "OK    $1"; }
ko() { echo "ECHEC $1"; ECHECS=$((ECHECS + 1)); }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export CLAUDE_PLUGIN_DATA="$HOME/.claude/plugins/data/kit-perso"
CACHE="$CLAUDE_PLUGIN_DATA/node-corriges.json"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/node" <<'EOF'
#!/bin/sh
touch "$TEMOIN"
echo "$VERSION_NODE"
EOF
chmod +x "$TMP/bin/node"
export TEMOIN="$TMP/temoin"
PYBIN=$(dirname "$(command -v python3)")
PATH_NODE="$TMP/bin:$PATH"

lance() { # $1 = version ; reste = arguments ; env : KIT_PERSO_NODE_INDEX
  local v=$1; shift
  VERSION_NODE=$v PATH="$PATH_NODE" python3 "$V" "$@"
}
hook() { # $1 = version, $2 = commande
  local c=${2//\\/\\\\}; c=${c//\"/\\\"}
  printf '{"tool_input":{"command":"%s"},"cwd":"/tmp"}' "$c" | VERSION_NODE=$1 PATH="$PATH_NODE" python3 "$V" --hook pre
}
export KIT_PERSO_NODE_INDEX="$IDX"

# ---------- règle et CI ----------
for mode in "" "--ci"; do
  for cas in v24.22.0:2 v26.12.0:2 v24.22.1:0 v24.23.0:0 v27.0.0:0 v22.23.4:0 v24.22.1-rc1:2 v24.22.1-rc.1:2; do
    v=${cas%:*}; attendu=${cas#*:}
    sortie=$(lance "$v" $mode 2>&1); c=$?
    [ "$c" = "$attendu" ] && ok "règle $v ${mode:-cli} -> $attendu" || ko "règle $v ${mode:-cli} (sortie $c)"
  done
done
lance v24.22.0 2>&1 | grep -q 'v24.22.1' && lance v26.12.0 2>&1 | grep -q 'v26.12.1' && ok "message cite la version corrigée" || ko "message de blocage"
lance v24.22.1 | grep -q 'Node v24.22.1 : à jour (branche 24 corrigée en v24.22.1)' && ok "message de succès" || ko "message de succès"
KIT_PERSO_NODE_INDEX="$TMP/absent" lance v24.22.1 --ci >/dev/null 2>&1; [ $? = 2 ] && ok "--ci index absent -> 2" || ko "--ci index absent"
echo '{}' > "$TMP/mauvais.json"; KIT_PERSO_NODE_INDEX="$TMP/mauvais.json" lance v24.22.1 --ci >/dev/null 2>&1; [ $? = 2 ] && ok "--ci index mal formé -> 2" || ko "--ci index mal formé"
PATH="$PYBIN:/usr/bin:/bin"; command -v node >/dev/null && { mkdir -p "$TMP/sansnode"; ln -s "$(command -v python3)" "$TMP/sansnode/python3"; PATH="$TMP/sansnode"; }
python3 "$V" --ci >/dev/null 2>&1; [ $? = 2 ] && ok "--ci sans node -> 2" || ko "--ci sans node"
printf '{"tool_input":{"command":"npm ci"}}' | python3 "$V" --hook pre >/dev/null 2>&1; [ $? = 0 ] && ok "hook sans node -> 0" || ko "hook sans node"
PATH="$PATH_NODE"; PATH_NODE="$TMP/bin:$(dirname "$(command -v python3)"):/usr/bin:/bin"
rm -rf "$HOME/.claude"

# ---------- hook ----------
rm -f "$TEMOIN"
for c in 'ls -la' 'cat node_modules/x/package.json' 'curl nodejs.org'; do
  hook v24.22.0 "$c" >/dev/null 2>&1; r=$?
  [ "$r" = 0 ] && [ ! -e "$TEMOIN" ] && ok "hook rapide : $c" || ko "hook rapide : $c ($r)"
done
[ ! -e "$CACHE" ] && ok "chemin rapide sans cache" || ko "cache écrit par le chemin rapide"
for c in 'npm ci' "bash -c 'npx tsc'"; do
  hook v24.22.0 "$c" >/dev/null 2>&1; [ $? = 2 ] && ok "hook bloque : $c" || ko "hook bloque : $c"
done
hook v24.22.0 'nvm install 24' >/dev/null 2>&1; [ $? = 0 ] && ok "hook laisse passer nvm" || ko "hook nvm"
hook v24.22.1 'npm ci' >/dev/null 2>&1; [ $? = 0 ] && ok "hook : Node à jour" || ko "hook Node à jour"
rm -rf "$HOME/.claude"
KIT_PERSO_NODE_INDEX="$TMP/absent" hook v24.22.0 'npm ci' >"$TMP/out" 2>/dev/null; r=$?
[ "$r" = 0 ] && grep -q 'systemMessage' "$TMP/out" && grep -q 'index injoignable' "$TMP/out" && ok "hook index injoignable : fail-open + avertissement" || ko "hook fail-open"

# ---------- cache ----------
rm -rf "$HOME/.claude"
lance v24.22.0 >/dev/null 2>&1
[ -f "$CACHE" ] && grep -q '"24": "24.22.1"' "$CACHE" && ok "cache écrit au premier appel" || ko "cache non écrit"
KIT_PERSO_NODE_INDEX="$TMP/absent" lance v24.22.0 >/dev/null 2>"$TMP/err"; r=$?
[ "$r" = 2 ] && grep -q 'vulnérable' "$TMP/err" && ! grep -q 'injoignable' "$TMP/err" && ok "cache frais : blocage sans réseau" || ko "cache frais ($r)"
python3 - "$CACHE" <<'PY'
import json, sys, time
t = time.time()
json.dump({"lu": t - 7 * 3600, "essai": t - 3600, "corriges": {"24": "24.22.1"}}, open(sys.argv[1], "w"))
PY
KIT_PERSO_NODE_INDEX="$TMP/absent" lance v24.22.0 >/dev/null 2>"$TMP/err"; r=$?
[ "$r" = 2 ] && grep -q 'nodejs.org injoignable' "$TMP/err" && grep -q 'index du 20' "$TMP/err" && ok "cache périmé : blocage + mention" || ko "cache périmé ($r)"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c["corriges"]=={"24":"24.22.1"} and c["lu"]<__import__("time").time()-7*3600+5 and c["essai"]>__import__("time").time()-60 else 1)' "$CACHE" \
  && ok "échec réseau : seul essai mis à jour" || ko "échec réseau : cache modifié"
# essai récent : le réseau n'est pas tenté (la fixture, pourtant présente, est ignorée)
python3 - "$CACHE" <<'PY'
import json, sys, time
t = time.time()
json.dump({"lu": t - 7 * 3600, "essai": t - 60, "corriges": {"24": "24.99.0"}}, open(sys.argv[1], "w"))
PY
lance v24.22.1 >/dev/null 2>"$TMP/err"; r=$?
[ "$r" = 2 ] && grep -q 'v24.99.0' "$TMP/err" && ok "essai récent : pas de réseau" || ko "essai récent ($r)"
echo '{pas du json' > "$CACHE"
lance v24.22.0 >/dev/null 2>&1; r=$?
[ "$r" = 2 ] && grep -q '"24": "24.22.1"' "$CACHE" && ok "cache mal formé = absent" || ko "cache mal formé ($r)"
rm -rf "$HOME/.claude"
CLAUDE_PLUGIN_DATA="$TMP/ailleurs" lance v24.22.0 >/dev/null 2>&1; r=$?
[ "$r" = 2 ] && [ ! -e "$TMP/ailleurs" ] && [ ! -e "$HOME/.claude" ] && ok "cache hors ~/.claude/plugins : rien écrit" || ko "cache hors plugins ($r)"
# index de test : jamais de lecture ni d'écriture du vrai cache (chemin par la base de comptes, pas $HOME)
VRAI=$(python3 -c 'import os,pwd; print(os.path.join(pwd.getpwuid(os.getuid()).pw_dir, ".claude/plugins/data/kit-perso-test-runtime-$$"))')
CLAUDE_PLUGIN_DATA="$VRAI" lance v24.22.0 >/dev/null 2>&1; r=$?
[ "$r" = 2 ] && [ ! -e "$VRAI" ] && ok "index de test : vrai cache non écrit" || ko "vrai cache écrit par un index de test ($r)"
rm -rf "$VRAI"
# sans cache, un échec réseau enregistre l'essai (limite des essais), sans valider le cache
rm -rf "$HOME/.claude"
KIT_PERSO_NODE_INDEX="$TMP/absent" lance v24.22.0 >/dev/null 2>&1
python3 -c 'import json,sys,time; c=json.load(open(sys.argv[1])); sys.exit(0 if c["corriges"]=={} and c["essai"]>time.time()-60 else 1)' "$CACHE" \
  && ok "échec sans cache : essai enregistré" || ko "essai non enregistré sans cache"
lance v24.22.0 >/dev/null 2>"$TMP/err"; r=$?
[ "$r" = 2 ] && ! grep -q 'vulnérable' "$TMP/err" && grep -q 'injoignable' "$TMP/err" && ok "cache vide : pas de verdict, pas de réseau" || ko "cache vide ($r)"
# mots supplémentaires
rm -rf "$HOME/.claude"
for c in 'nodejs app.js' 'pnpx tsc' 'yarnpkg install'; do
  hook v24.22.0 "$c" >/dev/null 2>&1; [ $? = 2 ] && ok "hook bloque : $c" || ko "hook bloque : $c"
done
rm -rf "$HOME/.claude"
ln -s "$TMP" "$HOME/lien" 2>/dev/null; mkdir -p "$HOME/.claude/plugins"; ln -s "$TMP/ailleurs2" "$HOME/.claude/plugins/data" 2>/dev/null
CLAUDE_PLUGIN_DATA="$HOME/.claude/plugins/data" lance v24.22.0 >/dev/null 2>&1
[ ! -e "$TMP/ailleurs2/node-corriges.json" ] && ok "cache : lien symbolique sortant refusé" || ko "cache via lien symbolique"

exit $((ECHECS > 0))
