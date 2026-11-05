#!/usr/bin/env python3
"""Génère les workflows CI kit-perso d'un projet hors de .github/ : kit-perso-deps.yml (job deps, pull_request_target)
et kit-perso-tests.yml (jobs de tests par manifeste, pull_request), deux événements séparés pour qu'aucun check obligatoire
ne soit satisfait par un job sauté.
Usage : genere-ci.py [--depot DIR] [--sans-tests] [--ref SHA] [--sortie DOSSIER]
Sortie 2 + message sur stderr = refus (rien d'écrit). Stdlib uniquement."""
import argparse, json, os, re, subprocess, sys

DEPOT_KIT = "https://github.com/stanixia-dev/kit-perso.git"
ICI = os.path.dirname(os.path.abspath(__file__))
MARQUEUR = "# JOBS-TESTS"
DEPS, TESTS = "kit-perso-deps.yml", "kit-perso-tests.yml"

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

CHECKOUT = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1"
SETUP_NODE = "actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0"

def job(nom, etapes, env=None):
    """etapes : str (run, guillemeté si besoin), ("brut", str) (run tel quel) ou ("bloc", [lignes]) (étape uses:)."""
    lignes = [f"  {nom}:",
              "    runs-on: ubuntu-24.04",
              "    timeout-minutes: 15",
              "    permissions:",
              "      contents: read"]
    if env:
        lignes += ["    env:"] + [f"      {k}: {json.dumps(v)}" for k, v in env.items()]
    lignes += ["    steps:",
               f"      - uses: {CHECKOUT}",
               "        with:",
               "          persist-credentials: false"]
    for e in etapes:
        if isinstance(e, tuple) and e[0] == "bloc":
            lignes += e[1]
        elif isinstance(e, tuple):
            lignes.append(f"      - run: {e[1]}")
        else:
            lignes.append(f"      - run: {json.dumps(e)}" if re.search(r"[:#&*!|>'\"%@`{}\[\],]", e) else f"      - run: {e}")
    return "\n".join(lignes)

def etapes_runtime(sha):
    return [("bloc", ["      - uses: " + SETUP_NODE,
                      "        with:",
                      "          node-version-file: .nvmrc",
                      "          check-latest: true",
                      "          package-manager-cache: false"]),
            ("bloc", ["      - uses: " + CHECKOUT,
                      "        with:",
                      "          repository: stanixia-dev/kit-perso",
                      f"          ref: {sha}",
                      "          path: .kit-perso",
                      "          persist-credentials: false"]),
            ("brut", "python3 .kit-perso/hooks/verifie-runtime.py --ci && rm -rf .kit-perso")]

def jobs_tests(depot, sha):
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
        jobs.append(job("node", etapes_runtime(sha) + [inst, f"{pm} run --if-present lint", f"{pm} run --if-present test"],
                        env={"npm_config_engine_strict": "true"}))
    if existe("pyproject.toml") or any(re.fullmatch(r"requirements.*\.txt", n) for n in noms):
        if existe("uv.lock"):
            cmd = "pip install uv && uv sync --locked && uv run pytest -q"
        elif existe("requirements.txt"):
            cmd = "pip install -r requirements.txt pytest && pytest -q"
        else:
            cmd = "pip install -e . pytest && pytest -q"
        jobs.append(job("python", ["python3 -m venv .venv && . .venv/bin/activate && " + cmd]))
    return jobs

