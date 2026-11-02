#!/usr/bin/env python3
"""Garde-secret : l'agent ne lit pas ~/.ssh, ~/.config/gh ni les .env, n'affiche et n'écrit aucun token, n'en commite aucun.
Modes : CLI (défaut), --hook pre (PreToolUse), --hook post (PostToolUse / PostToolUseFailure), --hook stop (Stop), --ci (strict).
Le filtre de commandes est une aide ; les barrières sont le masquage de la sortie et le scan du résultat git.
Sortie 2 + message sur stderr = refus. Aucun message ne contient une valeur de secret."""
import argparse, fnmatch, hashlib, importlib.util, json, math, os, re, sys, time
from collections import Counter
from datetime import date

DOSSIER = os.path.dirname(os.path.abspath(__file__))
EXCEPTIONS = ".garde-secret-exceptions"

# ---------- motifs ----------

FORTS = (("github", r"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,}"),
         ("gitlab", r"glpat-[A-Za-z0-9_-]{20,}"), ("anthropic", r"sk-ant-[A-Za-z0-9_-]{32,}"),
         ("openai", r"sk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{32,}|sk-[A-Za-z0-9]{40,}"),
         ("aws", r"(?:AKIA|ASIA)[0-9A-Z]{16}(?![0-9A-Z])"), ("google", r"AIza[0-9A-Za-z_-]{35}"),
         ("slack", r"xox[abprs]-[0-9A-Za-z-]{20,}|hooks\.slack\.com/services/T[0-9A-Z]+/B[0-9A-Z]+/[0-9A-Za-z]{20,}"),
         ("stripe", r"[sr]k_live_[0-9A-Za-z]{20,}"), ("npm", r"npm_[A-Za-z0-9]{36}"), ("pypi", r"pypi-[A-Za-z0-9_-]{50,}"),
         ("cle-privee", r"-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|\Z)"))
