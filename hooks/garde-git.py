#!/usr/bin/env python3
"""Hook PreToolUse (Bash) : bloque les commandes git/gh dangereuses.
Sortie 2 + message sur stderr = commande refusée, raison renvoyée à Claude."""
import json, os, re, shlex, subprocess, sys

PROTEGEES = {"main", "master"}
PROPRIETAIRES_TICKETS = {"stanixia-dev"}  # comptes dont les dépôts sont admis pour -R (create/comment/edit)

def bloque(raison):
    print(f"⛔ Bloqué par garde-git : {raison}", file=sys.stderr)
    sys.exit(2)

def branche_courante(cwd):
    try:
        return subprocess.run(["git", "symbolic-ref", "--short", "-q", "HEAD"], cwd=cwd,
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""

def resout(base, chemin):
    """Résout un chemin (cd / -C) par rapport au dossier courant suivi."""
    if not chemin or chemin == "-":
        return base
    return os.path.normpath(os.path.join(base or os.getcwd(), os.path.expanduser(chemin)))

def dossier_git(toks, cwd):
    """Dossier visé par `-C a -C b …` (cumulatif, comme git)."""
    i = 1
    while i < len(toks) and toks[i].startswith("-"):
        if toks[i] == "-C" and i + 1 < len(toks):
            cwd = resout(cwd, toks[i + 1])
        i += 2 if toks[i] in ("-C", "-c", "--git-dir", "--work-tree") else 1
    return cwd

def branche_cible(dossier):
    """Branche du dossier visé ; s'il n'est pas lisible, on retombe sur le cwd de session."""
    b = branche_courante(dossier) if dossier and os.path.isdir(dossier) else ""
    return b or branche_courante(CWD_SESSION)

# options qui consomment la valeur suivante, par préfixe
PREFIXES_VALEURS = {
    "env": {"-u", "-C", "-S", "--unset", "--chdir", "--split-string"},
    "timeout": {"-k", "-s", "--kill-after", "--signal"},
    "nice": {"-n", "--adjustment"},
    "xargs": {"-n", "-I", "-L", "-P", "-s", "-E", "-d", "-a", "-J", "--max-args", "--max-procs", "--delimiter", "--arg-file"},
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-r", "-t", "-U", "-T", "-D", "-R"},
    "stdbuf": {"-i", "-o", "-e"},
    "command": set(), "exec": {"-a"}, "time": set(), "nohup": set(),
    "setsid": set(), "unbuffer": set(), "chrt": set(), "taskset": set(),
    "ionice": {"-c", "-n", "-p", "-P", "-u", "-t"}, "doas": {"-u", "-C"},
    "flock": {"-w", "-E", "--timeout", "--conflict-exit-code"}, "watch": {"-n", "-d", "--interval"},
}
PREFIXES_POSITIONNEL = {"timeout", "chrt", "taskset", "flock"}  # un argument positionnel avant la commande

def saute_prefixes(toks):
    """Retire VAR=val et les préfixes (env, timeout, nice, xargs, sudo, stdbuf…) ; renvoie (toks, affecte)."""
    affecte = False
    while toks:
        t = toks[0]
        nom = t.rsplit("/", 1)[-1]
        if re.match(r"^\w+=", t):
            affecte = True
            toks = toks[1:]
        elif nom in PREFIXES_VALEURS:
            if nom == "env":
                affecte = True
            valeurs = PREFIXES_VALEURS[nom]
            toks = toks[1:]
            while toks and (toks[0].startswith("-") or (nom == "env" and re.match(r"^\w+=", toks[0]))):
                toks = toks[2:] if toks[0] in valeurs else toks[1:]
            if nom in PREFIXES_POSITIONNEL and toks:  # durée, priorité, masque, fichier
                toks = toks[1:]
            if nom == "flock" and toks and toks[0] in ("-c", "--command"):
                toks = ["sh"] + toks  # flock f -c 'chaîne' : exécuteur de chaîne
            elif nom == "watch" and toks:
                toks = ["sh", "-c", " ".join(toks)]  # watch passe par sh -c
        elif nom == "rtk" or (t in ("bypass", "proxy") and len(toks) > 1):
            toks = toks[1:]
        else:
            break
    return toks, affecte

def aplatit(cmd):
    """Transforme $( ), backticks et parenthèses (hors guillemets) en séparateurs `;`.
    `\\x` hors guillemets simples est littéral ; le corps d'un heredoc à délimiteur entre guillemets est ignoré."""
    out, q, i, delim, subst = [], None, 0, None, False
    while i < len(cmd):
        c = cmd[i]
        if q != "'" and c == "\\":
            out.append(cmd[i:i + 2]); i += 2; continue
        if q is None or (q == '"' and subst):
            m = re.match(r"<<-?\s*(['\"])(\w+)\1", cmd[i:])
            if m:
                delim = (m.group(2), cmd[i:].startswith("<<-"))
                out.append(m.group(0)); i += len(m.group(0)); continue
        if c == "\n" and delim:
            lignes = cmd[i + 1:].split("\n")
            n = 0
            while n < len(lignes) and (lignes[n].strip() if delim[1] else lignes[n]) != delim[0]:
                n += 1
            out.append("\n")
            i += 1 + sum(len(l) + 1 for l in lignes[:n + 1])
            delim = None
            continue
        if q != "'" and cmd.startswith("$(", i):
            out.append("$;"); i += 2; subst = True; continue  # garde le `$` (vu par gh api graphql)
        if q != "'" and c == "`":
            out.append("`;")
        elif q is None and c in "()":
            out.append(";")
        else:
            out.append(c)
            if q is None and c in "'\"":
                q = c
            elif q == c:
                q = None
        i += 1
    return "".join(out)

def segments(cmd):
    # Découpe sur ; && || | & et retours ligne (approximatif mais suffisant)
    for seg in re.split(r"\|\||&&|[;|&\n]", aplatit(cmd)):
        seg = seg.rstrip()
        if seg.endswith("\\"):
            seg = seg[:-1]  # `\;` de find -exec (le `;` a servi de séparateur)
        try:
            toks = shlex.split(seg)
        except ValueError:
            toks = seg.split()
        toks, affecte = saute_prefixes(toks)
        if toks:
            yield toks, affecte

def commande_interne(toks):
    """eval … ou bash|sh|zsh|dash -c/-lc … : renvoie la chaîne à ré-analyser (ou None)."""
    base = toks[0].rsplit("/", 1)[-1]
    if base == "eval":
        return " ".join(toks[1:])
    if base in ("bash", "sh", "zsh", "dash"):
        for k, t in enumerate(toks[1:], 1):
            if re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", t):
                return toks[k + 1] if k + 1 < len(toks) else None
    return None

def sous_commande(toks):
    """Pour git : retire les options globales (-C x, -c x, --no-pager…)."""
    i = 1
    while i < len(toks) and toks[i].startswith("-"):
        i += 2 if toks[i] in ("-C", "-c", "--git-dir", "--work-tree") else 1
    return toks[i] if i < len(toks) else "", toks[i + 1:]

def refuse_affectation(base, sc, affecte):
    """git push et gh portent les identifiants de l'utilisateur : une affectation (GIT_SSH_COMMAND…) ferait exécuter du code avec eux."""
    if affecte and (base == "gh" or (base == "git" and sc == "push")):
        bloque(f"`{base}{' push' if base == 'git' else ''}` précédé d'une affectation de variable (VAR=… ou env VAR=…) est interdit : "
               "cette commande porte les identifiants de l'utilisateur et la variable (ex. GIT_SSH_COMMAND) pourrait exécuter du code.")

def verifie_git(args_sc, sc, cwd):
    if sc == "push":
        for a in args_sc:
            nom = a.split("=", 1)[0]
            # git accepte les abréviations d'options longues (--rec, --exe…) : préfixe d'au moins 3 caractères
            if len(nom) >= 5 and nom.startswith("--") and ("--receive-pack".startswith(nom) or "--exec".startswith(nom)):
                bloque(f"`git push {a}` est interdit : le programme désigné s'exécuterait en local.")
        pos = [a for a in args_sc if not a.startswith("-")]
        depots = [a.split("=", 1)[1] for a in args_sc if a.startswith("--repo=")]
        if "--repo" in args_sc and args_sc.index("--repo") + 1 < len(args_sc):
            depots.append(args_sc[args_sc.index("--repo") + 1])
        depots += pos[:1]
        for d in depots:
            if re.match(r"^(https://|ssh://|git@[^:/\s]+:)", d):
                continue
            if d.startswith(("file://", "ext::", "~", ".")) or "/" in d or ":" in d or os.path.exists(os.path.join(cwd or "", d)):
                bloque(f"`git push {d}` est interdit : seuls un nom de remote ou une URL https/ssh sont admis "
                       "(les hooks d'un dépôt cible local s'exécuteraient en local).")
        for a in args_sc:
            if a in ("--force", "-f", "--force-with-lease", "--force-if-includes", "--mirror", "--delete", "-d", "--no-verify", "--prune") \
               or a.startswith("--force-with-lease=") or (re.match(r"^-[a-zA-Z]+$", a) and "f" in a):
                bloque(f"`git push {a}` est interdit (force/suppression/contournement des hooks).")
        refs = [a for a in args_sc if not a.startswith("-")][1:]  # après le remote
        for r in refs:
            if r.startswith("+"):
                bloque("push forcé via refspec `+…` interdit.")
            if r.startswith(":"):
                bloque("suppression de branche distante interdite.")
            cible = r.split(":")[-1].removeprefix("refs/heads/")
            if cible in PROTEGEES:
                bloque(f"push vers `{cible}` interdit : passe par une branche claude/<sujet> et une PR.")
        if not refs and branche_cible(cwd) in PROTEGEES:
            bloque("tu es sur main : push interdit, crée une branche claude/<sujet>.")
    elif sc == "commit":
        i = 0
        while i < len(args_sc):
            a = args_sc[i]
            if a in ("-m", "-F", "-C", "-c", "--author", "--date", "--fixup", "--squash"):
                i += 2; continue
            if a == "--no-verify" or (re.match(r"^-[a-zA-Z]+$", a) and "n" in a and not a.startswith("-m")):
                bloque("`git commit --no-verify` / `-n` interdit.")
            i += 1
        if branche_cible(cwd) in PROTEGEES:
            bloque("commit directement sur main interdit : crée une branche claude/<sujet>.")

def verifie_gh(toks):
    t = toks[1:]
    j = " ".join(t)
    regles = [
        (r"^pr merge\b", "fusionner une PR est réservé à l'utilisateur."),
        (r"^pr review\b.*(--approve|-a\b)", "approuver une PR est interdit."),
        (r"^pr close\b", "fermer une PR est réservé à l'utilisateur."),
        (r"^repo (delete|edit|archive|rename)\b", "modifier/supprimer un dépôt est interdit."),
        (r"^repo set-default\b", "changer le dépôt par défaut de gh est interdit (les tickets viseraient un autre dépôt)."),
        (r"^alias (set|import)\b", "définir un alias gh est interdit (contourne les contrôles)."),
        (r"^release delete\b", "supprimer une release est interdit."),
        (r"^secret\b", "gérer les secrets GitHub est interdit."),
        (r"^variable (set|delete)\b", "modifier les variables GitHub est interdit."),
    ]
    for motif, raison in regles:
        if re.search(motif, j, re.IGNORECASE):
            bloque(raison)
    if t and t[0] == "api":
        verifie_api(t[1:])
    if t and t[0] == "issue":
        verifie_issue(t[1:])

API_VALEURS_LONGUES = {"--header", "--preview", "--jq", "--template", "--cache", "--hostname", "--method",
                       "--field", "--raw-field", "--input"}
API_VALEURS_COURTES = "HpqtXfF"
API_ENDPOINT_MILESTONE = r"repos/(\{owner\}|[\w.-]+)/(\{repo\}|[\w.-]+)/milestones(/\d+)?"

def verifie_api(args):
    """Liste blanche : lecture libre, écriture limitée aux milestones (POST …/milestones, PATCH …/milestones/<n>)."""
    pos, methode, champ, fichier, hote = [], None, False, False, None
    i = 0
    while i < len(args):
        a = args[i]
        opts = []  # (option, valeur)
        if a.startswith("--"):
            nom, eq, val = a.partition("=")
            if nom in API_VALEURS_LONGUES:
                if not eq:
                    val = args[i + 1] if i + 1 < len(args) else ""
                    i += 1
                opts.append((nom, val))
        elif a.startswith("-") and len(a) > 1:
            for k in range(1, len(a)):
                if a[k] in API_VALEURS_COURTES:
                    val = a[k + 1:]
                    if not val:
                        val = args[i + 1] if i + 1 < len(args) else ""
                        i += 1
                    opts.append(("-" + a[k], val))
                    break
        else:
            pos.append(a)
        i += 1
        for nom, val in opts:
            if nom in ("-X", "--method"):
                methode = val.upper()
            elif nom == "--hostname":
                hote = val
            elif nom == "--input":
                champ = fichier = True
            elif nom in ("-f", "--raw-field"):
                champ = True
            elif nom in ("-F", "--field"):
                champ = True
                if val.partition("=")[2].startswith("@"):
                    fichier = True
    if fichier:
        bloque("gh api : lire un fichier local (--input, -F clé=@fichier) est interdit.")
    if hote is not None and hote.lower() != "github.com":
        bloque("gh api : --hostname autre que github.com interdit.")
    if len(pos) != 1 or "://" in pos[0]:
        bloque("gh api : un seul endpoint relatif est admis (pas d'URL).")
    endpoint = pos[0].lstrip("/")
    if endpoint == "graphql":
        if any("$" in x or "`" in x for x in args):
            bloque("gh api graphql : `$` et les backticks sont interdits (expansion shell : une mutation pourrait être masquée) ; écris la requête en littéral.")
        if any(re.search(r"\bmutation\b", a, re.IGNORECASE) for a in args):
            bloque("gh api graphql : les mutations sont interdites.")
        return
    methode = methode or ("POST" if champ else "GET")
    if methode in ("GET", "HEAD"):
        return
    if not re.fullmatch(API_ENDPOINT_MILESTONE, endpoint) or any(sg in (".", "..") for sg in endpoint.split("/")) \
       or methode not in ("POST", "PATCH") or (methode == "POST") == bool(re.search(r"/\d+$", endpoint)):
        bloque("gh api en écriture : seuls POST …/milestones et PATCH …/milestones/<n> sont admis.")

def depot_admis(depot):
    """`<proprio>/<nom>` exact, proprio dans PROPRIETAIRES_TICKETS (casse ignorée)."""
    parts = depot.split("/")
    return len(parts) == 2 and parts[0].lower() in PROPRIETAIRES_TICKETS \
        and re.fullmatch(r"[\w.-]+", parts[1]) is not None and parts[1] not in (".", "..")

def verifie_issue(args):
    """Allowlist : lecture, création, commentaire et milestone ; le reste est réservé à l'utilisateur."""
    sc, idx, i = "", -1, 0
    while i < len(args):
        a = args[i]
        if a in ("-R", "--repo"):
            i += 2; continue
        if not a.startswith("-"):
            sc, idx = a, i; break
        i += 1
    if sc not in ("view", "list", "ls", "status", "create", "new", "comment", "edit"):
        bloque("fermer, modifier ou supprimer un ticket est réservé à l'utilisateur.")
    if sc in ("create", "new", "comment", "edit"):
        i = 0
        while i < len(args):
            a = args[i]
            nom = a.split("=", 1)[0]
            depot = None
            if a == "-R" or nom == "--repo":
                if nom == "--repo" and "=" in a:
                    depot = a.split("=", 1)[1]
                else:
                    depot = args[i + 1] if i + 1 < len(args) else ""
                    i += 1
            elif a.startswith("-R"):
                depot = a[2:]
            elif re.match(r"^-[A-Za-z]+R", a):
                bloque("ticket hors du dépôt courant interdit (-R/--repo).")
            if depot is not None:
                if not depot_admis(depot):
                    bloque("ticket hors du dépôt courant interdit (-R/--repo), sauf <" + "|".join(sorted(PROPRIETAIRES_TICKETS)) + ">/<dépôt>.")
                i += 1; continue
            if nom in ("--edit-last", "--delete-last"):
                bloque(f"`gh issue {sc} {a}` interdit : modifier ou supprimer un commentaire est réservé à l'utilisateur.")
            if sc in ("create", "new") and nom in ("--parent", "--blocking", "--blocked-by"):
                bloque(f"`gh issue {sc} {nom}` interdit : lier un ticket d'un autre dépôt est réservé à l'utilisateur.")
            if "://" in a or a.lower().startswith("github.com/"):
                bloque("ticket hors du dépôt courant interdit (une URL vise un autre dépôt).")
            i += 1
    if sc == "edit":
        rest, milestone, i = args[idx + 1:], False, 0
        while i < len(rest):
            a = rest[i]
            if re.fullmatch(r"\d+", a):
                pass
            elif a in ("-m", "--milestone"):
                milestone = True; i += 1
            elif a == "--remove-milestone" or a.startswith(("--milestone=", "-m")):
                milestone = True
            elif a in ("-R", "--repo"):
                i += 1
            elif a.startswith(("-R", "--repo=")):
                pass
            else:
                bloque("gh issue edit : seul le milestone est modifiable.")
            i += 1
        if not milestone:
            bloque("gh issue edit : seul le milestone est modifiable (--milestone ou --remove-milestone requis).")

MOT_LIVRE = re.compile(r"\bgh\b|\bgit\s+push\b")

CMD_BRUT = ""

def est_executeur(toks):
    """eval, ou shell lancé avec -c/-lc, -s, une redirection << ou sans script (donc alimenté par stdin)."""
    base = toks[0].rsplit("/", 1)[-1]
    if base == "eval":
        return True
    if base in ("bash", "sh", "zsh", "dash"):
        pos = [t for t in toks[1:] if not t.startswith("-")]
        return commande_interne(toks) is not None or "-s" in toks or any(t.startswith("<<") for t in toks) or not pos \
            or any(re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", t) for t in toks[1:])
    return False

def verifie_segment(toks, affecte, cwd, profondeur):
    base = toks[0].rsplit("/", 1)[-1]
    if est_executeur(toks) and MOT_LIVRE.search(CMD_BRUT):
        # règle simple : le texte brut est contrôlé (heredocs compris), faux positifs admis (ex. bash -c 'echo gh')
        bloque("exécuteur de chaîne (eval, bash -c, shell sur stdin, watch, flock -c…) dans une commande contenant `gh` ou `git push` : "
               "lance la commande directement.")
    if base == "git":
        sc, args_sc = sous_commande(toks)
        refuse_affectation("git", sc, affecte)
        verifie_git(args_sc, sc, dossier_git(toks, cwd))
    elif base == "gh":
        refuse_affectation("gh", "", affecte)
        verifie_gh(toks)
    elif base == "find":
        for k, t in enumerate(toks):
            if t in ("-exec", "-execdir", "-ok", "-okdir"):
                reste = []
                for u in toks[k + 1:]:
                    if u in (";", "+", "\\;", "\\"):
                        break
                    reste.append(u)
                reste, aff = saute_prefixes(reste)
                if reste:
                    verifie_segment(reste, aff or affecte, cwd, profondeur)
    else:
        interne = commande_interne(toks)
        if interne:
            analyse(interne, cwd, profondeur + 1, affecte)  # eval / bash -c : mêmes règles

def analyse(cmd, cwd, profondeur, affecte_parent=False):
    if profondeur > 5:
        bloque("commandes imbriquées (eval / bash -c) trop profondes.")
    for toks, affecte in segments(cmd):
        base = toks[0].rsplit("/", 1)[-1]
        if base in ("cd", "pushd"):
            # suit les `cd <dossier> && …` (worktrees)
            cwd = resout(cwd, toks[1] if len(toks) > 1 else os.path.expanduser("~"))
            continue
        verifie_segment(toks, affecte or affecte_parent, cwd, profondeur)

CWD_SESSION = None

def main():
    global CWD_SESSION
    data = json.load(sys.stdin)
    cmd = (data.get("tool_input") or {}).get("command", "")
    cwd = CWD_SESSION = data.get("cwd") or None
    global CMD_BRUT
    CMD_BRUT = cmd
    segs = list(segments(cmd))
    livre = any((t[0].rsplit("/", 1)[-1] == "gh") or (t[0].rsplit("/", 1)[-1] == "git" and sous_commande(t)[0] == "push") for t, _ in segs)
    if livre and any(t[0] in ("export", "declare", "typeset") for t, _ in segs):
        bloque("`export`/`declare`/`typeset` dans la même commande qu'un `git push` ou un `gh` est interdit : "
               "la variable (ex. GIT_SSH_COMMAND) ferait exécuter du code avec les identifiants de l'utilisateur.")
    analyse(cmd, cwd, 0)
    sys.exit(0)

if __name__ == "__main__":
    main()
