#!/usr/bin/env python3
"""PermissionRequest hook: answers a permission prompt that nobody is there to answer.

Fires only after the settings rules (and the PreToolUse guard) decided a prompt is needed, so it
never overrides a deny rule. Locally (CLAUDE_CODE_REMOTE unset) it prints nothing and the human
gets the prompt as before. In a cloud session there is no human, and an unanswered prompt stalls
the session forever, so it answers:

- allow, once (no appliedRules), a command made ONLY of publish steps: git add/commit/status/diff/
  log/show/fetch/rev-parse, `git push [-u] origin <prefix>…` with explicit branches under
  CLOUD_BRANCH_PREFIX (default claude/), gh pr create/view/list/checks, and tail/head/wc/grep;
- deny everything else, with a reason Claude reads and acts on (push to its own branch, open a
  PR, or list the step as not done). Any construct the parser does not fully understand
  (substitution, heredoc, a redirect to a file, git -C/-c, an env prefix) is denied.

Config (.claude/ios.env, overridable by the environment): CLOUD_BRANCH_PREFIX=claude/ ·
CLOUD_PUBLISH=1 (0 = deny every publish too; the owner pushes by hand).
"""
import json
import os
import re
import shlex
import sys
from pathlib import Path

SEPARATORS = {"&&", "||", ";", "|", "|&", "&"}
REDIRECTS = {">", ">>", ">&", "<", "<<", "&>", "&>>", "<<<"}
FILTERS = {"tail", "head", "wc", "grep"}
GIT_LOCAL = {"add", "commit", "status", "diff", "log", "show", "fetch", "rev-parse"}
GH_PR = {"create", "view", "list", "checks"}
PUSH_FLAGS = {"-u", "--set-upstream", "-q", "--quiet", "-v", "--verbose"}
HOWTO = ("Cloud sessions publish only their own branch: `git push -u origin {p}<name>`, then "
         "`gh pr create`; the owner merges after /verify passes on a Mac.")


class Unclear(Exception):
    pass


