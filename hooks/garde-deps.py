#!/usr/bin/env python3
"""Hook PreToolUse (Bash) : bloque l'ajout d'un paquet (cargo, npm/pnpm/yarn, pip/uv) dont la licence
n'est pas permissive, qui a une faille OSV, qui est déprécié/yanked ou dont la dernière version a plus de 2 ans.
Sortie 2 + message sur stderr = commande refusée ; avertissements en JSON sur stdout ; fail-open hors réseau."""
import json, os, re, shlex, sys, time, urllib.parse, urllib.request
from datetime import date, datetime, timezone

UA = "kit-perso-garde-deps (https://github.com/stanixia-dev/kit-perso)"
DELAI, BUDGET, AGE_MAX = 4, 20, 730
DEBUT = time.monotonic()

SAUTE = {
    "cargo": {"-F", "--features", "-p", "--package", "--rename", "--registry", "--manifest-path", "--target"},
    "npm": {"--registry", "--prefix", "-w", "--workspace", "--omit", "--include", "--tag", "--cache", "--userconfig",
            "--loglevel", "-C", "--dir", "--cwd", "-F", "--filter"},
    "pip": {"-r", "--requirement", "-e", "--editable", "-c", "--constraint", "-i", "--index-url",
            "--extra-index-url", "-f", "--find-links", "-t", "--target", "--prefix", "--group", "--optional",
            "--extra", "--index", "--default-index", "--package"},
}
OSV_ECO = {"crates": "crates.io", "npm": "npm", "pypi": "PyPI"}
OK = {"mit", "apache-2.0", "bsd-2-clause", "bsd-3-clause", "isc", "zlib", "0bsd", "unlicense", "cc0-1.0"}
CLASSIFIERS = {
    "MIT License": "MIT", "Apache Software License": "Apache-2.0", "BSD License": "BSD-3-Clause",
    "ISC License (ISCL)": "ISC", "zlib/libpng License": "Zlib", "The Unlicense (Unlicense)": "Unlicense",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
}
ALIAS = {"apache 2.0": "Apache-2.0", "apache license 2.0": "Apache-2.0", "apache-2": "Apache-2.0", "bsd": "BSD-3-Clause"}

class Illisible(Exception):
    """Commande qui semble ajouter un paquet mais ne peut pas être analysée : bloquée (pas de fail-open)."""

SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
AJOUT = re.compile(r"\b(cargo\s+add|(npm|pnpm|yarn)\s+(\S+\s+){0,4}?(install|i|add)|pip[\d.]*\s+install"
                   r"|uv\s+add|uv\s+pip\s+install|python[\d.]*\s+(\S+\s+)*?-m\s*pip\s+install)\b")
PROFONDEUR_MAX = 8
MOTS_CLES = {"{", "}", "!", "if", "then", "else", "elif", "do", "while", "until", "for", "case"}
OPT_VALEUR = {
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "nice": {"-n", "--adjustment"},
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "-R", "-T", "--user", "--group", "--host",
             "--prompt", "--role", "--type", "--chdir"},
    "xargs": {"-I", "-n", "-P", "-L", "-s", "-d", "-E", "-a", "-J", "--max-args", "--max-procs", "--max-lines",
              "--delimiter", "--arg-file", "--eof"},
    "exec": {"-a"},
    "command": set(), "time": set(), "nohup": set(),
}
HEREDOC = re.compile(r"<<(-?)[ \t]*(?:'([^'\n]*)'|\"([^\"\n]*)\"|\\?([A-Za-z_]\w*))")
RECEVEUR_SHELL = re.compile(r"(?<![\w.-])(bash|sh|zsh|dash|ksh|eval|source)(?![\w.-])")

