#!/usr/bin/env python3
"""Génère les workflows CI kit-perso d'un projet hors de .github/ : kit-perso-deps.yml (job deps, pull_request_target)
et kit-perso-tests.yml (jobs de tests par manifeste, pull_request), deux événements séparés pour qu'aucun check obligatoire
ne soit satisfait par un job sauté.
Usage : genere-ci.py [--depot DIR] [--sans-tests] [--ref SHA] [--sortie DOSSIER]
Sortie 2 + message sur stderr = refus (rien d'écrit). Stdlib uniquement."""
import argparse, fnmatch, json, os, re, subprocess, sys

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
CACHE = "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0"
SETUP_NODE = "actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0"

CFG_DEFAUT = {"labels": ["ubuntu-24.04"], "chemins": {}}
CONFIG = ".kit-perso-ci"

def hebergeur(cfg):
    return "auto-hébergé" if "self-hosted" in cfg["labels"] else "hébergé"

def runs_on(cfg):
    l = cfg["labels"]
    return l[0] if len(l) == 1 else "[" + ", ".join(l) + "]"

def lit_config(depot, noms):
    """Lit .kit-perso-ci (runs-on, chemins <job> <motif>…) ; noms = jobs de tests générés. Refus (sortie 2) si invalide."""
    cfg = {"labels": list(CFG_DEFAUT["labels"]), "chemins": {}}
    chemin = os.path.join(depot, CONFIG)
    if not os.path.isfile(chemin):
        return cfg
    try:
        with open(chemin, encoding="utf-8") as f:
            lignes = f.read().splitlines()
    except (OSError, ValueError):
        refus(f"{CONFIG} illisible")
    vu_runs = False
    for n, brut in enumerate(lignes, 1):
        mots = brut.split()
        if not mots or mots[0].startswith("#"):
            continue
        err = lambda m: refus(f"{CONFIG} ligne {n} : {m}")
        if mots[0] == "runs-on":
            if vu_runs:
                err("runs-on en double")
            if len(mots) < 2:
                err("runs-on sans label")
            for l in mots[1:]:
                if not re.fullmatch(r"[A-Za-z0-9._-]+", l):
                    err(f"label invalide : {l!r}")
            vu_runs, cfg["labels"] = True, mots[1:]
        elif mots[0] == "chemins":
            if len(mots) < 3:
                err("chemins demande un job et au moins un motif")
            if mots[1] not in noms:
                err(f"job non généré : {mots[1]!r} (jobs : {', '.join(noms)})")
            if mots[1] in cfg["chemins"]:
                err(f"chemins en double pour {mots[1]}")
            for m in mots[2:]:
                if not re.fullmatch(r"[A-Za-z0-9._/*?-]+", m) or m.startswith("/"):
                    err(f"motif invalide : {m!r}")
            cfg["chemins"][mots[1]] = mots[2:]
        else:
            err(f"directive inconnue : {mots[0]!r}")
    return cfg

