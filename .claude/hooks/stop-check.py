#!/usr/bin/env python3
"""Stop hook: a turn that changed code cannot end on a broken build.

Runs scripts/ai/check.sh (format lint + incremental build on this change; cached per change, so
an unchanged tree costs nothing). On failure it exits 2 with a short summary on stderr, so Claude
continues and fixes it, or says plainly why it cannot. Never blocks twice in a row
(stop_hook_active), never blocks without code changes, never blocks on its own errors.
Off for a session: IOS_AI_STOP_CHECK=0. Time budget: IOS_AI_STOP_TIMEOUT seconds (default 240).
"""
import json
import os
import subprocess
import sys
from pathlib import Path


def main() -> int:
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return 0
    if ev.get("stop_hook_active") or os.environ.get("IOS_AI_STOP_CHECK", "1") == "0":
        return 0
    root = Path(ev.get("cwd") or os.getcwd())
    try:
        root = Path(subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"],
                                   capture_output=True, text=True, timeout=5).stdout.strip() or root)
    except Exception:
        pass
    check = root / "scripts/ai/check.sh"
    if not check.exists():
        return 0
    try:
        r = subprocess.run(["/bin/bash", str(check)], cwd=root, capture_output=True, text=True,
                           timeout=int(os.environ.get("IOS_AI_STOP_TIMEOUT", "240")))
    except subprocess.TimeoutExpired:
        print("ios-ai stop check: timed out; run scripts/ai/check.sh yourself before calling this done.", file=sys.stderr)
        return 0
    if r.returncode == 0:
        return 0
    lines = [l for l in (r.stdout + r.stderr).splitlines() if l.strip()][-25:]
    print("ios-ai stop check FAILED on this change (format lint + build). Fix it, or say plainly in your reply "
          "why it cannot be fixed now:\n" + "\n".join(lines), file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)