def premier_heredoc(s, debut=0):
    """Match du premier `<<DELIM` (hors `<<<`) situé dans du code, pas dans une chaîne (sauf dans un $( … ))."""
    frames, i, n = [["c", 0]], 0, len(s)
    while i < n:
        c, k = s[i], frames[-1][0]
        if c == "\\":
            i += 2
            continue
        if c == "`":
            j = s.find("`", i + 1)
            i = n if j < 0 else j
        elif k == "d":
            if c == '"':
                frames.pop()
            elif s.startswith("$(", i):
                frames.append(["c", 0])
                i += 1
        elif c == "'":
            j = s.find("'", i + 1)
            i = n if j < 0 else j
        elif c == '"':
            frames.append(["d", 0])
        elif s.startswith("$(", i):
            frames.append(["c", 0])
            i += 1
        elif c == "(":
            frames[-1][1] += 1
        elif c == ")":
            if frames[-1][1]:
                frames[-1][1] -= 1
            elif len(frames) > 1:
                frames.pop()
        elif s.startswith("<<", i):
            if s.startswith("<<<", i):
                i += 3
                continue
            m = HEREDOC.match(s, i)
            if m and i >= debut:
                return m
            i += 2
            continue
        i += 1
    return None

def retire_heredocs(s):
    """(commande sans corps de heredoc, [(corps, reçu par un shell, délimiteur cité)]).
    Un heredoc sans ligne délimiteur est laissé tel quel (donc analysé)."""
    extras, debut = [], 0
    while True:
        m = premier_heredoc(s, debut)
        if not m:
            return s, extras
        delim = next(g for g in m.group(2, 3, 4) if g is not None)
        cite = m.group(4) is None or s[m.start(4) - 1] == "\\"
        nl = s.find("\n", m.end())
        corps = None
        pos = nl + 1
        while nl >= 0 and pos <= len(s):
            fin = s.find("\n", pos)
            fin = len(s) if fin < 0 else fin
            ligne = s[pos:fin]
            if (ligne.lstrip("\t") if m.group(1) else ligne) == delim:
                corps = s[nl + 1:pos]
                break
            pos = fin + 1
        if corps is None:
            debut = m.end()
            continue
        entete = s[s.rfind("\n", 0, m.start()) + 1:m.start()] + s[m.end():nl]
        extras.append((corps, bool(RECEVEUR_SHELL.search(entete)), cite))
        s = s[:m.start()] + s[m.end():nl] + s[fin:]
        debut = m.start()

def substitutions(s, apostrophes=True):
    """Corps des $( … ), <( … ), >( … ) et `…` hors apostrophes (ils s'exécutent aussi entre guillemets doubles)."""
    out, i, n, sq = [], 0, len(s), False
    while i < n:
        c = s[i]
        if sq:
            sq = c != "'"
        elif c == "\\":
            i += 1
        elif c == "'" and apostrophes:
            sq = True
        elif c == "`":
            j = i + 1
            while j < n and s[j] != "`":
                j += 2 if s[j] == "\\" else 1
            if j >= n:
                raise Illisible("substitution `…` non fermée")
            out.append(s[i + 1:j])
            i = j
        elif s.startswith(("$(", "<(", ">("), i):
            j, prof = i + 2, 1
            while j < n and prof:
                prof += (s[j] == "(") - (s[j] == ")")
                j += 1
            if prof:
                raise Illisible("substitution $( … ) non fermée")
            out.append(s[i + 2:j - 1])
            i = j - 1
        i += 1
    return out

def jetons(cmd):
    lex = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    return list(lex)

def separateur(t):
    return bool(t) and all(c in ";&|()" for c in t)

def redirection(t):
    return bool(t) and all(c in "<>&|;()" for c in t) and ("<" in t or ">" in t)

def decoupe(toks):
    seg = []
    i = 0
    while i < len(toks):
        t = toks[i]
        if redirection(t):
            if seg and seg[-1].isdigit():
                seg.pop()
            i += 2
            continue
        if separateur(t):
            if seg:
                yield seg
            seg = []
        else:
            seg.append(t)
        i += 1
    if seg:
        yield seg

