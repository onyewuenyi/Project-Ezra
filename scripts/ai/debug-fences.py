#!/usr/bin/env python3
"""Find verification seams that would compile into a Release build.

Walks every .swift file under the given roots and reports each read of launch
arguments or the environment that is not inside an active `#if DEBUG` branch.
A seam that reaches Release lets anyone with the binary drive the app's test
paths, and App Review can trip them.

Do not replace this with `strings` on the binary: Swift stores string literals
of 15 UTF-8 bytes or fewer inline in the String value, so short flags such as
`-OpenSettings` never appear in the binary's string table.

Suppress one line deliberately with a trailing `// release-seam: <reason>`.

Environment reads are listed as notes and do not fail the run (a user cannot set
the environment of an App Store build, and test-host detection legitimately reads
it); pass --strict-env to fail on them too.

usage: debug-fences.py [--strict-env] <dir> [<dir> ...]   exit 1 when an argument read is unfenced
"""

import re
import sys
from pathlib import Path

ARGS = re.compile(r"ProcessInfo\.processInfo\.arguments|CommandLine\.(arguments|argc)")
ENV = re.compile(r"ProcessInfo\.processInfo\.environment")
DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")
SKIP_DIRS = {".build", "DerivedData", "Pods", "Carthage", "checkouts", "SourcePackages"}


def branch_is_debug(cond: str) -> bool | None:
    """True if the condition selects DEBUG builds, False if it selects non-DEBUG, None if unrelated."""
    c = cond.split("//")[0].strip()
    if not re.search(r"\bDEBUG\b", c):
        return None
    if re.search(r"!\s*DEBUG\b", c):
        return False
    return True


def scan(path: Path) -> list[tuple[int, str, str]]:
    stack: list[list] = []  # [debug_of_current_branch, conds_seen_debug_values]
    hits = []
    in_block_comment = False
    for n, raw in enumerate(path.read_text(errors="replace").splitlines(), 1):
        line = raw
        if in_block_comment:
            if "*/" in line:
                in_block_comment = False
                line = line.split("*/", 1)[1]
            else:
                continue
        line = re.sub(r"/\*.*?\*/", "", line)
        if "/*" in line:
            in_block_comment = True
            line = line.split("/*", 1)[0]
        m = DIRECTIVE.match(line)
        if m:
            kind, cond = m.group(1), m.group(2)
            if kind == "if":
                d = branch_is_debug(cond)
                stack.append([d, [d]])
            elif kind == "elseif" and stack:
                d = branch_is_debug(cond)
                stack[-1][0] = d
                stack[-1][1].append(d)
            elif kind == "else" and stack:
                seen = stack[-1][1]
                # `#if !DEBUG ... #else` is the DEBUG branch; `#if DEBUG ... #else` is Release.
                if any(v is False for v in seen):
                    stack[-1][0] = True
                elif any(v is True for v in seen):
                    stack[-1][0] = False
                else:
                    stack[-1][0] = None
            elif kind == "endif" and stack:
                stack.pop()
            continue
        code = line.split("//")[0]
        kind = "seam" if ARGS.search(code) else "env" if ENV.search(code) else None
        if kind is None:
            continue
        if "release-seam:" in line:
            continue
        fenced = any(frame[0] is True for frame in stack)
        if not fenced:
            hits.append((n, kind, raw.strip()))
    return hits


def main() -> int:
    args = sys.argv[1:]
    strict_env = "--strict-env" in args
    roots = [Path(a) for a in args if a != "--strict-env"] or [Path(".")]
    total = 0
    notes = 0
    files = 0
    for root in roots:
        for f in sorted(root.rglob("*.swift")):
            if any(part in SKIP_DIRS for part in f.parts) or re.search(r"Tests?/|UITests/", str(f)):
                continue
            files += 1
            for n, kind, text in scan(f):
                if kind == "seam" or strict_env:
                    total += 1
                    print(f"{f}:{n}: error: unfenced {'argument' if kind == 'seam' else 'environment'} read: {text}")
                else:
                    notes += 1
                    print(f"{f}:{n}: note: environment read outside DEBUG: {text}")
    print(f"debug-fences: {files} files, {total} unfenced argument read(s), {notes} environment note(s)", file=sys.stderr)
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