def contenu_nvmrc(depot):
    """Première suite de chiffres de engines.node, sinon lts/* (avec avis)."""
    try:
        with open(os.path.join(depot, "package.json"), encoding="utf-8") as f:
            m = re.search(r"\d+", str(json.load(f)["engines"]["node"]))
        if m:
            return m.group(0) + "\n"
    except (OSError, ValueError, KeyError, TypeError):
        pass
    print("genere-ci : pas de engines.node exploitable dans package.json : .nvmrc vaut lts/*, qui change de branche "
          "majeure à chaque nouvelle LTS. Fixe engines.node (ex. \">=24\").", file=sys.stderr)
    return "lts/*\n"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--depot", default=".")
    ap.add_argument("--sans-tests", action="store_true")
    ap.add_argument("--ref")
    ap.add_argument("--sortie", help="dossier de sortie (défaut : <git-common-dir>/kit-perso)")
    a = ap.parse_args()
    depot = os.path.abspath(a.depot)
    commun = git(depot, "rev-parse", "--path-format=absolute", "--git-common-dir") if os.path.isdir(depot) else None
    if commun is None:
        refus(f"{depot} n'est pas dans un dépôt git")
    sha = sha_kit(a.ref)
    sortie = os.path.abspath(a.sortie) if a.sortie else os.path.join(commun, "kit-perso")
    if ".github" in sortie.split(os.sep):
        refus("--sortie ne doit pas être sous un dossier .github")
    racine = git(depot, "rev-parse", "--show-toplevel")
    if racine:
        racine = os.path.realpath(racine)
        reel = os.path.realpath(sortie)
        if (reel == racine or reel.startswith(racine + os.sep)) and not (reel + os.sep).startswith(os.path.realpath(commun) + os.sep):
            refus("--sortie ne doit pas être dans l'arbre de travail (hors .git)")
    with open(os.path.join(ICI, "..", "..", ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
        version = json.load(f)["version"]
    entete = f"# Généré par kit-perso {version} (/kit-perso:ci-projet), kit figé à {sha}\n"
    def modele(nom):
        with open(os.path.join(ICI, nom), encoding="utf-8") as f:
            return f.read()
    jobs = [] if a.sans_tests else jobs_tests(depot, sha)
    os.makedirs(sortie, exist_ok=True)
    fichiers = [DEPS]
    ecrits = {DEPS: entete + modele("modele-deps.yml").replace("__SHA_KIT__", sha)}
    if jobs:
        fichiers.append(TESTS)
        ecrits[TESTS] = entete + modele("modele-tests.yml").replace(MARQUEUR + "\n", "".join(j + "\n" for j in jobs))
    else:
        print("Aucun job de tests ajouté (--sans-tests ou aucun manifeste à la racine) : seul le job deps.", file=sys.stderr)
        try:
            os.remove(os.path.join(sortie, TESTS))  # reste d'une génération précédente
        except FileNotFoundError:
            pass
    annexes = []  # fichiers générés à côté des workflows (job node seulement)
    if any(j.startswith("  node:") for j in jobs):
        if os.path.lexists(os.path.join(depot, ".nvmrc")):
            pass
        else:
            ecrits[".nvmrc"] = contenu_nvmrc(depot)
            annexes.append(".nvmrc")
        if os.path.lexists(os.path.join(depot, ".npmrc")):
            print("genere-ci : `.npmrc` existe : ajoute `engine-strict=true` si absent (la CI l'impose déjà).", file=sys.stderr)
        else:
            ecrits[".npmrc"] = "engine-strict=true\n"
            annexes.append(".npmrc")
    for nom in (".nvmrc", ".npmrc"):
        if nom not in ecrits:
            try:
                os.remove(os.path.join(sortie, nom))  # reste d'une génération précédente
            except FileNotFoundError:
                pass
    for nom, texte in ecrits.items():
        with open(os.path.join(sortie, nom), "w", encoding="utf-8") as f:
            f.write(texte)
    cibles = " ".join([f".github/workflows/{n}" for n in fichiers] + annexes)
    copies = " && ".join(f'cp "{os.path.join(sortie, n)}" .github/workflows/{n}' for n in fichiers)
    copies = " && ".join([copies] + [f'cp -n "{os.path.join(sortie, n)}" {n}' for n in annexes])
    print(f'git switch main && git pull --ff-only && mkdir -p .github/workflows && {copies} '
          f'&& git add {cibles} && git commit -m "Ajoute la CI kit-perso {version} ({sha[:12]})" && git push origin main')
    noms = "`deps`" + "".join(f", `{n}`" for n in (re.match(r"  (\w+):", j).group(1) for j in jobs))
    print("`deps` ne tourne qu'une fois ces workflows sur main. Ensuite : Settings > Rules > Rulesets > New branch ruleset, "
          f"cible `main`, Require status checks : {noms} (noms de jobs ; GitHub les affiche `kit-perso-deps / deps`, "
          "`kit-perso-tests / <job>`). Mise à jour du kit : relancer /kit-perso:ci-projet et recopier.")

if __name__ == "__main__":
    main()
