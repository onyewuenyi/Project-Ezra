#!/usr/bin/env python3
"""Claude Code status line for this workflow: where you are and what is waiting, always in view.

  ⎇ claude/topic · ✓ verified 3171e3c · 2 PRs need you · 3 uncommitted

HEAD's verify state comes from the verify history (✓ passed, ✗ failed with the gate, ○ not verified,
nothing on the default branch with nothing ahead); "need you" from /lead's cached digest. Git and
files only, so it stays fast. Opt in per developer: install.py --statusline (writes the gitignored
.claude/settings.local.json, never over a status line you already have).
"""
import json
import os
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True  # never leave __pycache__ in the project's scripts/ai
sys.path.insert(0, str(Path(__file__).resolve().parent))
import history  # noqa: E402
from kit import git, state_dir  # noqa: E402

DIM, GREEN, RED, YELLOW, RESET = "\033[2m", "\033[32m", "\033[31m", "\033[33m", "\033[0m"


def line(cwd: str) -> str:
    branch = git("rev-parse", "--abbrev-ref", "HEAD", cwd=cwd)
    if not branch:
        return ""
    parts = [f"⎇ {branch}"]
    base_ref = git("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD", cwd=cwd)
    base = base_ref.rsplit("/", 1)[-1] if base_ref else "main"
    ahead = git("rev-list", "--count", f"origin/{base}..HEAD", cwd=cwd)
    sd = state_dir(cwd)
    sha = git("rev-parse", "HEAD", cwd=cwd)
    run = history.last_run(sha, history.rows(sd / "verify.tsv"))
    gates = [r for r in run or [] if not r["gate"].startswith("fail:")]
    failed = [r["gate"] for r in gates if r["result"] == "FAIL"]
    if failed:
        parts.append(f"{RED}✗ {'/'.join(failed)} failed{RESET}")
    elif gates and gates[0]["dirty"] == "0":
        parts.append(f"{GREEN}✓ verified {sha[:7]}{RESET}")
    elif branch != base or (ahead.isdigit() and int(ahead)):
        parts.append(f"{DIM}○ not verified{RESET}")
    if branch == base and ahead.isdigit() and int(ahead):
        parts.append(f"{YELLOW}{ahead} on {base}: scripts/ai/pr.sh{RESET}")
    try:
        digest = json.loads((sd / "prs.json").read_text())
        mine = [i for i in digest.get("items", []) if i.get("bucket") == "needs-you"]
        age = time.time() - digest.get("generated", time.time())
        stale = f" {DIM}({age / 3600:.0f}h old: /lead){RESET}" if age > 6 * 3600 else ""
        if mine:
            parts.append(f"{YELLOW}{len(mine)} PR{'s' if len(mine) > 1 else ''} need you{RESET}{stale}")
    except (OSError, ValueError):
        pass
    dirty = [l for l in git("status", "--porcelain", "--untracked-files=no", cwd=cwd).splitlines() if l.strip()]
    if dirty:
        parts.append(f"{DIM}{len(dirty)} uncommitted{RESET}")
    return f" {DIM}·{RESET} ".join(parts)


def main() -> None:
    try:
        ev = json.load(sys.stdin)
    except Exception:
        ev = {}
    cwd = (ev.get("workspace") or {}).get("current_dir") or ev.get("cwd") or os.getcwd()
    print(line(cwd))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("")