def job(nom, etapes, env=None, cfg=CFG_DEFAUT):
    """etapes : str (run, guillemeté si besoin), ("brut", str) (run tel quel) ou ("bloc", [lignes]) (étape uses:)."""
    lignes = [f"  {nom}:"]
    if nom in cfg["chemins"]:  # job filtré : tourne seulement si `filtre` le décide
        lignes += ["    needs: filtre", f"    if: ${{{{ needs.filtre.outputs.{nom} == 'true' }}}}"]
    lignes += [f"    runs-on: {runs_on(cfg)}",
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

def job_filtre(sha, cfg, noms):
    filtres = {n: cfg["chemins"][n] for n in noms if n in cfg["chemins"]}
    kit = ["      - uses: " + CHECKOUT, "        with:", "          repository: stanixia-dev/kit-perso",
           f"          ref: {sha}", "          path: .kit-perso", "          persist-credentials: false"]
    return "\n".join([
        "  filtre:", f"    runs-on: {runs_on(cfg)}", "    timeout-minutes: 5", "    permissions:", "      contents: read",
        "    outputs:"] + [f"      {n}: ${{{{ steps.decide.outputs.{n} }}}}" for n in filtres] + [
        "    steps:", "      - uses: " + CHECKOUT, "        with:", "          fetch-depth: 2",
        "          persist-credentials: false"] + kit + [
        "      - id: decide", "        env:", "          BASE: ${{ github.event.pull_request.base.sha }}",
        f"          FILTRES: '{json.dumps(filtres)}'",
        "        run: python3 .kit-perso/skills/ci-projet/filtre-chemins.py"])

def job_resume(cfg, noms):
    return "\n".join([
        "  resume:", "    if: ${{ !cancelled() }}", "    needs: [" + ", ".join(noms) + "]",
        f"    runs-on: {runs_on(cfg)}", "    timeout-minutes: 5", "    permissions:", "      contents: read", "    steps:",
        "      - if: ${{ contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled') }}",
        "        run: exit 1",
        '      - run: echo "jobs de tests verts ou sautés par le filtre"'])

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

def jobs_tests(depot, sha, cfg=CFG_DEFAUT):
    existe = lambda n: os.path.isfile(os.path.join(depot, n))
    noms = os.listdir(depot)
    jobs = []
    if existe("Cargo.toml"):
        L = " --locked" if existe("Cargo.lock") else ""
        if hebergeur(cfg) == "hébergé":
            pre = [("bloc", ["      - uses: " + CACHE,
                             "        with:",
                             "          path: |",
                             "            ~/.cargo/registry/index",
                             "            ~/.cargo/registry/cache",
                             "            ~/.cargo/git/db",
                             "            target",
                             "          key: cargo-${{ runner.os }}-${{ hashFiles('Cargo.lock') }}",
                             "          restore-keys: cargo-${{ runner.os }}-"])]
        else:  # target/ est effacé par le checkout : répertoire persistant propre au runner et au dépôt
            pre = [("brut", 'echo "CARGO_TARGET_DIR=$(dirname "$GITHUB_WORKSPACE")/kit-perso-target" >> "$GITHUB_ENV"')]
        jobs.append(job("rust", pre + ["rustup component add rustfmt clippy", "cargo fmt --all --check",
                                       f"cargo clippy --all-targets{L} -- -D warnings", f"cargo test{L}"], cfg=cfg))
    if existe("package.json"):
        if existe("package-lock.json"):
            pm, inst = "npm", "npm ci"
        elif existe("pnpm-lock.yaml"):
            pm, inst = "corepack pnpm", "corepack pnpm install --frozen-lockfile"
        elif existe("yarn.lock"):
            pm, inst = "corepack yarn", "corepack yarn install --frozen-lockfile"
        else:
            pm, inst = "npm", "npm install"
        cache = []
        if pm == "npm" and inst == "npm ci" and hebergeur(cfg) == "hébergé":
            cache = [("bloc", ["      - uses: " + CACHE,
                               "        with:",
                               "          path: ~/.npm",
                               "          key: npm-${{ runner.os }}-${{ hashFiles('package-lock.json') }}",
                               "          restore-keys: npm-${{ runner.os }}-"])]
        jobs.append(job("node", etapes_runtime(sha) + cache + [inst, f"{pm} run --if-present lint", f"{pm} run --if-present test"],
                        env={"npm_config_engine_strict": "true"}, cfg=cfg))
    if existe("pyproject.toml") or any(re.fullmatch(r"requirements.*\.txt", n) for n in noms):
        if existe("uv.lock"):
            cmd = "pip install uv && uv sync --locked && uv run pytest -q"
        elif existe("requirements.txt"):
            cmd = "pip install -r requirements.txt pytest && pytest -q"
        else:
            cmd = "pip install -e . pytest && pytest -q"
        jobs.append(job("python", ["python3 -m venv .venv && . .venv/bin/activate && " + cmd], cfg=cfg))
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
    cfg = CFG_DEFAUT
    if jobs:  # config lue seulement si des jobs de tests sont générés
        noms_jobs = [re.match(r"  (\w+):", j).group(1) for j in jobs]
        cfg = lit_config(depot, noms_jobs)
        jobs = jobs_tests(depot, sha, cfg)
        if cfg["chemins"]:
            jobs.insert(0, job_filtre(sha, cfg, noms_jobs))
        jobs.append(job_resume(cfg, (["filtre"] if cfg["chemins"] else []) + noms_jobs))
        filtres = ", ".join(f"{k} ({' '.join(v)})" for k, v in cfg["chemins"].items()) or "aucun filtre"
        print(f"genere-ci : CI de tests : runs-on {runs_on(cfg)}, cache {'actions/cache' if hebergeur(cfg) == 'hébergé' else 'répertoire persistant'}, "
              f"filtres : {filtres}", file=sys.stderr)
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
    noms = "`deps`, `resume`" if jobs else "`deps`"
    print("`deps` ne tourne qu'une fois ces workflows sur main. Ensuite : Settings > Rules > Rulesets > New branch ruleset, "
          f"cible `main`, Require status checks : {noms} (noms de jobs ; GitHub les affiche `kit-perso-deps / deps`, "
          "`kit-perso-tests / resume`). Mise à jour du kit : relancer /kit-perso:ci-projet et recopier.")

if __name__ == "__main__":
    main()
