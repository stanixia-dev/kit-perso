#!/usr/bin/env python3
"""Contrôle du runtime Node : refuse un Node plus ancien que la dernière version de sécurité de sa branche
(index https://nodejs.org/dist/index.json, champ security). Autonome, stdlib uniquement.
Usage : verifie-runtime.py [--ci | --hook pre]
  CLI (défaut) : 1 essai réseau de 4 s, cache lu et écrit, sortie 2 si index injoignable sans cache.
  --ci         : 2 essais de 10 s, aucun cache, sortie 2 si index injoignable (fail-closed).
  --hook pre   : PreToolUse Bash, JSON sur stdin ; fail-open (sortie 0) si node ou l'index manquent.
Variable de test KIT_PERSO_NODE_INDEX=<fichier> : lit ce fichier au lieu du réseau."""
import datetime, json, os, re, shutil, subprocess, sys, tempfile, time, urllib.request

URL = "https://nodejs.org/dist/index.json"
FRAIS, PAUSE = 6 * 3600, 15 * 60
MOTS = re.compile(r"(?<![\w.-])(node|npm|npx|pnpm|yarn|corepack)(?![\w.-])")

def version_node():
    chemin = shutil.which("node")
    if not chemin:
        return None
    try:
        r = subprocess.run([chemin, "--version"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.match(r"v(\d+)\.(\d+)\.(\d+)", r.stdout.strip())
    return tuple(int(x) for x in m.groups()) if m else None

def lire_index(essais, delai):
    """Renvoie {majeure: (x, y, z)} ou None si injoignable ou inexploitable."""
    for _ in range(essais):
        try:
            test = os.environ.get("KIT_PERSO_NODE_INDEX")
            if test:
                with open(test, encoding="utf-8") as f:
                    data = json.load(f)
            else:
                req = urllib.request.Request(URL, headers={"User-Agent": "kit-perso"})
                with urllib.request.urlopen(req, timeout=delai) as r:
                    data = json.loads(r.read().decode("utf-8"))
            if not isinstance(data, list):
                continue
            corriges = {}
            for e in data:
                if not isinstance(e, dict) or e.get("security") is not True:
                    continue
                m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", str(e.get("version", "")))
                if m:
                    v = tuple(int(x) for x in m.groups())
                    corriges[v[0]] = max(corriges.get(v[0], v), v)
            if corriges:
                return corriges
        except (OSError, ValueError):
            pass
    return None

def chemin_cache():
    base = os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.join("~", ".claude", "plugins", "data", "kit-perso")
    dossier = os.path.realpath(os.path.expanduser(base))
    racine = os.path.realpath(os.path.expanduser("~/.claude/plugins"))
    if not (dossier + os.sep).startswith(racine + os.sep):
        return None
    return os.path.join(dossier, "node-corriges.json")

def lire_cache(chemin):
    try:
        with open(chemin, encoding="utf-8") as f:
            c = json.load(f)
        corriges = {}
        for k, v in c["corriges"].items():
            m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", v)
            corriges[int(k)] = tuple(int(x) for x in m.groups())
        if not corriges:
            return None
        return {"lu": float(c["lu"]), "essai": float(c["essai"]), "corriges": corriges}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None

def ecrire_cache(chemin, lu, essai, corriges):
    try:
        os.makedirs(os.path.dirname(chemin), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(chemin))
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"lu": lu, "essai": essai,
                       "corriges": {str(k): ".".join(map(str, v)) for k, v in corriges.items()}}, f)
        os.replace(tmp, chemin)
    except OSError:
        pass

def obtenir(ci):
    """Renvoie (corriges, date_si_perime) ; corriges None si injoignable."""
    if ci:
        return lire_index(2, 10), None
    chemin = chemin_cache()
    cache = lire_cache(chemin) if chemin else None
    maintenant = time.time()
    if cache and maintenant - cache["lu"] < FRAIS:
        return cache["corriges"], None
    perime = (cache["corriges"], datetime.date.fromtimestamp(cache["lu"]).isoformat()) if cache else (None, None)
    if cache and maintenant - cache["essai"] < PAUSE:
        return perime
    corriges = lire_index(1, 4)
    if corriges:
        if chemin:
            ecrire_cache(chemin, maintenant, maintenant, corriges)
        return corriges, None
    if chemin and cache:
        ecrire_cache(chemin, cache["lu"], maintenant, cache["corriges"])
    return perime

def fmt(v):
    return "v" + ".".join(map(str, v))

def main():
    args = sys.argv[1:]
    hook = args[:2] == ["--hook", "pre"]
    ci = args == ["--ci"]
    if hook:
        data = json.load(sys.stdin)
        cmd = (data.get("tool_input") or {}).get("command")
        if not isinstance(cmd, str) or not MOTS.search(cmd):
            sys.exit(0)
    v = version_node()
    if v is None:
        if hook:
            sys.exit(0)
        print("verifie-runtime : node introuvable ou illisible", file=sys.stderr)
        sys.exit(2)
    corriges, perime = obtenir(ci)
    if not corriges:
        if hook:
            msg = "⚠ verifie-runtime : contrôle du runtime Node impossible (index injoignable)"
            print(json.dumps({"systemMessage": msg, "hookSpecificOutput": {
                "hookEventName": "PreToolUse", "additionalContext": msg}}, ensure_ascii=False))
            sys.exit(0)
        print("verifie-runtime : index Node injoignable", file=sys.stderr)
        sys.exit(2)
    suffixe = f" (index du {perime}, nodejs.org injoignable)" if perime else ""
    m = v[0]
    if m in corriges and v < corriges[m]:
        print(f"⛔ Node {fmt(v)} vulnérable : la branche {m} est corrigée en {fmt(corriges[m])} "
              f"(nodejs.org, champ security). Demande à l'utilisateur de mettre à jour "
              f"(`nvm install {m} && nvm alias default {m}`){suffixe}", file=sys.stderr)
        sys.exit(2)
    if not hook:
        fin = f"branche {m} corrigée en {fmt(corriges[m])}" if m in corriges else f"branche {m} sans version de sécurité"
        print(f"Node {fmt(v)} : à jour ({fin}){suffixe}")
    sys.exit(0)

if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0 if "--hook" in sys.argv else 2)
