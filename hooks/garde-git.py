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

# options globales de git qui consomment la valeur suivante (la forme `--opt=v` ne consomme rien)
GIT_GLOBALES_VALEUR = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env", "--attr-source"}

def dossier_git(toks, cwd):
    """Dossier visé par `-C a -C b …` (cumulatif, comme git)."""
    i = 1
    while i < len(toks) and toks[i].startswith("-"):
        if toks[i] == "-C" and i + 1 < len(toks):
            cwd = resout(cwd, toks[i + 1])
        i += 2 if toks[i] in GIT_GLOBALES_VALEUR else 1
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
    "command": set(), "exec": {"-a"}, "time": set(), "nohup": set(), "busybox": set(),
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
    `\\x` hors guillemets simples est littéral ; un commentaire `# …` est copié tel quel ; le corps d'un heredoc
    à délimiteur entre guillemets est copié tel quel (`$(` et backticks y sont littéraux) mais reste analysé ligne à ligne."""
    out, q, i, delim, prof = [], None, 0, None, 0  # prof = nombre de `$(` encore ouverts
    while i < len(cmd):
        c = cmd[i]
        if q != "'" and c == "\\":
            out.append(cmd[i:i + 2]); i += 2; continue
        if q is None and c == "#" and (i == 0 or cmd[i - 1] in " \t\n;|&("):
            j = cmd.find("\n", i)
            j = len(cmd) if j < 0 else j
            out.append(cmd[i:j]); i = j; continue
        if (q is None or (q == '"' and prof > 0)) and cmd.startswith("<<", i) and (i == 0 or cmd[i - 1] != "<"):
            m = re.match(r"<<(-?)\s*(['\"])(\w+)\2", cmd[i:])
            if m:
                delim = (m.group(3), bool(m.group(1)))
                out.append(m.group(0)); i += len(m.group(0)); continue
        if c == "\n" and delim:
            lignes = cmd[i + 1:].split("\n")
            n = 0
            while n < len(lignes) and (lignes[n].strip() if delim[1] else lignes[n]) != delim[0]:
                n += 1
            corps = "\n".join(lignes[:n + 1])
            out.append("\n" + corps)
            i += 1 + len(corps)
            delim = None
            continue
        if q != "'" and cmd.startswith("$(", i):
            out.append("$;"); i += 2; prof += 1; continue  # garde le `$` (vu par gh api graphql)
        if q != "'" and c == "`":
            out.append("`;")
        elif q is None and c in "()":
            out.append(";")
            if c == ")" and prof:
                prof -= 1
        else:
            out.append(c)
            if c == ")" and prof and q != "'":
                prof -= 1
            if q is None and c in "'\"":
                q = c
            elif q == c:
                q = None
        i += 1
    return "".join(out)

SEPARATEURS = r"\|\||&&|[;|&\n]"

def _jetons(seg):
    seg = seg.rstrip()
    if seg.endswith("\\"):
        seg = seg[:-1]  # `\;` de find -exec (le `;` a servi de séparateur)
    try:
        toks = shlex.split(seg)
    except ValueError:
        toks = seg.split()
    return saute_prefixes(toks)

def segments(cmd):
    # Découpe sur ; && || | & et retours ligne (approximatif mais suffisant)
    for seg in re.split(SEPARATEURS, aplatit(cmd)):
        toks, affecte = _jetons(seg)
        if toks:
            yield toks, affecte

def decoupe_reelle(cmd):
    """Segments où les séparateurs entre guillemets, les commentaires et les corps de heredoc ne coupent pas : liste de
    textes, ou None si la commande ne peut pas être analysée sûrement (guillemet ouvert, heredoc mal formé, `$'`, `${`,
    backtick entre guillemets doubles…) : l'appelant garde alors le contrôle complet."""
    if re.search(r"\$['\"{]|`|\(\(", cmd):  # ANSI-C, ${ }, backticks, arithmétique : trop ambigus
        return None
    a = aplatit(cmd)
    segs, cur, q, pile, attente, i = [], [], None, [], [], 0
    def coupe():
        segs.append("".join(cur)); cur.clear()
    while i < len(a):
        c = a[i]
        if c == "\\" and q != "'":
            if q is None and a[i + 1:i + 2] in (";", "|", "&"):  # comme le découpage naïf : `\;` coupe (find -exec)
                cur.append(c); coupe(); i += 2; continue
            cur.append(a[i:i + 2]); i += 2; continue
        if q is None and c == "#" and (i == 0 or a[i - 1] in " \t\n;|&("):
            j = a.find("\n", i)
            i = len(a) if j < 0 else j
            continue
        if q != "'" and a.startswith(("$;", "`;"), i):
            if c == "`" and q == '"':
                return None
            if q == '"':
                pile.append(q); q = None
            cur.append(c); coupe(); i += 2
            continue
        if q is None and c == ")" and pile:
            q = pile.pop(); cur.append(c); i += 1; continue
        if q is None and a.startswith("<<<", i):
            cur.append("<<<"); i += 3; continue
        if q is None and a.startswith("<<", i):
            m = re.match(r"<<(-?)\s*(?:(['\"])(\w+)\2|(\w+))(?=[\s;&|<>)]|$)", a[i:])
            if not m:
                return None
            attente.append((m.group(3) or m.group(4), bool(m.group(1)), bool(m.group(2))))
            cur.append(m.group(0)); i += len(m.group(0)); continue
        if q is None and c in ";|&\n":
            if c == "\n" and attente:
                lignes = a[i + 1:].split("\n")
                pos = i + 1
                for delim, tiret, cite in attente:
                    n = 0
                    while n < len(lignes) and (lignes[n].strip() if tiret else lignes[n]) != delim:
                        n += 1
                    if n >= len(lignes):
                        return None
                    corps = "\n".join(lignes[:n])
                    if not cite:  # expansions `$( )` / backticks du corps : toujours des commandes
                        for morceau in re.split(r"\$;|`;", corps)[1:]:
                            segs.extend(re.split(SEPARATEURS, morceau))
                    pos += len("\n".join(lignes[:n + 1])) + 1
                    lignes = lignes[n + 1:]
                attente = []
                coupe(); i = pos - 1
                continue
            coupe(); i += 1
            continue
        if c in "'\"":
            if q is None:
                q = c
            elif q == c:
                q = None
        cur.append(c); i += 1
    if q or pile or attente:
        return None
    coupe()
    return segs

