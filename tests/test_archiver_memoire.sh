#!/usr/bin/env bash
# Tests hors réseau de l'archivage de la mémoire. Lancer depuis n'importe où.
# Tout se passe sous un dossier jetable : HOME et mémoires factices.
set -u
RACINE=$(cd "$(dirname "$0")/.." && pwd)
S="$RACINE/skills/archiver-memoire/archiver-memoire.py"
ECHECS=0
ok() { echo "OK    $1"; }
ko() { echo "ECHEC $1"; ECHECS=$((ECHECS + 1)); }
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
g() { git -c user.name=t -c user.email=t@t "$@"; }

# Garde : toute écriture de test se fait sous $TMP, en chemin absolu.
sous_tmp() { case "$1" in "$TMP"/*) return 0 ;; *) echo "ABANDON : $1 hors de $TMP" >&2; exit 2 ;; esac; }

# nouvelle_memoire <nom> : crée $TMP/<nom>/memory et n'affiche que son chemin.
nouvelle_memoire() {
  local m="$TMP/$1/memory"; sous_tmp "$m"; mkdir -p "$m"; printf '%s\n' "$m"
}
# lance <args...> : exécute le script ; stdout, stderr et code dans $TMP/{out,err,code}.
lance() { python3 "$S" "$@" >"$TMP/out" 2>"$TMP/err"; echo $? >"$TMP/code"; }
code() { cat "$TMP/code"; }
empreintes() { (cd "$1" && find . -type f -o -type l | sort | while read -r f; do echo "$f $(sha256sum < "$f")"; done); }
ligne() { python3 -c 'import sys; print(sys.argv[1] * int(sys.argv[2]))' "$1" "$2"; }

# --- copie intégrale
M=$(nouvelle_memoire a)
printf '%s\n' '- [Un](un.md) — durable' > "$M/MEMORY.md"
echo un > "$M/un.md"; mkdir -p "$M/sous"; echo deux > "$M/sous/deux.md"; ln -s un.md "$M/lien.md"
AVANT=$(empreintes "$M")
lance --memoire "$M" --date 2026-11-26
A="$TMP/a/historique/2026-11-26-memoire"
[ "$(code)" = 0 ] && diff -r "$M" "$A" >/dev/null && [ -L "$A/lien.md" ] && [ "$(readlink "$A/lien.md")" = un.md ] \
  && [ "$AVANT" = "$(empreintes "$M")" ] && ok "copie intégrale, memory inchangé" || ko "copie intégrale"
grep -q "^Mémoire : $M\$" "$TMP/out" && grep -q "^Archive : $A (3 fichiers)\$" "$TMP/out" && grep -q '^Rien à signaler\.$' "$TMP/out" \
  && ok "sortie standard" || ko "sortie standard : $(cat "$TMP/out")"

# --- même date
lance --memoire "$M" --date 2026-11-26; c2=$(code)
lance --memoire "$M" --date 2026-11-26; c3=$(code)
[ "$c2" = 0 ] && [ "$c3" = 0 ] && [ -d "$TMP/a/historique/2026-11-26-memoire-2" ] && [ -d "$TMP/a/historique/2026-11-26-memoire-3" ] \
  && diff -r "$M" "$A" >/dev/null && [ "$(ls "$TMP/a/historique" | wc -l)" = 3 ] && ok "même date : -2, -3" || ko "même date"

# --- mémoire absente
absente() { # $1 = libellé
  [ "$(code)" = 1 ] && grep -q 'aucune mémoire' "$TMP/err" && [ ! -e "$2/historique" ] && ok "mémoire absente : $1" || ko "mémoire absente : $1"
}
lance --memoire "$TMP/b/memory" --date 2026-11-26; absente "inexistant" "$TMP/b"
M=$(nouvelle_memoire c); lance --memoire "$M" --date 2026-11-26; absente "vide" "$TMP/c"
M=$(nouvelle_memoire d); mkdir -p "$M/x/y"; lance --memoire "$M" --date 2026-11-26; absente "sous-dossiers vides" "$TMP/d"

# --- refus
M=$(nouvelle_memoire e); echo x > "$M/MEMORY.md"
lance --memoire "$M" --date 2026-13-01; c1=$(code)
lance --memoire "$M" --date x; c2=$(code)
mkdir -p "$TMP/f/autre"; echo x > "$TMP/f/autre/MEMORY.md"
lance --memoire "$TMP/f/autre" --date 2026-11-26; c3=$(code)
[ "$c1" = 2 ] && [ "$c2" = 2 ] && [ "$c3" = 2 ] && [ ! -e "$TMP/e/historique" ] && [ ! -e "$TMP/f/historique" ] \
  && ok "refus : date mal formée, dossier non memory" || ko "refus ($c1 $c2 $c3)"

# --- ligne d'index
M=$(nouvelle_memoire g)
{ ligne a 151; ligne é 150; echo court; } > "$M/MEMORY.md"
lance --memoire "$M" --date 2026-11-26
grep -q '^Ligne d.index trop longue : MEMORY.md:1 (151 caractères) « a\{60\}… »$' "$TMP/out" \
  && [ "$(grep -c 'Ligne d.index' "$TMP/out")" = 1 ] && ! grep -q '^Rien à signaler' "$TMP/out" \
  && [ "$(code)" = 0 ] && ok "ligne d'index" || ko "ligne d'index : $(cat "$TMP/out")"

# --- taille
M=$(nouvelle_memoire h); echo x > "$M/MEMORY.md"; mkdir "$M/s"
head -c 3073 /dev/zero | tr '\0' x > "$M/s/gros.md"; head -c 3072 /dev/zero | tr '\0' x > "$M/pile.md"
lance --memoire "$M" --date 2026-11-26
grep -q '^Fichier trop gros : s/gros.md (3073 octets > 3072)$' "$TMP/out" && ! grep -q 'pile.md' "$TMP/out" \
  && ! grep -q '^Rien à signaler' "$TMP/out" && ok "taille : 3073 signalé, 3072 non" || ko "taille : $(cat "$TMP/out")"

# --- index absent
M=$(nouvelle_memoire i); echo x > "$M/autre.md"
lance --memoire "$M" --date 2026-11-26
[ "$(code)" = 0 ] && grep -q '^MEMORY.md absent$' "$TMP/out" && [ -f "$TMP/i/historique/2026-11-26-memoire/autre.md" ] \
  && ok "index absent" || ko "index absent"

# --- dérivation
derive() { echo "$HOME/.claude/projects/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')/memory"; }
mkdir -p "$TMP/depot/sub"; g -C "$TMP/depot" init -q -b main; echo x > "$TMP/depot/f"; g -C "$TMP/depot" add -A; g -C "$TMP/depot" commit -q -m i
g -C "$TMP/depot" worktree add -q "$TMP/wt" -b wt
M=$(derive "$TMP/depot"); sous_tmp "$M"; mkdir -p "$M"; echo m > "$M/MEMORY.md"
res=""
for p in "$TMP/depot" "$TMP/depot/sub" "$TMP/wt"; do
  lance --projet "$p" --date 2026-11-26; grep -q "^Mémoire : $M\$" "$TMP/out" && res="$res.ok" || res="$res.ko"
done
[ "$res" = ".ok.ok.ok" ] && [ -f "$(dirname "$M")/historique/2026-11-26-memoire/MEMORY.md" ] && ok "dérivation depuis dépôt, sous-dossier et worktree" || ko "dérivation dépôt ($res)"
mkdir -p "$TMP/a.b"
lance --projet "$TMP/a.b" --date 2026-11-26
grep -q "aucune mémoire à $(derive "$TMP/a.b")\$" "$TMP/err" && ok "dérivation hors git" || ko "dérivation hors git : $(cat "$TMP/err")"
lance --projet /tmp/a.b/ --date 2026-11-26
grep -q "aucune mémoire à $HOME/.claude/projects/-tmp-a-b/memory\$" "$TMP/err" && ok "dérivation /tmp/a.b -> -tmp-a-b" || ko "dérivation /tmp/a.b : $(cat "$TMP/err")"
lance --projet "$TMP/depot" --memoire "$TMP/e/memory" --date 2026-11-26
grep -q "^Mémoire : $TMP/e/memory\$" "$TMP/out" && ok "--memoire prioritaire" || ko "--memoire prioritaire"

# --- rien n'a été écrit hors du dossier jetable
[ ! -e "$RACINE/historique" ] && ok "kit intact" || ko "kit touché"

[ "$ECHECS" = 0 ] || { echo "$ECHECS échec(s)"; exit 1; }
