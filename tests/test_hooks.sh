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
for c in 'gh issue close 9' 'gh issue edit 9 -t x' 'gh issue delete 9' 'gh issue reopen 9' 'gh issue transfer 9 o/r' \
         'gh issue create -R o/r -t x -b y' 'gh issue create --repo=o/r -t x' 'gh issue comment 9 --repo o/r -b x' \
         'gh issue comment https://github.com/o/r/issues/1 -b x' 'gh issue comment 9 --edit-last -b x' 'rtk gh issue close 9' \
         "bash -c 'gh issue delete 9'" 'gh issue create -Ro/r -t x' 'gh issue comment 9 --delete-last' 'gh issue -R o/r close 9' 'gh issue pin 9' 'gh issue' \
         'gh issue comment HTTPS://github.com/o/r/issues/1 -b x' 'gh issue create --parent HTTPS://github.com/o/r/issues/1 -t x' \
         'gh issue comment 9 --edit-last=true -b x' 'gh issue comment 9 --delete-last=true' 'gh issue create -wRo/r -t x' 'gh issue create -eRo/r -t x' \
         'gh issue create --parent 5 -t x' 'gh issue create --blocking=5 -t x' 'gh issue create --blocked-by 5 -t x' \
         'gh repo set-default o/r' 'gh alias set x y' 'gh alias import f'; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'timeout 5 gh pr merge 1' 'nice gh pr merge 1' 'nice -n 5 gh pr merge 1' 'echo 1 | xargs gh pr merge' 'xargs -n1 gh pr merge' \
         'eval gh pr merge 1' "bash -lc 'gh pr merge 1'" "sh -c 'gh pr merge 1'" '( gh pr merge 1 )' '(gh pr merge 1)' 'echo $(gh pr merge 1)' \
         'echo `gh pr merge 1`' 'env gh pr merge 1' 'command gh pr merge 1' 'sudo gh pr merge 1' 'sudo -u x gh pr merge 1' 'stdbuf -oL gh pr merge 1' \
         'stdbuf -o L gh pr merge 1' '/usr/bin/gh pr merge 1' 'nohup gh pr merge 1' 'timeout -k 1 5 gh pr merge 1' \
         'timeout 5 gh api -X POST repos/o/r/merges' 'timeout 5 git push origin main' 'nice git push origin main' "bash -c 'eval gh pr merge 1'" \
         'eval git push origin main' "bash -ic 'git push origin main'"; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'timeout 5 gh pr view 1' "bash -c 'echo ok'" 'echo $(date)' 'nice make test' 'echo `date`' '(cd /tmp && ls)' 'timeout 5 git status'; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
for c in 'GIT_SSH_COMMAND=x eval git push origin claude/x' 'GIT_SSH_COMMAND=x bash -c \"git push origin claude/x\"' "env GH_PAGER=x bash -lc 'gh pr view 1'" \
         'echo \\'"'"' $(gh pr merge 1)' 'exec -a n gh pr merge 1' 'setsid gh pr merge 1' 'ionice -c 3 gh pr merge 1' 'doas -u x gh pr merge 1' \
         'chrt -f 10 gh pr merge 1' 'taskset 0x1 gh pr merge 1' 'flock /tmp/l gh pr merge 1' 'unbuffer gh pr merge 1' 'watch -n 5 gh pr merge 1' \
         'find . -exec gh pr merge 1 \\;' 'find . -execdir gh pr merge {} +' 'echo gh pr merge 1 | bash' "printf 'git push origin main' | sh -s" \
         'bash <<< gh pr merge 1' 'bash <<EOF\ngh pr merge 1\nEOF' 'cat <<EOF\n$(gh pr merge 1)\nEOF'; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'echo ok | bash' 'gh pr view 1 | cat' 'echo \"\\`gh pr merge\\`\"' 'git commit -m \"$(cat <<'"'"'EOF'"'"'\nx gh pr merge\nx git push origin main\nEOF\n)\"'; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
