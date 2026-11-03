#!/usr/bin/env python3
"""Hook PreToolUse (Bash) : bloque l'ajout d'un paquet (cargo, npm/pnpm/yarn, pip/uv) dont la licence
n'est pas permissive, qui a une faille OSV, qui est déprécié/yanked ou dont la dernière version a plus de 2 ans.
Sortie 2 + message sur stderr = commande refusée ; avertissements en JSON sur stdout ; fail-open hors réseau."""
import json, os, re, shlex, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deps_communs import *

SAUTE = {
    "cargo": {"-F", "--features", "-p", "--package", "--rename", "--registry", "--manifest-path", "--target"},
    "npm": {"--registry", "--prefix", "-w", "--workspace", "--omit", "--include", "--tag", "--cache", "--userconfig",
            "--loglevel", "-C", "--dir", "--cwd", "-F", "--filter"},
    "pip": {"-r", "--requirement", "-e", "--editable", "-c", "--constraint", "-i", "--index-url",
            "--extra-index-url", "-f", "--find-links", "-t", "--target", "--prefix", "--group", "--optional",
            "--extra", "--index", "--default-index", "--package"},
}
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
DEBUT_MOT = " \t\r\n;&|()<>"
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
        elif c == "#" and (i == 0 or s[i - 1] in DEBUT_MOT):
            j = s.find("\n", i)
            i = n if j < 0 else j
            continue
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

def sans_commentaires(s):
    """Retire les commentaires shell : hors apostrophes/guillemets et non échappé, un `#` en début de mot
    supprime jusqu'au `\\n` exclu. Les $( … ) (même entre guillemets doubles) sont du code : cadres empilés."""
    out, i, n = [], 0, len(s)
    frames = [["c", 0]]
    while i < n:
        c, k = s[i], frames[-1][0]
        if c == "\\" and i + 1 < n:
            out.append(s[i:i + 2])
            i += 2
            continue
        if k == "d":
            if c == '"':
                frames.pop()
            elif s.startswith("$(", i):
                frames.append(["c", 0])
                out.append("$")
                i += 1
                c = "("
        elif c == "'":
            j = s.find("'", i + 1)
            j = n - 1 if j < 0 else j
            out.append(s[i:j + 1])
            i = j + 1
            continue
        elif c == "#" and (i == 0 or s[i - 1] in DEBUT_MOT):
            j = s.find("\n", i)
            i = n if j < 0 else j
            continue
        elif c == '"':
            frames.append(["d", 0])
        elif s.startswith("$(", i):
            frames.append(["c", 0])
            out.append("$")
            i += 1
            c = "("
        elif c == "(":
            frames[-1][1] += 1
        elif c == ")":
            if frames[-1][1]:
                frames[-1][1] -= 1
            elif len(frames) > 1:
                frames.pop()
        out.append(c)
        i += 1
    return "".join(out)

def jetons(cmd):
    lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|()<>\n")
    lex.whitespace = " \t\r"
    lex.commenters = ""
    lex.whitespace_split = True
    return list(lex)

def separateur(t):
    return bool(t) and all(c in ";&|()\n" for c in t)

def redirection(t):
    return bool(t) and all(c in "<>&|;()\n" for c in t) and ("<" in t or ">" in t)

def decoupe(toks):
    """Segments de commande, chacun avec ses cibles de redirection de sortie : yield (segment, [cibles])."""
    seg, cibles = [], []
    i = 0
    while i < len(toks):
        t = toks[i]
        if redirection(t):
            if t[0] in ";|()\n" or t.startswith("&&"):  # `;>log`, `&&>log` : la redirection clôt aussi le segment
                if seg or cibles:
                    yield seg, cibles
                seg, cibles = [], []
            elif seg and seg[-1].isdigit():
                seg.pop()
            if ">" in t and i + 1 < len(toks):
                cibles.append(toks[i + 1])
            i += 2
            continue
        if separateur(t):
            if seg or cibles:
                yield seg, cibles
            seg, cibles = [], []
        else:
            seg.append(t)
        i += 1
    if seg or cibles:
        yield seg, cibles

# ---------- écritures vers les chemins protégés ----------

MOTIFS = (".claude/settings", ".claude/hooks", ".claude/plugins", ".github/workflows", ".garde-deps-exceptions",
          ".garde-secret-exceptions")
ECRIVAINS = {"cp", "mv", "rm", "ln", "install", "rsync", "dd", "truncate", "tee", "touch", "chmod", "chown", "patch",
             "tar", "unzip", "unlink", "rmdir", "sponge"}
INTERPRETES = re.compile(r"(python[\d.]*|node|ruby|perl|php|deno|bun)")
GIT_ECRIT = {"checkout", "restore", "rm", "mv", "apply", "am", "clean", "clone", "worktree", "init"}
GIT_OPT_VALEUR = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}

def developpe(t):
    home = os.path.expanduser("~")
    t = t.replace("${HOME}", home).replace("$HOME", home)
    return home + t[1:] if t == "~" or t.startswith("~/") else t

