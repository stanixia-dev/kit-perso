#!/usr/bin/env python3
"""Décide quels jobs de tests lancer d'après les fichiers modifiés par la PR (job `filtre` de kit-perso-tests.yml).
Env : BASE (SHA de base de la PR, vide hors PR), FILTRES (JSON {job: [motifs]}), GITHUB_OUTPUT.
Ajoute `<job>=true|false` à $GITHUB_OUTPUT. Fail-safe : un job n'est sauté que si c'est prouvé.
Sortie 2 + message = entrée invalide (rien écrit). Stdlib uniquement."""
import fnmatch, json, os, subprocess, sys

def refus(msg):
    print(f"filtre-chemins : {msg}", file=sys.stderr)
    sys.exit(2)

def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None

def fichiers_modifies(base):
    """Liste des fichiers modifiés, ou (None, raison) si on ne peut pas le prouver."""
    if not base:
        return None, "pas de PR (push)"
    p1 = git("rev-parse", "HEAD^1")
    if p1 is None or p1.strip() != base:
        return None, "base incohérente"
    sortie = git("diff", "--name-only", "--no-renames", "-z", "HEAD^1", "HEAD")
    if sortie is None:
        return None, "diff illisible"
    fichiers = [f for f in sortie.split("\0") if f]
    return (fichiers, None) if fichiers else (None, "diff vide")

def main():
    try:
        filtres = json.loads(os.environ.get("FILTRES", ""))
    except ValueError:
        filtres = None
    if not (isinstance(filtres, dict) and filtres and all(
            isinstance(m, list) and m and all(isinstance(x, str) for x in m) for m in filtres.values())):
        refus("FILTRES doit être un objet JSON {job: [motif, …]} non vide")
    sortie = os.environ.get("GITHUB_OUTPUT")
    if not sortie:
        refus("GITHUB_OUTPUT absent")
    fichiers, raison = fichiers_modifies(os.environ.get("BASE", ""))
    lignes = []
    for job, motifs in filtres.items():
        if fichiers is None:
            lance, why = True, raison
        else:
            classes = lambda f: any(fnmatch.fnmatchcase(f, m) for ms in filtres.values() for m in ms)
            hit = next((f for f in fichiers if any(fnmatch.fnmatchcase(f, m) for m in motifs)), None)
            nonclasse = next((f for f in fichiers if not classes(f)), None)
            lance = hit is not None or nonclasse is not None
            why = f"fichier {hit}" if hit is not None else f"fichier non classé {nonclasse}"
        print(f"{job} : lancé ({why})" if lance else f"{job} : sauté")
        lignes.append(f"{job}={'true' if lance else 'false'}\n")
    with open(sortie, "a", encoding="utf-8") as f:
        f.writelines(lignes)

if __name__ == "__main__":
    main()