def saute_options(toks, valeur):
    """Retire toks[0] et ses options (`valeur` : celles qui prennent un argument séparé)."""
    i = 1
    while i < len(toks) and toks[i].startswith("-") and len(toks[i]) > 1:
        if toks[i] == "--":
            i += 1
            break
        i += 2 if toks[i] in valeur else 1
    return toks[i:]

def sans_prefixe(toks):
    """Saute mots-clés shell, affectations VAR=val, env (et ses options, dont -S) et préfixes courants."""
    while toks:
        t = toks[0]
        base = t.rsplit("/", 1)[-1]
        if t in MOTS_CLES:
            toks = toks[1:]
        elif base == "env":
            toks = toks[1:]
            while toks and (toks[0].startswith("-") or re.match(r"^\w+=", toks[0])):
                o = toks[0]
                if o in ("-S", "--split-string") and len(toks) > 1:
                    script, toks = toks[1], toks[2:]
                elif o.startswith("--split-string=") or (o.startswith("-S") and len(o) > 2):
                    script, toks = o.split("=", 1)[1] if o.startswith("--") else o[2:], toks[1:]
                else:
                    toks = toks[2:] if o in ("-u", "-C", "--unset", "--chdir") else toks[1:]
                    continue
                try:
                    toks = shlex.split(script) + toks
                except ValueError as e:
                    raise Illisible(f"env -S illisible ({e})")
                break
        elif base in OPT_VALEUR:
            toks = saute_options(toks, OPT_VALEUR[base])
            if base == "timeout":
                toks = toks[1:]
        elif re.match(r"^\w+=", t) or base == "rtk" or (t in ("bypass", "proxy") and len(toks) > 1):
            toks = toks[1:]
        else:
            break
    return toks

def appel_shell(toks):
    """('c', script) pour `sh -c` / `bash -lc` / `eval`, ('stdin', None) si un shell lit son script sur stdin, sinon None."""
    base = toks[0].rsplit("/", 1)[-1]
    if base == "eval":
        return ("c", " ".join(toks[1:])) if len(toks) > 1 else None
    if base not in SHELLS:
        return None
    i, stdin = 1, False
    while i < len(toks) and toks[i][:1] in "-+" and len(toks[i]) > 1:
        t = toks[i]
        if not t.startswith("--") and "c" in t[1:]:
            j = i + 1
            if j < len(toks) and toks[j] == "--":
                j += 1
            return ("c", toks[j]) if j < len(toks) else None
        if not t.startswith("--") and "s" in t[1:]:
            stdin = True
        i += 2 if t in ("-o", "+o") else 1
    if stdin or i >= len(toks) or toks[i] == "-":
        return ("stdin", None)
    return None

def analyse(cmd, prof=0):
    """[(registre, nom, version)] ajoutés par cmd, y compris dans les -c, sous-shells et substitutions."""
    if prof > PROFONDEUR_MAX:
        if AJOUT.search(cmd):
            raise Illisible("imbrication trop profonde")
        return []
    out = []
    cmd, heredocs = retire_heredocs(cmd)
    try:
        corps = substitutions(cmd)
        for texte, shell, cite in heredocs:
            if shell:
                corps.append(texte)
            elif not cite:
                corps += substitutions(texte, apostrophes=False)
        segs = list(decoupe(jetons(cmd)))
    except (ValueError, Illisible) as e:
        if AJOUT.search(cmd):
            raise Illisible(f"commande non analysable ({e}) qui semble ajouter un paquet")
        return []
    for c in corps:
        out += analyse(c, prof + 1)
    for toks in segs:
        try:
            toks = sans_prefixe(toks)
        except Illisible:
            if AJOUT.search(cmd):
                raise
            continue
        if not toks:
            continue
        out += paquets(toks)
        sh = appel_shell(toks)
        if sh and sh[0] == "c":
            out += analyse(sh[1], prof + 1)
        elif sh and AJOUT.search(cmd):
            raise Illisible("script passé à un shell par stdin, non analysable, dans une commande qui semble ajouter un paquet")
    return out

