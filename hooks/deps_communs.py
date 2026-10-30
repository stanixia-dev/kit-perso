"""Code commun de garde-deps (hook Bash) et de verifie-manifestes (contrôle par résultat) :
accès aux registres et à OSV, règles de licence, examen d'un paquet."""
import json, os, re, time, urllib.parse, urllib.request
from datetime import date, datetime, timezone

UA = "kit-perso-garde-deps (https://github.com/stanixia-dev/kit-perso)"
DELAI, BUDGET, AGE_MAX = 4, 20, 730
DEBUT = time.monotonic()

OSV_ECO = {"crates": "crates.io", "npm": "npm", "pypi": "PyPI"}
OK = {"mit", "apache-2.0", "bsd-2-clause", "bsd-3-clause", "isc", "zlib", "0bsd", "unlicense", "cc0-1.0"}
CLASSIFIERS = {
    "MIT License": "MIT", "Apache Software License": "Apache-2.0", "BSD License": "BSD-3-Clause",
    "ISC License (ISCL)": "ISC", "zlib/libpng License": "Zlib", "The Unlicense (Unlicense)": "Unlicense",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
}
ALIAS = {"apache 2.0": "Apache-2.0", "apache license 2.0": "Apache-2.0", "apache-2": "Apache-2.0", "bsd": "BSD-3-Clause"}

def non_paquet(t):
    return (t.startswith((".", "/", "~", "file:", "git+", "github:")) or "://" in t
            or t.endswith((".tgz", ".whl", ".tar.gz", ".zip")))

def exacte(spec, motif):
    spec = (spec or "").removeprefix("=")
    return spec if re.match(motif, spec) else None

SEMVER = r"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$"

def pep508(t):
    """(nom normalisé, version exacte ou None) d'une ligne PEP 508, ou None si illisible."""
    m = re.match(r"^([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?\s*(?:(===|==|~=|!=|<=|>=|<|>)\s*([^,;\s]*))?", t)
    if not m:
        return None
    v = m.group(3) if m.group(2) in ("==", "===") and m.group(3) and "*" not in m.group(3) else None
    return re.sub(r"[._]+", "-", m.group(1)).lower(), v

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

def norme(registre, nom):
    """Nom de paquet normalisé pour comparer manifestes, lockfiles et exceptions."""
    if registre == "pypi":
        return re.sub(r"[._]+", "-", nom).lower()
    return nom.lower().replace("_", "-") if registre == "crates" else nom

def lit_exceptions(texte):
    """([(registre, nom, version|*, date, raison)], avertissements) d'un `.garde-deps-exceptions`."""
    res, avert = [], []
    for n, ligne in enumerate(texte.splitlines(), 1):
        ligne = ligne.strip()
        if not ligne or ligne.startswith("#"):
            continue
        p = ligne.split(None, 4)
        try:
            if len(p) < 5 or p[0] not in OSV_ECO or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", p[3]):
                raise ValueError
            date.fromisoformat(p[3])
        except ValueError:
            avert.append(f".garde-deps-exceptions ligne {n} invalide (attendu : registre nom version|* AAAA-MM-JJ raison)")
            continue
        res.append(tuple(p))
    return res, avert

def exception_pour(exceptions, registre, nom, version):
    for e in exceptions or ():
        if e[0] == registre and norme(registre, e[1]) == norme(registre, nom) and e[2] in ("*", version):
            return e
    return None

def examine_brut(registre, nom, exact, blocs, avert, strict=False):
    imprevu = blocs if strict else avert
    etiq = f"{registre} {nom}"
    d = charge(registre, nom)
    if d is None:
        imprevu.append(f"{etiq} : vérification impossible")
        return exact
    v = exact or d["latest"]
    etiq = f"{etiq}@{v}"
    info = d["versions"].get(v)
    if info is None:
        blocs.append(f"{etiq} : version inconnue du registre")
        return v
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
        imprevu.append(f"{etiq} : vérification impossible (OSV)")
        return v
    vulns = o.get("vulns") or []
    graves = [x.get("id", "?") for x in vulns if not (x.get("database_specific") or {}).get("informational")]
    infos = [x.get("id", "?") for x in vulns if (x.get("database_specific") or {}).get("informational")]
    if graves:
        blocs.append(f"{etiq} : faille connue ({', '.join(graves[:3])})")
    if infos:
        avert.append(f"{etiq} : avis informatif ({', '.join(infos[:3])})")
    return v

def examine(registre, nom, exact, blocs, avert, strict=False, exceptions=None):
    """Ajoute à `blocs` / `avert` les raisons de refuser / signaler registre nom@exact (dernière version si None).
    strict : « vérification impossible » devient un blocage. Un paquet couvert par `exceptions` voit ses
    blocages passer en avertissements."""
    b = []
    v = examine_brut(registre, nom, exact, b, avert, strict)
    exc = exception_pour(exceptions, registre, nom, v or exact)
    if exc:
        avert += [f"{m} (exception du {exc[3]} : {exc[4]})" for m in b]
    else:
        blocs += b

def osv_lot(items):
    """[(registre, nom, version)] -> liste alignée d'identifiants de failles (listes), ou None si OSV est injoignable.
    Un seul POST querybatch ; en fixtures, clés `osv-<registre>-<nom>` (clé absente = aucune faille)."""
    if not items:
        return []
    fix = os.environ.get("GARDE_DEPS_FIXTURES")
    if fix:
        try:
            with open(fix, encoding="utf-8") as f:
                d = json.load(f)
        except Exception:
            return None
        return [[x.get("id", "?") for x in (d.get(cle(r, n, "osv-")) or {}).get("vulns") or []] for r, n, _ in items]
    o = recupere("osv-lot", "https://api.osv.dev/v1/querybatch", {"queries": [
        {"package": {"name": n, "ecosystem": OSV_ECO[r]}, "version": v} for r, n, v in items]})
    res = o.get("results") if isinstance(o, dict) else None
    if not isinstance(res, list) or len(res) != len(items):
        return None
    return [[x.get("id", "?") for x in (e or {}).get("vulns") or []] for e in res]