def segments(cmd: str) -> list[list[str]]:
    """Simple commands of a shell line, quotes respected. Raises Unclear on anything else."""
    buf, q, i = [], "", 0
    while i < len(cmd):
        c = cmd[i]
        if c == "\\" and q != "'":
            buf.append(cmd[i:i + 2])
            i += 2
            continue
        if c == "`" or (c == "$" and cmd[i + 1:i + 2] == "(" and q != "'"):
            raise Unclear("command substitution")
        if q:
            if c == q:
                q = ""
        elif c in "'\"":
            q = c
        elif c == "\n":
            c = " ; "  # an unquoted newline separates commands, exactly like ;
        buf.append(c)
        i += 1
    try:
        lex = shlex.shlex("".join(buf), posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""  # a `#` must never hide the rest of the line (the newline became `;`)
        toks = list(lex)
    except ValueError as e:
        raise Unclear(str(e))
    segs, cur, j = [], [], 0
    while j < len(toks):
        t = toks[j]
        if t in SEPARATORS:
            segs.append(cur)
            cur = []
        elif t in REDIRECTS:
            target = toks[j + 1] if j + 1 < len(toks) else ""
            if t not in (">", ">&", "&>") or target not in ("1", "2", "/dev/null"):
                raise Unclear(f"redirect {t} {target}")
            if cur and cur[-1].isdigit():
                cur.pop()
            j += 1
        elif t and all(ch in "()<>|&;" for ch in t):  # `<(`, `>(`, `>|`, `(`, `;;`: not a plain argument
            raise Unclear(f"operator {t}")
        else:  # unquoted operators are already their own tokens; these characters here were quoted
            cur.append(t)
        j += 1
    segs.append(cur)
    return [s for s in segs if s]


def push_problem(args: list[str], prefix: str) -> str | None:
    flags = [a for a in args if a.startswith("-")]
    pos = [a for a in args if not a.startswith("-")]
    odd = [f for f in flags if f not in PUSH_FLAGS]
    if odd:
        return f"{' '.join(odd)} can rewrite, delete or widen what is pushed"
    if len(pos) < 2:
        return "a push without an explicit remote and branch follows config and can reach the default branch"
    if pos[0] != "origin":
        return f"the remote is {pos[0]}, not origin"
    branch = re.compile(r"^(HEAD:)?(refs/heads/)?" + re.escape(prefix) + r"[A-Za-z0-9._/-]+$")
    bad = [r for r in pos[1:] if not branch.match(r)]
    return f"{', '.join(bad)} is not a {prefix}* branch" if bad else None


def verdict(cmd: str, prefix: str = "claude/", publish: bool = True) -> tuple[str, str]:
    howto = HOWTO.format(p=prefix)
    try:
        segs = segments(cmd)
    except Unclear as e:
        return "deny", (f"Nobody is here to approve this in a cloud session, and it has a construct the "
                        f"cloud gate does not approve ({e}). Split it into plain commands, or list it as not done.")
    if not segs:
        return "deny", "Nobody is here to approve an empty command in a cloud session."
    for i, s in enumerate(segs):
        if s[0] == "git" and len(s) > 1 and s[1] == "fetch" and any(a.startswith(("--upload-pack", "--exec", "-c")) for a in s[2:]):
            return "deny", "git fetch with --upload-pack/--exec/-c can run arbitrary commands."
        if s[0] == "git" and s[1:2] == ["push"]:
            if not publish:
                return "deny", "This repo publishes cloud work by hand (CLOUD_PUBLISH=0): commit, and say the branch is unpushed."
            why = push_problem(s[2:], prefix)
            if why:
                return "deny", f"Refused: {why}. {howto}"
        elif s[:3] == ["gh", "pr", "merge"]:
            return "deny", f"Cloud sessions never merge. {howto}"
        elif s[0] == "git" and len(s) > 1 and s[1] in GIT_LOCAL:
            continue
        elif s[:2] == ["gh", "pr"] and len(s) > 2 and s[2] in GH_PR:
            if s[2] == "create" and not publish:
                return "deny", "This repo publishes cloud work by hand (CLOUD_PUBLISH=0)."
        elif s[0] in FILTERS and i > 0:  # a filter is a pipe's tail, never a standalone file reader
            continue
        else:
            return "deny", (f"Nobody is here to approve `{' '.join(s)[:80]}` in a cloud session. Do it another "
                            f"way, or list it as not done in your report.")
    return "allow", "Cloud session publishing its own branch (ios-ai-kit cloud gate)."


def config() -> tuple[str, bool]:
    vals = {}
    env = Path(os.environ.get("CLAUDE_PROJECT_DIR", ".")) / ".claude/ios.env"
    try:
        for line in env.read_text().splitlines():
            m = re.match(r"\s*(CLOUD_[A-Z_]+)=(.*)", line)
            if m:
                vals[m.group(1)] = m.group(2).strip().strip("'\"")
    except OSError:
        pass
    vals.update({k: v for k, v in os.environ.items() if k.startswith("CLOUD_")})
    return vals.get("CLOUD_BRANCH_PREFIX") or "claude/", vals.get("CLOUD_PUBLISH", "1") != "0"


def answer(behavior: str, reason: str) -> None:
    d = {"behavior": behavior}
    if behavior == "deny":
        d["message"] = reason
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": d}}))


def main() -> None:
    if os.environ.get("CLAUDE_CODE_REMOTE") != "true":
        return  # a human is here: let the prompt show
    try:
        ev = json.load(sys.stdin)
        tool, ti = ev.get("tool_name", ""), ev.get("tool_input") or {}
        if tool != "Bash":
            answer("deny", f"Nobody is here to approve {tool} in a cloud session. Do it another way, or list it "
                           "as not done in your report.")
            return
        prefix, publish = config()
        answer(*verdict(ti.get("command", ""), prefix, publish))
    except Exception as e:  # fail safe: in the cloud a broken gate refuses, it never approves
        answer("deny", f"The cloud gate could not read this request ({str(e)[:80]}); list the step as not done.")


if __name__ == "__main__":
    main()
