#!/usr/bin/env python3
"""Archive la mémoire automatique de Claude Code dans un dossier frère `historique/`.

Usage : archiver-memoire.py [--memoire DIR] [--projet DIR] [--date AAAA-MM-JJ]
Copie `memory/` vers `historique/<date>-memoire/` (suffixe -2, -3… si elle existe),
signale les lignes d'index et les fichiers trop gros. Ne modifie jamais `memory/`.
Codes : 0 ok, 1 aucune mémoire, 2 refus ou erreur.
"""
import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys

MAX_LIGNE = 150
MAX_OCTETS = 3072


def refus(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


def racine_projet(projet):
    projet = os.path.realpath(projet)
    try:
        r = subprocess.run(
            ["git", "-C", projet, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            return os.path.dirname(os.path.realpath(r.stdout.strip()))
    except (OSError, subprocess.SubprocessError):
        pass
    return projet


def dossier_memoire(projet):
    racine = racine_projet(projet)
    nom = re.sub(r"[^A-Za-z0-9]", "-", racine)
    return os.path.join(os.path.expanduser("~"), ".claude", "projects", nom, "memory")


def fichiers(memoire):
    """Fichiers ordinaires de la mémoire (récursif), chemins relatifs triés."""
    res = []
    for dossier, _, noms in os.walk(memoire):
        for n in noms:
            p = os.path.join(dossier, n)
            if os.path.isfile(p) and not os.path.islink(p):
                res.append(os.path.relpath(p, memoire))
    return sorted(res)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--memoire")
    ap.add_argument("--projet", default=os.getcwd())
    ap.add_argument("--date")
    a = ap.parse_args()

    date = a.date or datetime.date.today().isoformat()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        refus(f"--date mal formée : {date}")
    try:
        datetime.date.fromisoformat(date)
    except ValueError:
        refus(f"--date mal formée : {date}")

    m = os.path.abspath(a.memoire) if a.memoire else dossier_memoire(a.projet)
    if os.path.basename(m) != "memory":
        refus(f"le dossier mémoire doit s'appeler « memory » : {m}")

    liste = fichiers(m) if os.path.isdir(m) else []
    if not liste:
        print(f"aucune mémoire à {m}", file=sys.stderr)
        sys.exit(1)

    hist = os.path.join(os.path.dirname(m), "historique")
    base = os.path.join(hist, f"{date}-memoire")
    cible, n = base, 1
    while os.path.lexists(cible):
        n += 1
        cible = f"{base}-{n}"
    try:
        os.makedirs(hist, exist_ok=True)
        shutil.copytree(m, cible, symlinks=True)
    except OSError as e:
        refus(f"échec d'écriture : {e}")

    sortie = [f"Mémoire : {m}", f"Archive : {cible} ({len(liste)} fichiers)"]
    signal = []
    index = os.path.join(m, "MEMORY.md")
    if os.path.isfile(index):
        with open(index, encoding="utf-8", errors="replace") as f:
            for i, l in enumerate(f.read().split("\n"), 1):
                l = l.rstrip("\r")
                if len(l) > MAX_LIGNE:
                    signal.append(f"Ligne d'index trop longue : MEMORY.md:{i} ({len(l)} caractères) « {l[:60]}… »")
    else:
        signal.append("MEMORY.md absent")
    for r in liste:
        o = os.path.getsize(os.path.join(m, r))
        if o > MAX_OCTETS:
            signal.append(f"Fichier trop gros : {r} ({o} octets > {MAX_OCTETS})")
    sortie += signal or ["Rien à signaler."]
    print("\n".join(sortie))


if __name__ == "__main__":
    main()
