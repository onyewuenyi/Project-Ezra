#!/usr/bin/env python3
"""Drift between .claude/ios-screens.txt and the app. Silent when they agree.

  broken   a screen's launch argument (-Flag) that no Swift source reads any more: the visual gate
           would capture the wrong screen and call it judged. Exit 1.
  stale    a screen whose `#seen:YYYY-MM-DD` line (directly above it) is older than 60 days:
           re-probe its labels with /map refresh and re-date it, or retire it.
  --seams  also list the seams the code reads that no screen uses (candidates for /map).
usage: screens-drift.py [--seams] [source dirs… (default: SOURCE_DIRS from .claude/ios.env)]
"""
import re
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True  # never leave __pycache__ in the project's scripts/ai
sys.path.insert(0, str(Path(__file__).resolve().parent))
from kit import env, repo_root  # noqa: E402

FLAG = re.compile(r"(?<![\w-])-[A-Z][A-Za-z0-9]+")
READS = re.compile(r"ProcessInfo\.processInfo\.arguments|CommandLine\.arguments|LaunchSeams")
SEEN = re.compile(r"^#\s*seen:\s*(\d{4}-\d{2}-\d{2})")
STALE_DAYS = 60


def code_flags(dirs: list[Path]) -> set[str]:
    """Every -Flag literal in a Swift file that reads launch arguments."""
    flags: set[str] = set()
    for d in dirs:
        for f in d.rglob("*.swift"):
            try:
                text = f.read_text(errors="replace")
            except OSError:
                continue
            if READS.search(text):
                flags |= set(re.findall(r'"(-[A-Z][A-Za-z0-9]+)"', text))
    return flags


def screens(path: Path) -> list[dict]:
    out, seen = [], None
    for n, line in enumerate(path.read_text().splitlines(), 1):
        m = SEEN.match(line.strip())
        if m:
            seen = m.group(1)
            continue
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("|")
        out.append({"line": n, "name": parts[0].strip(), "flags": FLAG.findall(parts[1]) if len(parts) > 1 else [],
                    "seen": seen})
        seen = None
    return out


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = repo_root()
    path = root / ".claude/ios-screens.txt"
    if not path.exists():
        return 0
    dirs = [root / d for d in (args or env().get("SOURCE_DIRS", ".").split())]
    have = code_flags(dirs)
    rows, broken, now = screens(path), 0, time.time()
    for s in rows:
        missing = [f for f in s["flags"] if f not in have]
        if missing:
            broken += 1
            print(f"broken  {s['name']} (line {s['line']}): {', '.join(missing)} is not read anywhere in the app; "
                  "the visual gate would capture the wrong screen")
        if s["seen"]:
            age = (now - time.mktime(time.strptime(s["seen"], "%Y-%m-%d"))) / 86400
            if age > STALE_DAYS:
                print(f"stale   {s['name']}: last seen {s['seen']} ({age:.0f}d): /map refresh re-probes and re-dates it")
    if "--seams" in argv:
        used = {f for s in rows for f in s["flags"]}
        spare = sorted(have - used)
        if spare:
            print(f"seams not in the matrix ({len(spare)}): {' '.join(spare)}")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