# ---------- extraction des paquets ----------

def non_paquet(t):
    return (t.startswith((".", "/", "~", "file:", "git+", "github:")) or "://" in t
            or t.endswith((".tgz", ".whl", ".tar.gz", ".zip")))

def arguments(args, skip):
    """Jetons positionnels (options sautées, avec leur valeur pour celles qui en prennent une)."""
    i, out = 0, []
    while i < len(args):
        a = args[i]
        if a.startswith("-"):
            i += 2 if a in skip else 1
            continue
        out.append(a)
        i += 1
    return out

def exacte(spec, motif):
    spec = (spec or "").removeprefix("=")
    return spec if re.match(motif, spec) else None

SEMVER = r"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$"

def module_python(toks):
    """[module, args…] de `python -m module args` ou `python -mmodule args` (options avant -m sautées), sinon None."""
    for i, t in enumerate(toks[1:], 1):
        if t == "-m":
            return toks[i + 1:]
        if t.startswith("-m"):
            return [t[2:]] + toks[i + 1:]
        if not t.startswith("-"):
            return None
    return None

def paquets(toks):
    """[(registre, nom, version exacte ou None)] ajoutés par la commande."""
    base = toks[0].rsplit("/", 1)[-1]
    sc = toks[1] if len(toks) > 1 else ""
    if base in ("npm", "pnpm", "yarn"):  # options globales avant la sous-commande
        toks = [toks[0]] + saute_options(toks, SAUTE["npm"])
        sc = toks[1] if len(toks) > 1 else ""
    res = []
    if base == "cargo" and sc == "add":
        if any(a in ("--git", "--path") or a.startswith(("--git=", "--path=")) for a in toks):
            return []
        for t in arguments(toks[2:], SAUTE["cargo"]):
            if non_paquet(t):
                continue
            nom, _, spec = t.partition("@")
            res.append(("crates", nom, exacte(spec, SEMVER)))
    elif (base == "npm" and sc in ("install", "i", "add")) or (base in ("pnpm", "yarn") and sc == "add"):
        for t in arguments(toks[2:], SAUTE["npm"]):
            if non_paquet(t) or ("/" in t and not t.startswith("@")):
                continue
            m = re.match(r"^(@[^/@]+/[^@]+|[^@/]+)(?:@(.*))?$", t)
            if m:
                res.append(("npm", m.group(1), exacte(m.group(2), SEMVER)))
    else:
        if re.fullmatch(r"pip[\d.]*", base) and sc == "install":
            args = toks[2:]
        elif re.fullmatch(r"python[\d.]*", base) and (mod := module_python(toks)) and mod[:2] == ["pip", "install"]:
            args = mod[2:]
        elif base == "uv" and toks[1:3] == ["pip", "install"]:
            args = toks[3:]
        elif base == "uv" and sc == "add":
            args = toks[2:]
        else:
            return []
        for t in arguments(args, SAUTE["pip"]):
            if non_paquet(t):
                continue
            m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?\s*(?:(===|==|~=|!=|<=|>=|<|>)\s*([^,;\s]*))?", t)
            if m:
                v = m.group(3) if m.group(2) in ("==", "===") and m.group(3) and "*" not in m.group(3) else None
                res.append(("pypi", re.sub(r"[._]+", "-", m.group(1)).lower(), v))
    return res

def tous_paquets(cmd):
    return list(dict.fromkeys(analyse(cmd)))

# ---------- réseau ----------

def recupere(cle, url, corps=None):
    """Réponse JSON, ou None si injoignable (HTTP, délai, JSON, fixture absente, budget épuisé)."""
    try:
        fix = os.environ.get("GARDE_DEPS_FIXTURES")
        if fix:
            with open(fix, encoding="utf-8") as f:
                return json.load(f).get(cle)
        reste = BUDGET - (time.monotonic() - DEBUT)
        if reste <= 0:
            return None
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
        if corps is not None:
            req.data = json.dumps(corps).encode()
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=min(DELAI, reste)) as r:
            return json.load(r)
    except Exception:
        return None

