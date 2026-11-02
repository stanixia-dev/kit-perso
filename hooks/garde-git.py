#!/usr/bin/env python3
"""Hook PreToolUse (Bash) : bloque les commandes git/gh dangereuses.
Sortie 2 + message sur stderr = commande refusée, raison renvoyée à Claude."""
import json, os, re, shlex, subprocess, sys

PROTEGEES = {"main", "master"}

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

def segments(cmd):
    # Découpe sur ; && || | et retours ligne (approximatif mais suffisant)
    for seg in re.split(r"\|\||&&|[;|\n]", cmd):
        try:
            toks = shlex.split(seg)
        except ValueError:
            toks = seg.split()
        # saute les affectations VAR=val et les préfixes courants (en notant s'il y en a eu)
        affecte = False
        while toks and (re.match(r"^\w+=", toks[0]) or toks[0] in ("env", "command", "exec", "time", "nohup")
                        or toks[0].rsplit("/", 1)[-1] == "rtk" or (toks[0] in ("bypass", "proxy") and len(toks) > 1)):
            affecte = affecte or bool(re.match(r"^\w+=", toks[0]))
            toks = toks[1:]
        if toks:
            yield toks, affecte

def sous_commande(toks):
    """Pour git : retire les options globales (-C x, -c x, --no-pager…)."""
    i = 1
    while i < len(toks) and toks[i].startswith("-"):
        i += 2 if toks[i] in ("-C", "-c", "--git-dir", "--work-tree") else 1
    return toks[i] if i < len(toks) else "", toks[i + 1:]

def refuse_affectation(base, sc, affecte):
    """git push et gh tournent hors du bac à sable : une affectation (GIT_SSH_COMMAND…) ferait exécuter du code non confiné."""
    if affecte and (base == "gh" or (base == "git" and sc == "push")):
        bloque(f"`{base}{' push' if base == 'git' else ''}` précédé d'une affectation de variable (VAR=… ou env VAR=…) est interdit : "
               "cette commande tourne hors du bac à sable et la variable (ex. GIT_SSH_COMMAND) pourrait exécuter du code.")

def verifie_git(args_sc, sc, cwd):
    if sc == "push":
        for a in args_sc:
            if a in ("--receive-pack", "--exec") or a.startswith(("--receive-pack=", "--exec=")):
                bloque(f"`git push {a}` est interdit : le programme désigné s'exécuterait en local, hors du bac à sable.")
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
        (r"^release delete\b", "supprimer une release est interdit."),
        (r"^secret\b", "gérer les secrets GitHub est interdit."),
        (r"^variable (set|delete)\b", "modifier les variables GitHub est interdit."),
        (r"^api\b.*(-X|--method)[ =]?(DELETE|PUT|PATCH)\b", "appel gh api en écriture/suppression interdit."),
    ]
    for motif, raison in regles:
        if re.search(motif, j, re.IGNORECASE):
            bloque(raison)

CWD_SESSION = None

def main():
    global CWD_SESSION
    data = json.load(sys.stdin)
    cmd = (data.get("tool_input") or {}).get("command", "")
    cwd = CWD_SESSION = data.get("cwd") or None
    for toks, affecte in segments(cmd):
        base = toks[0].rsplit("/", 1)[-1]
        if base in ("cd", "pushd"):
            # suit les `cd <dossier> && …` (worktrees)
            cwd = resout(cwd, toks[1] if len(toks) > 1 else os.path.expanduser("~"))
        elif base == "git":
            sc, args_sc = sous_commande(toks)
            refuse_affectation("git", sc, affecte)
            verifie_git(args_sc, sc, dossier_git(toks, cwd))
        elif base == "gh":
            refuse_affectation("gh", "", affecte)
            verifie_gh(toks)
        elif base in ("bash", "sh", "zsh") and "-c" in toks:
            # sous-shell : on analyse la commande passée à -c
            k = toks.index("-c")
            if k + 1 < len(toks):
                for sub, aff in segments(toks[k + 1]):
                    b = sub[0].rsplit("/", 1)[-1]
                    if b == "git":
                        sc, a = sous_commande(sub); refuse_affectation("git", sc, aff); verifie_git(a, sc, dossier_git(sub, cwd))
                    elif b == "gh":
                        refuse_affectation("gh", "", aff); verifie_gh(sub)
    sys.exit(0)

if __name__ == "__main__":
    main()