for c in 'eval \"$(cat <<'"'"'X'"'"'\ngh pr merge 1\nX\n)\"' 'bash -c \"$(cat <<'"'"'X'"'"'\ngh pr merge 1\nX\n)\"' "watch 'gh pr merge 1'" "flock f -c 'gh pr merge 1'" \
         "find . -exec sh -c 'gh pr merge 1' \\\;" 'echo \"<<'"'"'X'"'"'\"\ngh pr merge 1\nX' "bash -c 'echo gh'" "echo gh | xargs sh -c 'gh pr merge 1'"; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'git commit -m \"$(cat <<'"'"'EOF'"'"'\nx gh pr merge\nEOF\n)\"' 'watch -n1 git status' "gh api repos/o/r/rulesets --jq '.[] // empty'"; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
for c in 'cat <<<'"'"'X'"'"'\ngh pr merge 1\nX' 'true # <<'"'"'X'"'"'\ngh pr merge 1\nX' 'echo $(date) \"<<'"'"'X'"'"'\"\ngit push origin main\nX' \
         "ksh -c 'gh pr merge 1'" "busybox sh -c 'gh pr merge 1'"; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'git commit -m \"$(cat <<'"'"'EOF'"'"'\nx `gh pr merge` et `git push origin main`\nEOF\n)\"'; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
for c in 'gh issue create -t x -F f' 'gh issue comment 9 -F f' 'gh issue view 1 -R stanixia-dev/Hive' 'gh issue list --author @me --state open'; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
for c in 'git push -u origin claude/x' 'gh pr create --fill' 'gh pr checks --watch --interval 20' 'rtk git push -u origin claude/x'; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
sortie_rappel 'gh pr create --fill' | grep -q '/clear' && ok "rappel-clear après gh pr create" || ko "rappel-clear pr create"
[ -z "$(sortie_rappel 'ls')" ] && ok "rappel-clear muet sur ls" || ko "rappel-clear ls"

