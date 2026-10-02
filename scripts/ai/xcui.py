#!/usr/bin/env python3
"""Assert what a screen SHOWS, through Xcode's device-interaction tools (xcrun mcpbridge).

Launches the app ALREADY built and installed by scripts/ai (sim.sh launch, with the given launch
arguments) on THIS checkout's simulator, attaches a device-only interaction session (no Xcode build,
no open workspace needed), captures the UI hierarchy, and checks each expected label.

Why not DeviceInteractionInstallAndRun: it rebuilds the app with Xcode's own DerivedData, and on a
large project (measured on Ezra, Xcode 27.0) the session was dropped during that build while Xcode
kept the device locked to it, surviving EndSession and a simulator reboot.

usage: xcui.py --udid <UDID> --container <path.xcodeproj|.xcworkspace> --bundle <id>
               [--args="-Flag value"] (the = form: launch arguments start with -) [--expect "label"]… [--absent "label"]… [--name "Screen Name"]
Prints `hierarchy: <path>`, `screenshot: <path>`, then `ok`/`FAIL` per expectation.
Exit 0 all good · 1 an expectation failed · 3 Xcode's tools unavailable (not running, not approved).

Notes measured on Xcode 27.0: the agent is approved by the first XcodeOpenWorkspace (until then
every tool answers "isn't approved"); workspace calls need the workspaceIdentifier from
XcodeListWorkspaces / XcodeOpenWorkspace (a path is rejected); deviceIdentifier accepts a UDID;
a session id that was "recently used" is refused, so every attempt gets a fresh one.
"""

import argparse
import json
import re
import select
import shlex
import subprocess
import sys
import time
import uuid
from pathlib import Path


class Bridge:
    def __init__(self) -> None:
        self.p = subprocess.Popen(["xcrun", "mcpbridge"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "ios-ai-kit", "version": "1"}}, 30)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, msg: dict) -> None:
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def rpc(self, method: str, params: dict, timeout: float) -> dict:
        self.n += 1
        self.send({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params})
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([self.p.stdout], [], [], 1)
            if not r:
                if self.p.poll() is not None:
                    raise RuntimeError("mcpbridge exited")
                continue
            line = self.p.stdout.readline()
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("id") == self.n:
                return d
        raise TimeoutError(method)

    def tool(self, name: str, args: dict, timeout: float = 300) -> str:
        d = self.rpc("tools/call", {"name": name, "arguments": args}, timeout)
        res = d.get("result") or {}
        text = "".join(c.get("text", "") for c in res.get("content", []))
        if res.get("isError") or "Error Domain=" in text:
            raise RuntimeError(f"{name}: {text[:400]}")
        return text

    def close(self) -> None:
        try:
            self.p.terminate()
        except Exception:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", required=True)
    ap.add_argument("--container", required=True)
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--args", default="")
    ap.add_argument("--expect", action="append", default=[])
    ap.add_argument("--absent", action="append", default=[])
    ap.add_argument("--name", default="Verify Screen")
    ap.add_argument("--sim", default=str(Path(__file__).with_name("sim.sh")), help="sim.sh that launches the app")
    ap.add_argument("--wait", type=float, default=4.0, help="seconds after launch before capturing")
    a = ap.parse_args()
    try:
        b = Bridge()
    except Exception as e:
        print(f"xcui: Xcode tools unavailable ({str(e)[:160]})")
        return 3
    try:
        b.tool("XcodeListWorkspaces", {}, 30)
    except RuntimeError as e:
        if "approved" not in str(e):
            print(f"xcui: Xcode tools unavailable ({str(e)[:160]})")
            b.close()
            return 3
        try:  # opening the project once is what asks the person to approve this agent
            b.tool("XcodeOpenWorkspace", {"path": a.container}, 180)
        except Exception as e2:
            print(f"xcui: Xcode tools not approved ({str(e2)[:160]})")
            b.close()
            return 3

    def start() -> str:
        def args() -> dict:  # Xcode refuses an id "currently in use or recently used": fresh one per attempt
            return {"sessionIdentifier": f"{a.name.title()} {uuid.uuid4().hex[:6]}", "deviceIdentifier": a.udid}
        try:
            return json.loads(b.tool("DeviceInteractionStartSession", args(), 120))["interactionSessionKey"]
        except RuntimeError as e:
            stale = re.search(r"different session with key '([^']+)'", str(e))
            if not stale:
                raise
            b.tool("DeviceInteractionEndSession", {"interactionSessionKey": stale.group(1)}, 60)
            return json.loads(b.tool("DeviceInteractionStartSession", args(), 120))["interactionSessionKey"]

    # Launch our build with the screen's arguments, the same way the screenshots do.
    sim = ["/bin/bash", a.sim, "launch", *shlex.split(a.args)]
    subprocess.run(sim, capture_output=True, text=True)
    time.sleep(a.wait)
    try:
        key = start()
    except Exception as e:
        print(f"xcui: could not attach a device-interaction session ({str(e)[:220]})")
        b.close()
        return 3
    rc = 0
    try:
        cap = json.loads(b.tool("DeviceInteractionSynthesize", {"interactSessionKey": key, "activationBundleId": a.bundle}, 120))
        hier = open(cap["hierarchyPath"], errors="replace").read()
        print(f"hierarchy: {cap['hierarchyPath']}\nscreenshot: {cap['screenshotPath']}")
        labels = re.findall(r"label: '((?:[^'\\]|\\.)*)'", hier) + re.findall(r"identifier: '((?:[^'\\]|\\.)*)'", hier)
        for want in a.expect:
            hit = any(want in l for l in labels)
            print(f"{'ok  ' if hit else 'FAIL'} shows '{want}'")
            rc |= 0 if hit else 1
        for bad in a.absent:
            hit = any(bad in l for l in labels)
            print(f"{'FAIL' if hit else 'ok  '} does not show '{bad}'")
            rc |= 1 if hit else 0
    except Exception as e:
        print(f"xcui: {str(e)[:300]}")
        rc = 1
    finally:
        try:
            b.tool("DeviceInteractionEndSession", {"interactionSessionKey": key}, 60)
        except Exception:
            pass
        b.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
