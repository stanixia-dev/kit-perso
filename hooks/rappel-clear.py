#!/usr/bin/env python3
"""Hook PostToolUse (Bash) : après un vrai `gh pr create`, rappelle de faire /clear."""
import json, re, shlex, sys

data = json.load(sys.stdin)
cmd = (data.get("tool_input") or {}).get("command", "")

def lance_pr(cmd):
    for seg in re.split(r"\|\||&&|[;|\n]", cmd):
        try:
            t = shlex.split(seg)
        except ValueError:
            continue
        while t and (t[0].rsplit("/", 1)[-1] == "rtk" or t[0] in ("bypass", "proxy", "env") or re.match(r"^\w+=", t[0])):
            t = t[1:]
        if t[:3] == ["gh", "pr", "create"]:
            return True
    return False

if lance_pr(cmd):
    print(json.dumps({
        "systemMessage": "✅ PR créée — tape /clear avant la prochaine tâche pour repartir d'un contexte vide.",
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": "PR créée : termine par le lien de la PR et rappelle à l'utilisateur de faire /clear. Ne commence pas d'autre tâche."
        }
    }, ensure_ascii=False))
