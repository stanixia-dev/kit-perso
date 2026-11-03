#!/usr/bin/env python3
"""Génère le workflow CI kit-perso d'un projet (job deps + jobs de tests par manifeste) hors de .github/.
Usage : genere-ci.py [--depot DIR] [--sans-tests] [--ref SHA] [--sortie FICHIER]
Sortie 2 + message sur stderr = refus (rien d'écrit). Stdlib uniquement."""
import argparse, json, os, re, subprocess, sys

DEPOT_KIT = "https://github.com/stanixia-dev/kit-perso.git"
ICI = os.path.dirname(os.path.abspath(__file__))
MARQUEUR = "# JOBS-TESTS"

def refus(msg):
    print(f"genere-ci : {msg}", file=sys.stderr)
    sys.exit(2)

def git(depot, *args):
    r = subprocess.run(["git", "-C", depot, *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None

def sha_kit(ref):
    if ref is None:
        try:
            r = subprocess.run(["git", "ls-remote", DEPOT_KIT, "refs/heads/main"], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            refus("git ls-remote a échoué : kit-perso doit être public et joignable")
        if r.returncode != 0 or not r.stdout.strip():
            refus("git ls-remote a échoué : kit-perso doit être public et joignable")
        ref = r.stdout.split()[0]
    if not re.fullmatch(r"[0-9a-f]{40}", ref):
        refus(f"SHA invalide (40 hex attendus) : {ref!r}")
    return ref

def job(nom, etapes):
    lignes = [f"  {nom}:",
              "    if: github.event_name != 'pull_request_target'",
              "    runs-on: ubuntu-24.04",
              "    timeout-minutes: 15",
              "    permissions:",
              "      contents: read",
              "    steps:",
              "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1",
              "        with:",
              "          persist-credentials: false"]
    for e in etapes:
        lignes.append(f"      - run: {json.dumps(e)}" if re.search(r"[:#&*!|>'\"%@`{}\[\],]", e) else f"      - run: {e}")
    return "\n".join(lignes)

def jobs_tests(depot):
    existe = lambda n: os.path.isfile(os.path.join(depot, n))
    noms = os.listdir(depot)
    jobs = []
    if existe("Cargo.toml"):
        L = " --locked" if existe("Cargo.lock") else ""
        jobs.append(job("rust", ["rustup component add rustfmt clippy", "cargo fmt --all --check",
                                 f"cargo clippy --all-targets{L} -- -D warnings", f"cargo test{L}"]))
    if existe("package.json"):
        if existe("package-lock.json"):
            pm, inst = "npm", "npm ci"
        elif existe("pnpm-lock.yaml"):
            pm, inst = "corepack pnpm", "corepack pnpm install --frozen-lockfile"
        elif existe("yarn.lock"):
            pm, inst = "corepack yarn", "corepack yarn install --frozen-lockfile"
        else:
            pm, inst = "npm", "npm install"
        jobs.append(job("node", [inst, f"{pm} run --if-present lint", f"{pm} run --if-present test"]))
    if existe("pyproject.toml") or any(re.fullmatch(r"requirements.*\.txt", n) for n in noms):
        if existe("uv.lock"):
            cmd = "pip install uv && uv sync --locked && uv run pytest -q"
        elif existe("requirements.txt"):
            cmd = "pip install -r requirements.txt pytest && pytest -q"
        else:
            cmd = "pip install -e . pytest && pytest -q"
        jobs.append(job("python", ["python3 -m venv .venv && . .venv/bin/activate && " + cmd]))
    return jobs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--depot", default=".")
    ap.add_argument("--sans-tests", action="store_true")
    ap.add_argument("--ref")
    ap.add_argument("--sortie")
    a = ap.parse_args()
    depot = os.path.abspath(a.depot)
    commun = git(depot, "rev-parse", "--path-format=absolute", "--git-common-dir") if os.path.isdir(depot) else None
    if commun is None:
        refus(f"{depot} n'est pas dans un dépôt git")
    sha = sha_kit(a.ref)
    sortie = os.path.abspath(a.sortie) if a.sortie else os.path.join(commun, "kit-perso", "kit-perso.yml")
    if ".github" in sortie.split(os.sep):
        refus("--sortie ne doit pas être sous un dossier .github")
    racine = git(depot, "rev-parse", "--show-toplevel")
    if racine:
        racine = os.path.realpath(racine)
        reel = os.path.realpath(sortie)
        if (reel == racine or reel.startswith(racine + os.sep)) and not (reel + os.sep).startswith(os.path.realpath(commun) + os.sep):
            refus("--sortie ne doit pas être dans l'arbre de travail (hors .git)")
    with open(os.path.join(ICI, "modele-ci.yml"), encoding="utf-8") as f:
        modele = f.read()
    with open(os.path.join(ICI, "..", "..", ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
        version = json.load(f)["version"]
    jobs = [] if a.sans_tests else jobs_tests(depot)
    if not jobs:
        print("Aucun job de tests ajouté (--sans-tests ou aucun manifeste à la racine) : seul le job deps.", file=sys.stderr)
    texte = modele.replace("__SHA_KIT__", sha).replace(MARQUEUR + "\n", "".join(j + "\n" for j in jobs))
    texte = f"# Généré par kit-perso {version} (/kit-perso:ci-projet), kit figé à {sha}\n" + texte
    os.makedirs(os.path.dirname(sortie), exist_ok=True)
    with open(sortie, "w", encoding="utf-8") as f:
        f.write(texte)
    print(f'git switch main && git pull --ff-only && mkdir -p .github/workflows && cp "{sortie}" .github/workflows/kit-perso.yml '
          f'&& git add .github/workflows/kit-perso.yml && git commit -m "Ajoute la CI kit-perso {version} ({sha[:12]})" && git push origin main')
    print("`deps` ne tourne qu'une fois ce workflow sur main. Ensuite : Settings > Rules > Rulesets > New branch ruleset, "
          "cible `main`, Require status checks : `deps` + jobs de tests générés. "
          "Mise à jour du kit : relancer /kit-perso:ci-projet et recopier.")

if __name__ == "__main__":
    main()
