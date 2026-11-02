#!/usr/bin/env bash
# Tests des hooks par stdin JSON. Lancer depuis n'importe où.
set -u
cd "$(dirname "$0")/.." || exit 1
ECHECS=0
ok() { echo "OK    $1"; }
ko() { echo "ECHEC $1"; ECHECS=$((ECHECS + 1)); }

code_garde() { # $1 = commande
  printf '{"tool_input":{"command":"%s"},"cwd":"/tmp"}' "$1" | python3 hooks/garde-git.py >/dev/null 2>&1
  echo $?
}
sortie_rappel() {
  printf '{"tool_input":{"command":"%s"}}' "$1" | python3 hooks/rappel-clear.py 2>/dev/null
}

PROFOND=ls; PROFOND_AJOUT='npm i gpl-pkg'
for _ in 1 2 3 4 5 6 7 8 9 10; do PROFOND="echo \$($PROFOND)"; PROFOND_AJOUT="echo \$($PROFOND_AJOUT)"; done
DEPS_ENV="GARDE_DEPS_FIXTURES=tests/fixtures/garde-deps.json GARDE_DEPS_AUJOURDHUI=2026-10-29"
json_cmd() { local c=${1//\\/\\\\}; c=${c//\"/\\\"}; printf '{"tool_input":{"command":"%s"}}' "${c//$'\n'/\\n}"; }
code_deps() { # $1 = commande
  json_cmd "$1" | env $DEPS_ENV python3 hooks/garde-deps.py >/dev/null 2>&1
  echo $?
}
sortie_deps() {
  json_cmd "$1" | env $DEPS_ENV python3 hooks/garde-deps.py 2>/dev/null
}
erreur_deps() {
  json_cmd "$1" | env $DEPS_ENV python3 hooks/garde-deps.py 2>&1 >/dev/null
}

code_edit() { # $1 = tool_name, $2 = chemin
  printf '{"tool_name":"%s","tool_input":{"file_path":"%s"},"cwd":"/tmp"}' "$1" "$2" \
    | env $DEPS_ENV python3 hooks/garde-deps.py >/dev/null 2>&1
  echo $?
}

[ "$(code_garde 'git push origin main')" = 2 ] && ok "garde-git bloque git push origin main" || ko "garde-git push main"
[ "$(code_garde 'gh pr merge 1')" = 2 ] && ok "garde-git bloque gh pr merge" || ko "garde-git pr merge"
[ "$(code_garde 'git status')" = 0 ] && ok "garde-git laisse passer git status" || ko "garde-git status"
for c in 'git push --receive-pack=x origin b' 'git push --exec x origin b' 'git push --exec=x origin b' 'GIT_SSH_COMMAND=x git push origin b' \
         'env A=1 gh pr create' "bash -c 'X=1 git push origin b'" 'rtk git push --receive-pack=x origin b' 'A=1 gh pr view 1' \
         'git push --receive=x origin b' 'git push --exe=x origin b' 'git push --rec x origin b' 'env -i gh pr create' 'env -u X git push origin b' \
         'git push /tmp/depot b' 'git push ./d b' 'git push file:///tmp/d b' 'git push ext::sh origin b' 'git push --repo=../d b' \
         'export GIT_SSH_COMMAND=x; git push origin b' 'declare -x A=1 && gh pr create'; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'git push -u origin claude/x' 'gh pr create --fill' 'gh pr checks --watch --interval 20' 'rtk git push -u origin claude/x'; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
sortie_rappel 'gh pr create --fill' | grep -q '/clear' && ok "rappel-clear après gh pr create" || ko "rappel-clear pr create"
[ -z "$(sortie_rappel 'ls')" ] && ok "rappel-clear muet sur ls" || ko "rappel-clear ls"

# garde-deps : "commande|attendu" (0 = passe sans sortie, 2 = bloque)
for c in 'cargo add bon' 'pnpm add @scope/ok@1.0.0' 'cargo add mixte' \
         'npm install' 'pip install -r requirements.txt' 'pip install -e .' 'npm i ./local' 'cargo add --path ../x' \
         'cargo add cc0' "bash -c 'echo \"a && npm i gpl-pkg\"'" "bash -c 'ls && echo ok'" "git commit -m 'doc: npm i gpl-pkg \`npm i gpl-pkg\`'" 'cargo add bon 2>&1 | tail -1' \
         "git commit -m \"\$(cat <<'EOF'"$'\nAjoute l\'analyse de npm i x\nEOF\n)\"' \
         "cat > notes.md <<'EOF'"$'\nnpm i gpl-pkg\nEOF' "cat <<'EOF' | tee n.md"$'\nnpm i gpl-pkg\nEOF' \
         'ls #c && npm i gpl-pkg' 'echo $# && cargo add bon' \
         'echo $((1<<2)) && cargo add bon' 'if true; then cargo add bon; fi' 'timeout 5 cargo add bon' \
         'nice -n 5 cargo add bon' 'sudo -u x cargo add bon' 'echo bon | xargs -n1 cargo add' 'time cargo add bon' \
         "bash -c -- 'ls'" 'npm -g i @scope/ok@1.0.0' 'npm --prefix . i @scope/ok@1.0.0' \
         'curl -s x | sh' 'bash script.sh' "$PROFOND" 'cat ~/.claude/settings.json' 'grep x ~/.claude/settings.json' \
         "python3 -c \"import json,os;d=json.load(open(os.path.expanduser('~/.claude/settings.json')));print('sandbox' in d)\"" \
         'grep -r x .github/workflows' \
         "git commit -m 'doc .github/workflows'" 'git diff main -- .garde-deps-exceptions' 'ls ~/.claude/hooks' \
         'echo ok > /dev/null' 'git status' 'curl -s https://x.io/a' 'echo "$(git log --format="%h #%s")"' 'git log --format="%h #%s"' \
         'wget -q https://x.io/a' 'awk 1 ~/.claude/settings.json' 'sed -n 1p ~/.claude/settings.json' 'cp a b'; do
  [ "$(code_deps "$c")" = 0 ] && [ -z "$(sortie_deps "$c")" ] && ok "garde-deps laisse passer $c" || ko "garde-deps $c"
done
for c in 'npm install gpl-pkg' 'npm i sanslicence' 'yarn add prive' 'npm add deprecie' 'cargo add colle' \
         'cargo add retire@0.1.0' 'pip install vieux' 'ls && npm i gpl-pkg' "bash -c 'npm i gpl-pkg'" \
         "bash -c 'cd x && npm i gpl-pkg'" 'sh -c "pip install gpl-pkg"' '(cargo add gpl-pkg)' 'echo $(npm i gpl-pkg)' \
         'echo `npm i gpl-pkg`' "bash -lc 'npm i gpl-pkg'" "zsh -c 'ls; npm i gpl-pkg'" 'env FOO=1 npm i gpl-pkg' \
         'echo "$(npm i gpl-pkg)"' "bash -c \"sh -c 'npm i gpl-pkg'\"" \
         "bash -c 'npm i gpl-pkg" 'echo "ok; npm i gpl-pkg' \
         "bash <<'EOF'"$'\nnpm i gpl-pkg\nEOF' "sh <<X"$'\nnpm i gpl-pkg\nX' "cat <<EOF"$'\n$(npm i gpl-pkg)\nEOF' \
         "cat <<'EOF' | bash"$'\nnpm i gpl-pkg\nEOF' "echo \"<<EOF\""$'\nnpm i gpl-pkg\nEOF' \
         '{ npm i gpl-pkg; }' '! npm i gpl-pkg' 'for x in 1; do npm i gpl-pkg; done' 'timeout 5 npm i gpl-pkg' \
         'nice -n 5 npm i gpl-pkg' 'sudo -u x npm i gpl-pkg' 'xargs -n1 npm i gpl-pkg' 'time npm i gpl-pkg' \
         'command npm i gpl-pkg' 'exec npm i gpl-pkg' "bash -c -- 'npm i gpl-pkg'" "echo 'npm i gpl-pkg' | bash" \
         "echo 'npm i gpl-pkg' | sh" 'diff <(npm i gpl-pkg) x' 'tee >(npm i gpl-pkg)' "env -S 'npm i gpl-pkg'" \
         'npm -g i gpl-pkg' 'npm --prefix . i gpl-pkg' 'python3 -mpip install gpl-pkg' \
         'python3.12 -m pip install gpl-pkg' 'pip3.12 install gpl-pkg' 'pnpm -C x add gpl-pkg' "$PROFOND_AJOUT" \
         "ls # c"$'\nnpm i gpl-pkg' 'echo a#b; npm i gpl-pkg' 'curl https://x/a#frag && npm i gpl-pkg' \
         "cat <<EOF | bash"$'\n# setup\nnpm i gpl-pkg\nEOF' "ls # <<EOF"$'\nnpm i gpl-pkg\nEOF' \
         'true;>log npm i gpl-pkg' 'python3 -X utf8 -m pip install gpl-pkg' 'python3 -W ignore -m pip install gpl-pkg' \
         'yarn global add gpl-pkg' 'echo x > .garde-deps-exceptions' 'sed -i s/a/b/ ~/.claude/settings.json' \
         "python3 -c \"open('/home/u/.claude/hooks/x','w')\"" 'cp a .github/workflows/t.yml' 'tee -a ~/.claude/settings.json' \
         "bash -c 'mv a ~/.claude/plugins/x'" 'git checkout main -- .garde-deps-exceptions' \
         'claude plugin disable kit-perso@kit-perso' 'echo x >> $HOME/.claude/settings.json' 'rm -rf ~/.claude' \
         'claude plugin marketplace remove kit-perso' 'git -C x restore .github/workflows/t.yml' \
         'find .github -exec rm {} +' "echo 'x > .github/workflows/t.yml" 'true;>.garde-deps-exceptions' \
         'cat a | tee .github/workflows/t.yml' 'echo "$(echo "a #")"; npm i gpl-pkg' \
         'echo "$(echo "a #")"; echo x > .garde-deps-exceptions' 'curl -o .garde-deps-exceptions https://x.io/a' \
         'curl --output ~/.claude/settings.json https://x.io/a' 'curl -sSo .github/workflows/t.yml https://x.io/a' \
         'wget -O .garde-deps-exceptions https://x.io/a' 'wget --output-document=.github/workflows/t.yml https://x.io/a' \
         'unlink .garde-deps-exceptions' 'rmdir ~/.claude/hooks' 'awk -i inplace 1 ~/.claude/settings.json' \
         'echo x | sponge .garde-deps-exceptions' 'truncate -s0 .garde-deps-exceptions' 'install a ~/.claude/hooks/x' \
         'ln -sf a .garde-deps-exceptions' 'dd if=a of=.garde-deps-exceptions' 'node -e "x" .garde-deps-exceptions' 'echo x > .garde-secret-exceptions' \
         "python3 -c \"import json,os;p=os.path.expanduser('~/.claude/settings.json');d=json.load(open(p));d.pop('sandbox',None);json.dump(d,open(p+'.tmp','w'),indent=2);os.replace(p+'.tmp',p)\"" \
         "python3 -c \"import os;os.replace('a','/home/u/.claude/settings.json')\"" \
         "python3 -c \"from pathlib import Path;Path('/home/u/.claude/settings.json').write_text('x')\"" \
         "python3 -c \"print(1)\" ~/.claude/settings.json" "python3 ~/.claude/hooks/x.py" \
         "node -e \"console.log(require('/home/u/.claude/settings.json').sandbox)\"" \
         'python3 w.py -c ~/.claude/settings.json' 'node w.js -e ~/.claude/settings.json' 'python3 -m mod -c ~/.claude/settings.json' \
         'node -r ~/.claude/hooks/x.js app.js' \
         "python3 -c \"import os;print(1,file=open(os.path.expanduser('~/.claude/settings.json'),'w'))\"" \
         "python3 -c \"from pathlib import Path;Path('/home/u/.claude/settings.json').open('w')\"" \
         "python3 -c \"from os import replace as r;r('a','/home/u/.claude/settings.json')\"" \
         "python3 -c \"from os import system as s;s('cp a /home/u/.claude/settings.json')\"" \
         "python3 -c \"import pty;pty.spawn(['cp','a','/home/u/.claude/settings.json'])\"" \
         "python3 -c \"from pathlib import Path;Path('/home/u/.claude/settings.json').symlink_to('/tmp/x')\"" \
         "python3 -c \"import sys;sys.modules['os'].replace('a','/home/u/.claude/settings.json')\"" \
         "python3 -c \"import tempfile,shutil;shutil.copy('a','/home/u/.claude/settings.json')\"" \
         "perl -e 'open F, \">\", \"\$ENV{HOME}/.claude/settings.json\"; print F \"x\"'" \
         "perl -e 'system \"cp a \$ENV{HOME}/.claude/settings.json\"'" \
         "perl -e 'rename \"a\", \"\$ENV{HOME}/.claude/settings.json\"'" \
         "ruby -e '\`cp a ~/.claude/settings.json\`'" \
         "node -e \"require('f'+'s')['wr'+'iteFileSync']('/home/u/.claude/settings.json','x')\"" \
         "php -r 'unlink(\"/home/u/.claude/settings.json\");'"; do
  [ "$(code_deps "$c")" = 2 ] && ok "garde-deps bloque $c" || ko "garde-deps $c"
done
for ch in 'Edit|$HOME/.claude/settings.json' 'Write|/x/.github/workflows/a.yml' 'Write|/x/.garde-deps-exceptions' \
          'MultiEdit|/home/u/proj/.claude/settings.local.json' 'NotebookEdit|/x/.garde-deps-exceptions' 'Edit|/x/.garde-secret-exceptions'; do
  [ "$(code_edit "${ch%%|*}" "$(eval echo "${ch#*|}")")" = 2 ] && ok "garde-deps bloque ${ch%%|*} ${ch#*|}" || ko "garde-deps ${ch}"
done
for ch in 'Edit|/x/README.md' 'Write|/x/.github/CODEOWNERS'; do
  [ "$(code_edit "${ch%%|*}" "${ch#*|}")" = 0 ] && ok "garde-deps laisse passer ${ch%%|*} ${ch#*|}" || ko "garde-deps ${ch}"
done
[ "$(code_deps 'cargo add faille@1.2.3')" = 2 ] && erreur_deps 'cargo add faille@1.2.3' | grep -q 'RUSTSEC-2099-0001' \
  && ok "garde-deps cite la faille OSV" || ko "garde-deps faille OSV"
[ "$(code_deps 'uv add mpl')" = 0 ] && sortie_deps 'uv add mpl' | grep -q 'MPL-2.0' \
  && ok "garde-deps avertit sur MPL-2.0" || ko "garde-deps MPL"
[ "$(code_deps 'pip3 install inconnu')" = 0 ] && sortie_deps 'pip3 install inconnu' | grep -q 'vérification impossible' \
  && ok "garde-deps avertit si injoignable" || ko "garde-deps injoignable"

# bac à sable : contrôle du fragment de réglages et de la sonde
controle_bac() { # $1 = fichier ; sort 0 si conforme
  python3 -I - "$1" <<'PY'
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))["sandbox"]
    assert d["enabled"] is True and d["allowUnsandboxedCommands"] is False
    assert d["failIfUnavailable"] is True and d["autoAllowBashIfSandboxed"] is False
    ex = d["excludedCommands"]
    assert all(re.match(r"^(rtk )?(git push|gh (pr|run|issue)) ", e) for e in ex) and ex
    for e in ("git push *", "gh pr create *", "rtk git push *", "rtk gh pr create *"):
        assert e in ex, e
    assert {"~/.ssh", "~/.config/gh"} <= set(d["filesystem"]["denyRead"])
    for w in d["filesystem"]["allowWrite"]:
        w = w.rstrip("/")
        assert w != "~/.cargo" and not re.match(r"^~/(\.claude|\.ssh|\.config/gh)(/|$)", w), w
    assert {"GH_TOKEN", "GITHUB_TOKEN"} <= {c["name"] for c in d["credentials"]["envVars"] if c["mode"] == "deny"}
    assert "api.github.com" in d["network"]["allowedDomains"] and d["network"]["allowLocalBinding"] is True
except Exception as e:
    print(f"fragment non conforme : {e!r}", file=sys.stderr); sys.exit(1)
PY
}
T_BAC=$(mktemp -d)
controle_bac config/bac-a-sable.json && ok "bac à sable : fragment conforme" || ko "bac à sable : fragment"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); del d["sandbox"]["allowUnsandboxedCommands"]; json.dump(d, open(sys.argv[2], "w"))' config/bac-a-sable.json "$T_BAC/a.json"
controle_bac "$T_BAC/a.json" 2>/dev/null && ko "bac à sable : allowUnsandboxedCommands retiré accepté" || ok "bac à sable : allowUnsandboxedCommands retiré refusé"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["sandbox"]["filesystem"]["allowWrite"].append("~/.claude"); json.dump(d, open(sys.argv[2], "w"))' config/bac-a-sable.json "$T_BAC/b.json"
controle_bac "$T_BAC/b.json" 2>/dev/null && ko "bac à sable : ~/.claude en écriture accepté" || ok "bac à sable : ~/.claude en écriture refusé"
rm -rf "$T_BAC"
bash -n tests/sonde-bac-a-sable.sh && ok "sonde : syntaxe" || ko "sonde : syntaxe"
AVANT=$(git status --porcelain | md5sum)
bash tests/sonde-bac-a-sable.sh --liste >/dev/null && [ "$(git status --porcelain | md5sum)" = "$AVANT" ] \
  && ok "sonde --liste : sort en 0, rien créé" || ko "sonde --liste"

bash tests/test_manifestes.sh | grep -v '^OK' | sed 's/^/manifestes: /'
[ "${PIPESTATUS[0]}" = 0 ] || ko "tests/test_manifestes.sh"
bash tests/test_secrets.sh | grep -v '^OK' | sed 's/^/secrets: /'
[ "${PIPESTATUS[0]}" = 0 ] || ko "tests/test_secrets.sh"

exit $((ECHECS > 0))
