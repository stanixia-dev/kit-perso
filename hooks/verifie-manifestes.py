#!/usr/bin/env python3
"""Contrôle par résultat des dépendances : compare les manifestes et lockfiles (cargo, npm/pnpm/yarn, pip/uv/poetry)
entre une base et une cible, et applique les règles de garde-deps aux paquets ajoutés ou modifiés.
Modes : CLI (défaut), hook PostToolUse (--hook post), hook Stop (--hook stop), CI (--ci, strict).
Sortie 2 + message sur stderr = paquet non conforme ; avertissements sur stdout ; fail-open en hook."""
import argparse, fnmatch, hashlib, json, os, posixpath, re, subprocess, sys, tomllib
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deps_communs as dc
from deps_communs import SEMVER, examine, exacte, exception_pour, lit_exceptions, non_paquet, norme, osv_lot, pep508

MANIFESTES = {"Cargo.toml": "crates", "package.json": "npm", "pyproject.toml": "pypi"}
LOCKFILES = {"Cargo.lock": "crates", "package-lock.json": "npm", "pnpm-lock.yaml": "npm", "yarn.lock": "npm",
             "uv.lock": "pypi", "poetry.lock": "pypi"}
IGNORES = {"node_modules", "target", ".venv", "vendor"}
VIDE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"  # arbre vide
MAX_TRANSITIFS = 1000

def ecosysteme(chemin):
    """Registre d'un manifeste ou lockfile (par son nom), sinon None."""
    nom = chemin.rsplit("/", 1)[-1]
    if nom in MANIFESTES:
        return MANIFESTES[nom]
    if nom in LOCKFILES:
        return LOCKFILES[nom]
    if fnmatch.fnmatch(nom, "requirements*.txt") or (nom.endswith(".txt") and "requirements" in chemin.split("/")[:-1]):
        return "pypi"
    return None

def est_lock(chemin):
    return chemin.rsplit("/", 1)[-1] in LOCKFILES

def suivi(chemin):
    return ecosysteme(chemin) is not None and not IGNORES & set(chemin.split("/")[:-1])

# ---------- git ----------

def git(racine, *args):
    """Sortie de git (texte) ou None en cas d'échec."""
    try:
        r = subprocess.run(["git", "-C", racine, *args], capture_output=True, check=False)
    except OSError:
        return None
    return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None

def base_par_defaut(racine):
    for ref in ("origin/main", "main", "master"):
        mb = git(racine, "merge-base", "HEAD", ref)
        if mb and mb.strip():
            return mb.strip()
    if git(racine, "rev-parse", "--verify", "-q", "HEAD") is not None:
        return "HEAD"
    return VIDE