def motif(t):
    """Vrai si `t` cite un chemin protégé (ou un dossier qui les contient : ~/.claude, .claude, .github)."""
    t = developpe(t)
    if any(m in t for m in MOTIFS):
        return True
    n = t.rstrip("/")
    return n.rsplit("/", 1)[-1] in (".claude", ".github") and n != ""

# Exemption « lecture inline » : liste blanche stricte, python uniquement, forme `python -c "<code>"`.
# Tout doute (construction inconnue, autre interpréteur, autre forme) : on garde le comportement bloquant.
IMPORTS_OK = r"(?:json|os|sys|re|tomllib)"
IMPORT_STMT = re.compile(rf"\bimport\s+{IMPORTS_OK}(?:\s*,\s*{IMPORTS_OK})*[ \t]*(?=;|\n|$)")
INTERDIT = re.compile(
    r"__|\bfrom\b|\bas\b|\bfile\s*=|\bPath\b|pathlib|\bexec|\beval|\bcompile|getattr|setattr|globals|locals|\bvars\b"
    r"|sys\s*\.\s*modules|subprocess|\bpty\b|system|spawn|link|write|\bdump\s*\(|builtins|importlib|\binput\b"
    r"|breakpoint|\bmode\s*=|\\|\bdel\b|\blambda\b|\bclass\b|\bdef\b|\bwith\b")
OS_OK = re.compile(r"\bos\b(?!\s*\.\s*(?:path\s*\.|environ\b|getenv\b))")
SYS_OK = re.compile(r"\bsys\b(?!\s*\.\s*(?:argv|stdin|exit|version|platform)\b)")
OPEN_OK = re.compile(r"open\s*\(\s*(?:[^(),]|\([^()]*\))+?(?:,\s*['\"]rb?['\"]\s*)?\)")

def code_lecture_seule(code):
    # Non-ASCII : Python normalise les identifiants en NFKC (ｏｐｅｎ == open). `*` : dépaquetage qui cache le mode.
    if not code.isascii() or "*" in code or INTERDIT.search(code):
        return False
    reste = IMPORT_STMT.sub("", code)
    if re.search(r"\bimport\b", reste) or OS_OK.search(reste) or SYS_OK.search(reste):
        return False
    for m in re.finditer(r"\bopen\b", reste):
        if reste[:m.start()].rstrip().endswith(".") or not OPEN_OK.match(reste, m.start()):
            return False
    return True

def lecture_inline(base, args):
    """Vrai pour `python[3] -c "<code>"` (rien d'autre) dont le code passe la liste blanche de lecture seule."""
    return bool(re.fullmatch(r"python[\d.]*", base)) and len(args) == 2 and args[0] == "-c" \
        and code_lecture_seule(args[1])

def sous_commande_git(args):
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in GIT_OPT_VALEUR else 1
    return args[i] if i < len(args) else ""

def script_du_plugin(t):
    """Vrai pour un script réellement situé sous ~/.claude/plugins (`..` et liens résolus) et sans autre chemin protégé."""
    t = developpe(t)
    racine = os.path.realpath(os.path.join(os.path.expanduser("~"), ".claude", "plugins")) + os.sep
    return not t.startswith("-") and os.path.realpath(t).startswith(racine) and \
        not any(m in t for m in MOTIFS if m != ".claude/plugins")

def ecriture_protegee(toks):
    """Le premier argument protégé d'un segment qui écrit (écrivain connu), sinon None."""
    base, args = toks[0].rsplit("/", 1)[-1], toks[1:]
    if base == "claude" and args[:1] == ["plugin"] and (
            args[1:2] in (["disable"], ["uninstall"]) or args[1:3] == ["marketplace", "remove"]):
        return " ".join(toks)
    if base == "git":
        ecrit = sous_commande_git(args) in GIT_ECRIT
    elif base == "sed":
        ecrit = any(a.startswith("--in-place") or re.match(r"^-[A-Za-z]*i", a) for a in args)
    elif base == "curl":
        ecrit = any(a.startswith("--output") or re.match(r"^-[A-Za-z]*o", a) for a in args)
    elif base == "wget":
        ecrit = any(a.startswith("--output-document") or re.match(r"^-[A-Za-z]*O", a) for a in args)
    elif base in ("awk", "gawk"):
        ecrit = "inplace" in args or any(a.startswith("-i") and "inplace" in a for a in args)
    elif base == "find":
        ecrit = any(a in ("-delete", "-exec", "-execdir", "-ok", "-okdir") for a in args)
    else:
        ecrit = base in ECRIVAINS or bool(INTERPRETES.fullmatch(base))
        if ecrit and base not in ECRIVAINS and lecture_inline(base, args):
            ecrit = False
        elif ecrit and base not in ECRIVAINS and args and script_du_plugin(args[0]):
            args = args[1:]  # script du plugin installé : exécuté, pas écrit ; ses arguments restent contrôlés
    return next((a for a in args if motif(a)), None) if ecrit else None

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

