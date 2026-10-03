#!/usr/bin/env python3
"""Summarize an .xcresult bundle as short, parseable lines (via `xcrun xcresulttool`).

usage: xcresult.py build <bundle> [--baseline <file>] [--update-baseline]
       xcresult.py test  <bundle>

build: prints `error <file>:<line>: <message>` per error and `warning ...` per NEW warning
       (not in the committed baseline), then one `build: ...` summary line.
       Exit 1 on any error or any new warning.
test:  prints `fail <test id>: <message> [<file>:<line>]` per failure and one `tests: ...` line.
       Exit 1 on any failure, or when no test ran at all.
"""

import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse


def xcresult(*args: str) -> dict:
    r = subprocess.run(["xcrun", "xcresulttool", "get", *args, "--compact"], capture_output=True, text=True)
    if r.returncode != 0:
        r = subprocess.run(["xcrun", "xcresulttool", "get", *args], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"xcresulttool failed: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout)


def location(issue: dict, root: Path) -> str:
    url = issue.get("sourceURL") or ""
    if not url:
        return ""
    parsed = urlparse(url)
    path = unquote(parsed.path)
    try:
        path = str(Path(path).resolve().relative_to(root))
    except ValueError:
        pass
    m = re.search(r"StartingLineNumber=(\d+)", parsed.fragment)
    return f"{path}:{int(m.group(1)) + 1}" if m else path  # xcresult lines are 0-based


def fingerprint(issue: dict, root: Path) -> str:
    """Stable across line shifts: file and message, not the line number."""
    loc = location(issue, root).rsplit(":", 1)[0]
    return f"{loc} | {issue.get('message', '').strip()}"


def build(bundle: str, baseline: str | None, update: bool, root: Path) -> int:
    d = xcresult("build-results", "--path", bundle)
    errors, warnings = d.get("errors", []), d.get("warnings", [])
    for e in errors:
        print(f"error {location(e, root) or '(no location)'}: {e.get('message', '').strip()}")
    known: set[str] = set()
    if baseline and Path(baseline).exists():
        known = {l.strip() for l in Path(baseline).read_text().splitlines() if l.strip() and not l.startswith("#")}
    current = [fingerprint(w, root) for w in warnings]
    if update and baseline:
        Path(baseline).parent.mkdir(parents=True, exist_ok=True)
        Path(baseline).write_text("# Accepted warnings (file | message). Regenerate: scripts/ai/build.sh --update-baseline\n"
                                  + "\n".join(sorted(set(current))) + "\n")
        print(f"baseline: {len(set(current))} warning(s) written to {baseline}")
        known = set(current)
    new = [w for w, fp in zip(warnings, current) if fp not in known]
    for w in new:
        print(f"warning {location(w, root) or '(no location)'}: {w.get('message', '').strip()}")
    status = d.get("status", "?")
    print(f"build: {status} · {len(errors)} error(s) · {len(warnings)} warning(s), {len(new)} new")
    return 1 if errors or new or status not in ("succeeded", "success") else 0


def test(bundle: str, root: Path) -> int:
    s = xcresult("test-results", "summary", "--path", bundle)
    for f in s.get("testFailures", []):
        name = f.get("testIdentifierString") or f.get("testName", "?")
        msg = (f.get("failureText") or "").strip().replace("\n", " ")
        print(f"fail {name}: {msg[:400]}")
    passed, failed, skipped = s.get("passedTests", 0), s.get("failedTests", 0), s.get("skippedTests", 0)
    print(f"tests: {s.get('result', '?')} · {passed} passed · {failed} failed · {skipped} skipped")
    if passed + failed == 0:
        print("tests: nothing ran. Check the scheme, the -only-testing id (a Swift Testing function needs \"()\": Target/Suite/name()), or a build failure before testing")
        return 1
    return 1 if failed else 0


def main() -> int:
    a = sys.argv[1:]
    if len(a) < 2 or a[0] not in ("build", "test"):
        print(__doc__)
        return 2
    root = Path.cwd().resolve()
    if a[0] == "build":
        baseline = a[a.index("--baseline") + 1] if "--baseline" in a else None
        return build(a[1], baseline, "--update-baseline" in a, root)
    return test(a[1], root)


if __name__ == "__main__":
    sys.exit(main())