def lire(racine, ref, chemin):
    """Contenu d'un fichier à `ref` (None = arbre de travail) ; absent = chaîne vide."""
    if ref is None:
        try:
            with open(os.path.join(racine, chemin), encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return ""
    return git(racine, "show", f"{ref}:{chemin}") or ""

def fichiers(racine, ref):
    if ref is None:
        out = git(racine, "ls-files", "-z", "-c", "-o", "--exclude-standard")
    else:
        out = git(racine, "ls-tree", "-r", "-z", "--name-only", ref)
    return sorted({p for p in (out or "").split("\0") if p and suivi(p)})

# ---------- extraction : manifestes ----------

def finalise(d):
    return {k: tuple(sorted(v)) for k, v in d.items()}

def hors_depot(dossier, rel):
    """Vrai si le chemin `rel` (relatif au dossier du manifeste, dans le dépôt) sort du dépôt."""
    rel = rel.removeprefix("file:").removeprefix("link:")
    if os.path.isabs(rel) or rel.startswith("~"):
        return True
    return posixpath.normpath(posixpath.join(dossier, rel)).startswith("..")

def cargo_manifeste(texte, dossier="", hors=None):
    d, out = tomllib.loads(texte), defaultdict(set)
    sources = [d] + [v for v in (d.get("target") or {}).values() if isinstance(v, dict)]
    tables = [s.get(k) for s in sources for k in ("dependencies", "dev-dependencies", "build-dependencies")]
    tables.append((d.get("workspace") or {}).get("dependencies"))
    for t in tables:
        for nom, v in (t if isinstance(t, dict) else {}).items():
            if isinstance(v, dict):
                nom_reel = v.get("package", nom)
                if v.get("git"):
                    if hors is not None:
                        hors[("crates", nom_reel, f"git = {v['git']}")] = None
                    continue
                if v.get("path"):
                    if hors is not None and hors_depot(dossier, str(v["path"])):
                        hors[("crates", nom_reel, f"path = {v['path']}")] = None
                    continue
                if v.get("workspace"):
                    continue
                nom, v = nom_reel, v.get("version", "*")
            if isinstance(v, str):
                out[("crates", nom)].add(v)
    return finalise(out)

NPM_URL = ("github:", "gitlab:", "bitbucket:", "gist:", "git+", "git:", "git@", "http:", "https:", "ssh:")

def npm_manifeste(texte, dossier="", hors=None):
    d, out = json.loads(texte), defaultdict(set)
    for k in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
        for nom, v in (d.get(k) if isinstance(d.get(k), dict) else {}).items():
            if not isinstance(v, str):
                continue
            if v.startswith("npm:"):
                reel, i = v[4:], v.rfind("@")
                nom, v = (v[4:i], v[i + 1:]) if i > 4 else (reel, "*")
            elif v.startswith(("file:", "link:", "portal:")):
                if hors is not None and hors_depot(dossier, v.split(":", 1)[1]):
                    hors[("npm", nom, v)] = None
                continue
            elif v.startswith("workspace:"):
                continue
            elif v.startswith(NPM_URL) or "://" in v or re.fullmatch(r"[\w.-]+/[\w.-]+(#.*)?", v):
                if hors is not None:
                    hors[("npm", nom, v)] = None
                continue
            elif ":" in v or "/" in v:
                continue
            out[("npm", nom)].add(v)
    return finalise(out)

def ligne_pep508(t, out, hors, dossier=""):
    """Une exigence PEP 508 : paquet de registre (dans `out`) ou dépendance hors registre (dans `hors`)."""
    t = t.strip()
    if re.search(r"(^|\s)@\s*\S", t) or "://" in t or t.startswith("git+"):
        egg = re.search(r"[#&]egg=([A-Za-z0-9._-]+)", t)
        r = (re.sub(r"[._]+", "-", egg.group(1)).lower(),) if egg else pep508(t) if not t.startswith("git+") else None
        if hors is not None:
            nom = r[0] if r else re.sub(r"\.git$", "", re.split(r"[/#?@]", t.split("://", 1)[-1].rstrip("/"))[0] or t)
            hors[("pypi", nom, re.sub(r"\s+", " ", t))] = None
        return
    r = pep508(t)
    if r and not non_paquet(t):
        out[("pypi", r[0])].add(re.sub(r"\s+", " ", t))

def pyproject_manifeste(texte, dossier="", hors=None):
    d, out = tomllib.loads(texte), defaultdict(set)

    def ligne(t):
        if isinstance(t, str):
            ligne_pep508(t, out, hors, dossier)

    p = d.get("project") or {}
    for t in p.get("dependencies") or []:
        ligne(t)
    for liste in (p.get("optional-dependencies") or {}).values():
        for t in liste if isinstance(liste, list) else []:
            ligne(t)
    for liste in (d.get("dependency-groups") or {}).values():
        for t in liste if isinstance(liste, list) else []:
            ligne(t)
    outil = d.get("tool") or {}
    for nom, srcs in ((outil.get("uv") or {}).get("sources") or {}).items():
        for src in srcs if isinstance(srcs, list) else [srcs]:
            if isinstance(src, dict) and hors is not None:
                if src.get("git") or src.get("url") or (src.get("path") and hors_depot(dossier, str(src["path"]))):
                    hors[("pypi", re.sub(r"[._]+", "-", nom).lower(),
                          "uv source " + str(src.get("git") or src.get("url") or src.get("path")))] = None
    poetry = outil.get("poetry") or {}
    tables = [poetry.get("dependencies"), poetry.get("dev-dependencies")]
    tables += [g.get("dependencies") for g in (poetry.get("group") or {}).values() if isinstance(g, dict)]
    for t in tables:
        for nom, v in (t if isinstance(t, dict) else {}).items():
            if nom.lower() == "python":
                continue
            nom = re.sub(r"[._]+", "-", nom).lower()
            for v in v if isinstance(v, list) else [v]:
                if isinstance(v, dict):
                    if v.get("git") or v.get("url") or (v.get("path") and hors_depot(dossier, str(v["path"]))):
                        if hors is not None:
                            hors[("pypi", nom, "poetry " + str(v.get("git") or v.get("url") or v.get("path")))] = None
                    if v.get("git") or v.get("url") or v.get("path"):
                        continue
                    v = v.get("version", "*")
                if isinstance(v, str):
                    out[("pypi", nom)].add(f"{nom}=={v}" if re.fullmatch(r"\d[\w.+-]*", v) else f"{nom} {v}")
    return finalise(out)

INCLUS = re.compile(r"^(?:-r|-c|--requirement|--constraint)(?:\s+|=)(\S+)")

def requirements(texte, dossier="", hors=None, lecteur=None, chemin="", vus=None, out=None):
    """Exigences d'un requirements*.txt, y compris celles des fichiers inclus par -r / -c (sans boucle)."""
    racine = out is None
    out = defaultdict(set) if racine else out
    vus = {chemin} if vus is None else vus
    for l in texte.splitlines():
        l = re.split(r"(?:^|\s)#", l, 1)[0].strip()
        m = INCLUS.match(l)
        if m:
            if lecteur is not None:
                ref = posixpath.normpath(posixpath.join(dossier, m.group(1)))
                if not ref.startswith("..") and not posixpath.isabs(ref) and "://" not in ref and ref not in vus:
                    vus.add(ref)
                    requirements(lecteur(ref), posixpath.dirname(ref), hors, lecteur, ref, vus, out)
            continue
        l = re.sub(r"^(?:-e|--editable)(?:\s+|=)", "", l)
        if not l or l.startswith("-"):
            continue
        if l.startswith((".", "/", "~")) and not l.endswith((".whl", ".tar.gz", ".zip", ".tgz")) or \
                l.endswith((".whl", ".tar.gz", ".zip", ".tgz")) and "://" not in l:
            if hors is not None and hors_depot(dossier, l):
                hors[("pypi", posixpath.basename(l.rstrip("/")) or l, l)] = None
            continue
        ligne_pep508(l, out, hors, dossier)
    return finalise(out) if racine else out

def manifeste(chemin, texte, hors=None, lecteur=None):
    """{(registre, nom): (spec, …)} des dépendances d'un manifeste ; ValueError si illisible.
    `hors` (dict) reçoit les dépendances hors registre ; `lecteur(chemin)` lit les fichiers inclus par -r / -c."""
    nom, dossier = chemin.rsplit("/", 1)[-1], posixpath.dirname(chemin)
    try:
        if nom == "Cargo.toml":
            return cargo_manifeste(texte, dossier, hors)
        if nom == "package.json":
            return npm_manifeste(texte, dossier, hors)
        if nom == "pyproject.toml":
            return pyproject_manifeste(texte, dossier, hors)
        return requirements(texte, dossier, hors, lecteur, chemin)
    except (ValueError, TypeError, AttributeError) as e:  # tomllib.TOMLDecodeError et json.JSONDecodeError sont des ValueError
        raise ValueError(str(e))

def version_exacte(registre, spec):
    if registre == "pypi":
        r = pep508(spec)
        return r[1] if r else None
    return exacte(spec, SEMVER)

# ---------- extraction : lockfiles ----------

def lock_toml(nom_fichier, texte):
    """Cargo.lock, uv.lock, poetry.lock : paquets venant d'un registre (sources git, chemin, url ignorées)."""
    registre, out = LOCKFILES[nom_fichier], set()
    for p in tomllib.loads(texte).get("package") or []:
        nom, v, src = p.get("name"), p.get("version"), p.get("source")
        if not nom or not v:
            continue
        if nom_fichier == "Cargo.lock":
            ok = isinstance(src, str) and src.startswith(("registry+", "sparse+"))
        elif nom_fichier == "uv.lock":
            ok = isinstance(src, dict) and "registry" in src
        else:
            ok = not isinstance(src, dict) or src.get("type") not in ("git", "directory", "file", "url")
        if ok:
            out.add((registre, re.sub(r"[._]+", "-", nom).lower() if registre == "pypi" else nom, v))
    return out

def lock_package_lock(texte):
    out = set()
    for cle, p in (json.loads(texte).get("packages") or {}).items():
        if not cle or not isinstance(p, dict) or p.get("link") or not p.get("version"):
            continue
        nom = p.get("name") or cle.rsplit("node_modules/", 1)[-1]
        out.add(("npm", nom, p["version"]))
    return out

def lock_pnpm(texte):
    out, dans = set(), False
    for l in texte.splitlines():
        if l and not l[0].isspace():
            dans = l.rstrip() == "packages:"
            continue
        m = dans and re.match(r"^  ['\"]?/?((?:@[^/@\s'\"]+/)?[^@/\s'\"]+)@([^(:'\"\s]+)", l)
        if m:
            out.add(("npm", m.group(1), m.group(2)))
    return out

PROTOCOLES = ("workspace:", "patch:", "file:", "link:", "portal:", "git", "http")

def lock_yarn(texte):
    out, nom = set(), None
    for l in texte.splitlines():
        if l and l[0] not in " \t#":
            nom = None
            if not l.rstrip().endswith(":") or l.startswith("__metadata"):
                continue
            desc = l.rstrip()[:-1].split(",")[0].strip().strip("\"'")
            i = desc.rfind("@")
            if i <= 0 or desc[i + 1:].startswith(PROTOCOLES) or "@" in desc[1:i]:
                continue
            nom = desc[:i]
        elif nom:
            m = re.match(r"^\s+version:?\s+\"?([^\"\s]+)\"?\s*$", l)
            if m:
                out.add(("npm", nom, m.group(1)))
                nom = None
    return out

def lock(chemin, texte):
    """{(registre, nom, version)} d'un lockfile ; ValueError si illisible."""
    nom = chemin.rsplit("/", 1)[-1]
    try:
        if nom in ("Cargo.lock", "uv.lock", "poetry.lock"):
            return lock_toml(nom, texte)
        if nom == "package-lock.json":
            return lock_package_lock(texte)
        return lock_pnpm(texte) if nom == "pnpm-lock.yaml" else lock_yarn(texte)
    except (ValueError, TypeError, AttributeError) as e:
        raise ValueError(str(e))

# ---------- états (base / cible) ----------

class Etat:
    def __init__(self, racine, ref):
        self.racine, self.ref = racine, ref
        self.fichiers = fichiers(racine, ref)
        self.manifestes = [p for p in self.fichiers if not est_lock(p)]
        self.locks = [p for p in self.fichiers if est_lock(p)]
        self._lock = {}  # chemin -> (paquets, erreur ou None)

    def texte(self, chemin):
        return lire(self.racine, self.ref, chemin)

    def lock(self, chemin, illisibles=None):
        if chemin not in self._lock:
            try:
                self._lock[chemin] = (lock(chemin, self.texte(chemin)), None)
            except ValueError as e:
                self._lock[chemin] = (set(), str(e) or "illisible")
        paquets, erreur = self._lock[chemin]
        if erreur and illisibles is not None:  # l'erreur est reportée à chaque appel, pas seulement au premier
            illisibles.append(chemin)
        return paquets

    def resolu(self, chemin, registre, nom):
        """Versions résolues par les lockfiles du dossier du manifeste, sinon du plus proche parent qui en a un."""
        d, n = os.path.dirname(chemin), norme(registre, nom)
        while True:
            locks = [p for p in self.locks if os.path.dirname(p) == d and LOCKFILES[p.rsplit("/", 1)[-1]] == registre]
            if locks:
                return {v for p in locks for r, nm, v in self.lock(p) if r == registre and norme(r, nm) == n}
            if not d:
                return set()
            d = os.path.dirname(d)

# ---------- contrôle ----------

def touches(racine, base, cible):
    args = ["diff", "-z", "--name-only", "--no-renames", base] + ([cible] if cible else [])
    sortie = git(racine, *args)
    if sortie is None:
        raise OSError(f"git {' '.join(args)} a échoué")
    noms = set(sortie.split("\0"))
    if not cible:
        noms |= set((git(racine, "ls-files", "-z", "-o", "--exclude-standard") or "").split("\0"))
    gardes = {p for p in noms if p and suivi(p)}
    extras = {p for p in noms if p and p not in gardes and p.endswith((".txt", ".in"))}
    if extras:  # fichier inclus par un requirements via -r / -c
        inclus, a_lire = set(), [p for p in fichiers(racine, cible) if ecosysteme(p) == "pypi" and not est_lock(p)]
        while a_lire:
            p = a_lire.pop()
            for l in lire(racine, cible, p).splitlines():
                m = INCLUS.match(re.split(r"(?:^|\s)#", l, 1)[0].strip())
                ref = m and posixpath.normpath(posixpath.join(posixpath.dirname(p), m.group(1)))
                if ref and ref not in inclus:
                    inclus.add(ref)
                    a_lire.append(ref)
        gardes |= extras & inclus
    return sorted(gardes)

def sensibles(racine, base, cible):
    """Fichiers modifiés sous .github/workflows/ ou nommés .garde-deps-exceptions / .garde-secret-exceptions
    (listés dans le résumé CI)."""
    sortie = git(racine, "diff", "-z", "--name-only", "--no-renames", base, cible) or ""
    return sorted(p for p in sortie.split("\0")
                  if p.startswith(".github/workflows/") or p.rsplit("/", 1)[-1] in (".garde-deps-exceptions", ".garde-secret-exceptions"))

def lignes_exceptions(texte):
    return {l.strip() for l in texte.splitlines() if l.strip() and not l.strip().startswith("#")}

def resume_ci(examines, blocs, avert, ajoutees, fichiers_sensibles):
    """Résumé Markdown ajouté à $GITHUB_STEP_SUMMARY."""
    chemin = os.environ.get("GITHUB_STEP_SUMMARY")
    if not chemin:
        return
    def section(titre, items, code=False):
        if not items:
            return []
        return [f"### {titre}"] + [f"- `{i}`" if code else f"- {i}" for i in items] + [""]
    l = ["## garde-deps (contrôle des dépendances)", "",
         "**Bloqué**" if blocs else "**Conforme**", f"{len(examines)} élément(s) examiné(s).", ""]
    l += section("Paquets examinés", examines) + section("Blocages", blocs) + section("Avertissements", avert)
    l += section("Exceptions ajoutées (non appliquées tant qu'elles ne sont pas sur main)", ajoutees, True)
    l += section("Fichiers à valider par l'utilisateur", fichiers_sensibles, True)
    with open(chemin, "a", encoding="utf-8") as f:
        f.write("\n".join(l) + "\n")

def directs(base, cible, touche, illisibles):
    """({(registre, nom, version|None): {chemins}} des paquets de manifestes dont spec ou version résolue a changé,
    {(registre, nom, description): {chemins}} des dépendances hors registre ajoutées ou modifiées)."""
    res, hors_res = {}, {}
    for chemin in cible.manifestes:
        hc, hb = {}, {}
        try:
            c = manifeste(chemin, cible.texte(chemin), hc, cible.texte)
        except ValueError:
            if chemin in touche:
                illisibles.append(chemin)
            continue
        try:
            b = manifeste(chemin, base.texte(chemin), hb, base.texte) if chemin in base.manifestes else {}
        except ValueError:
            b = {}
        for k in hc:
            if k not in hb:
                hors_res.setdefault(k, set()).add(chemin)
        for (registre, nom), specs in c.items():
            rc, rb = cible.resolu(chemin, registre, nom), base.resolu(chemin, registre, nom)
            if b.get((registre, nom)) == specs and rc == rb:
                continue
            v = next(iter(rc)) if len(rc) == 1 else None
            for spec in specs if v is None else ():
                v = v or version_exacte(registre, spec)
            res.setdefault((registre, nom, v), set()).add(chemin)
    return res, hors_res

def controle(racine, base_ref, cible_ref, touche, strict, exceptions=None):
    """(blocs, avertissements, examinés) ; fichiers illisibles : avertissement, blocage si strict."""
    base, cible = Etat(racine, base_ref), Etat(racine, cible_ref)
    blocs, avert, illisibles = [], [], []
    dir_, hors = directs(base, cible, touche, illisibles)
    for (registre, nom, descr), chemins in sorted(hors.items()):
        msg = f"{registre} {nom} ({', '.join(sorted(chemins))}) : dépendance hors registre, à valider ({descr})"
        exc = exception_pour(exceptions, registre, nom, descr)
        if exc:
            avert.append(f"{msg} (exception du {exc[3]} : {exc[4]})")
        else:
            (blocs if strict else avert).append(msg)
    for (registre, nom, v), chemins in sorted(dir_.items(), key=lambda kv: (kv[0][0], kv[0][1], kv[0][2] or "")):
        b, a = [], []
        examine(registre, nom, v, b, a, strict, exceptions)
        ou = f" ({', '.join(sorted(chemins))}) : "
        blocs += [m.replace(" : ", ou, 1) for m in b]
        avert += [m.replace(" : ", ou, 1) for m in a]
    connus = set()
    for p in base.locks:
        connus |= base.lock(p)
    nouveaux = set()
    for p in cible.locks:
        if p in touche:
            nouveaux |= cible.lock(p, illisibles)
    nouveaux = sorted(nouveaux - connus - {(r, n, v) for r, n, v in dir_})
    if len(nouveaux) > MAX_TRANSITIFS:
        avert.append(f"{len(nouveaux) - MAX_TRANSITIFS} paquets transitifs non examinés (plus de {MAX_TRANSITIFS})")
        nouveaux = nouveaux[:MAX_TRANSITIFS]
    ids = osv_lot(nouveaux)
    if ids is None:
        (blocs if strict else avert).append("paquets transitifs : vérification impossible (OSV)")
    else:
        for (r, n, v), f in zip(nouveaux, ids):
            if f:
                avert.append(f"{r} {n}@{v} (transitif) : faille connue ({', '.join(f[:3])})")
    for p in sorted(set(illisibles)):
        (blocs if strict else avert).append(f"{p} illisible")
    examines = [f"{r} {n}@{v or 'dernière'} ({', '.join(sorted(c))})" for (r, n, v), c in sorted(
        dir_.items(), key=lambda kv: (kv[0][0], kv[0][1], kv[0][2] or ""))]
    if nouveaux:
        examines.append(f"{len(nouveaux)} paquet(s) transitif(s) (OSV)")
    return blocs, avert, examines

def etat_hash(racine, base_ref, cible_ref, touche):
    h = hashlib.sha256(base_ref.encode())
    for p in touche:
        h.update(b"\0" + p.encode() + b"\0" + lire(racine, cible_ref, p).encode("utf-8", "replace"))
    return h.hexdigest()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--depot")
    ap.add_argument("--base")
    ap.add_argument("--cible")
    ap.add_argument("--hook", choices=("post", "stop"))
    ap.add_argument("--ci", action="store_true")
    args = ap.parse_args()
    data = {}
    if args.hook:
        data = json.load(sys.stdin)
        if args.hook == "post" and data.get("tool_name", "Bash") != "Bash":
            ti = data.get("tool_input") or {}
            f = str(ti.get("file_path") or ti.get("notebook_path") or "")
            if not suivi(f) and not f.endswith((".txt", ".in")):  # peut être inclus par un requirements -r
                sys.exit(0)
    if args.ci:  # barrière : délais plus généreux, tout échec est un blocage
        dc.DELAI, dc.BUDGET = 10, 120
    depot = os.path.abspath(data.get("cwd") or args.depot or os.getcwd())
    top = git(depot, "rev-parse", "--show-toplevel")
    if not top:
        if args.ci:
            raise OSError(f"{depot} n'est pas un dépôt git")
        sys.exit(0)
    racine = top.strip()
    base_ref = args.base or base_par_defaut(racine)
    touche = touches(racine, base_ref, args.cible)
    if args.ci:
        # exceptions lues dans la base seulement ; celles que la cible ajoute sont listées, non appliquées
        exceptions, avert_exc = lit_exceptions(lire(racine, base_ref, ".garde-deps-exceptions"))
        ajoutees = sorted(lignes_exceptions(lire(racine, args.cible, ".garde-deps-exceptions"))
                          - lignes_exceptions(lire(racine, base_ref, ".garde-deps-exceptions")))
        fichiers_sensibles = sensibles(racine, base_ref, args.cible or "HEAD")
    if not touche:
        if args.ci:
            resume_ci([], [], avert_exc, ajoutees, fichiers_sensibles)
        sys.exit(0)
    if args.hook == "post":
        gitdir = (git(racine, "rev-parse", "--absolute-git-dir") or "").strip()
        h = etat_hash(racine, base_ref, args.cible, touche)
        fichier = os.path.join(gitdir, "garde-deps-etat")
        try:
            with open(fichier, encoding="utf-8") as f:
                if f.read().strip() == h:
                    sys.exit(0)
        except OSError:
            pass
        if gitdir:
            with open(fichier, "w", encoding="utf-8") as f:
                f.write(h)
    if not args.ci:
        exceptions, avert_exc = lit_exceptions(lire(racine, args.cible, ".garde-deps-exceptions"))
    blocs, avert, examines = controle(racine, base_ref, args.cible, touche, args.ci, exceptions)
    avert = avert_exc + avert
    if args.ci:
        avert += [f"exception non appliquée tant qu'elle n'est pas sur main : {l}" for l in ajoutees]
        resume_ci(examines, blocs, avert, ajoutees, fichiers_sensibles)
    if blocs:
        texte = "⛔ Bloqué par garde-deps (manifestes) :\n" + "\n".join(f"- {b}" for b in blocs)
        if args.hook == "stop" and data.get("stop_hook_active"):
            print(json.dumps({"systemMessage": "⚠ garde-deps : paquet non conforme encore présent : "
                              + " ; ".join(blocs)}, ensure_ascii=False))
            sys.exit(0)
        print(texte, file=sys.stderr)
        sys.exit(2)
    if avert and args.hook == "post":
        msg = "⚠ garde-deps : " + " ; ".join(avert)
        print(json.dumps({"systemMessage": msg, "hookSpecificOutput": {
            "hookEventName": "PostToolUse", "additionalContext": msg}}, ensure_ascii=False))
    elif avert and not args.hook:
        for a in avert:
            print(f"⚠ {a}")
    sys.exit(0)

if __name__ == "__main__":
    code = 0
    try:
        main()
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    except Exception:
        if "--ci" in sys.argv:
            import traceback
            traceback.print_exc()
            code = 2
    if "--ci" in sys.argv:  # le scan de secrets tourne aussi quand les dépendances bloquent
        sys.stdout.flush()
        r = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "garde-secret.py"),
                            *sys.argv[1:]], check=False)
        code = max(code, r.returncode)
    sys.exit(code)