# garde-deps : "commande|attendu" (0 = passe sans sortie, 2 = bloque)
for c in 'cargo add bon' 'pnpm add @scope/ok@1.0.0' 'cargo add mixte' \
         'npm install' 'pip install -r requirements.txt' 'pip install -e .' 'npm i ./local' 'cargo add --path ../x' \
         'cargo add cc0' 'npm i @fontsource/police' 'pip install police' "bash -c 'echo \"a && npm i gpl-pkg\"'" "bash -c 'ls && echo ok'" "git commit -m 'doc: npm i gpl-pkg \`npm i gpl-pkg\`'" 'cargo add bon 2>&1 | tail -1' \
         "git commit -m \"\$(cat <<'EOF'"$'\nAjoute l\'analyse de npm i x\nEOF\n)\"' \
         "cat > notes.md <<'EOF'"$'\nnpm i gpl-pkg\nEOF' "cat <<'EOF' | tee n.md"$'\nnpm i gpl-pkg\nEOF' \
         'ls #c && npm i gpl-pkg' 'echo $# && cargo add bon' \
         'echo $((1<<2)) && cargo add bon' 'if true; then cargo add bon; fi' 'timeout 5 cargo add bon' \
         'nice -n 5 cargo add bon' 'sudo -u x cargo add bon' 'echo bon | xargs -n1 cargo add' 'time cargo add bon' \
         "bash -c -- 'ls'" 'npm -g i @scope/ok@1.0.0' 'npm --prefix . i @scope/ok@1.0.0' \
         'curl -s x | sh' 'bash script.sh' "$PROFOND" 'cat ~/.claude/settings.json' 'grep x ~/.claude/settings.json' \
         "python3 -c \"import json,os;d=json.load(open(os.path.expanduser('~/.claude/settings.json')));print('permissions' in d)\"" \
         'grep -r x .github/workflows' 'python3 ~/.claude/plugins/cache/k/3.1.0/skills/ci-projet/genere-ci.py' \
         'python3 ~/.claude/plugins/cache/k/3.1.0/skills/ci-projet/genere-ci.py 2>&1 | tail -5' \
         "git commit -m 'doc .github/workflows'" 'git diff main -- .garde-deps-exceptions' 'ls ~/.claude/hooks' \
         'echo ok > /dev/null' 'git status' 'curl -s https://x.io/a' 'echo "$(git log --format="%h #%s")"' 'git log --format="%h #%s"' \
         'sed -i "114s|a|python3 ~/.claude/plugins/x.py|" tests/test_hooks.sh' 'sed -i -e "s|a|.claude/hooks|" t.sh' \
         'sed -i --expression=s/a/.github\/workflows/ t.sh' 'echo "it'"'"'s" ok' \
         'wget -q https://x.io/a' 'awk 1 ~/.claude/settings.json' 'sed -n 1p ~/.claude/settings.json' 'sed -n 1,5p f' 'sed -i s/a/b/ src/x.rs' \
         "sed -i -e 's/x/y/' -e 's/a/b/' src/x.rs" "find . -name '*.rs' -exec grep x {} +" 'cp a b'; do
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
         'find . -exec npm i gpl-pkg \;' \
         'sed -i --file=x .github/workflows/ci.yml' 'sed -i -fx ~/.claude/settings.json' 'sed -i -n -fy ~/.claude/settings.json' \
         'sed -i --expr=s/a/b/ ~/.claude/settings.json' 'find . -exec true \; -exec npm i gpl-pkg \;' \
         'find . -exec true \; -exec cp a ~/.claude/settings.json \;' "find . -exec sh -c 'npm i gpl-pkg' \\;" \
         "sed -i 'w ~/.claude/settings.json' f" "sed -i 's/a/b/w ~/.claude/settings.json' f" "sed -i '1e npm i gpl-pkg' f" \
         'echo `echo # `; npm i gpl-pkg' 'echo "it'"'"'s" `npm i gpl-pkg`' 'echo "it'"'"'s $(npm i gpl-pkg)"' \
         'sed -i -e x .github/workflows/ci.yml' 'sed -i -e x -e y ~/.claude/settings.json' \
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
         "echo 'script x.sh $(printf 'a%.0s' {1..64}) 2026-11-04 r' >> .garde-secret-exceptions" \
         "python3 -c \"import json,os;p=os.path.expanduser('~/.claude/settings.json');d=json.load(open(p));d.pop('permissions',None);json.dump(d,open(p+'.tmp','w'),indent=2);os.replace(p+'.tmp',p)\"" \
         "python3 -c \"import os;os.replace('a','/home/u/.claude/settings.json')\"" \
         "python3 -c \"from pathlib import Path;Path('/home/u/.claude/settings.json').write_text('x')\"" \
         "python3 -c \"print(1)\" ~/.claude/settings.json" "python3 ~/.claude/hooks/x.py" \
         'python3 ~/.claude/plugins/cache/k/3.1.0/skills/ci-projet/genere-ci.py ~/.claude/settings.json' \
         'python3 ~/.claude/plugins/cache/k/x.py > ~/.claude/settings.json' \
         'python3 ~/.claude/plugins/../hooks/x.py' 'python3 ~/.claude/plugins/x/../../hooks/garde-deps.py' \
         'python3 ~/.claude/plugins/x/../../settings.local.json' 'python3 ./.claude/plugins/x.py' \
         'git clone https://x.io/r ~/.claude/plugins/evil' 'git worktree add ~/.claude/hooks/w' 'git init ~/.claude/plugins/evil' \
         "node -e \"console.log(require('/home/u/.claude/settings.json').permissions)\"" \
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
         "python3 -c \"p='/home/u/.claude/settings.json';open(*(p,'w'))\"" \
         "python3 -c \"ｏｐｅｎ('/home/u/.claude/settings.json','w')\"" \
         "python3 -c \"import os;os.ｒｅｍｏｖｅ('/home/u/.claude/settings.json')\"" \
         "perl -e 'open F, \">\", \"\$ENV{HOME}/.claude/settings.json\"; print F \"x\"'" \
         "perl -e 'system \"cp a \$ENV{HOME}/.claude/settings.json\"'" \
         "perl -e 'rename \"a\", \"\$ENV{HOME}/.claude/settings.json\"'" \
         "ruby -e '\`cp a ~/.claude/settings.json\`'" \
         "node -e \"require('f'+'s')['wr'+'iteFileSync']('/home/u/.claude/settings.json','x')\"" \
         "php -r 'unlink(\"/home/u/.claude/settings.json\");'"; do
  [ "$(code_deps "$c")" = 2 ] && ok "garde-deps bloque $c" || ko "garde-deps $c"
