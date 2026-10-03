#!/usr/bin/env python3
"""SessionStart hook: the few facts a session should know before it touches anything. Silent when all
is well, and in cloud sessions.

Only unhealthy lines: commits on the default branch that never went through a PR, uncommitted work
(another session may share this checkout), HEAD's last /verify failed or a branch's HEAD was never
verified, PRs that need the owner (from /lead's cached digest, with its age), doctor warnings, and
healthchecks gone stale. Cheap by contract: git and files only, never the network or xcodebuild.
Fails open: any error prints nothing.
"""
import json
import os
import sys
import time
from pathlib import Path


def ago(seconds: float) -> str:
    return f"{seconds / 3600:.0f}h" if seconds < 2 * 86400 else f"{seconds / 86400:.0f}d"


def main() -> None:
    try:
        ev = json.load(sys.stdin)
    except Exception:
        ev = {}
    if os.environ.get("CLAUDE_CODE_REMOTE") == "true":
        return
    root = Path(os.environ.get("CLAUDE_PROJECT_DIR") or ev.get("cwd") or os.getcwd())
    ai = root / "scripts/ai"
    if not (ai / "kit.py").exists():
        return
    sys.dont_write_bytecode = True  # never leave __pycache__ in the project's scripts/ai
    sys.path.insert(0, str(ai))
    import history  # noqa: E402
    from kit import git, state_dir  # noqa: E402

    now, lines = time.time(), []
    sd = state_dir(root)
    base_ref = git("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD", cwd=root)
    base = base_ref.rsplit("/", 1)[-1] if base_ref else "main"
    branch = git("rev-parse", "--abbrev-ref", "HEAD", cwd=root)
    ahead = git("rev-list", "--count", f"origin/{base}..HEAD", cwd=root)
    if branch == base and ahead.isdigit() and int(ahead):
        lines.append(f"{ahead} commit(s) on {base} are not on origin: scripts/ai/pr.sh moves them to a branch and "
                     "opens the PR (never push to the default branch).")
    merged = branch not in (base, "HEAD") and ahead == "0" and \
        git("rev-parse", "--verify", "-q", f"origin/{base}", cwd=root) != ""
    if merged:
        lines.append(f"{branch} has nothing that is not already on {base} (merged or empty): start the next change "
                     f"with `git switch -c claude/<topic> origin/{base}`.")
    dirty = [l for l in git("status", "--porcelain", "--untracked-files=no", cwd=root).splitlines() if l.strip()]
    if dirty:
        lines.append(f"{len(dirty)} uncommitted path(s): stage by path, another session may share this checkout.")

    sha = git("rev-parse", "HEAD", cwd=root)
    rows = history.rows(sd / "verify.tsv")
    run = history.last_run(sha, rows)
    if run and any(r["result"] == "FAIL" and not r["gate"].startswith("fail:") for r in run):
        failed = ", ".join(r["gate"] for r in run if r["result"] == "FAIL" and not r["gate"].startswith("fail:"))
        lines.append(f"The last /verify on HEAD {sha[:7]} FAILED ({failed}): .build/verify/report.md.")
    elif not run and branch != base and ahead.isdigit() and int(ahead):
        lines.append(f"HEAD {sha[:7]} on {branch} has not been verified: /verify before scripts/ai/pr.sh.")

    try:
        digest = json.loads((sd / "prs.json").read_text())
        mine = [i for i in digest.get("items", []) if i.get("bucket") == "needs-you"]
        if mine:
            shown = "; ".join(f"#{i['number']} {i['action']}" if i.get("number") else f"cloud {i['action']}"
                              for i in mine[:4])
            more = f" and {len(mine) - 4} more" if len(mine) > 4 else ""
            lines.append(f"Needs you ({ago(now - digest.get('generated', now))} old, /lead refreshes): {shown}{more}.")
    except (OSError, ValueError):
        pass

    doctor = sd / "doctor.txt"
    try:
        stamp, *warns = doctor.read_text().splitlines()
        age = now - float(stamp)
        lines += [f"doctor: {w.strip()}" for w in warns[:3]]
        if age > 7 * 86400:
            lines.append(f"scripts/ai/doctor.sh last ran {ago(age)} ago.")
    except (OSError, ValueError):
        pass
    friction = sd / "friction.last"
    oldest = float(rows[0]["ts"]) if rows else now
    since = friction.stat().st_mtime if friction.exists() else oldest
    if now - since > 7 * 86400:
        lines.append("The friction healthcheck has not run in 7 days: /friction.")

    if lines:
        text = "ios-ai-kit bearings:\n" + "\n".join(f"- {l}" for l in lines)
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
