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
"""
import json
import re
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


def bash(cmd: str) -> None:
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