done
# gh api : liste blanche (lecture libre, écriture limitée aux milestones)
for c in 'gh api -X POST repos/o/r/merges -f base=main -f head=x' 'gh api repos/o/r/merges -f base=main' 'gh api repos/o/r/pulls/1/merge -X PUT' \
         'gh api -XPATCH repos/o/r/issues/1 -f state=closed' 'gh api --method=patch repos/o/r/pulls/1 -f state=closed' \
         'gh api -iXPATCH repos/o/r/issues/1 -f state=closed' 'gh api -X DELETE repos/o/r/milestones/1' 'gh api -X PUT repos/o/r/milestones/1' \
         'gh api -X POST repos/o/r/milestones/1 -f state=closed' 'gh api -X PATCH repos/o/r/milestones -f title=x' \
         "gh api -H 'Accept: x' repos/o/r/labels -f name=x" 'gh api repos/o/../milestones -f title=x' \
         'gh api https://api.github.com/repos/o/r/milestones -f title=x' "gh api 'repos/o/r/milestones?x=1' -f title=x" \
         'gh api --input f repos/o/r/milestones' 'gh api repos/o/r/milestones -F title=@f' 'gh api repos/o/r/milestones -Ftitle=@f' \
         'gh api -X GET search/issues -F q=@f' 'gh api --hostname evil.example repos/o/r/milestones -f title=x' \
         'gh api repos/o/r/milestones repos/o/r/merges -f title=x' "gh api graphql -f query='mutation { x }'" \
         'gh api graphql -f query=$(cat q.txt)' 'gh api graphql -f query=mu$(echo t)ation' 'Q=x; gh api graphql -f query=$Q' \
         'rtk gh api -X POST repos/o/r/merges -f base=main' "bash -c 'gh api repos/o/r/merges -f base=main'"; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'gh api repos/o/r/milestones' 'rtk gh api repos/o/r/milestones' "gh api --paginate 'repos/{owner}/{repo}/milestones?state=all'" \
         'gh api -X GET search/issues -f q=repo:o/r' 'gh api graphql -f query=query{viewer{login}}' "gh api graphql -f query='query { viewer { login } }'" \
         "gh api 'repos/{owner}/{repo}/milestones' -f title=v1 -f due_on=2026-12-01T00:00:00Z" \
         'gh api -X POST repos/stanixia-dev/kit-perso/milestones -f title=v1' "gh api -XPATCH 'repos/{owner}/{repo}/milestones/3' -f state=closed" \
         'gh api --method=patch /repos/o/r/milestones/3 -f state=closed' \
         "gh api -H 'Accept: application/vnd.github+json' -X PATCH repos/o/r/milestones/3 -f state=closed"; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