FAIBLES = (("jwt", r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
           ("url", r"[a-z][a-z0-9+.-]{0,30}://[^/\s:@'\"]+:(?P<v>[^/\s:@'\"]{8,})@"),
           ("affectation", r"(?i)(?:pass(?:word|wd|phrase)?|pwd|secret|token|api[_-]?key|access[_-]?key|auth[_-]?key)[\"']?\s*[:=]\s*[\"'](?P<v>[^\"'\s]{12,})[\"']"))

def compile_motifs(liste):
    out = []
    for nom, p in liste:
        flags = 0
        if p.startswith("(?i)"):  # un drapeau global doit rester en tête : il passe en argument
            p, flags = p[4:], re.I
        if nom != "cle-privee":
            p = r"(?<![A-Za-z0-9])(?:" + p + ")"
        out.append((nom, re.compile(p, flags)))
    return out

MOTIFS_FORTS, MOTIFS_FAIBLES = compile_motifs(FORTS), compile_motifs(FAIBLES)
FAUX_FAIBLE = re.compile(r"(?i)example|exemple|changeme|change_me|replace|your|xxx|dummy|fake|sample|placeholder|todo")
CHEMIN_DOC = re.compile(r"(^|/)(tests?|__tests__|specs?|fixtures?|docs?|examples?)/|\.(md|example|sample|template)$")

def entropie(v):
    n = len(v)
    return -sum(c / n * math.log2(c / n) for c in Counter(v).values()) if n else 0.0

def empreinte(v):
    return hashlib.sha256(v.encode("utf-8", "replace")).hexdigest()[:12]

def fort_ignore(v):
    return "EXAMPLE" in v or len(set(v)) < 6

def faible_ignore(v, chemin):
    return (bool(FAUX_FAIBLE.search(v)) or v[:1] in ("$", " ", "{", "<", "%") or entropie(v) < 3.0
            or bool(CHEMIN_DOC.search(chemin)))

def analyse(texte, chemin=""):
    """[(niveau, nom, valeur)] des secrets trouvés dans `texte` ; `chemin` écarte les faux positifs faibles de la doc."""
    out = []
    for niveau, motifs in (("fort", MOTIFS_FORTS), ("faible", MOTIFS_FAIBLES)):
        for nom, rx in motifs:
            for m in rx.finditer(texte):
                v = m.group("v") if "v" in rx.groupindex else m.group(0)
                if fort_ignore(v) if niveau == "fort" else faible_ignore(v, chemin):
                    continue
                out.append((niveau, nom, v))
    return out

# ---------- chemins ----------

PERSO = re.compile(r"(^|/)(\.ssh|\.gnupg|\.config/gh)(/|$)"
                   r"|(^|/)(\.aws/credentials|\.git-credentials|\.netrc|\.cargo/credentials(\.toml)?"
                   r"|\.docker/config\.json|\.claude/\.credentials\.json)$|^/proc/[^/]+/environ$")
ENV_NOM = re.compile(r"^(\.env(\..+)?|.+\.env|\.envrc)$")
ENV_EXEMPLE = re.compile(r"\.(example|sample|template|tmpl|dist|defaults?)$")
NOM_INTERDIT = re.compile(r"^(id_(rsa|dsa|ecdsa|ed25519)|\.netrc|\.git-credentials)$|\.(p12|pfx|jks|keystore)$")

def classe(chemin):
    """"perso" (clés, identifiants de l'utilisateur), "env" (fichier d'environnement) ou None."""
    if PERSO.search(chemin):
        return "perso"
    nom = chemin.rstrip("/").rsplit("/", 1)[-1]
    if ENV_NOM.match(nom) and not ENV_EXEMPLE.search(nom):
        return "env"
    # un joker de shell ne couvre un fichier caché que s'il commence par un point
    if nom.startswith(".") and any(c in nom for c in "*?") and (
            fnmatch.fnmatchcase(".env", nom) or fnmatch.fnmatchcase(".env.local", nom)):
        return "env"
    return None

def nom_interdit(chemin):
    return classe(chemin) == "env" or bool(NOM_INTERDIT.search(chemin.rsplit("/", 1)[-1]))

def developpe(t):
    home = os.path.expanduser("~")
    t = t.replace("${HOME}", home).replace("$HOME", home)
    return home + t[1:] if t == "~" or t.startswith("~/") else t

def classe_chemin(chemin, cwd):
    """Classe d'un chemin testé brut puis résolu (liens symboliques, relatif à cwd)."""
    brut = developpe(str(chemin))
    c = classe(brut)
    if c:
        return c
    return classe(os.path.realpath(brut if os.path.isabs(brut) else os.path.join(cwd or os.getcwd(), brut)))

# ---------- modules voisins (chargement paresseux) ----------

_modules = {}
def charge(fichier):
    if fichier not in _modules:
        spec = importlib.util.spec_from_file_location(fichier.removesuffix(".py").replace("-", "_"),
                                                      os.path.join(DOSSIER, fichier))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        _modules[fichier] = m
    return _modules[fichier]

def vm():
    return charge("verifie-manifestes.py")

def racine_de(dossier):
    top = vm().git(dossier or os.getcwd(), "rev-parse", "--show-toplevel")
    return top.strip() if top and top.strip() else None

# ---------- exceptions ----------

def lit_exceptions(texte):
    """([(glob, empreinte|*, date, raison)], avertissements)."""
    res, avert = [], []
    for n, l in enumerate(texte.splitlines(), 1):
        l = l.strip()
        if not l or l.startswith("#"):
            continue
        p = l.split(None, 3)
        try:
            if len(p) < 4 or not (p[1] == "*" or re.fullmatch(r"[0-9a-f]{12}", p[1])) \
                    or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", p[2]):
                raise ValueError
            date.fromisoformat(p[2])
        except ValueError:
            avert.append(f"{EXCEPTIONS} ligne {n} invalide (attendu : glob empreinte|* AAAA-MM-JJ raison)")
            continue
        res.append(tuple(p))
    return res, avert

def exceptions_du_depot(racine):
    try:
        with open(os.path.join(racine, EXCEPTIONS), encoding="utf-8") as f:
            return lit_exceptions(f.read())
    except OSError:
        return [], []

def couvre(exceptions, rel, emp=None):
    """Vrai si une exception couvre le chemin relatif `rel` (empreinte `emp`, ou `*` seul si emp est None)."""
    for g, e, *_ in exceptions or ():
        if (e == "*" or (emp and e == emp)) and (fnmatch.fnmatchcase(rel, g)
                                                 or ("/" not in g and fnmatch.fnmatchcase(rel.rsplit("/", 1)[-1], g))):
            return True
    return False

# ---------- scan git ----------

OPTS_DIFF = ("--text", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=0",
             "--src-prefix=a/", "--dst-prefix=b/")

def git(racine, *args):
    return vm().git(racine, "-c", "core.quotePath=false", *args)

def analyse_diff(texte, commit, trouv):
    """Ajoute à `trouv` les secrets des lignes ajoutées (`+`) d'un diff, fichier par fichier."""
    fichiers, chemin, entete, prec = {}, "", False, ""
    for l in texte.split("\n"):
        if l.startswith("diff --git "):
            entete, chemin = True, ""
        elif entete:
            if l.startswith("+++ ") and prec.startswith("--- "):
                chemin = l[4:].split("\t")[0]
                chemin = "" if chemin == "/dev/null" else chemin.removeprefix("b/")
            elif l.startswith("@@"):
                entete = False
        elif l.startswith("+"):
            fichiers.setdefault(chemin, []).append(l[1:])
        prec = l
    for chemin, lignes in fichiers.items():
        for niveau, nom, v in analyse("\n".join(lignes), chemin):
            trouv.append((chemin, commit, niveau, nom, empreinte(v)))

def scan(racine, base, cible, ci, budget=None):
    """(trouvailles, illisibles). Trouvaille = (chemin, commit, niveau, nom, empreinte). Les commits sont lus un par un."""
    v = vm()
    fin_budget = time.monotonic() + budget if budget else None
    trouv, illis = [], []
    def g(motif, *args):
        r = git(racine, *args)
        if r is None:
            illis.append(f"git {motif} a échoué")
        return r
    def noms(liste, commit):
        for n in liste:
            if n and nom_interdit(n):
                trouv.append((n, commit, "fort", "fichier-interdit", empreinte(n)))
    a_head = v.git(racine, "rev-parse", "--verify", "-q", "HEAD") is not None
    if cible or a_head:
        fin = cible or "HEAD"
        plage = fin if base == v.VIDE else f"{base}..{fin}"
        sortie = g("log", "log", "-p", *OPTS_DIFF, "--diff-merges=first-parent", "--format=%x00%H", plage)
        # un NUL peut figurer dans un contenu (--text) : on ne coupe que sur `\0<sha>\n` en début de ligne
        for bloc in re.split(r"(?<![^\n])\0(?=[0-9a-f]{40}\n)", sortie or ""):
            h, _, diff = bloc.partition("\n")
            if h.strip():
                analyse_diff(diff, h.strip()[:8], trouv)
        liste = g("log --name-only", "log", "--name-only", "--format=", "-z", "--no-renames",
                  "--diff-merges=first-parent", "--diff-filter=ACMR", plage)
        noms((liste or "").split("\0"), "historique")
    if not cible:
        ref = "HEAD" if a_head else v.VIDE
        analyse_diff(g("diff", "diff", *OPTS_DIFF, ref) or "", "copie", trouv)
        noms((g("diff --name-only", "diff", "--name-only", "-z", "--no-renames", "--diff-filter=ACMR", ref) or "").split("\0"), "copie")
        nonsuivis = [n for n in (g("ls-files", "ls-files", "-z", "-o", "--exclude-standard") or "").split("\0") if n]
        noms(nonsuivis, "copie")
        for n in nonsuivis:
            if fin_budget and time.monotonic() > fin_budget:
                illis.append("analyse des fichiers non suivis interrompue (budget de temps dépassé)")
                break
            p = os.path.join(racine, n)
            try:
                if os.path.islink(p) or os.path.getsize(p) > 1 << 20:
                    continue
                with open(p, "rb") as f:
                    brut = f.read()
            except OSError:
                continue
            if b"\0" in brut[:8192]:
                continue
            for niveau, nom, val in analyse(brut.decode("utf-8", "replace"), n):
                trouv.append((n, "copie", niveau, nom, empreinte(val)))
    return list(dict.fromkeys(trouv)), illis

def sans_exceptions(trouv, exceptions):
    return [t for t in trouv if not couvre(exceptions, t[0], t[4])]

def ligne_trouvaille(t):
    return f"- {t[0] or '(sans chemin)'} [{t[1]}] : {t[3]} (empreinte {t[4]})"

# ---------- CLI et CI ----------

def lignes_exceptions(texte):
    return {l.strip() for l in texte.splitlines() if l.strip() and not l.strip().startswith("#")}

def resume_ci(blocs, avert, ajoutees):
    chemin = os.environ.get("GITHUB_STEP_SUMMARY")
    if not chemin:
        return
    def section(titre, items, code=False):
        if not items:
            return []
        return [f"### {titre}"] + [f"- `{i}`" if code else f"- {i}" for i in items] + [""]
    l = ["## garde-secret (contrôle des secrets)", "", "**Bloqué**" if blocs else "**Conforme**", ""]
    l += section("Blocages", blocs) + section("Avertissements", avert)
    l += section("Exceptions ajoutées (non appliquées tant qu'elles ne sont pas sur main)", ajoutees, True)
    with open(chemin, "a", encoding="utf-8") as f:
        f.write("\n".join(l) + "\n")

def commande(args):
    v = vm()
    depot = os.path.abspath(args.depot or os.getcwd())
    racine = racine_de(depot)
    if not racine:
        if args.ci:
            raise OSError(f"{depot} n'est pas un dépôt git")
        return 0
    base = args.base or v.base_par_defaut(racine)
    trouv, illis = scan(racine, base, args.cible, args.ci)
    avert, ajoutees = [], []
    if args.ci:  # exceptions lues dans la base seulement ; celles de la cible sont listées, non appliquées
        exceptions, avert = lit_exceptions(v.lire(racine, base, EXCEPTIONS))
        ajoutees = sorted(lignes_exceptions(v.lire(racine, args.cible, EXCEPTIONS))
                          - lignes_exceptions(v.lire(racine, base, EXCEPTIONS)))
    elif trouv:
        exceptions, avert = exceptions_du_depot(racine) if not args.cible else lit_exceptions(
            v.lire(racine, args.cible, EXCEPTIONS))
    else:
        exceptions = []
    trouv = sans_exceptions(trouv, exceptions)
    bloquants = [t for t in trouv if t[2] == "fort" or args.ci]
    faibles = [t for t in trouv if t not in bloquants]
    blocs = [ligne_trouvaille(t)[2:] for t in bloquants] + (illis if args.ci else [])
    warns = avert + [ligne_trouvaille(t)[2:] for t in faibles]
    if args.ci:
        resume_ci(blocs, warns + [f"exception non appliquée tant qu'elle n'est pas sur main : {l}" for l in ajoutees],
                  ajoutees)
    if blocs:
        print("⛔ Bloqué par garde-secret :", file=sys.stderr)
        for b in blocs:
            print(f"- {b}", file=sys.stderr)
        return 2
    for w in warns:
        print(f"⚠ {w}")
    return 0

# ---------- hooks ----------

ECRITURE = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
ACCES = "Demande à l'utilisateur où placer le secret, ou de te transmettre l'information utile autrement."

def refuse(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)

def avertit(evenement, msg):
    print(json.dumps({"systemMessage": msg, "hookSpecificOutput": {
        "hookEventName": evenement, "additionalContext": msg}}, ensure_ascii=False))

def relatif(chemin, cwd, racine):
    p = os.path.realpath(chemin if os.path.isabs(chemin) else os.path.join(cwd, chemin))
    r = os.path.realpath(racine)
    return os.path.relpath(p, r) if p == r or p.startswith(r + os.sep) else None

def controle_chemin(chemin, cwd):
    """Refuse (exit 2) un chemin protégé, sauf fichier `env` couvert par un `*` de .garde-secret-exceptions à la racine."""
    c = classe_chemin(chemin, cwd)
    if not c:
        return
    if c == "env":
        racine = racine_de(cwd)
        rel = relatif(developpe(str(chemin)), cwd, racine) if racine else None
        if rel and couvre(exceptions_du_depot(racine)[0], rel):
            return
    refuse(f"⛔ Bloqué par garde-secret : accès à un fichier de secrets ({chemin}). {ACCES}")

def controle_contenu(textes, chemin, cwd):
    """Secrets dans un contenu écrit : fort non couvert = refus, faible = avertissement."""
    trouv = [(chemin, "écriture", n, nom, empreinte(v)) for t in textes for n, nom, v in analyse(t, chemin)]
    if not trouv:
        return
    racine = racine_de(cwd)
    if racine:
        rel = relatif(developpe(chemin), cwd, racine) if chemin else None
        if rel:
            trouv = [t for t in trouv if not couvre(exceptions_du_depot(racine)[0], rel, t[4])]
    forts = [t for t in trouv if t[2] == "fort"]
    if forts:
        refuse("⛔ Bloqué par garde-secret : secret dans le contenu à écrire.\n"
               + "\n".join(f"- {t[0]} : {t[3]} (empreinte {t[4]})" for t in forts) + f"\n{ACCES}")
    if trouv:
        avertit("PreToolUse", "⚠ garde-secret : valeur ressemblant à un secret dans le contenu écrit ("
                + ", ".join(f"{t[3]} {t[4]}" for t in trouv) + "). Si c'est réel, ne l'écris pas : " + ACCES)

# -- Bash --

SANS_CONTROLE = {"echo", "printf", "ls", "stat", "test", "[", "[[", "cd", "mkdir", "which", "type", "pwd", "gh"}
GIT_TESTE = {"add", "show", "diff", "log", "blame", "cat-file", "grep", "archive", "stash"}
MOTIF_PREMIER = {"grep", "egrep", "fgrep", "rg", "ag", "ack", "sed", "awk", "gawk"}
MOTIF_OPT_VALEUR = {"-A", "-B", "-C", "-m", "-d", "-D", "--max-count", "--context", "--include", "--exclude"}
MOTIF_OPT_EXPLICITE = {"-e", "-f", "--regexp", "--file", "--expression"}
CANDIDAT = re.compile(r"[~\w./*?$+{}-]+")

def candidats(texte):
    return CANDIDAT.findall(texte)

def chemin_protege(texte):
    return next((c for c in candidats(texte) if classe(developpe(c))), None)

def bash_chemins(cmd, ctx, prof=0):
    """Remplit ctx : "hits" (raisons de refus) et "scan" (git commit/push, gh pr create)."""
    gd = charge("garde-deps.py")
    def brut():
        c = chemin_protege(cmd)
        if c:
            ctx["hits"].append(c)
    if prof > gd.PROFONDEUR_MAX:
        return brut()
    cmd, heredocs = gd.retire_heredocs(cmd)
    cmd = gd.sans_commentaires(cmd)
    try:
        corps = gd.substitutions(cmd)
        for texte, shell, cite in heredocs:
            if shell:
                corps.append(texte)
            elif not cite:
                corps += gd.substitutions(texte, apostrophes=False)
        toks_tous = gd.jetons(cmd)
        segs = list(gd.decoupe(toks_tous))
    except (ValueError, gd.Illisible):
        return brut()
    for c in corps:
        bash_chemins(c, ctx, prof + 1)
    # cible de toute redirection (entrée ou sortie, hors heredoc et herestring) : toujours testée
    for i, t in enumerate(toks_tous[:-1]):
        suivant = toks_tous[i + 1]
        if gd.redirection(t) and "<<" not in t and not gd.separateur(suivant) and not gd.redirection(suivant):
            c = chemin_protege(suivant)
            if c:
                ctx["hits"].append(c)
    for toks, _ in segs:
        try:
            toks = gd.sans_prefixe(toks)
        except gd.Illisible:
            brut()
            continue
        if not toks:
            continue
        base, args = toks[0].rsplit("/", 1)[-1], toks[1:]
        sous = gd.sous_commande_git(args) if base == "git" else ""
        if (base == "gh" and (args[:2] == ["auth", "token"] or (args[:2] == ["auth", "status"] and any(
                a in ("-t", "--show-token") for a in args)))) or (
                base == "git" and sous == "credential" and args[args.index(sous) + 1:][:1] == ["fill"]):
            ctx["hits"].append("identifiants git/gh")
        if (base == "git" and sous in ("commit", "push")) or (base == "gh" and args[:2] == ["pr", "create"]):
            ctx["scan"] = True
        sh = gd.appel_shell(toks)
        if sh and sh[0] == "c":
            bash_chemins(sh[1], ctx, prof + 1)
        if base in SANS_CONTROLE or (base == "git" and sous not in GIT_TESTE):
            continue
        a_tester = args
        if base in MOTIF_PREMIER and not MOTIF_OPT_EXPLICITE & set(args):
            i = 0
            while i < len(args) and args[i].startswith("-") and args[i] != "--":
                i += 2 if args[i] in MOTIF_OPT_VALEUR else 1
            a_tester = args[:i] + args[i + 1:]
        interprete = bool(gd.INTERPRETES.fullmatch(base))
        for t in a_tester:
            if any(c.isspace() for c in t) and not interprete:
                continue
            c = chemin_protege(t)
            if c:
                ctx["hits"].append(c)

def scan_depot(cwd, budget=None):
    """Scan du dépôt de cwd : (forts, faibles, illisibles) non couverts, ou vide hors dépôt / sur échec git."""
    racine = racine_de(cwd)
    if not racine:
        return [], [], []
    trouv, illis = scan(racine, vm().base_par_defaut(racine), None, False, budget)
    if trouv:
        trouv = sans_exceptions(trouv, exceptions_du_depot(racine)[0])
    return [t for t in trouv if t[2] == "fort"], [t for t in trouv if t[2] != "fort"], illis

def pre(data):
    outil = data.get("tool_name") or "Bash"
    ti = data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()
    if outil == "Read":
        controle_chemin(ti.get("file_path") or "", cwd)
    elif outil == "Grep":
        p = ti.get("path") or ""
        if p:
            controle_chemin(p, cwd)
            r = os.path.realpath(os.path.join(cwd, developpe(p)))
            home = os.path.realpath(os.path.expanduser("~"))
            if r in (home, os.path.join(home, ".config")):
                refuse(f"⛔ Bloqué par garde-secret : recherche dans {p}, qui contient des fichiers de secrets. {ACCES}")
        if ti.get("glob"):
            controle_chemin(ti["glob"], cwd)
    elif outil in ECRITURE:
        chemin = ti.get("file_path") or ti.get("notebook_path") or ""
        if chemin:
            controle_chemin(chemin, cwd)
        textes = [ti[k] for k in ("new_string", "content", "new_source") if isinstance(ti.get(k), str)]
        textes += [e["new_string"] for e in ti.get("edits") or [] if isinstance(e, dict) and isinstance(e.get("new_string"), str)]
        controle_contenu(textes, chemin, cwd)
    else:
        cmd = ti.get("command") or ""
        forts = [x for x in analyse(cmd) if x[0] == "fort"]
        if forts:
            refuse("⛔ Bloqué par garde-secret : secret dans le texte de la commande ("
                   + ", ".join(f"{n} {empreinte(v)}" for _, n, v in forts) + f"). {ACCES}")
        ctx = {"hits": [], "scan": False}
        bash_chemins(cmd, ctx)
        if ctx["hits"]:
            refuse(f"⛔ Bloqué par garde-secret : la commande touche un fichier ou une commande de secrets ({ctx['hits'][0]}). {ACCES}")
        if ctx["scan"]:
            forts, faibles, illis = scan_depot(cwd, 10)
            if forts:
                refuse("⛔ Bloqué par garde-secret : secret dans les modifications ou commits à livrer.\n"
                       + "\n".join(ligne_trouvaille(t) for t in forts)
                       + "\nCommits non poussés : retire le secret, puis `git reset --soft <base>` et recommite."
                       "\nDéjà poussé : préviens l'utilisateur, le secret est à révoquer.")
            notes = [f"{t[0]} {t[3]} {t[4]}" for t in faibles] + illis
            if notes:
                avertit("PreToolUse", "⚠ garde-secret : scan incomplet ou valeur ressemblant à un secret dans le dépôt ("
                        + ", ".join(notes) + "). Stop et la CI refont le scan complet.")

# -- post --

NOM_SECRET = re.compile(r"(?i)TOKEN|SECRET|PASSW|PASSPHRASE|API_?KEY|PRIVATE_?KEY|CREDENTIAL")

def valeurs_connues(cwd):
    vals = set()
    def ajoute(k, v):
        if NOM_SECRET.search(k) and len(v) >= 8 and not v.isdigit() and not v.startswith("/"):
            vals.add(v)
    for k, v in os.environ.items():
        ajoute(k, v)
    for nom in (".env", ".env.local"):
        try:
            with open(os.path.join(cwd, nom), encoding="utf-8", errors="replace") as f:
                lignes = f.read().splitlines()
        except OSError:
            continue
        for l in lignes:
            m = re.match(r"\s*(?:export\s+)?([A-Za-z_]\w*)\s*=\s*(.*)$", l)
            if m:
                val = m.group(2).strip()
                if val[:1] in ("'", '"'):  # valeur citée : jusqu'à la guillemet fermante
                    fin = val.find(val[0], 1)
                    val = val[1:fin] if fin > 0 else val[1:]
                else:  # sinon, sans commentaire de fin de ligne
                    val = re.split(r"\s+#", val, 1)[0].strip()
                ajoute(m.group(1), val)
    return sorted(vals, key=len, reverse=True)

def masque_texte(s, connus, trouves):
    for nom, rx in MOTIFS_FORTS:
        def remplace(m, nom=nom):
            v = m.group(0)
            if fort_ignore(v):
                return v
            trouves.append((nom, empreinte(v)))
            return f"[masqué:{nom}:{empreinte(v)}]"
        s = rx.sub(remplace, s)
    for v in connus:
        if v in s:
            trouves.append(("valeur-connue", empreinte(v)))
            s = s.replace(v, f"[masqué:valeur-connue:{empreinte(v)}]")
    return s

def masque(obj, connus, trouves):
    if isinstance(obj, str):
        return masque_texte(obj, connus, trouves)
    if isinstance(obj, dict):
        return {k: masque(v, connus, trouves) for k, v in obj.items()}
    if isinstance(obj, list):
        return [masque(v, connus, trouves) for v in obj]
    return obj

def post(data):
    if data.get("hook_event_name") == "PostToolUseFailure":
        trouv = [(n, empreinte(v)) for niv, n, v in analyse(str(data.get("error") or "")) if niv == "fort"]
        if trouv:
            print(json.dumps({"systemMessage": msg_alerte(data, trouv), "hookSpecificOutput": {
                "hookEventName": "PostToolUseFailure", "additionalContext": msg_alerte(data, trouv)}}, ensure_ascii=False))
        return
    reponse = data.get("tool_response")
    if reponse is None:
        return
    trouves = []
    nouveau = masque(reponse, valeurs_connues(data.get("cwd") or os.getcwd()), trouves)
    if not trouves:
        return
    msg = msg_alerte(data, trouves)
    print(json.dumps({"systemMessage": msg, "hookSpecificOutput": {
        "hookEventName": "PostToolUse", "updatedToolOutput": nouveau, "additionalContext": msg}}, ensure_ascii=False))

def msg_alerte(data, trouves):
    return (f"⚠ garde-secret : secret ({', '.join(sorted({f'{n} {e}' for n, e in trouves}))}) dans la sortie de "
            f"{data.get('tool_name') or 'Bash'}, masqué ; s'il est réel, il est à révoquer.")

# -- stop --

def stop(data):
    forts, _, _ = scan_depot(data.get("cwd") or os.getcwd())
    if not forts:
        return
    if data.get("stop_hook_active"):
        print(json.dumps({"systemMessage": "⚠ garde-secret : secret encore présent dans le dépôt ("
                          + ", ".join(f"{t[0]} {t[3]} {t[4]}" for t in forts) + ")."}, ensure_ascii=False))
        return
    refuse("⛔ Bloqué par garde-secret : secret dans le dépôt.\n" + "\n".join(ligne_trouvaille(t) for t in forts)
           + "\nRetire-le (commits non poussés : `git reset --soft <base>` puis recommite) ; déjà poussé : "
           "préviens l'utilisateur, il est à révoquer.")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--depot")
    ap.add_argument("--base")
    ap.add_argument("--cible")
    ap.add_argument("--hook", choices=("pre", "post", "stop"))
    ap.add_argument("--ci", action="store_true")
    args = ap.parse_args()
    if not args.hook:
        sys.exit(commande(args))
    data = json.load(sys.stdin)
    {"pre": pre, "post": post, "stop": stop}[args.hook](data)
    sys.exit(0)

if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        if sys.argv[1:][-2:] == ["--hook", "pre"] or "--hook=pre" in sys.argv:  # PreToolUse : un échec est un bug ou une entrée anormale, on bloque
            import traceback
            print("⛔ garde-secret : erreur interne.\n" + traceback.format_exc(), file=sys.stderr)
            sys.exit(2)
        if "--ci" in sys.argv:
            import traceback
            traceback.print_exc()
            sys.exit(2)
        sys.exit(0)