def segments_reels(cmd):
    """Liste de (jetons, affectation) des vraies commandes, ou None si non analysable."""
    segs = decoupe_reelle(cmd)
    if segs is None:
        return None
    res = []
    for seg in segs:
        toks, affecte = _jetons(seg)
        if toks:
            res.append((toks, affecte))
    return res

def commande_interne(toks):
    """eval … ou bash|sh|zsh|dash|ksh -c/-lc … : renvoie la chaîne à ré-analyser (ou None)."""
    base = toks[0].rsplit("/", 1)[-1]
    if base == "eval":
        return " ".join(toks[1:])
    if base in ("bash", "sh", "zsh", "dash", "ksh"):
        for k, t in enumerate(toks[1:], 1):
            if re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", t):
                return toks[k + 1] if k + 1 < len(toks) else None
    return None

def sous_commande(toks):
    """Pour git : retire les options globales (-C x, -c x, --no-pager…)."""
    i = 1
    while i < len(toks) and toks[i].startswith("-"):
        i += 2 if toks[i] in GIT_GLOBALES_VALEUR else 1
    return toks[i] if i < len(toks) else "", toks[i + 1:]

def globales_git(toks):
    """Options globales de git (avant la sous-commande) sous forme de couples (option, valeur ou "")."""
    out, i = [], 1
    while i < len(toks) and toks[i].startswith("-"):
        nom, eq, val = toks[i].partition("=")
        if toks[i] in GIT_GLOBALES_VALEUR:
            out.append((toks[i], toks[i + 1] if i + 1 < len(toks) else ""))
            i += 2
        else:
            out.append((nom, val))
            i += 1
    return out

def verifie_globales(toks, sc):
    for nom, val in globales_git(toks):
        if nom in ("-c", "--config-env") and val.split("=", 1)[0].lower().startswith("alias."):
            bloque(f"`git {nom} {val}` interdit : un alias défini à la volée contourne les contrôles.")
        if sc == "push" and nom in ("-c", "--config-env", "--exec-path"):
            bloque("configuration à la volée devant `git push` interdite : elle peut exécuter du code avec les identifiants.")

def option_dangereuse(a, liste):
    """Option de `liste` visée par `a`, abréviation d'option longue comprise (git accepte --rec pour --receive-pack)."""
    nom = a.split("=", 1)[0]
    if nom.startswith("--") and len(nom) > 2:
        return next((o for o in liste if o.startswith(nom)), None)
    return None

def refuse_affectation(base, sc, affecte):
    """git push et gh portent les identifiants de l'utilisateur : une affectation (GIT_SSH_COMMAND…) ferait exécuter du code avec eux."""
    if affecte and (base == "gh" or (base == "git" and sc == "push")):
        bloque(f"`{base}{' push' if base == 'git' else ''}` précédé d'une affectation de variable (VAR=… ou env VAR=…) est interdit : "
               "cette commande porte les identifiants de l'utilisateur et la variable (ex. GIT_SSH_COMMAND) pourrait exécuter du code.")

PUSH_DANGEREUX = ["--force", "--force-with-lease", "--force-if-includes", "--mirror", "--delete", "--no-verify", "--prune",
                  "--all", "--branches", "--receive-pack", "--exec"]