def risque(cmd):
    """Vrai si une commande illisible semble ajouter un paquet ou toucher un chemin protégé."""
    return bool(AJOUT.search(cmd)) or any(m in developpe(cmd) for m in MOTIFS)

def analyse(cmd, prof=0, ecritures=None):
    """[(registre, nom, version)] ajoutés par cmd, y compris dans les -c, sous-shells et substitutions.
    `ecritures` (liste) reçoit les chemins protégés visés par un écrivain ou une redirection."""
    if ecritures is None:
        ecritures = []
    if prof > PROFONDEUR_MAX:
        if risque(cmd):
            raise Illisible("imbrication trop profonde")
        return []
    out = []
    cmd, heredocs = retire_heredocs(cmd)
    cmd = sans_commentaires(cmd)
    try:
        corps = substitutions(cmd)
        for texte, shell, cite in heredocs:
            if shell:
                corps.append(texte)
            elif not cite:
                corps += substitutions(texte, apostrophes=False)
        segs = list(decoupe(jetons(cmd)))
    except (ValueError, Illisible) as e:
        if risque(cmd):
            raise Illisible(f"commande non analysable ({e}) qui semble ajouter un paquet ou toucher un chemin protégé")
        return []
    for c in corps:
        out += analyse(c, prof + 1, ecritures)
    for toks, cibles in segs:
        ecritures += [c for c in cibles if motif(c)]
        try:
            toks = sans_prefixe(toks)
        except Illisible:
            if risque(cmd):
                raise
            continue
        if not toks:
            continue
        out += paquets(toks)
        cible = ecriture_protegee(toks)
        if cible:
            ecritures.append(cible)
        sh = appel_shell(toks)
        if sh and sh[0] == "c":
            out += analyse(sh[1], prof + 1, ecritures)
        elif sh and AJOUT.search(cmd):
            raise Illisible("script passé à un shell par stdin, non analysable, dans une commande qui semble ajouter un paquet")
    return out

# ---------- extraction des paquets ----------

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

def module_python(toks):
    """[module, args…] de `python -m module args` ou `python -mmodule args` (options avant -m sautées), sinon None."""
    i = 1
    while i < len(toks):
        t = toks[i]
        if t == "-m":
            return toks[i + 1:]
        if t.startswith("-m"):
            return [t[2:]] + toks[i + 1:]
        if not t.startswith("-"):
            return None
        i += 2 if t in ("-X", "-W") else 1
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
    elif (base == "npm" and sc in ("install", "i", "add")) or (base in ("pnpm", "yarn") and sc == "add") \
            or (base == "yarn" and toks[1:3] == ["global", "add"]):
        for t in arguments(toks[3:] if sc == "global" else toks[2:], SAUTE["npm"]):
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
            r = pep508(t)
            if r:
                res.append(("pypi",) + r)
    return res

def tous_paquets(cmd, ecritures=None):
    return list(dict.fromkeys(analyse(cmd, ecritures=ecritures)))

def exceptions_du_depot(cwd):
    """Lit `.garde-deps-exceptions` dans le dossier contenant `.git` le plus proche de cwd (sinon rien)."""
    d = os.path.abspath(cwd or os.getcwd())
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            try:
                with open(os.path.join(d, ".garde-deps-exceptions"), encoding="utf-8") as f:
                    return lit_exceptions(f.read())
            except OSError:
                return [], []
        if os.path.dirname(d) == d:
            return [], []
        d = os.path.dirname(d)

ECRITURE_FICHIER = {"Edit", "Write", "MultiEdit", "NotebookEdit"}

def refuse_protege(chemin):
    print(f"⛔ Bloqué par garde-deps : écriture vers un chemin protégé ({chemin}) : réglages Claude, hooks, plugins, "
          "workflows CI, .garde-deps-exceptions et .garde-secret-exceptions.\nDemande à l'utilisateur de faire cette modification lui-même.",
          file=sys.stderr)
    sys.exit(2)

def main():
    data = json.load(sys.stdin)
    ti = data.get("tool_input") or {}
    if data.get("tool_name", "Bash") in ECRITURE_FICHIER:
        chemin = ti.get("file_path") or ti.get("notebook_path") or ""
        if chemin and protege(chemin, data.get("cwd")):
            refuse_protege(chemin)
        sys.exit(0)
    cmd = ti.get("command", "")
    ecritures = []
    try:
        pqs = tous_paquets(cmd, ecritures)
    except Illisible as e:
        print(f"⛔ Bloqué par garde-deps : {e}.\nReformule la commande plus simplement (une commande par appel, "
              "sans imbrication) ou demande à l'utilisateur d'ajouter lui-même le paquet.", file=sys.stderr)
        sys.exit(2)
    if ecritures:
        refuse_protege(ecritures[0])
    if not pqs:
        sys.exit(0)
    exceptions, avert = exceptions_du_depot(data.get("cwd"))
    blocs = []
    for registre, nom, exact in pqs:
        examine(registre, nom, exact, blocs, avert, exceptions=exceptions)
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
