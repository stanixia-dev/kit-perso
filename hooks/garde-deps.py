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
    "npm": {"--registry", "--prefix", "-w", "--workspace", "--omit", "--tag"},
    "pip": {"-r", "--requirement", "-e", "--editable", "-c", "--constraint", "-i", "--index-url",
            "--extra-index-url", "-f", "--find-links", "-t", "--target", "--prefix", "--group", "--optional",
            "--extra", "--index", "--default-index", "--package"},
}
OSV_ECO = {"crates": "crates.io", "npm": "npm", "pypi": "PyPI"}
OK = {"mit", "apache-2.0", "bsd-2-clause", "bsd-3-clause", "isc", "zlib", "0bsd", "unlicense"}
CLASSIFIERS = {
    "MIT License": "MIT", "Apache Software License": "Apache-2.0", "BSD License": "BSD-3-Clause",
    "ISC License (ISCL)": "ISC", "zlib/libpng License": "Zlib", "The Unlicense (Unlicense)": "Unlicense",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
}
ALIAS = {"apache 2.0": "Apache-2.0", "apache license 2.0": "Apache-2.0", "apache-2": "Apache-2.0", "bsd": "BSD-3-Clause"}

def segments(cmd):
    # Découpe sur ; && || | et retours ligne (approximatif mais suffisant)
    for seg in re.split(r"\|\||&&|[;|\n]", cmd):
        try:
            toks = shlex.split(seg)
        except ValueError:
            toks = seg.split()
        # saute les affectations VAR=val et les préfixes courants
        while toks and (re.match(r"^\w+=", toks[0]) or toks[0] in ("env", "command", "exec", "time", "nohup")
                        or toks[0].rsplit("/", 1)[-1] == "rtk" or (toks[0] in ("bypass", "proxy") and len(toks) > 1)):
            toks = toks[1:]
        if toks:
            yield toks

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

def paquets(toks):
    """[(registre, nom, version exacte ou None)] ajoutés par la commande."""
    base = toks[0].rsplit("/", 1)[-1]
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
        if base in ("pip", "pip3") and sc == "install":
            args = toks[2:]
        elif base in ("python", "python3") and toks[1:4] == ["-m", "pip", "install"]:
            args = toks[4:]
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
    out = []
    for toks in segments(cmd):
        out += paquets(toks)
        if toks[0].rsplit("/", 1)[-1] in ("bash", "sh", "zsh") and "-c" in toks:
            k = toks.index("-c")
            if k + 1 < len(toks):
                out += tous_paquets(toks[k + 1])
    return out

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
    pqs = tous_paquets(cmd)
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
