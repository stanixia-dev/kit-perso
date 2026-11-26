#!/usr/bin/env bash
# Tests de garde-secret.py sur des dépôts jetables. Lancer depuis n'importe où.
# Aucun jeton en clair : ils sont construits à l'exécution (concaténation). HOME est un dossier jetable.
set -u
RACINE=$(cd "$(dirname "$0")/.." && pwd)
S="$RACINE/hooks/garde-secret.py"
ECHECS=0
ok() { echo "OK    $1"; }
ko() { echo "ECHEC $1"; ECHECS=$((ECHECS + 1)); }
# Garde-fou : le dépôt du kit ne doit pas bouger pendant les tests (branche, HEAD, arbre de travail)
ETAT_KIT_DEBUT=$(git -C "$RACINE" branch --show-current; git -C "$RACINE" rev-parse HEAD; git -C "$RACINE" status --porcelain)
verifie_kit() {
  local fin; fin=$(git -C "$RACINE" branch --show-current; git -C "$RACINE" rev-parse HEAD; git -C "$RACINE" status --porcelain)
  [ "$fin" = "$ETAT_KIT_DEBUT" ] || { echo "ECHEC le dépôt du kit a changé pendant les tests (branche, HEAD ou arbre)"; return 1; }
}
TMP=$(mktemp -d)
trap 'rc=$?; rm -rf "$TMP"; verifie_kit || rc=1; exit $rc' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.ssh" "$HOME/.config/gh"
unset GITHUB_STEP_SUMMARY
g() { git -c user.name=t -c user.email=t@t "$@"; }
# Garde-fou : refuse de lancer git ailleurs que dans un dépôt jetable (jamais le dépôt du kit)
case "$TMP" in "$RACINE"|"$RACINE"/*) echo "ABANDON : dossier temporaire dans le dépôt du kit"; exit 1 ;; esac
sur() { # $1 = dossier ; quitte si ce n'est pas la racine d'un dépôt situé sous $TMP
  case "$1" in "$TMP"/?*) ;; *) echo "ABANDON : dépôt hors du dossier temporaire (« $1 »)"; exit 1 ;; esac
  [ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" = "$1" ] || { echo "ABANDON : « $1 » n'est pas un dépôt jetable"; exit 1; }
}

# ---------- jetons de test ----------
A36=abcdefghijklmnopqrstuvwxyz0123456789
GH="gh""p_$A36"
GHPAT="github""_pat_$A36${A36:0:30}"
GL="glpat""-${A36:0:24}"
ANT="sk-""ant-$A36"
OAI="sk-""proj-$A36"
OAI2="sk-""${A36}wxyz"
AWS="AK""IA""ABCDEFGH12345678"
AWSEX="AK""IA""IOSFODNN7EXAMPLE"
GOO="AI""za${A36:0:35}"
SLK="xo""xb-${A36:0:24}"
STR="sk""_live_${A36:0:24}"
NPM="np""m_$A36"
PYPI="py""pi-$A36${A36:0:20}"
CLE="-----""BEGIN RSA PRIVATE KEY-----"$'\n'"${A36}${A36}"$'\n'"-----""END RSA PRIVATE KEY-----"
JWT="ey""J${A36:0:12}.ey""J${A36:3:12}.${A36:0:12}"
URL="post""gres://user:${A36:0:14}@hote"
AFF="pass""word='${A36:0:14}'"

# an [chemin] < texte : "niveau:nom" distincts, triés, séparés par des virgules
an() {
  python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("gs", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(",".join(sorted({f"{a}:{b}" for a, b, _ in m.analyse(sys.stdin.read(), sys.argv[2])})))' "$S" "${1:-src/x}"
}
attend() { # $1 = libellé, $2 = attendu, $3 = texte, $4 = chemin éventuel
  [ "$(printf '%s' "$3" | an "${4:-src/x}")" = "$2" ] && ok "analyse $1" || ko "analyse $1"
}

for cas in "github|$GH" "github|$GHPAT" "gitlab|$GL" "anthropic|$ANT" "openai|$OAI" "openai|$OAI2" "aws|$AWS" \
           "google|$GOO" "slack|$SLK" "stripe|$STR" "npm|$NPM" "pypi|$PYPI" "cle-privee|$CLE"; do
  attend "${cas%%|*} positif" "fort:${cas%%|*}" "x ${cas#*|} y"
done
attend "jwt positif" "faible:jwt" "t=$JWT"
attend "url positif" "faible:url" "u=$URL/b"
attend "affectation positif" "faible:affectation" "$AFF"
for cas in "github|gh""p_court" "gitlab|glpat""-court" "anthropic|sk-""ant-court" "openai|sk-""court" "aws|AK""IAcourt" \
           "google|AI""zacourt" "slack|xo""xb-court" "stripe|sk""_live_court" "npm|np""m_court" "pypi|py""pi-court" \
           "cle-privee|-----""BEGIN CERTIFICATE-----"; do
  attend "${cas%%|*} négatif" "" "x ${cas#*|} y"
done
attend "jwt négatif" "" "ey""J${A36:0:12}.court"
attend "url négatif (mot de passe court)" "" "post""gres://user:court@hote/b"
attend "affectation négatif (valeur courte)" "" "pass""word='court'"
attend "task- + 50 alphanumériques n'est pas un jeton" "" "task-${A36}${A36:0:14}"
attend "AKIA…EXAMPLE ignoré" "" "$AWSEX"
attend "fort à 5 caractères distincts ignoré" "" "gh""p_$(printf 'a%.0s' {1..40})"
attend "faible à valeur 'example' ignoré" "" "pass""word='example${A36:0:8}'"
attend "faible à entropie basse ignoré" "" "pass""word='aaaaaaaaaaaaaaaa'"
attend "faible avec \$ ignoré" "" "pass""word='\${A36:0:14}'"
attend "faible dans docs/ ignoré" "" "$AFF" docs/a.txt
attend "faible dans un .md ignoré" "" "$AFF" a/LISEZMOI.md
attend "fort dans docs/ gardé" "fort:github" "$GH" docs/a.md
[ "$(printf '%s' "$CLE" | python3 -c 'import sys; print("fin" if "END" in sys.stdin.read() else "")')" = fin ] && ok "clé privée de test complète"

for f in hooks/garde-secret.py docs/specs/*.md docs/specs/archives/*.md; do
  [ -f "$RACINE/$f" ] || continue
  [ -z "$(an src/x < "$RACINE/$f")" ] && ok "analyse ne trouve rien dans $f" || ko "secret apparent dans $f"
done
for f in "$RACINE"/tests/*.sh; do
  [ -z "$(an src/x < "$f")" ] && ok "aucun secret en clair dans tests/$(basename "$f")" || ko "secret en clair dans $f"
done

# ---------- chemins ----------
cl() { python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("gs", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.classe(sys.argv[2]) or "-")' "$S" "$1"; }
for cas in "~/.ssh/config|perso" "/h/.config/gh/hosts.yml|perso" "/h/.aws/credentials|perso" "/h/.netrc|perso" \
           "/proc/1/environ|perso" "/x/.env|env" "/x/.env.local|env" "/x/prod.env|env" "/x/.envrc|env" ".env*|env" \
           "/x/.env.example|-" "/x/.env.sample|-" "/x/README.md|-" "/x/.gitignore|-" "*|-" "/x/environ|-"; do
  [ "$(cl "${cas%|*}")" = "${cas##*|}" ] && ok "classe ${cas%|*}" || ko "classe ${cas%|*}"
done

# ---------- scan git ----------
depot() { # $1 = nom ; dépôt avec un commit initial sur main, affiche son chemin
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  echo base > "$d/LISEZMOI"
  git -C "$d" add -A
  g -C "$d" commit -qm init >/dev/null
  echo "$d"
}
valide() { git -C "$1" add -A && g -C "$1" commit -qm "$2"; }
# lance DEPOT [options] ; remplit CODE, SORTIE (stdout), ERREUR (stderr)
lance() {
  local d=$1; shift
  SORTIE=$(python3 "$S" --depot "$d" "$@" 2>"$TMP/erreur")
  CODE=$?
  ERREUR=$(cat "$TMP/erreur")
}
vaut() { # $1 = libellé, $2 = code attendu
  [ "$CODE" = "$2" ] && ok "$1" || ko "$1 (code $CODE)"
}
sans_valeur() { # aucun message ne contient de valeur
  case "$SORTIE$ERREUR" in *"$A36"*|*"${A36:0:14}"*) ko "$1 : valeur dans un message";; *) ok "$1 : aucune valeur dans les messages";; esac
}
EMP=$(printf '%s' "$GH" | sha256sum | cut -c1-12)

d=$(depot intermediaire)
git -C "$d" checkout -qb f
printf 'cle=%s\n' "$GH" > "$d/a.txt"; valide "$d" ajoute
git -C "$d" rm -q a.txt; g -C "$d" commit -qm retire
lance "$d" --base main
vaut "fort dans un commit intermédiaire puis retiré : 2" 2
grep -q "garde-secret" <<<"$ERREUR" && grep -q "github (empreinte $EMP)" <<<"$ERREUR" && ok "message cite le nom et l'empreinte" || ko "message du scan"
sans_valeur "scan"

d=$(depot env-force)
printf 'x=1\n' > "$d/.env"; git -C "$d" add -f .env
lance "$d" --base main
vaut ".env forcé : 2" 2

d=$(depot nonsuivi)
printf '%s\n' "$GH" > "$d/n.txt"
lance "$d"
vaut "fichier non suivi à fort : 2" 2

d=$(depot exemple)
git -C "$d" checkout -qb f
printf 'T=%s\n' "$GH" > "$d/.env.example"; valide "$d" ex
lance "$d" --base main
vaut ".env.example à fort : 2" 2

d=$(depot plusplus)
git -C "$d" checkout -qb f
printf '++ %s\n' "$GH" > "$d/p.txt"; valide "$d" pp
lance "$d" --base main
vaut "ligne '++ <fort>' : 2" 2

d=$(depot rien)
git -C "$d" checkout -qb f
echo propre > "$d/ok.txt"; valide "$d" propre
lance "$d" --base main
vaut "rien de neuf : 0" 0
[ -z "$SORTIE$ERREUR" ] && ok "rien de neuf : muet" || ko "rien de neuf : muet"

mkdir -p "$TMP/horsdepot"
lance "$TMP/horsdepot"
vaut "hors dépôt : 0" 0

d=$(depot exception)
git -C "$d" checkout -qb f
printf 'T=%s\n' "$GH" > "$d/secret.txt"
printf '# test\nsecret.txt %s 2026-10-30 fixture\nligne invalide\n' "$EMP" > "$d/.garde-secret-exceptions"
valide "$d" ex
lance "$d" --base main
vaut "fort couvert par empreinte : 0" 0
grep -q "invalide" <<<"$SORTIE" && ok "ligne d'exception invalide signalée" || ko "exception invalide non signalée"
printf 'secret.txt %s 2026-10-30 autre\n' 000000000000 > "$d/.garde-secret-exceptions"
lance "$d" --base main
vaut "empreinte différente : 2" 2

d=$(depot faible)
git -C "$d" checkout -qb f
printf '%s\n' "$AFF" > "$d/conf.txt"; valide "$d" faible
lance "$d" --base main
vaut "faible en local : 0" 0
grep -q '⚠' <<<"$SORTIE" && ok "faible en local : avertit" || ko "faible en local : avertissement"
sans_valeur "faible"
lance "$d" --base main --ci
vaut "faible en --ci : 2" 2

d=$(depot ci-exception)
printf 'secret.txt %s 2026-10-30 fixture\n' "$EMP" > "$d/.garde-secret-exceptions"; valide "$d" exc-main
git -C "$d" checkout -qb f
printf 'T=%s\n' "$GH" > "$d/secret.txt"; valide "$d" secret
lance "$d" --base main --ci
vaut "--ci applique l'exception de la base : 0" 0
d=$(depot ci-ajoutee)
git -C "$d" checkout -qb f
printf 'T=%s\n' "$GH" > "$d/secret.txt"
printf 'secret.txt %s 2026-10-30 ajoutee\n' "$EMP" > "$d/.garde-secret-exceptions"; valide "$d" secret
lance "$d" --base main
vaut "local applique l'exception du dépôt : 0" 0
GITHUB_STEP_SUMMARY="$TMP/resume.md" lance "$d" --base main --ci
vaut "--ci ignore l'exception ajoutée par la cible : 2" 2
grep -q "secret.txt $EMP" "$TMP/resume.md" && ok "--ci liste l'exception non appliquée" || ko "--ci liste l'exception"
lance "$TMP/horsdepot" --ci
vaut "--ci hors dépôt : 2" 2

# ---------- PreToolUse ----------
mkdir -p "$TMP/w"
ln -s "$TMP/w/.env" "$TMP/w/lien"
# hk OUTIL CWD champ valeur [champ valeur] ; remplit CODE, SORTIE, ERREUR
hk() {
  local json
  json=$(python3 -c 'import json, sys
t, c, *kv = sys.argv[1:]
print(json.dumps({"tool_name": t, "cwd": c, "tool_input": dict(zip(kv[::2], kv[1::2]))}))' "$@")
  SORTIE=$(printf '%s' "$json" | python3 "$S" --hook pre 2>"$TMP/erreur")
  CODE=$?
  ERREUR=$(cat "$TMP/erreur")
}
hk_json() { # JSON brut
  SORTIE=$(printf '%s' "$1" | python3 "$S" --hook pre 2>"$TMP/erreur")
  CODE=$?
  ERREUR=$(cat "$TMP/erreur")
}
bloque() { vaut "bloque $1" 2; }
passe() { [ "$CODE" = 0 ] && [ -z "$SORTIE" ] && ok "laisse passer $1" || ko "laisse passer $1 (code $CODE)"; }

hk Read "$TMP/w" file_path "$HOME/.ssh/config"; bloque "Read ~/.ssh/config"
hk Read "$TMP/w" file_path "~/.config/gh/hosts.yml"; bloque "Read ~/.config/gh/hosts.yml"
hk Read "$TMP/w" file_path "/x/.env"; bloque "Read /x/.env"
hk Read "$TMP/w" file_path "/x/.env.local"; bloque "Read /x/.env.local"
hk Read "$TMP/w" file_path "$TMP/w/lien"; bloque "Read lien symbolique vers .env"
hk Read "$TMP/w" file_path "/x/.env.example"; passe "Read /x/.env.example"
hk Grep "$TMP/w" path "$HOME/.ssh" pattern x; bloque "Grep path ~/.ssh"
hk Grep "$TMP/w" path "~" pattern x; bloque "Grep path ~"
hk Grep "$TMP/w" path "~/.config" pattern x; bloque "Grep path ~/.config"
hk Grep "$TMP/w" glob "**/.env*" pattern x; bloque "Grep glob .env*"
hk Grep "$TMP/w" path "$TMP/w" pattern x; passe "Grep dans un projet"
hk Write "$TMP/w" file_path "/x/.env" content "A=1"; bloque "Write /x/.env"