def cle(registre, nom, prefixe=""):
    return f"{prefixe}{registre}-{nom.replace('/', '__')}"

# ---------- registres : normalisés en {latest, versions{v: {licence, deprecie, yanked}}, date} ----------

def licence_npm(v):
    l = v.get("license")
    if isinstance(l, dict):
        l = l.get("type")
    if not l and isinstance(v.get("licenses"), list) and v["licenses"]:
        l = (v["licenses"][0] or {}).get("type")
    return l if isinstance(l, str) else None

def charge(registre, nom):
    d = recupere(cle(registre, nom), {
        "crates": f"https://crates.io/api/v1/crates/{nom}",
        "npm": "https://registry.npmjs.org/" + urllib.parse.quote(nom, safe="@"),
        "pypi": f"https://pypi.org/pypi/{nom}/json",
    }[registre])
    if not isinstance(d, dict):
        return None
    if registre == "crates":
        c = d["crate"]
        vs = {v["num"]: {"licence": v.get("license"), "deprecie": False, "yanked": bool(v.get("yanked"))}
              for v in d["versions"]}
        dates = [v["created_at"] for v in d["versions"] if v.get("created_at")]
        return {"latest": c.get("max_stable_version") or c.get("newest_version"), "versions": vs,
                "date": max(dates, default=None)}
    if registre == "npm":
        vs = {k: {"licence": licence_npm(v), "deprecie": bool(v.get("deprecated")), "yanked": False}
              for k, v in d["versions"].items()}
        dates = [t for k, t in d.get("time", {}).items() if k not in ("created", "modified")]
        return {"latest": d["dist-tags"]["latest"], "versions": vs, "date": max(dates, default=None)}
    info = d["info"]
    cl = info.get("classifiers") or []
    lic = info.get("license_expression")
    if not lic:
        noms = [CLASSIFIERS.get(c[len("License :: OSI Approved :: "):] if c.startswith("License :: OSI Approved :: ")
                                else c[len("License :: "):], "?")
                if "Lesser General Public License" not in c else "LGPL-3.0"
                for c in cl if c.startswith("License :: ")]
        lic = " OR ".join(noms) if noms else None
    if not lic and info.get("license") and len(info["license"]) <= 40:
        lic = ALIAS.get(info["license"].strip().lower(), info["license"].strip())
    inactif = "Development Status :: 7 - Inactive" in cl
    rel = d.get("releases", {})
    vs = {k: {"licence": lic, "deprecie": inactif, "yanked": bool(f) and all(x.get("yanked") for x in f)}
          for k, f in rel.items()}
    dates = [x["upload_time_iso_8601"] for f in rel.values() for x in f if x.get("upload_time_iso_8601")]
    return {"latest": info["version"], "versions": vs, "date": max(dates, default=None)}

# ---------- licences ----------

def niveau_id(i):
    i = i.lower().removesuffix("+")
    if i in OK:
        return 0
    if i == "mpl-2.0" or i.startswith("lgpl-"):
        return 1
    return 2

def niveau(expr):
    """0 permissive, 1 avertit, 2 bloque. OR = min, AND = max ; expression illisible ou absente = 2."""
    if not expr:
        return 2
    toks = re.findall(r"\(|\)|[^\s()]+", expr.replace("/", " OR "))
    pos = 0

    def expression():
        nonlocal pos
        n = [terme()]
        while pos < len(toks) and toks[pos].upper() == "OR":
            pos += 1
            n.append(terme())
        return min(n)

    def terme():
        nonlocal pos
        n = [atome()]
        while pos < len(toks) and toks[pos].upper() == "AND":
            pos += 1
            n.append(atome())
        return max(n)

    def atome():
        nonlocal pos
        if pos >= len(toks):
            raise ValueError
        t = toks[pos]
        pos += 1
        if t == "(":
            n = expression()
            if pos >= len(toks) or toks[pos] != ")":
                raise ValueError
            pos += 1
            return n
        if t == ")" or t.upper() in ("AND", "OR", "WITH"):
            raise ValueError
        if pos < len(toks) and toks[pos].upper() == "WITH":
            pos += 2
        return niveau_id(t)

    try:
        n = expression()
        return n if pos == len(toks) else 2
    except ValueError:
        return 2

