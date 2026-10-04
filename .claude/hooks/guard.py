#!/usr/bin/env python3
"""PreToolUse guard: blocks the mistakes that corrupt iOS verification. Fails open on any error.

- xcodebuild -destination naming a simulator without OS= or id=: with several runtimes
  installed it picks one you did not mean (deny; scripts/ai/build.sh targets this checkout's
  simulator by UDID).
- simctl ... booted while more than one simulator is booted: "booted" then means any of them,
  so a parallel session can screenshot or reset someone else's app (deny).
- simctl erase/delete all: destroys every simulator, including other sessions' (ask).
- Editing a committed Core Data model version: a shipped version edited in place cannot
  migrate users' stores; add a new version instead (ask).
- git push to the default branch (explicitly, via HEAD:<default>, or a bare push while on it):
  every change reaches it through a pull request, so push a branch and open one with
  scripts/ai/pr.sh (deny). GitHub's ruleset (scripts/ai/protect-main.sh) is the hard lock.
"""
import json
import re
import shlex
import subprocess
import sys


def decide(decision: str, reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "permissionDecision": decision,
                                             "permissionDecisionReason": reason}}))
    sys.exit(0)


def booted_count() -> int:
    try:
        out = subprocess.run(["xcrun", "simctl", "list", "devices", "booted", "-j"],
                             capture_output=True, text=True, timeout=8).stdout
        return sum(len(v) for v in json.loads(out)["devices"].values())
    except Exception:
        return 0


def git_out(*args: str) -> str:
    try:
        return subprocess.run(["git", *args], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def default_branch() -> str:
    ref = git_out("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")  # refs/remotes/origin/main
    return ref.rsplit("/", 1)[-1] if ref else "main"


# A heredoc fed to cat or tee is text being written to a file, not commands: a test script that
# pushes to a scratch remote's main must not read as a push. A heredoc fed to anything else (bash,
# sh, python) may run, so it stays.
WRITTEN = re.compile(r"\b(cat|tee)\b[^\n]*<<-?\s*(['\"]?)(\w+)\2[^\n]*\n.*?\n[ \t]*\3[ \t]*(?=\n|$)", re.S)


def without_written_text(cmd: str) -> str:
    return WRITTEN.sub(lambda m: m.group(0).split("\n", 1)[0], cmd)


def pushes_default(cmd: str) -> str | None:
    """The default branch's name when this command pushes to it, else None."""
    cmd = without_written_text(cmd)
    if not re.search(r"\bgit\b[^;&|]*\bpush\b", cmd):
        return None
    base = default_branch()
    for part in re.split(r"&&|\|\||;|\||\n", cmd):
        try:
            words = shlex.split(part)
        except ValueError:
            words = part.split()
        if "git" not in words:
            continue
        # `push` must be git's SUBCOMMAND (the first non-option word after `git`, skipping the value
        # of -C/-c/--git-dir/--work-tree): `git stash push`, `git grep push`, `git commit -m push` are not pushes.
        gi = words.index("git")
        j, sub = gi + 1, None
        while j < len(words):
            w = words[j]
            if w in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
                j += 2
                continue
            if w.startswith("-"):
                j += 1
                continue
            sub = w
            break
        if sub != "push":
            continue
        args = words[j + 1:]
        pos = [a for a in args if not a.startswith("-")]
        refs = pos[1:]
        if not refs:  # a bare push follows the current branch's upstream
            if git_out("rev-parse", "--abbrev-ref", "HEAD") == base or "--all" in args or "--mirror" in args:
                return base
            continue
        for r in refs:
            dst = r.lstrip("+").split(":")[-1]
            if "$" in dst or "(" in dst or "`" in dst:
                return base  # a ref that is computed at run time could be anything, including main
            if dst in (base, f"refs/heads/{base}", f"heads/{base}") \
                    or (dst in ("HEAD", "@") and git_out("rev-parse", "--abbrev-ref", "HEAD") == base):
                return base
    return None


def bash(cmd: str) -> None:
    base = pushes_default(cmd)
    if base:
        decide("deny", f"Every change reaches '{base}' through a pull request, never a direct push. Commit on a "
                       "branch, then run scripts/ai/pr.sh: it moves commits made on the default branch onto a new "
                       "branch, pushes it, and opens the PR with the /verify report.")
    if "xcodebuild" in cmd:
        for dest in re.findall(r"-destination\s+(?:'([^']*)'|\"([^\"]*)\"|(\S+))", cmd):
            d = next(x for x in dest if x)
            if "Simulator" in d and "name=" in d and "OS=" not in d and "id=" not in d:
                decide("deny", f"'{d}' names a simulator without a runtime, so xcodebuild may pick another iOS "
                               "version or another session's device. Use scripts/ai/build.sh / test.sh (they target "
                               "this checkout's own simulator by UDID), or pass id=<udid> from scripts/ai/sim.sh udid.")
    if re.search(r"\bsimctl\b[^|;&]*\bbooted\b", cmd) and booted_count() > 1:
        decide("deny", "More than one simulator is booted, so 'booted' could be another session's device. "
                       "Use scripts/ai/sim.sh (this checkout's simulator by UDID) or pass the UDID from "
                       "scripts/ai/sim.sh udid.")
    if re.search(r"simctl\s+(erase\s+all|delete\s+(all|unavailable))", cmd):
        decide("ask", "This erases or deletes EVERY simulator, including other sessions' devices. "
                      "Prefer scripts/ai/sim.sh destroy for this checkout's own device.")


def edit(path: str) -> None:
    m = re.search(r"(.*\.xcdatamodeld/[^/]+\.xcdatamodel)/contents$", path)
    if not m:
        return
    try:
        tracked = subprocess.run(["git", "ls-files", "--error-unmatch", path], capture_output=True,
                                 timeout=5).returncode == 0
    except Exception:
        tracked = False
    if tracked:
        decide("ask", "This Core Data model version is committed. If a build with it reached users, editing it in "
                      "place breaks migration of their stores: add a new model version (a superset) and make it "
                      "current. Approve only if this version never shipped.")


def main() -> None:
    try:
        ev = json.load(sys.stdin)
    except Exception:
        return
    tool, ti = ev.get("tool_name", ""), ev.get("tool_input") or {}
    if tool == "Bash":
        bash(ti.get("command", ""))
    elif tool in ("Edit", "Write", "MultiEdit"):
        edit(ti.get("file_path", ""))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        pass