# détection de la CI (livrer, specs) : deux GET admis, écriture sur la protection refusée
code_garde_j() { json_cmd "$1" | python3 hooks/garde-git.py >/dev/null 2>&1; echo $?; }
for c in "gh api repos/{owner}/{repo}/rules/branches/main --jq '[.[] | select(.type == \"required_status_checks\")] | length'" \
         "gh api repos/{owner}/{repo}/branches/main/protection --jq '.required_status_checks.checks | length'"; do
  [ "$(code_garde_j "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
[ "$(code_garde_j 'gh api -X PUT repos/o/r/branches/main/protection')" = 2 ] && ok "garde-git bloque le PUT sur la protection" || ko "garde-git PUT protection"
for c in 'gh issue edit 9 --milestone v1 -t x' 'gh issue edit 9 --add-label x' 'gh issue edit 9' 'gh issue edit 9 -m v1 -R o/r' \
         'gh issue edit https://github.com/o/r/issues/9 -m v1' 'gh issue create -R autre/r -t x' 'gh issue -R o/r create -t x' \
         'gh issue create -wRstanixia-dev/kit-perso -t x' 'gh issue create -R stanixia-dev/.. -t x' 'gh issue create -R stanixia-dev/a/b -t x' \
         'gh issue create -R stanixia-dev -t x' 'gh issue create -R github.com/stanixia-dev/kit-perso -t x'; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'gh issue edit 9 --milestone v1' 'gh issue edit 9 10 -m v1' 'gh issue edit 9 --milestone=v1' 'gh issue edit 9 --remove-milestone' \
         'gh issue edit 9 -m v1 -R stanixia-dev/kit-perso' 'gh issue create -R stanixia-dev/kit-perso -t x -b y' \
         'gh issue create --repo=STANIXIA-DEV/kit-perso -t x' 'gh issue comment 5 -Rstanixia-dev/kit-perso -b x' \
         'gh issue -R stanixia-dev/kit-perso create -t x' 'gh issue create -R stanixia-dev/Hive -t x' 'gh pr edit 3 --milestone v1'; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
# gh : options avant ou entre les sous-commandes (-R/--repo)
for c in 'gh pr -R o/r merge 1' 'gh -R o/r pr merge 1' 'gh pr --repo=o/r merge 1' 'gh pr --repo o/r review 1 --approve' 'gh -R o/r pr close 1' \
         'gh -R o/r api -X POST repos/o/r/merges -f base=main' 'gh -R o/r issue close 3' 'gh --repo o/r secret set X'; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'gh pr --body x merge 1' 'gh pr -b x merge 1' 'gh -b x pr merge 1' 'gh pr --body x review 1 --approve' 'gh pr --draft --body x merge 1'; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'gh pr create --fill' 'gh pr view 23' 'gh pr list --state open'; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
for c in 'gh pr -R o/r view 1' 'gh -R o/r pr list' 'gh -R stanixia-dev/kit-perso issue create -t x'; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
# git : options globales, abréviations, --all, HEAD, refspec *
for c in 'git -c core.sshCommand=x push origin b' 'git -c protocol.ext.allow=always push origin b' 'git --config-env core.sshCommand=E push origin b' \
         'git --config-env=core.sshCommand=E push origin b' 'git --exec-path=/tmp/x push origin b' 'git -c alias.p=push p origin main' \
         'git --namespace x push origin main' 'git --attr-source x push origin main' \
         'git push --all origin' 'git push --branches origin' 'git push --al origin' "git push origin 'refs/heads/*:refs/heads/*'" \
         'git push --mirr origin' 'git push --del origin b' 'git push --ex=x origin b' 'git push --receive-p=x origin b' \
         'git push --no-veri origin b' 'git push --force-w origin b' 'git push --pru origin' 'git push -ud origin b' \
         'git commit --no-veri -m x'; do
  [ "$(code_garde "$c")" = 2 ] && ok "garde-git bloque $c" || ko "garde-git $c"
done
for c in 'git -c user.name=x commit -m y' 'git -C x push origin b' 'git push --tags origin' 'git push --follow-tags origin b' \
         'git push --porcelain origin b' 'git push --dry-run origin b' 'git push -u origin b' 'git push --push-option=ci.skip origin b' \
         'git commit -am x' 'git push origin HEAD'; do
  [ "$(code_garde "$c")" = 0 ] && ok "garde-git laisse passer $c" || ko "garde-git $c"
done
code_garde_main() { # $1 = commande, dans un dépôt jetable sur main
  local d; d=$(mktemp -d); git init -q -b main "$d"
  printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$d" | python3 hooks/garde-git.py >/dev/null 2>&1
  local r=$?; rm -rf "$d"; echo $r
}
for c in 'git push origin HEAD' 'git push origin @'; do
  [ "$(code_garde_main "$c")" = 2 ] && ok "garde-git bloque sur main $c" || ko "garde-git main $c"
done
[ "$(code_garde_main 'git push -o x origin')" = 2 ] && ok "garde-git bloque sur main git push -o x origin" || ko "garde-git push -o"
[ "$(code_garde_main 'git push --push-option x origin')" = 2 ] && ok "garde-git bloque sur main git push --push-option x origin" || ko "garde-git push --push-option"
# garde-deps : chemins protégés normalisés
for c in 'cp a .github/./workflows/t.yml' 'cp a .github//workflows/t.yml' 'cp a .github/x/../workflows/t.yml'; do
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
[ "$(code_deps 'npm i depublie')" = 0 ] && sortie_deps 'npm i depublie' | grep -q 'vérification impossible' \
  && ok "garde-deps avertit sur une réponse de registre mal formée" || ko "garde-deps réponse mal formée"

bash tests/test_manifestes.sh | grep -v '^OK' | sed 's/^/manifestes: /'
[ "${PIPESTATUS[0]}" = 0 ] || ko "tests/test_manifestes.sh"
bash tests/test_secrets.sh | grep -v '^OK' | sed 's/^/secrets: /'
[ "${PIPESTATUS[0]}" = 0 ] || ko "tests/test_secrets.sh"
bash tests/test_ci_projet.sh | grep -v '^OK' | sed 's/^/ci-projet: /'
[ "${PIPESTATUS[0]}" = 0 ] || ko "tests/test_ci_projet.sh"

exit $((ECHECS > 0))