# ---------- examen ----------

def aujourdhui():
    e = os.environ.get("GARDE_DEPS_AUJOURDHUI")
    return date.fromisoformat(e) if e else datetime.now(timezone.utc).date()

def examine(registre, nom, exact, blocs, avert):
    etiq = f"{registre} {nom}"
    d = charge(registre, nom)
    if d is None:
        avert.append(f"{etiq} : vérification impossible")
        return
    v = exact or d["latest"]
    etiq = f"{etiq}@{v}"
    info = d["versions"].get(v)
    if info is None:
        blocs.append(f"{etiq} : version inconnue du registre")
        return
    n = niveau(info["licence"])
    if n == 2:
        blocs.append(f"{etiq} : licence non permissive ({info['licence'] or 'absente'})")
    elif n == 1:
        avert.append(f"{etiq} : licence {info['licence']} (copyleft faible)")
    if info["deprecie"]:
        blocs.append(f"{etiq} : paquet déprécié")
    if info["yanked"]:
        blocs.append(f"{etiq} : version retirée (yanked)")
    if d["date"]:
        try:
            if (aujourdhui() - date.fromisoformat(d["date"][:10])).days > AGE_MAX:
                blocs.append(f"{etiq} : dernière publication le {d['date'][:10]} (plus de 2 ans)")
        except ValueError:
            pass
    o = recupere(cle(registre, nom, "osv-"), "https://api.osv.dev/v1/query",
                 {"package": {"name": nom, "ecosystem": OSV_ECO[registre]}, "version": v})
    if o is None:
        avert.append(f"{etiq} : vérification impossible (OSV)")
        return
    vulns = o.get("vulns") or []
    graves = [x.get("id", "?") for x in vulns if not (x.get("database_specific") or {}).get("informational")]
    infos = [x.get("id", "?") for x in vulns if (x.get("database_specific") or {}).get("informational")]
    if graves:
        blocs.append(f"{etiq} : faille connue ({', '.join(graves[:3])})")
    if infos:
        avert.append(f"{etiq} : avis informatif ({', '.join(infos[:3])})")

def main():
    data = json.load(sys.stdin)
    cmd = (data.get("tool_input") or {}).get("command", "")
    try:
        pqs = tous_paquets(cmd)
    except Illisible as e:
        print(f"⛔ Bloqué par garde-deps : {e}.\nReformule la commande plus simplement (une commande par appel, "
              "sans imbrication) ou demande à l'utilisateur d'ajouter lui-même le paquet.", file=sys.stderr)
        sys.exit(2)
    if not pqs:
        sys.exit(0)
    blocs, avert = [], []
    for registre, nom, exact in pqs:
        examine(registre, nom, exact, blocs, avert)
    if blocs:
        print("⛔ Bloqué par garde-deps :", file=sys.stderr)
        for b in blocs:
            print(f"- {b}", file=sys.stderr)
        print("Propose une alternative, ou demande à l'utilisateur d'ajouter lui-même ce paquet s'il l'accepte.",
              file=sys.stderr)
        sys.exit(2)
    if avert:
        msg = "⚠ garde-deps : " + " ; ".join(avert)
        print(json.dumps({"systemMessage": msg, "hookSpecificOutput": {
            "hookEventName": "PreToolUse", "additionalContext": msg}}, ensure_ascii=False))
    sys.exit(0)

if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(0)