def verifie_git(args_sc, sc, cwd):
    if sc == "push":
        for a in args_sc:
            o = option_dangereuse(a, PUSH_DANGEREUX)
            if o in ("--receive-pack", "--exec"):
                bloque(f"`git push {a}` est interdit : le programme désigné s'exécuterait en local.")
        pos, i = [], 0  # positionnels (remote, refspecs), sans les valeurs des options qui en prennent une
        while i < len(args_sc):
            a = args_sc[i]
            if a in ("-o", "--push-option", "--repo", "--receive-pack", "--exec") or re.fullmatch(r"-[a-zA-Z]*o", a):
                i += 2; continue
            if not a.startswith("-"):
                pos.append(a)
            i += 1
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
            o = option_dangereuse(a, PUSH_DANGEREUX)
            if o in ("--all", "--branches"):
                bloque(f"`git push {a}` est interdit : pousse toutes les branches, main comprise.")
            if o or a in ("-f", "-d") or (re.match(r"^-[a-zA-Z]+$", a) and re.match(r"^[^o]*[fd]", a[1:])):
                bloque(f"`git push {a}` est interdit (force/suppression/contournement des hooks).")
        refs = pos[1:]  # après le remote
        for r in refs:
            if r.startswith("+"):
                bloque("push forcé via refspec `+…` interdit.")
            if r.startswith(":"):
                bloque("suppression de branche distante interdite.")
            if "*" in r:
                bloque("push d'une refspec avec `*` interdit : elle peut viser main.")
            cible = r.split(":")[-1].removeprefix("refs/heads/")
            if cible in ("HEAD", "@"):
                cible = branche_cible(cwd)
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
            if option_dangereuse(a, ["--no-verify"]) or (re.match(r"^-[a-zA-Z]+$", a) and re.match(r"^[^mFCct]*n", a[1:])):
                bloque("`git commit --no-verify` / `-n` interdit.")
            i += 1
        if branche_cible(cwd) in PROTEGEES:
            bloque("commit directement sur main interdit : crée une branche claude/<sujet>.")

def lectures_gh(args, valeurs=("-R", "--repo")):
    """Lectures possibles d'une ligne `gh` : liste de (mots, reste, pos0). `mots` = les 2 premiers jetons positionnels,
    `reste` = les autres jetons, `pos0` = indice du 1er mot dans `args`. Avant le 2e mot, une option sans `=` peut ou non
    consommer le jeton suivant (gh accepte `--body x`) : on énumère les deux (jusqu'à 6 options, au-delà aucune consommation) ;
    les options de `valeurs` consomment toujours."""
    res = []
    def rec(i, mots, reste, pos0, libres):
        while i < len(args):
            a = args[i]
            if a.startswith("-"):
                suite = i + 1 < len(args)
                if suite and a in valeurs:
                    reste = reste + [a, args[i + 1]]; i += 2; continue
                if suite and "=" not in a and len(mots) < 2 and libres < 6:
                    rec(i + 2, mots, reste + [a, args[i + 1]], pos0, libres + 1)  # l'option consomme le jeton suivant
                    libres += 1
                reste = reste + [a]
            elif len(mots) < 2:
                mots = mots + [a]
                pos0 = i if pos0 < 0 else pos0
            else:
                reste = reste + [a]
            i += 1
        res.append((mots, reste, pos0))
    rec(0, [], [], -1, 0)
    return res

def verifie_gh(toks):
    for mots, reste, pos0 in lectures_gh(toks[1:]):
        verifie_gh_lecture(toks[1:], mots, reste, pos0)

def verifie_gh_lecture(t, mots, reste, pos0):
    j = " ".join(mots + reste)
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
    if mots and mots[0] in ("api", "issue") and (API_CONTROLE or mots[0] != "api"):
        (verifie_api if mots[0] == "api" else verifie_issue)(t[:pos0] + t[pos0 + 1:])  # sans le jeton api/issue

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
API_CONTROLE = True  # faux : le segment n'est que du texte (guillemets, heredoc, commentaire), `gh api` n'y est pas exécuté

def est_executeur(toks):
    """eval, ou shell lancé avec -c/-lc, -s, une redirection << ou sans script (donc alimenté par stdin)."""
    base = toks[0].rsplit("/", 1)[-1]
    if base == "eval":
        return True
    if base in ("bash", "sh", "zsh", "dash", "ksh"):
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
        verifie_globales(toks, sc)
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
    global API_CONTROLE
    reels = segments_reels(cmd) if profondeur == 0 else None  # None : non analysable ou commande interne, tout est contrôlé
    cles = {tuple(t) for t, _ in reels} if reels is not None else None
    vus = set()
    for toks, affecte in segments(cmd):
        base = toks[0].rsplit("/", 1)[-1]
        if base in ("cd", "pushd"):
            # suit les `cd <dossier> && …` (worktrees)
            cwd = resout(cwd, toks[1] if len(toks) > 1 else os.path.expanduser("~"))
            continue
        vus.add(tuple(toks))
        API_CONTROLE = cles is None or tuple(toks) in cles
        verifie_segment(toks, affecte or affecte_parent, cwd, profondeur)
    API_CONTROLE = True
    for toks, affecte in reels or []:  # vraies commandes `gh` que le découpage naïf a coupées (guillemets contenant ; | &)
        if tuple(toks) not in vus and toks[0].rsplit("/", 1)[-1] == "gh":
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