for c in 'cat .env' 'cat < .env' 'cat .env*' 'dd if=.env' 'echo x > .env' 'git show HEAD:.env' 'git add .env' \
         "python3 -c \"print(open('.env').read())\"" "bash -c 'cat ~/.ssh/id_x'" 'echo "$(cat .env)"' 'gh auth token' \
         'git credential fill' 'gh auth status --show-token' 'cat $HOME/.ssh/id_x' 'cat ~/.config/gh/hosts.yml' \
         'tee .env.local < a' 'grep -e x .env' 'sed -n 1p .env' 'cat /proc/self/environ' "sh -c 'sh -c \"cat .env\"'" \
         "bash <<'EOF'"$'\ncat .env\nEOF' 'x=1 cat .env' 'env A=1 cat .env' 'head -n1 -- .env'; do
  hk Bash "$TMP/w" command "$c"; bloque "$c"
done
for c in 'cat "mon dossier/.env"' 'cat mon\ dossier/.env'; do
  hk Bash "$TMP/w" command "$c"; bloque "$c"
done
for c in "node --eval=\"readFileSync('.env','utf8')\"" "node --print=\"readFileSync('.env')\"" "node -e\"readFileSync('.env')\"" \
         "deno eval \"Deno.readTextFileSync('.env')\""; do
  hk Bash "$TMP/w" command "$c"; bloque "$c"
done
hk Bash "$TMP/w" command "python3 x.py --msg 'voir la doc .env'"; passe "jeton à blanc qui n'est pas un chemin"
for c in "git commit -m 'protège .env'" "git commit -m \"\$(cat <<'EOF'"$'\nprotège .env et ~/.ssh\nEOF\n)"' 'echo .env >> .gitignore' \
         'grep .env .gitignore' 'ls ~/.ssh' 'git check-ignore .env' "gh pr create --body 'voir ~/.ssh/ et .env'" \
         'cat .env.example' 'ls -la' 'echo "ok" | wc -l' 'git status' 'grep -rn "\.env" src' 'cat README.md'; do
  hk Bash "$TMP/w" command "$c"; passe "$c"
done
# commandes qui portent les identifiants : un argument qui est un lien vers un chemin protégé est refusé
echo "contenu" > "$HOME/.ssh/id_x"; ln -sfn "$HOME/.ssh/id_x" "$TMP/w/l"; echo "notes" > "$TMP/w/notes.md"
for c in 'gh pr create --body-file l' 'gh pr create --body-file=l' 'gh issue view --body-file l' 'gh release upload v1 l' 'git push origin l'; do
  hk Bash "$TMP/w" command "$c"; bloque "identifiants : $c"
done
for c in 'git push -Fl origin b' 'git push -F=l origin b'; do hk Bash "$TMP/w" command "$c"; bloque "identifiants : $c"; done
hk Bash "$TMP/w" command 'gh pr create --body-file notes.md'; passe "exclue : gh pr create --body-file notes.md"
rm -f "$TMP/w/l" "$TMP/w/notes.md" "$HOME/.ssh/id_x"
hk_json 'pas du json'; bloque "entrée JSON invalide"
hk_json '{"tool_input":{"command":"ls"}}'; passe "tool_name absent = Bash"

