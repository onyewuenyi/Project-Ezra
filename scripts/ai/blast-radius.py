#!/usr/bin/env python3
"""Which surfaces can a Swift change reach? Run it before verifying, so the proof covers them.

For each changed line it finds the enclosing TYPE (struct/class/enum/actor/protocol/extension)
in the file as it now stands, plus any non-private declaration added or removed on that line.
It then lists every other app file that names those declarations and maps them onto the verify
skill's feature map. Output is the list of surfaces to re-capture, not a verdict: a shared view
or design token is exactly where "I checked the screen I changed" misses a regression.

usage: blast-radius.py [--diff "<git diff args>"] [--src <app source dir>] [paths …]
  --diff defaults to "HEAD" (uncommitted changes); e.g. --diff "main...HEAD" for a branch.
  paths limit the diff to your own files when the checkout carries other work.
"""

import argparse
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

TYPE_DECL = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:public|internal|fileprivate|private|final|open)\s+)*"
                       r"(struct|class|enum|actor|protocol|extension)\s+([A-Za-z_][\w.]*)")
MEMBER_DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*((?:public|internal|fileprivate|private|static|final|open|"
                         r"override|mutating|nonisolated)\s+)*(func|var|let|case|typealias)\s+([A-Za-z_]\w*)")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True).stdout


def enclosing_type(lines: list[str], idx: int) -> tuple[str, str] | None:
    """(kind, name) of the top-level declaration whose body contains line idx (swift-format indentation)."""
    for i in range(min(idx, len(lines) - 1), -1, -1):
        m = TYPE_DECL.match(lines[i])
        if m and (len(lines[i]) - len(lines[i].lstrip())) == 0:
            return m.group(1), m.group(2).split(".")[0]
    return None


def touched(root: Path, diff: str, paths: list[str]) -> dict[str, set[str]]:
    out: dict[str, set[str]] = defaultdict(set)
    text = git(root, "diff", "-U0", *diff.split(), "--", *(paths or ["*.swift"]))
    current, new_lines, new_no = None, [], 0
    for line in text.splitlines():
        if line.startswith("+++ "):
            name = line[6:] if line.startswith("+++ b/") else None
            current = name if name and name.endswith(".swift") and "Tests" not in name else None
            p = root / current if current else None
            new_lines = p.read_text(errors="replace").splitlines() if p and p.exists() else []
            continue
        if current is None:
            continue
        h = HUNK.match(line)
        if h:
            new_no = int(h.group(3))
            continue
        if line.startswith("+") or line.startswith("-"):
            idx = new_no - 1 if line.startswith("+") else max(new_no - 1, 0)
            t = enclosing_type(new_lines, idx)
            if t:
                out[current].add(t[1])
            m = MEMBER_DECL.match(line[1:])
            # A property or case is reached through its type (traced above); a function, or any
            # member of an extension, is called by name from elsewhere, so trace it by name.
            if m and "private" not in (m.group(1) or "") and (m.group(2) == "func" or (t and t[0] == "extension")):
                out[current].add(m.group(3))
            if line.startswith("+"):
                new_no += 1
    # One hop inside each file: a type whose body builds a changed type is changed with it
    # (a shared container view rendering the changed row carries the change to ITS users).
    for file, syms in list(out.items()):
        p = root / file
        if not p.exists():
            continue
        lines = p.read_text(errors="replace").splitlines()
        spans, cur = [], None
        for i, l in enumerate(lines):
            m = TYPE_DECL.match(l)
            if m and not l[:1].isspace():
                cur = m.group(2).split(".")[0]
                spans.append((cur, i))
        for n, (name, start) in enumerate(spans):
            end = spans[n + 1][1] if n + 1 < len(spans) else len(lines)
            body = "\n".join(lines[start + 1:end])
            if name not in syms and any(re.search(rf"\b{re.escape(t)}\(", body) for t in syms if t[:1].isupper()):
                syms.add(name)
    return out


def declared_in_app(src: Path, symbol: str) -> bool:
    pat = re.compile(rf"^\s*(?:\w+\s+)*(?:struct|class|enum|actor|protocol)\s+{re.escape(symbol)}\b", re.M)
    return any(pat.search(f.read_text(errors="replace")) for f in src.rglob("*.swift"))


def naming_files(src: Path, symbol: str) -> set[Path]:
    pat = re.compile(rf"\b{re.escape(symbol)}\b")
    return {f for f in src.rglob("*.swift")
            if "Tests" not in str(f) and pat.search(f.read_text(errors="replace"))}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--diff", default="HEAD")
    ap.add_argument("--src", default="")
    ap.add_argument("paths", nargs="*")
    a = ap.parse_args()
    root = Path(git(Path("."), "rev-parse", "--show-toplevel").strip() or ".").resolve()
    src = Path(a.src).resolve() if a.src else root

    changed = touched(root, a.diff, a.paths)
    if not changed:
        print(f"No Swift changes in `git diff {a.diff}`" + (f" for {' '.join(a.paths)}" if a.paths else "") + ".")
        return 0

    print(f"## Blast radius of `git diff {a.diff}`" + (f" ({' '.join(a.paths)})" if a.paths else "") + "\n")
    reach: dict[str, set[Path]] = {}
    generic: set[str] = set()
    for file, syms in changed.items():
        print(f"- `{file}` changes: " + ", ".join(f"`{s}`" for s in sorted(syms)))
        for s in syms:
            # `extension View` changes View's members, not View: trace the members, skip the framework type.
            if s[:1].isupper() and not declared_in_app(src, s):
                continue
            users = {p for p in naming_files(src, s) if not str(p).endswith(file)}
            # A lowercase member named in many files (title, text, body) is a common word, not a
            # dependency: tracing it would bury the real reach. Types are always traced.
            if s[:1].islower() and len(users) > 10:
                generic.add(s)
                continue
            if users:
                reach[s] = users
    print()
    all_files: set[Path] = set()
    for sym, files in sorted(reach.items(), key=lambda kv: -len(kv[1])):
        rel = sorted(str(p.relative_to(root)) for p in files)
        all_files |= files
        more = f" … and {len(rel) - 10} more" if len(rel) > 10 else ""
        print(f"- `{sym}` is also named in {len(rel)} file(s): " + ", ".join(f"`{r}`" for r in rel[:10]) + more)
    if not reach:
        print("- Nothing outside the changed files names these declarations.")
    if generic:
        print(f"- Not traced (names too common to mean a dependency): {', '.join(f'`{g}`' for g in sorted(generic))}")

    screens = sorted({p.parent.name for p in all_files if p.parent.parent.name == "Features"}
                     | {Path(f).parent.name for f in changed if Path(f).parent.parent.name == "Features"})
    views = sorted({v for p in all_files | {root / f for f in changed}
                    for v in re.findall(r"\bstruct\s+(\w+(?:View|Row|Sheet|Page|Bar|Card))\b", p.read_text(errors="replace"))})
    fmap = [(f.stem, f.read_text(errors="replace"))
            for f in sorted(root.glob(".claude/skills/verify-*/features/*.md")) if f.name != "README.md"]
    print(f"\nScreens reached: {', '.join(screens) or 'none'}")
    if fmap:
        hit = [n for n, t in fmap if any(w in t for w in screens + views)]
        print("Verify-skill features to re-capture: " + (", ".join(f"`{h}`" for h in hit) or
              "none matched by name; pick them by hand from the list above"))
    print("\nRe-capture each at the default size AND the largest accessibility size before calling the change done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