# contenu écrit
for cas in "github|$GH" "cle-privee|$CLE" "aws|$AWS"; do
  hk Write "$TMP/w" file_path "$TMP/w/a.txt" content "x ${cas#*|} y"; bloque "Write d'un fort (${cas%%|*})"
done
hk Edit "$TMP/w" file_path "$TMP/w/a.txt" old_string a new_string "k=$GH"; bloque "Edit d'un fort"
hk NotebookEdit "$TMP/w" notebook_path "$TMP/w/a.ipynb" new_source "k=$GH"; bloque "NotebookEdit d'un fort"
hk_json "$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "MultiEdit", "cwd": "/tmp", "tool_input": {"file_path": "/tmp/a.txt", "edits": [{"old_string": "a", "new_string": sys.argv[1]}]}}))' "$GH")"
bloque "MultiEdit d'un fort"
grep -q "github (empreinte $EMP)" <<<"$ERREUR" && ok "message d'écriture : nom et empreinte" || ko "message d'écriture"
sans_valeur "écriture"
hk Write "$TMP/w" file_path "$TMP/w/a.txt" content "$AFF"
[ "$CODE" = 0 ] && grep -q 'systemMessage' <<<"$SORTIE" && grep -q 'additionalContext' <<<"$SORTIE" && ok "Write d'un faible : 0 + avertissement" || ko "Write d'un faible"
sans_valeur "avertissement faible"
hk Write "$TMP/w" file_path "$TMP/w/a.txt" content "$AWSEX"; passe "Write de AKIA…EXAMPLE"
hk Bash "$TMP/w" command "echo $GH"; bloque "commande Bash contenant un fort"

# scan avant commit et push
d=$(depot precommit)
printf 'T=%s\n' "$GH" > "$d/n.txt"
for c in 'git add -A && git commit -m x' 'git push origin f' 'gh pr create --fill' 'gh -R o/r pr create --fill' 'gh pr -R o/r create --fill' 'git --namespace x push origin f' 'gh pr --body x create --fill' 'gh pr -b x create --fill' 'gh -b x pr create --fill'; do
  hk Bash "$d" command "$c"; bloque "$c avec un secret dans le dépôt"
done
sans_valeur "scan avant commit"
grep -q 'reset --soft' <<<"$ERREUR" && ok "message : reset --soft et révocation" || ko "message du scan avant commit"
printf 'n.txt %s 2026-10-30 fixture\n' "$EMP" > "$d/.garde-secret-exceptions"
hk Bash "$d" command 'git commit -m x'; passe "git commit avec fort couvert par une exception"
rm "$d/n.txt" "$d/.garde-secret-exceptions"
printf '%s\n' "$AFF" > "$d/f.txt"
hk Bash "$d" command 'git commit -am x'
[ "$CODE" = 0 ] && grep -q 'systemMessage' <<<"$SORTIE" && ok "git commit avec un faible : avertit" || ko "git commit avec un faible"
rm "$d/f.txt"
hk Bash "$d" command 'git commit -m x'; passe "git commit dans un dépôt propre"
hk Bash "$TMP/horsdepot" command 'git commit -m x'; passe "git commit hors dépôt"

# exceptions : jamais sur la classe perso, `*` couvre la lecture d'un .env de la racine
d=$(depot exc-chemins)
printf '* * 2026-10-30 tout\n.env * 2026-10-30 lecture\n' > "$d/.garde-secret-exceptions"
hk Read "$d" file_path "$HOME/.ssh/config"; bloque "Read ~/.ssh/config malgré une exception"
hk Read "$d" file_path "$d/.env"; passe "Read .env couvert par une exception *"
hk Read "$d" file_path "$d/.env.local"; passe "Read .env.local couvert par le joker *"
hk Read "$TMP/w" file_path "$d/.env"; bloque "Read .env d'un autre dépôt que le cwd (exception sans effet)"

# CLI et mode pre : fail-closed
d=$(depot cli-base)
lance "$d" --base inexistant
[ "$CODE" = 2 ] && grep -q 'a échoué' <<<"$ERREUR" && ok "CLI --base inexistant : code 2" || ko "CLI --base inexistant"
printf '' | python3 "$S" --hook pre --depot x >/dev/null 2>&1
[ "$?" = 2 ] && ok "--hook pre --depot x sur entrée vide : code 2" || ko "--hook pre entrée vide"

# ---------- PostToolUse, PostToolUseFailure, Stop ----------
VC="valeur""connue-${A36:0:10}"
# po EVENEMENT OUTIL CWD CHAMP VALEUR : tool_response = {stdout: VALEUR, stderr: "", interrupted: false}
po() {
  local json
  json=$(python3 -c 'import json, sys
ev, t, c, _, v = sys.argv[1:6]
d = {"hook_event_name": ev, "tool_name": t, "cwd": c}
if ev == "PostToolUseFailure":
    d["error"] = v
else:
    d["tool_response"] = {"stdout": v, "stderr": "", "interrupted": False}
print(json.dumps(d))' "$@")
  SORTIE=$(printf '%s' "$json" | MON_TOKEN_TEST="$VC" python3 "$S" --hook post 2>"$TMP/erreur")
  CODE=$?
  ERREUR=$(cat "$TMP/erreur")
}
# json_ok CHAMP : extrait un champ de SORTIE (chemin pointé), vide si absent
champ() { printf '%s' "$SORTIE" | python3 -c 'import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[k]
print(json.dumps(d) if not isinstance(d, str) else d)' "$1" 2>/dev/null; }
sans_secret() { # $1 = libellé, $2 = valeur qui ne doit apparaître nulle part
  case "$SORTIE$ERREUR" in *"$2"*) ko "$1 : la valeur apparaît";; *) ok "$1 : la valeur n'apparaît pas";; esac
}

po PostToolUse Bash "$TMP/w" stdout "sortie $GH fin"
[ "$CODE" = 0 ] && [ "$(champ hookSpecificOutput.updatedToolOutput.stdout)" = "sortie [masqué:github:$EMP] fin" ] \
  && ok "post : fort masqué, forme conservée" || ko "post : fort masqué"
[ "$(champ hookSpecificOutput.updatedToolOutput.interrupted)" = false ] && [ "$(champ hookSpecificOutput.hookEventName)" = PostToolUse ] \
  && ok "post : autres champs conservés" || ko "post : autres champs"
grep -q 'masqué' <<<"$(champ systemMessage)" && grep -q 'masqué' <<<"$(champ hookSpecificOutput.additionalContext)" \
  && ok "post : alerte" || ko "post : alerte"
sans_secret "post (github)" "$A36"
po PostToolUse Bash "$TMP/w" stdout "avant"$'\n'"$CLE"$'\n'"après"
[ "$CODE" = 0 ] && grep -q 'masqué:cle-privee' <<<"$SORTIE" && ok "post : clé privée masquée" || ko "post : clé privée"
case "$(champ hookSpecificOutput.updatedToolOutput.stdout)" in *END*|*PRIVATE*) ko "post : clé privée entière";; *"avant"*"après"*) ok "post : clé privée masquée en entier, END compris";; *) ko "post : clé privée (texte autour)";; esac
sans_secret "post (clé privée)" "$A36"
po PostToolUse Bash "$TMP/w" stdout "la valeur est $VC ici"
grep -q 'masqué:valeur-connue' <<<"$SORTIE" && ok "post : valeur connue de l'environnement masquée" || ko "post : valeur connue"
sans_secret "post (valeur connue)" "$VC"
printf 'MON_API_KEY=%s\nHOME_DIR=/tmp/zzzzzzzzzz\n' "valeurenv-${A36:5:10}" > "$TMP/w/.env"
po PostToolUse Bash "$TMP/w" stdout "contenu valeurenv-${A36:5:10} et /tmp/zzzzzzzzzz"
case "$(champ hookSpecificOutput.updatedToolOutput.stdout)" in *"valeurenv-"*) ko "post : valeur du .env masquée";; *"/tmp/zzzzzzzzzz"*) ok "post : valeur du .env masquée, le reste intact";; *) ko "post : .env";; esac
rm "$TMP/w/.env"
po PostToolUse Bash "$TMP/w" stdout "rien à signaler 12345678"
[ "$CODE" = 0 ] && [ -z "$SORTIE" ] && ok "post : sortie saine, stdout vide" || ko "post : sortie saine"
po PostToolUse Bash "$TMP/w" stdout "$AWSEX"
[ -z "$SORTIE" ] && ok "post : exemple AKIA…EXAMPLE laissé" || ko "post : exemple"
po PostToolUseFailure Bash "$TMP/w" error "échec avec $GH"
[ "$CODE" = 0 ] && grep -q 'additionalContext' <<<"$SORTIE" && ok "failure : alerte" || ko "failure : alerte"
sans_secret "failure" "$A36"
po PostToolUseFailure Bash "$TMP/w" error "échec banal"
[ -z "$SORTIE" ] && ok "failure : erreur saine, stdout vide" || ko "failure : erreur saine"
SORTIE=$(printf 'pas du json' | python3 "$S" --hook post 2>/dev/null); CODE=$?
[ "$CODE" = 0 ] && [ -z "$SORTIE" ] && ok "post : entrée invalide, sortie intacte" || ko "post : entrée invalide"

# stop
st() { # $1 = cwd, $2 = stop_hook_active
  SORTIE=$(printf '{"cwd":"%s","stop_hook_active":%s}' "$1" "$2" | python3 "$S" --hook stop 2>"$TMP/erreur")
  CODE=$?
  ERREUR=$(cat "$TMP/erreur")
}
d=$(depot stop)
printf 'T=%s\n' "$GH" > "$d/n.txt"
st "$d" false; vaut "stop : bloque une première fois" 2
sans_valeur "stop"
st "$d" true
[ "$CODE" = 0 ] && grep -q 'systemMessage' <<<"$SORTIE" && ok "stop : avertit ensuite" || ko "stop : avertissement"
sans_valeur "stop (rappel)"
rm "$d/n.txt"
st "$d" false; [ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "stop : dépôt propre, muet" || ko "stop : dépôt propre"
printf '%s\n' "$AFF" > "$d/f.txt"
st "$d" false; [ "$CODE" = 0 ] && [ -z "$SORTIE$ERREUR" ] && ok "stop : un faible n'est pas signalé" || ko "stop : faible"
st "$TMP/horsdepot" false; vaut "stop : hors dépôt" 0

# ---------- CI via verifie-manifestes.py, protection des exceptions ----------
V="$RACINE/hooks/verifie-manifestes.py"
FIX="$RACINE/tests/fixtures/garde-deps.json"
ci() { # DEPOT [options] ; lance verifie-manifestes.py --ci
  local d=$1; shift
  SORTIE=$(env GARDE_DEPS_FIXTURES="$FIX" GARDE_DEPS_AUJOURDHUI=2026-10-29 python3 "$V" --depot "$d" --base main --ci "$@" 2>"$TMP/erreur")
  CODE=$?
  ERREUR=$(cat "$TMP/erreur")
}
d=$(depot ci-secret)
git -C "$d" checkout -qb f
printf 'T=%s\n' "$GH" > "$d/n.txt"; valide "$d" secret
ci "$d"
vaut "verifie-manifestes --ci échoue sur un secret sans manifeste touché" 2
grep -q 'garde-secret' <<<"$ERREUR" && ok "--ci : détection de garde-secret" || ko "--ci : message garde-secret"
sans_valeur "--ci"
d=$(depot ci-propre)
git -C "$d" checkout -qb f
echo propre > "$d/ok.txt"; valide "$d" propre
ci "$d"; vaut "verifie-manifestes --ci propre : 0" 0
d=$(depot ci-deux)
git -C "$d" checkout -qb f
printf '{"dependencies":{"gpl-pkg":"1.0.0"}}' > "$d/package.json"
printf 'T=%s\n' "$GH" > "$d/n.txt"; valide "$d" les-deux
ci "$d"
vaut "--ci : dépendance et secret bloquent" 2
grep -q 'garde-deps' <<<"$ERREUR" && grep -q 'garde-secret' <<<"$ERREUR" && ok "--ci : garde-secret tourne même si les dépendances bloquent" || ko "--ci : les deux contrôles"
GITHUB_STEP_SUMMARY="$TMP/resume2.md" ci "$d"
grep -q 'garde-deps' "$TMP/resume2.md" && grep -q 'garde-secret' "$TMP/resume2.md" && ok "--ci : les deux sections dans le résumé" || ko "--ci : résumé"
d=$(depot ci-sensible)
git -C "$d" checkout -qb f
printf 'x.txt %s 2026-10-30 ajoutee\n' "$EMP" > "$d/.garde-secret-exceptions"; valide "$d" exc
GITHUB_STEP_SUMMARY="$TMP/resume3.md" ci "$d"
grep -q '\.garde-secret-exceptions' "$TMP/resume3.md" && ok "--ci : .garde-secret-exceptions listé parmi les fichiers sensibles" || ko "--ci : fichier sensible"

# garde-deps protège .garde-secret-exceptions
gd() { json=$(python3 -c 'import json, sys
t, k, v = sys.argv[1:4]
print(json.dumps({"tool_name": t, "cwd": "/tmp", "tool_input": {k: v}}))' "$@")
  SORTIE=$(printf '%s' "$json" | python3 "$RACINE/hooks/garde-deps.py" 2>"$TMP/erreur"); CODE=$?; ERREUR=$(cat "$TMP/erreur"); }
gd Edit file_path /x/.garde-secret-exceptions; vaut "garde-deps bloque Edit .garde-secret-exceptions" 2
grep -q 'garde-secret-exceptions' <<<"$ERREUR" && ok "garde-deps cite .garde-secret-exceptions" || ko "garde-deps message"
gd Write file_path /x/.garde-secret-exceptions; vaut "garde-deps bloque Write .garde-secret-exceptions" 2
gd Bash command 'echo x > .garde-secret-exceptions'; vaut "garde-deps bloque echo x > .garde-secret-exceptions" 2
gd Bash command 'git diff main -- .garde-secret-exceptions'; vaut "garde-deps laisse passer git diff du fichier" 0

# ---------- correctifs de relecture ----------
d=$(depot gitattributes)
git -C "$d" checkout -qb f
echo '*.txt -diff' > "$d/.gitattributes"
printf 'T=%s\n' "$GH" > "$d/n.txt"; valide "$d" masque
lance "$d" --base main --ci; vaut ".gitattributes '-diff' n'aveugle pas le scan" 2
d=$(depot nul)
git -C "$d" checkout -qb f
printf 'a\0b T=%s\n' "$GH" > "$d/n.dat"; valide "$d" nul
lance "$d" --base main --ci; vaut "fichier à NUL : le jeton est trouvé" 2
grep -q 'n.dat' <<<"$ERREUR" && ok "fichier à NUL : bon chemin" || ko "fichier à NUL : chemin"
d=$(depot nul-sha)
git -C "$d" checkout -qb f
printf '+\0%s\n+T=%s\n' "$(printf 'a%.0s' {1..40})" "$GH" > "$d/n.dat"; valide "$d" nul-sha
lance "$d" --base main --ci; vaut "NUL suivi d'un faux sha : le jeton est trouvé" 2

# signal : garde-secret tué => échec du job
cp -r "$RACINE/hooks" "$TMP/hooks-tues"
printf 'import os, signal\nos.kill(os.getpid(), signal.SIGKILL)\n' > "$TMP/hooks-tues/garde-secret.py"
d=$(depot tue)
env GARDE_DEPS_FIXTURES="$FIX" python3 "$TMP/hooks-tues/verifie-manifestes.py" --depot "$d" --base main --ci >/dev/null 2>&1
[ "$?" = 2 ] && ok "--ci : garde-secret tué par un signal = échec" || ko "--ci : garde-secret tué"

# budget de temps du scan (hook) : avertissement, pas de blocage
d=$(depot budget)
printf 'x\n' > "$d/nonsuivi.txt"
python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("gs", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
t, i = m.scan(sys.argv[2], "HEAD", None, False, 1e-9)
print("budget" if i and not t else "rien")' "$S" "$d" | grep -q budget && ok "scan : budget dépassé signalé" || ko "scan : budget"

# motif url non quadratique
t0=$(date +%s)
python3 -c 'print("a-" * 150000)' | an >/dev/null
[ $(( $(date +%s) - t0 )) -lt 10 ] && ok "motif url : entrée pathologique rapide" || ko "motif url : lent"

# commentaire de fin de ligne d'un .env
printf 'MON_API_KEY=%s # commentaire\n' "valeurenv-${A36:5:10}" > "$TMP/w/.env"
po PostToolUse Bash "$TMP/w" stdout "contenu valeurenv-${A36:5:10}"
grep -q 'masqué:valeur-connue' <<<"$SORTIE" && ok "post : valeur de .env suivie d'un commentaire masquée" || ko "post : .env avec commentaire"
rm "$TMP/w/.env"

# git credential fill avec options globales
for c in 'git -c a=b credential fill' 'git -C . credential fill'; do
  hk Bash "$TMP/w" command "$c"; bloque "$c"
done

# retirer un .env suivi n'est pas refusé
d=$(depot retrait)
printf 'x=1\n' > "$d/.env"; git -C "$d" add -f .env; g -C "$d" commit -qm env
git -C "$d" checkout -qb f
git -C "$d" rm -q .env
lance "$d" --base HEAD; vaut "retrait d'un .env suivi : 0" 0

# ---------- second aller-retour de relecture ----------
t0=$(date +%s%N)
python3 -c 'print("eyJ-" * 100000)' | an >/dev/null
[ $(( ($(date +%s%N) - t0) / 1000000 )) -lt 2000 ] && ok "motif jwt : entrée pathologique rapide" || ko "motif jwt : lent"
hk Bash "$TMP/w" command 'git -C credential credential fill'; bloque "git -C credential credential fill"
hk Bash "$TMP/w" command 'gh gist create .env'; bloque "gh gist create .env"
hk Bash "$TMP/w" command 'gh gist edit abc ~/.ssh/id_x'; bloque "gh gist edit ~/.ssh/id_x"
hk Bash "$TMP/w" command 'gh auth -h github.com token'; bloque "gh auth -h github.com token"
hk Bash "$TMP/w" command 'gh auth --hostname github.com status --show-token'; bloque "gh auth --hostname … status --show-token"
hk Bash "$TMP/w" command 'gh -R o/r gist create .env'; bloque "gh -R o/r gist create .env"
hk Bash "$TMP/w" command 'gh gist create README.md'; passe "gh gist create README.md"
grep -q '"matcher": "Bash|Read|Grep|BashOutput|TaskOutput"' "$RACINE/hooks/hooks.json" && ok "hooks.json : masquage aussi sur BashOutput et TaskOutput" || ko "hooks.json : matcher BashOutput|TaskOutput"
d=$(depot budget-log)
python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("gs", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
t, i = m.scan(sys.argv[2], m.vm().VIDE, "HEAD", False, 1e-9)
print("budget" if any("commits" in x for x in i) else "rien")' "$S" "$d" | grep -q budget && ok "scan : budget couvre aussi les commits" || ko "scan : budget des commits"
d=$(depot incomplet)
printf 'x\n' > "$d/nonsuivi.txt"
GARDE_SECRET_BUDGET=1e-9 hk Bash "$d" command 'git push origin f' 2>/dev/null
SORTIE=$(printf '%s' "$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1], "tool_input": {"command": "git push origin f"}}))' "$d")" | GARDE_SECRET_BUDGET=1e-9 python3 "$S" --hook pre 2>"$TMP/erreur"); CODE=$?
vaut "scan incomplet : git push refusé" 2
SORTIE=$(printf '%s' "$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1], "tool_input": {"command": "git commit -m x"}}))' "$d")" | GARDE_SECRET_BUDGET=1e-9 python3 "$S" --hook pre 2>"$TMP/erreur"); CODE=$?
[ "$CODE" = 0 ] && grep -q 'scan incomplet' <<<"$SORTIE" && ok "scan incomplet : git commit avertit" || ko "scan incomplet : git commit"
d=$(depot typechange)
ln -s LISEZMOI "$d/l"; valide "$d" lien
rm "$d/l"; printf 'T=%s\n' "$GH" > "$d/l"; git -C "$d" add l
lance "$d"; vaut "lien devenu fichier (type change) : fort trouvé" 2

# ---------- scripts de banc épinglés ----------
BV="banc""-valeur-${A36:0:10}"
banc() { # $1 = nom ; dépôt avec script de banc déclaré (empreinte, directives script et masque)
  local d; d=$(depot "$1")
  mkdir -p "$d/scripts" "$d/.banc"
  printf '#!/bin/sh\n. .banc/identifiants.env\ncurl https://127.0.0.1:8443/x\n' > "$d/scripts/banc.sh"
  chmod +x "$d/scripts/banc.sh"
  printf 'BANC_ADMIN_USER=administrateur\nBANC_ADMIN_PASSWORD=%s\n' "$BV" > "$d/.banc/identifiants.env"
  printf 'script scripts/banc.sh %s 2026-11-04 captures\nmasque .banc/*.env 2026-11-04 banc\n' \
    "$(sha256sum "$d/scripts/banc.sh" | cut -d' ' -f1)" > "$d/.garde-secret-exceptions"
  echo "$d"
}
d=$(banc banc1)
for c in 'scripts/banc.sh' './scripts/banc.sh' ' scripts/banc.sh '; do hk Bash "$d" command "$c"; passe "script de banc : '$c'"; done
for c in 'bash scripts/banc.sh' 'sh -x scripts/banc.sh' 'source scripts/banc.sh' '. scripts/banc.sh' 'scripts/banc.sh --x' \
         'scripts/banc.sh | tee o' 'scripts/banc.sh > o' 'scripts/banc.sh; env' 'scripts/banc.sh && env' 'scripts/banc.sh &' \
         'X=1 scripts/banc.sh' 'env scripts/banc.sh' 'scripts/../scripts/banc.sh' '"$PWD"/scripts/banc.sh' \
         "bash -c 'scripts/banc.sh'" 'cd scripts && ./banc.sh' 'cat scripts/banc.sh' 'sed -i s/a/b/ scripts/banc.sh'; do
  hk Bash "$d" command "$c"; bloque "banc : $c"; sans_secret "banc : $c" "$BV"
done
mkdir -p "$d/sous"
hk Bash "$d/sous" command '../scripts/banc.sh'; bloque "banc : depuis un sous-dossier"
# formes admises : `cd <racine> &&` devant, `2>&1` et un seul filtre de lecture derrière
mkdir -p "$d/sous"
for c in "cd $d && scripts/banc.sh" "cd $d && ./scripts/banc.sh 2>&1" "cd $d && scripts/banc.sh 2>&1 | head -5" 'cd .. && scripts/banc.sh'; do
  hk Bash "$d/sous" command "$c"; passe "script de banc depuis un sous-dossier : $c"
done
hk Bash "$d" command 'cd . && scripts/banc.sh 2>&1 | tail -n 3'; passe "script de banc : cd . puis filtre"
hk Bash "$d" command 'scripts/banc.sh 2>&1 | tail -n 20'; passe "script de banc : 2>&1 puis tail"
hk_home() { HOME="$TMP" hk "$@"; }  # `~` résolu vers $TMP, donc ~/<nom> désigne le dépôt de test
hk_home Bash "$d/sous" command "cd ~/$(basename "$d") && scripts/banc.sh"; passe "script de banc : cd ~/…"
for c in "cd $d && scripts/banc.sh; rm x" "cd $d && scripts/banc.sh | sh" 'scripts/banc.sh | tail -n 3 | sh' 'scripts/banc.sh | tail $(id)' \
         'scripts/banc.sh | tail -f x > o' 'scripts/banc.sh | tee o' 'scripts/banc.sh 2>&1 | sh' 'scripts/banc.sh | grep P .banc/identifiants.env' \
         "cd $d/sous && scripts/banc.sh" 'cd /tmp && scripts/banc.sh' "cd $d && cat scripts/banc.sh" "cd $d && scripts/banc.sh &" 'scripts/banc.sh 2>&1 | tail `id`'; do
  hk Bash "$d/sous" command "$c"; bloque "banc : $c"; sans_secret "banc : $c" "$BV"
done
hk Bash "$d/sous" command 'scripts/banc.sh 2>&1'; bloque "banc : sous-dossier sans cd, avec 2>&1"
hk Bash "$d/sous" command 'scripts/banc.sh'; bloque "banc : racine non courante"
ln -s scripts/banc.sh "$d/l"
hk Bash "$d" command './l'; bloque "banc : lien l vers le script"
rm "$d/l"
hk Edit "$d" file_path "$d/scripts/banc.sh" old_string a new_string b; bloque "Edit du script de banc"
hk Write "$d" file_path "$d/scripts/banc.sh" content x; bloque "Write du script de banc"
hk Write "$d" file_path "$d/scripts/autre.sh" content x; passe "Write de scripts/autre.sh"
hk Write "$TMP" file_path "$d/scripts/banc.sh" content x; bloque "Write en chemin absolu depuis un cwd hors du dépôt"
for c in 'bash -x scripts/"banc".sh' 'bash -x scripts/b*' 'cp scripts/b* z' "cat scripts/'banc.sh'" 'cat scripts/ban?.sh'; do
  hk Bash "$d" command "$c"; bloque "banc : $c"
done
hk Edit "$d" file_path "$d/LISEZMOI" old_string a new_string b; passe "Edit d'un autre fichier"
for c in 'cat .banc/identifiants.env' 'source .banc/identifiants.env' 'grep P .banc/identifiants.env' 'echo x > .banc/identifiants.env'; do
  hk Bash "$d" command "$c"; bloque "banc : $c"
done
hk Read "$d" file_path "$d/.banc/identifiants.env"; bloque "banc : Read de identifiants.env"
d=$(banc banc2); mv "$d/scripts" "$d/copie"; mkdir "$d/vrai"; ln -s vrai "$d/scripts"; cp "$d/copie/banc.sh" "$d/vrai/banc.sh"
hk Bash "$d" command 'scripts/banc.sh'; bloque "banc : scripts remplacé par un lien"
d=$(banc banc3); printf '# x\n' >> "$d/scripts/banc.sh"
hk Bash "$d" command 'scripts/banc.sh'; bloque "banc : script modifié"
grep -q 'modifié' <<<"$ERREUR" && ok "banc : message d'empreinte" || ko "banc : message d'empreinte"
d=$(banc banc4); sed -i 's/ [0-9a-f]\{52\}\([0-9a-f]\{12\}\) / \1 /' "$d/.garde-secret-exceptions"
hk Bash "$d" command 'scripts/banc.sh'; bloque "banc : empreinte de 12 hex"
d=$(banc banc5); printf 'curl https://exemple.org/x\n' >> "$d/scripts/banc.sh"
printf 'script scripts/banc.sh %s 2026-11-04 r\n' "$(sha256sum "$d/scripts/banc.sh" | cut -d' ' -f1)" > "$d/.garde-secret-exceptions"
hk Bash "$d" command 'scripts/banc.sh'; bloque "banc : URL non locale"
grep -q 'non locale' <<<"$ERREUR" && ok "banc : message de cible" || ko "banc : message de cible"
for u in 'https:///exemple.org' 'http://[::1].exemple.org' 'http://[::1]x/' 'http://user@127.0.0.1/' 'http://127.0.0.1.exemple.org/'; do
  d=$(banc banc9); printf 'curl %s\n' "$u" >> "$d/scripts/banc.sh"
  printf 'script scripts/banc.sh %s 2026-11-04 r\n' "$(sha256sum "$d/scripts/banc.sh" | cut -d' ' -f1)" > "$d/.garde-secret-exceptions"
  hk Bash "$d" command 'scripts/banc.sh'; bloque "banc : cible $u"
done
d=$(banc banc9); printf 'curl http://[::1]:8080/x\ncurl file:///tmp/x\n' >> "$d/scripts/banc.sh"
printf 'script scripts/banc.sh %s 2026-11-04 r\n' "$(sha256sum "$d/scripts/banc.sh" | cut -d' ' -f1)" > "$d/.garde-secret-exceptions"
hk Bash "$d" command 'scripts/banc.sh'; passe "banc : [::1]:port et file:///"
d=$(depot banc6)
hk Bash "$d" command 'scripts/banc.sh'; passe "banc : sans directive, comportement inchangé"
d=$(banc banc8)
po PostToolUse Bash "$d" stdout "mdp $BV fin"
[ "$(champ hookSpecificOutput.updatedToolOutput.stdout | grep -c 'masqué:valeur-connue')" = 1 ] && ok "banc : mot de passe masqué" || ko "banc : mot de passe masqué"
sans_secret "banc : masquage" "$BV"
d=$(banc banc7); mkdir "$d/sous"
po PostToolUse Bash "$d/sous" stdout "mdp $BV fin"
grep -q 'masqué:valeur-connue' <<<"$SORTIE" && ok "banc : masqué depuis un sous-dossier" || ko "banc : masqué depuis un sous-dossier"
sans_secret "banc : masquage sous-dossier" "$BV"
po PostToolUse Bash "$d" stdout "u administrateur"
[ -z "$SORTIE" ] && ok "banc : BANC_ADMIN_USER intact" || ko "banc : BANC_ADMIN_USER intact"
rm "$d/.garde-secret-exceptions"
po PostToolUse Bash "$d" stdout "mdp $BV fin"
[ -z "$SORTIE" ] && ok "banc : sans directive masque, non masqué" || ko "banc : sans directive masque"
# ---------- scripts de banc : argument de filtre ----------
banc_filtre() { # $1 = nom ; banc + cibles tests/e2e/*.spec.ts déclarées
  local d; d=$(banc "$1")
  mkdir -p "$d/tests/e2e" "$d/sous"
  touch "$d/tests/e2e/connexion.spec.ts" "$d/tests/e2e/entites.spec.ts" "$d/tests/e2e/Majuscule.spec.ts"
  printf 'filtre scripts/banc.sh tests/e2e/*.spec.ts 2026-11-26 e2e\n' >> "$d/.garde-secret-exceptions"
  echo "$d"
}
d=$(banc_filtre bf1)
for c in 'scripts/banc.sh connexion' './scripts/banc.sh entites' $'scripts/banc.sh\tconnexion' 'scripts/banc.sh connexion 2>&1 | tail -n 20'; do
  hk Bash "$d" command "$c"; passe "banc filtre : admis $c"
done
hk Bash "$d/sous" command "cd $d && scripts/banc.sh connexion"; passe "banc filtre : cd racine depuis un sous-dossier"
touch "$d/tests/e2e/nouveau.spec.ts"
hk Bash "$d" command 'scripts/banc.sh nouveau'; passe "banc filtre : cible ajoutée"
d2=$(banc bf2); mkdir -p "$d2/outils"; touch "$d2/outils/test_api.py"
printf 'filtre scripts/banc.sh outils/test_*.py 2026-11-26 e2e\n' >> "$d2/.garde-secret-exceptions"
hk Bash "$d2" command 'scripts/banc.sh api'; passe "banc filtre : préfixe"
for c in 'scripts/banc.sh connexion entites' 'scripts/banc.sh Majuscule' 'scripts/banc.sh --ui' 'scripts/banc.sh -x' "scripts/banc.sh 'connexion'" \
         'scripts/banc.sh "connexion"' 'scripts/banc.sh $X' 'scripts/banc.sh $(echo connexion)' 'scripts/banc.sh `id`' 'scripts/banc.sh conn*' \
         'scripts/banc.sh conn?xion' 'scripts/banc.sh connexion2>&1' $'scripts/banc.sh\nenv' $'scripts/banc.sh connexion\nenv' \
         'scripts/banc.sh connexion; env' 'scripts/banc.sh connexion && env' 'scripts/banc.sh connexion > o' 'scripts/banc.sh connexion | sh' \
         'scripts/banc.sh connexion | base64' 'scripts/banc.sh connexion &' 'X=1 scripts/banc.sh connexion' 'bash scripts/banc.sh connexion' \
         'scripts/banc.sh ../connexion' 'scripts/banc.sh connexion.spec'; do
  hk Bash "$d" command "$c"; bloque "banc filtre : refus $c"; sans_secret "banc filtre : refus $c" "$BV"
done
hk Bash "$d" command 'scripts/banc.sh inconnu'; bloque "banc filtre : cible inconnue"
grep -q connexion <<<"$ERREUR" && ok "banc filtre : cible inconnue, message" || ko "banc filtre : cible inconnue, message"
d=$(banc bf3)
hk Bash "$d" command 'scripts/banc.sh connexion'; bloque "banc filtre : sans directive"
grep -q 'aucune cible de filtre' <<<"$ERREUR" && ok "banc filtre : sans directive, message" || ko "banc filtre : sans directive, message"
d=$(banc_filtre bf4); mv "$d/scripts" "$d/copie"; mkdir "$d/vrai"; ln -s vrai "$d/scripts"; cp "$d/copie/banc.sh" "$d/vrai/banc.sh"
hk Bash "$d" command 'scripts/banc.sh connexion'; bloque "banc filtre : contrôle, scripts en lien"
grep -q 'lien symbolique' <<<"$ERREUR" && ok "banc filtre : contrôle, message de lien" || ko "banc filtre : contrôle, message de lien"
d=$(banc_filtre bf5); printf '# x\n' >> "$d/scripts/banc.sh"
hk Bash "$d" command 'scripts/banc.sh connexion'; bloque "banc filtre : contrôle, script modifié"
grep -q 'modifié' <<<"$ERREUR" && ok "banc filtre : contrôle, message d'empreinte" || ko "banc filtre : contrôle, message d'empreinte"
d=$(banc_filtre bf6); printf 'curl https://exemple.org/x\n' >> "$d/scripts/banc.sh"
printf 'script scripts/banc.sh %s 2026-11-04 r\nfiltre scripts/banc.sh tests/e2e/*.spec.ts 2026-11-26 e2e\n' "$(sha256sum "$d/scripts/banc.sh" | cut -d' ' -f1)" > "$d/.garde-secret-exceptions"
hk Bash "$d" command 'scripts/banc.sh connexion'; bloque "banc filtre : contrôle, URL non locale"
grep -q 'non locale' <<<"$ERREUR" && ok "banc filtre : contrôle, message de cible" || ko "banc filtre : contrôle, message de cible"
d=$(banc_filtre bf7)
hk Bash "$d/sous" command 'scripts/banc.sh connexion'; bloque "banc filtre : contrôle, sous-dossier sans cd"
grep -q 'racine du dépôt' <<<"$ERREUR" && ok "banc filtre : contrôle, message de racine" || ko "banc filtre : contrôle, message de racine"
d=$(banc_filtre bf8)
printf 'script scripts/banc.sh %s 2026-11-04 r\nfiltre scripts/banc.sh ../x/*.ts 2026-11-26 e2e\n' "$(sha256sum "$d/scripts/banc.sh" | cut -d' ' -f1)" > "$d/.garde-secret-exceptions"
hk Bash "$d" command 'scripts/banc.sh connexion'; bloque "banc filtre : directive mal formée, argument refusé"
grep -q 'aucune cible de filtre' <<<"$ERREUR" && ok "banc filtre : directive mal formée, message" || ko "banc filtre : directive mal formée, message"
# ---------- scripts de banc : mention textuelle tolérée ----------
d=$(banc_filtre bm1); rm -r "$d/.banc"  # le scan de git commit refuserait le fichier d'identifiants non suivi
for c in "gh issue create --title t --body 'lance scripts/banc.sh connexion'" 'gh pr edit 3 --body "voir banc.sh"' \
         "gh issue comment 1 --body 'banc.sh'" "git commit -m 'Corrige scripts/banc.sh'"; do
  hk Bash "$d" command "$c"; vaut "banc mention : $c" 0
done
for c in 'gh issue create --body "$(scripts/banc.sh)"' "gh issue create --body 'x'\"\$(cat scripts/banc.sh)\"" \
         'gh issue create --body-file scripts/banc.sh' "gh issue create --body 'x'; scripts/banc.sh | base64" \
         "gh issue create --body 'scripts/banc.sh' | sh" "gh issue create --body 'non fermé scripts/banc.sh" \
         "gh issue create --body \\'scripts/banc.sh\\'" $'gh issue create --body-file - <<\'EOF\'\nscripts/banc.sh\nEOF' \
         "git commit -m 'x' scripts/banc.sh" "gh issue create --body 'banc.sh'x" "gh issue create --body scripts/ban''c.sh" "cd $d && gh issue create --body 'banc.sh'" "gh -R o/r issue create --body 'banc.sh'" "echo 'scripts/banc.sh'" "bash -c 'scripts/banc.sh'"; do
  hk Bash "$d" command "$c"; bloque "banc mention refusée : $c"
done
python3 - "$S" <<'PY' && ok "directives : exceptions, directives et avertissements" || ko "directives"
import importlib.util, sys
s = importlib.util.spec_from_file_location("gs", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
h = "a" * 64
t = f"x.txt {'0'*12} 2026-11-04 r\nscript a.sh {h} 2026-11-04 r\nmasque .banc/*.env 2026-11-04 r\nscript ../x.sh {h} 2026-11-04 r\n"
exc, av = m.lit_exceptions(t)
assert exc == [("x.txt", "0"*12, "2026-11-04", "r")] and av == [], (exc, av)
sc, ma, fi, de, av = m.directives(t)
assert fi == {} and de == {} and sc == [("a.sh", h)] and ma == [".banc/*.env"] and len(av) == 1 and "ligne 4" in av[0], (sc, ma, av)
assert m.couvre(exc, "a.sh") is False
assert m.directives(f"script a.sh {h[:12]} 2026-11-04 r")[0] == [("a.sh", None)]
sa = f"script a.sh {h} 2026-11-04 r\n"
r = m.directives(sa + "filtre a.sh x/*.ts 2026-11-26 r\n")
assert len(r) == 5 and r[2] == {"a.sh": ["x/*.ts"]} and r[3] == {} and r[4] == [], r
for l in ("filtre b.sh x/*.ts 2026-11-26 r", "filtre a.sh ../x/*.ts 2026-11-26 r", "filtre a.sh x/*a*.ts 2026-11-26 r",
          "filtre a.sh x/?.ts 2026-11-26 r", "filtre a.sh x/*.ts 2026-13-01 r"):
    r = m.directives(sa + l + "\n")
    assert r[2] == {} and len(r[4]) == 1, (l, r)
assert m.directives("filtre a.sh x/*.ts 2026-11-26 r\n")[2] == {}
exc, av = m.lit_exceptions(sa + "filtre a.sh x/*.ts 2026-11-26 r\n")
assert exc == [] and av == [], (exc, av)

sd = sa + f"depend a.sh outils/a.ts {h} 2026-11-26 r\n"
r = m.directives(sd)
assert r[3] == {"a.sh": [(2, "outils/a.ts", h)]} and r[4] == [], r
exc, av = m.lit_exceptions(sd)
assert exc == [] and av == [], (exc, av)
r = m.directives(sa + f"depend a.sh outils/a.ts {h[:12]} 2026-11-26 r\n")
assert r[3] == {"a.sh": [(2, "outils/a.ts", None)]} and len(r[4]) == 1, r
r = m.directives(sa + f"depend a.sh outils/a.ts {h} 2026-13-01 r\n")
assert r[3] == {"a.sh": [(2, "outils/a.ts", None)]} and len(r[4]) == 1, r
r = m.directives(sa + f"depend a.sh ../x {h} 2026-11-26 r\n")
assert r[3] == {"a.sh": [(2, None, None)]} and len(r[4]) == 1, r
r = m.directives(sa + f"depend b.sh outils/a.ts {h} 2026-11-26 r\n")
assert r[3] == {} and len(r[4]) == 1 and "b.sh" in r[4][0], r
PY

# ---------- scripts de banc : dépendances (depend) ----------
emp_arbre() { # $1 = dossier ; empreinte d'arbre recalculée à part (implémentation de référence)
  python3 - "$1" <<'PY'
import hashlib, os, sys
r = sys.argv[1]; e = []
for dp, dn, fn in os.walk(r):
    for f in fn:
        p = os.path.join(dp, f)
        e.append(os.path.relpath(p, r).encode() + b"\0" + hashlib.sha256(open(p, "rb").read()).hexdigest().encode() + b"\n")
print(hashlib.sha256(b"".join(sorted(e))).hexdigest())
PY
}
sha() { sha256sum "$1" | cut -d' ' -f1; }
ecrit_dep() { # $1 = dépôt ; réécrit les 2 lignes depend selon l'état courant
  local d=$1
  { printf 'script scripts/banc.sh %s 2026-11-04 captures\nmasque .banc/*.env 2026-11-04 banc\n' "$(sha "$d/scripts/banc.sh")"
    printf 'depend scripts/banc.sh outils/a.ts %s 2026-11-26 lancé\n' "$(sha "$d/outils/a.ts")"
    printf 'depend scripts/banc.sh outils/lib %s 2026-11-26 modules\n' "$(emp_arbre "$d/outils/lib")"; } > "$d/.garde-secret-exceptions"
}
banc_dep() { # $1 = nom ; banc + outils/a.ts, outils/lib/{x,y}.ts et leurs lignes depend
  local d; d=$(banc "$1")
  mkdir -p "$d/outils/lib"
  printf 'console.log(1)\n' > "$d/outils/a.ts"; printf 'x\n' > "$d/outils/lib/x.ts"; printf 'y\n' > "$d/outils/lib/y.ts"
  ecrit_dep "$d"
  echo "$d"
}
d=$(banc_dep bd1); hk Bash "$d" command 'scripts/banc.sh'; passe "depend : dépendances intactes"
d=$(banc_dep bd2); printf ' ' >> "$d/outils/a.ts"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : fichier modifié"
for mot in outils/a.ts modifié -- --empreintes; do grep -q -e "$mot" <<<"$ERREUR" && ok "depend : message contient $mot" || ko "depend : message contient $mot"; done
sans_secret "depend : fichier modifié" "$BV"
d=$(banc_dep bd3); printf 'z\n' > "$d/outils/lib/z.ts"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : dossier ajout"
grep -q 'outils/lib' <<<"$ERREUR" && ok "depend : dossier ajout, message" || ko "depend : dossier ajout, message"
d=$(banc_dep bd4); rm "$d/outils/lib/y.ts"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : dossier suppression"
grep -q 'outils/lib' <<<"$ERREUR" && ok "depend : dossier suppression, message" || ko "depend : dossier suppression, message"
d=$(banc_dep bd5); printf 'x2\n' > "$d/outils/lib/x.ts"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : dossier modif"
grep -q 'outils/lib' <<<"$ERREUR" && ok "depend : dossier modif, message" || ko "depend : dossier modif, message"
d=$(banc_dep bd6); rm "$d/outils/a.ts"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : absent"
grep -q 'absent' <<<"$ERREUR" && ok "depend : absent, message" || ko "depend : absent, message"
d=$(banc_dep bd7); ln -s ../../hors "$d/outils/lib/l"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : lien interne"
grep -q 'lien' <<<"$ERREUR" && ok "depend : lien interne, message" || ko "depend : lien interne, message"
d=$(banc_dep bd8); mv "$d/outils/a.ts" "$d/outils/b.ts"; ln -s b.ts "$d/outils/a.ts"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : lien"
d=$(banc_dep bd9); sed -i 's/ [0-9a-f]\{52\}\([0-9a-f]\{12\}\) 2026-11-26 lancé/ \1 2026-11-26 lancé/' "$d/.garde-secret-exceptions"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : mal formée (empreinte de 12 hex)"
grep -q 'mal déclarée' <<<"$ERREUR" && ok "depend : mal formée, message" || ko "depend : mal formée, message"
d=$(banc_dep bd10); sed -i 's/2026-11-26 lancé/2026-13-45 lancé/' "$d/.garde-secret-exceptions"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : mal formée (date)"
d=$(banc_dep bd11); printf 'depend scripts/autre.sh outils/a.ts %s 2026-11-26 r\ndepend scripts/autre.sh outils/a.ts 123456789abc 2026-11-26 r\n' "$(sha "$d/outils/a.ts")" >> "$d/.garde-secret-exceptions"
printf ' ' >> "$d/outils/a.ts"; ecrit_dep "$d"; printf 'depend scripts/autre.sh outils/a.ts 123456789abc 2026-11-26 r\n' >> "$d/.garde-secret-exceptions"
hk Bash "$d" command 'scripts/banc.sh'; passe "depend : mal formée, script non déclaré sans effet"
d=$(banc_dep bd12); printf ' ' >> "$d/outils/a.ts"; printf 'x2\n' > "$d/outils/lib/x.ts"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : plusieurs"
{ grep -q 'outils/a.ts' <<<"$ERREUR" && grep -q 'outils/lib' <<<"$ERREUR" && [ "$(grep -c 'Bloqué' <<<"$ERREUR")" = 1 ]; } && ok "depend : plusieurs, un seul refus" || ko "depend : plusieurs, un seul refus"
d=$(banc_dep bd13); for i in $(seq 1 1001); do : > "$d/outils/lib/f$i"; done
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : arbre trop grand"
grep -q 'plus de 1000 fichiers' <<<"$ERREUR" && ok "depend : arbre trop grand, message" || ko "depend : arbre trop grand, message"
d=$(banc_dep bd14)
hk Edit "$d" file_path "$d/outils/a.ts" new_string 'x'; vaut "depend : écriture, Edit d'une dépendance" 0
hk Write "$d" file_path "$d/outils/a.ts" content 'x'; vaut "depend : écriture, Write d'une dépendance" 0
hk Edit "$d" file_path "$d/scripts/banc.sh" new_string 'x'; bloque "depend : écriture, Edit du script"
d=$(banc bd15); hk Bash "$d" command 'scripts/banc.sh'; passe "depend : script sans depend inchangé"
d=$(banc_dep bd16)
av=$(sha "$d/.garde-secret-exceptions"); SORTIE=$(python3 "$S" --empreintes --depot "$d" 2>&1); CODE=$?
vaut "depend : --empreintes, tout à jour" 0; grep -q 'empreintes à jour' <<<"$SORTIE" && ok "depend : --empreintes, message à jour" || ko "depend : --empreintes, message à jour"
printf ' ' >> "$d/outils/a.ts"
SORTIE=$(python3 "$S" --empreintes --depot "$d" 2>&1); CODE=$?
vaut "depend : --empreintes, dépendance modifiée" 1
NOUV="$(sha "$d/outils/a.ts")"
grep -q "^ligne 3 : depend scripts/banc.sh outils/a.ts $NOUV $(date +%F) lancé\$" <<<"$SORTIE" && ok "depend : --empreintes, ligne à recopier" || ko "depend : --empreintes, ligne à recopier ($SORTIE)"
[ "$(grep -c '^ligne' <<<"$SORTIE")" = 1 ] && ok "depend : --empreintes, une seule ligne" || ko "depend : --empreintes, une seule ligne"
[ "$av" = "$(sha "$d/.garde-secret-exceptions")" ] && ok "depend : --empreintes, fichier inchangé" || ko "depend : --empreintes, fichier inchangé"
hk Bash "$d" command 'scripts/banc.sh'; bloque "depend : --empreintes, refus avant recopie"
ligne=$(grep '^ligne 3' <<<"$SORTIE" | sed 's/^ligne 3 : //')
sed -i "3s|.*|$ligne|" "$d/.garde-secret-exceptions"
hk Bash "$d" command 'scripts/banc.sh'; passe "depend : --empreintes, ligne recopiée"
d=$(banc bd17); SORTIE=$(python3 "$S" --empreintes --depot "$d" 2>&1); CODE=$?
grep -q 'scripts/banc.sh : aucune dépendance déclarée' <<<"$SORTIE" && [ "$CODE" = 0 ] && ok "depend : --empreintes, script sans depend" || ko "depend : --empreintes, script sans depend ($CODE)"
d=$(banc_dep bd18); rm "$d/outils/a.ts"
SORTIE=$(python3 "$S" --empreintes --depot "$d" 2>&1); CODE=$?
vaut "depend : --empreintes, absent" 1; grep -q 'ligne 3 : outils/a.ts : absent' <<<"$SORTIE" && ok "depend : --empreintes, motif absent" || ko "depend : --empreintes, motif absent"
d=$(depot bd19); SORTIE=$(python3 "$S" --empreintes --depot "$d" 2>&1); CODE=$?
vaut "depend : --empreintes, sans fichier" 0
for l in 'depend scripts/banc.sh ../x 2026-11-26 r' 'depend scripts/banc.sh' 'depend scripts/banc.sh outils/a.ts' 'depend scripts/autre.sh outils/a.ts 2026-11-26 r'; do
  d=$(banc_dep bd20); printf '%s\n' "$l" >> "$d/.garde-secret-exceptions"
  SORTIE=$(python3 "$S" --empreintes --depot "$d" 2>&1); CODE=$?
  [ "$CODE" = 1 ] && grep -q '^ligne 5 : ' <<<"$SORTIE" && ! grep -q 'empreintes à jour' <<<"$SORTIE" && ok "depend : --empreintes, signale « $l »" || ko "depend : --empreintes, signale « $l » ($CODE)"
done

# ---------- banc exigé ----------
exb() { # $1 = nom, $2.. = lignes ajoutées à .garde-secret-exceptions ; branche claude/x créée, fichiers à ajouter ensuite
  local d; d=$(banc "$1"); shift
  for l in "$@"; do printf '%s\n' "$l" >> "$d/.garde-secret-exceptions"; done
  sur "$d"
  git -C "$d" checkout -q -b claude/x >/dev/null 2>&1
  echo "$d"
}
fic() { # $1 = dépôt, $2.. = fichiers ajoutés puis commités
  local d=$1; shift
  sur "$d"
  for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; echo x > "$d/$f"; done
  git -C "$d" add -- "$@" && g -C "$d" commit -qm ajout
}
d=$(exb ex1 'exige scripts/banc.sh web/* 2026-11-26 interface'); fic "$d" web/a.ts
lance "$d" --exige --base main
vaut "exige : chemin couvert" 0
[ "$SORTIE" = "exige scripts/banc.sh : 1 fichier(s) (web/a.ts)" ] && ok "exige : sortie chemin couvert" || ko "exige : sortie chemin couvert ($SORTIE)"
d=$(exb ex2 'exige scripts/banc.sh web/* 2026-11-26 a' 'exige scripts/banc.sh lib/* 2026-11-26 b'); fic "$d" web/a.ts web/b.ts lib/c.ts lib/d.ts
lance "$d" --exige --base main
[ "$SORTIE" = "exige scripts/banc.sh : 4 fichier(s) (lib/c.ts, lib/d.ts, web/a.ts, …)" ] && ok "exige : union" || ko "exige : union ($SORTIE)"
d=$(exb ex3 'exige scripts/banc.sh web/* 2026-11-26 a'); fic "$d" web/sous/b.ts
lance "$d" --exige --base main
[ "$SORTIE" = "exige scripts/banc.sh : 1 fichier(s) (web/sous/b.ts)" ] && ok "exige : sous-dossier" || ko "exige : sous-dossier ($SORTIE)"
d=$(exb ex4 'exige scripts/banc.sh web/* 2026-11-26 a'); fic "$d" doc/a.md
lance "$d" --exige --base main
vaut "exige : hors glob, code" 0
[ "$SORTIE" = "aucun banc exigé" ] && ok "exige : hors glob" || ko "exige : hors glob ($SORTIE)"
d=$(depot ex5); sur "$d"; git -C "$d" checkout -q -b claude/x; fic "$d" web/a.ts
lance "$d" --exige --base main
vaut "exige : sans fichier, code" 0
[ "$SORTIE" = "aucun banc exigé" ] && ok "exige : sans fichier" || ko "exige : sans fichier ($SORTIE)"
i=0
for l in 'exige scripts/autre.sh web/* 2026-11-26 r' 'exige scripts/banc.sh ../x 2026-11-26 r' 'exige scripts/banc.sh web/* 2026-13-45 r' 'exige scripts/banc.sh web/*'; do
  i=$((i + 1)); d=$(exb ex6$i "$l"); fic "$d" web/a.ts
  lance "$d" --exige --base main
  [ "$CODE" = 0 ] && grep -q '^⚠ ' <<<"$SORTIE" && grep -q '^aucun banc exigé$' <<<"$SORTIE" && ok "exige : ligne ignorée « $l »" || ko "exige : ligne ignorée « $l » ($CODE $SORTIE)"
done
d=$(exb ex7 'exige scripts/banc.sh web/* 2026-11-26 a'); fic "$d" web/a.ts
lance "$d" --exige --base inconnue
vaut "exige : base inconnue" 2
d=$(exb ex8 'exige scripts/banc.sh web/* 2026-11-26 a'); fic "$d" web/a.ts
rm -rf "$d/.banc"; lance "$d" --base main
vaut "exige : pas une exception, code" 0
! grep -q 'invalide' <<<"$SORTIE$ERREUR" && ok "exige : pas une exception" || ko "exige : pas une exception ($SORTIE)"

# ---------- FIN ----------
exit $((ECHECS > 0))
