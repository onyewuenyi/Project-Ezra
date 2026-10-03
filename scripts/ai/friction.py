#!/usr/bin/env python3
"""The friction and waste healthcheck: what keeps going wrong in this repo's Claude Code sessions,
as proposals. Silent when there is nothing to propose.

Reads this repo's transcripts (~/.claude/projects/<repo path with every non-alphanumeric as ->*, so
its worktrees count too), the verify history and the permission rules, and proposes:
  allow        a read-only command run often in several sessions that no allow rule covers
               (transcripts never record an APPROVED prompt, so this is inferred; for the full
               read-only sweep use Claude Code's /fewer-permission-prompts)
  rejected     tool calls the owner rejected more than once: a deny rule or a playbook line
  guard        the same hook refusal over and over: fix whatever keeps walking into it
  stop         the Stop hook's build check failing turn after turn
  build-error  the same compiler error recurring across sessions: a rule, a type or a test
  flaky        a test that failed and passed on the same commit
  slow-gate    a /verify gate whose median time grew by half
  waste        (--waste, and on Mondays) huge tool outputs, a file re-read many times in one
               session, compactions, output tokens
usage: friction.py [--since 7d] [--json] [--waste] [--transcripts DIR]
Stamps $STATE_DIR/friction.last on every run. If more than a fifth of the transcript lines cannot be
read, it says the format changed and proposes nothing, rather than guess.
"""
import json
import os
import re
import statistics
import sys
import time
from collections import Counter, defaultdict
from fnmatch import fnmatch
from pathlib import Path

sys.dont_write_bytecode = True  # never leave __pycache__ in the project's scripts/ai
sys.path.insert(0, str(Path(__file__).resolve().parent))
import history  # noqa: E402
from kit import repo_root, state_dir  # noqa: E402

# Exact read-only subcommands only: a rule on "gh pr" would also allow "gh pr merge", and one on
# "git branch" would allow "git branch -D".
READONLY = {"git status", "git diff", "git log", "git show", "git rev-parse", "git ls-files", "git blame",
            "git fetch", "git worktree list", "gh pr view", "gh pr list", "gh pr checks", "gh pr diff",
            "gh run view", "gh run list", "gh repo view", "xcrun simctl list", "xcodebuild -list",
            "xcodebuild -version", "xcodebuild -showsdks", "xcrun xcresulttool get"}
# Plain utilities that only read: they rarely prompt, and /fewer-permission-prompts handles them.
UTILITIES = {"ls", "cat", "head", "tail", "grep", "rg", "wc", "file", "stat", "du", "df", "which", "pwd"}
TWO_WORD = {"git", "gh", "xcrun", "xcodebuild", "swift", "defaults", "npm", "brew"}
HOOK = re.compile(r"^(PreToolUse|PostToolUse|PermissionRequest):(\w+) hook error: (.*)", re.S)


def mangle(p: Path) -> str:
    return re.sub(r"[^A-Za-z0-9]", "-", str(p))


def transcripts(root: Path, override: str | None) -> list[Path]:
    if override:
        return sorted(Path(override).glob("*.jsonl"))
    base = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"
    name = mangle(root)
    return sorted(p for d in base.glob(name + "*") if d.name == name or d.name.startswith(name + "-")
                  for p in d.glob("*.jsonl"))


def prefix(cmd: str) -> str:
    """The longest known read-only prefix (up to three words), else the command and, for multi-tool
    CLIs, its subcommand."""
    words = cmd.strip().split()
    for n in (3, 2):
        if " ".join(words[:n]) in READONLY:
            return " ".join(words[:n])
    if not words:
        return ""
    if words[0] in TWO_WORD and len(words) > 1:
        return f"{words[0]} {words[1]}"
    return words[0]


def first_real(cmd: str) -> str:
    """The first command that is not a cd (`cd X && real thing`)."""
    for seg in segments(cmd):
        if prefix(seg) != "cd":
            return prefix(seg)
    return prefix(cmd)


def segments(cmd: str) -> list[str]:
    return [s.strip() for s in re.split(r"&&|\|\||;|\||\n", cmd) if s.strip()]


def allow_rules(root: Path) -> list[str]:
    rules = []
    for f in (root / ".claude/settings.json", root / ".claude/settings.local.json", Path.home() / ".claude/settings.json"):
        try:
            rules += json.loads(f.read_text()).get("permissions", {}).get("allow", [])
        except (OSError, ValueError):
            pass
    pats = []
    for r in rules:
        m = re.fullmatch(r"Bash\((.*)\)", r)
        if m:
            pats.append(m.group(1).replace(":*", "*").replace(" *", "*"))
    return pats


def covered(seg: str, pats: list[str]) -> bool:
    return any(fnmatch(seg, p) or fnmatch(seg, p.rstrip("*") + " *") or seg == p.rstrip("*") for p in pats)


def text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def scan(files: list[Path], since: float) -> dict:
    s = {"bad": 0, "lines": 0, "sessions": set(), "bash": defaultdict(set), "bash_n": Counter(),
         "rejected": Counter(), "hooks": Counter(), "hook_cmds": defaultdict(list), "stop_fail": 0, "errors": defaultdict(set), "big": Counter(),
         "rereads": Counter(), "compactions": 0, "out_tokens": 0}
    for f in files:
        try:
            if f.stat().st_mtime < since:
                continue
            fh = f.open(errors="replace")
        except OSError:
            continue
        sid, uses, reads = f.stem, {}, Counter()
        with fh:
            for line in fh:
                s["lines"] += 1
                try:
                    d = json.loads(line)
                    if not isinstance(d, dict) or "type" not in d:
                        raise ValueError
                except ValueError:
                    s["bad"] += 1
                    continue
                ts = d.get("timestamp")
                if isinstance(ts, str):
                    try:
                        if time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")) < since:
                            continue
                    except ValueError:
                        pass
                s["sessions"].add(sid)
                t, msg = d.get("type"), d.get("message") or {}
                if t == "system" and d.get("subtype") == "compact_boundary":
                    s["compactions"] += 1
                if t == "assistant" and isinstance(msg, dict):
                    s["out_tokens"] += (msg.get("usage") or {}).get("output_tokens", 0) or 0
                    for b in msg.get("content") or []:
                        if isinstance(b, dict) and b.get("type") == "tool_use":
                            inp = b.get("input") or {}
                            uses[b.get("id")] = (b.get("name"), inp)
                            if b.get("name") == "Bash":
                                for seg in segments(str(inp.get("command", ""))):
                                    p = prefix(seg)
                                    s["bash"][p].add(sid)
                                    s["bash_n"][p] += 1
                            if b.get("name") == "Read" and inp.get("file_path"):
                                reads[inp["file_path"]] += 1
                if t == "user" and isinstance(msg, dict):
                    content = msg.get("content")
                    if isinstance(content, str) and content.startswith("Stop hook feedback:") \
                            and "ios-ai stop check FAILED" in content:
                        s["stop_fail"] += 1
                    if isinstance(content, list):
                        for b in content:
                            if not isinstance(b, dict) or b.get("type") != "tool_result":
                                continue
                            txt = text_of(b.get("content"))
                            name, inp = uses.get(b.get("tool_use_id"), ("?", {}))
                            cmd = str(inp.get("command", "")) if isinstance(inp, dict) else ""
                            if "doesn't want to proceed" in txt:
                                what = first_real(cmd) if cmd else (inp.get("file_path", "") if isinstance(inp, dict) else "")
                                s["rejected"][f"{name}: {what}"] += 1
                            m = HOOK.match(txt)
                            if m:
                                key = f"{m.group(1)} {m.group(2)}: {m.group(3).strip()[:110]}"
                                s["hooks"][key] += 1
                                snippet = " ".join(cmd.split())[:70]
                                if snippet and snippet not in s["hook_cmds"][key]:
                                    s["hook_cmds"][key].append(snippet)
                            if len(txt) > 20000:
                                s["big"][prefix(cmd) or name] += 1
                            if "build.sh" in cmd or "xcodebuild" in cmd:
                                for e in re.findall(r"^error[^\n]*?: (.{8,160})$", txt, re.M):
                                    norm = re.sub(r"'[^']*'|\"[^\"]*\"|\d+", "_", e)
                                    s["errors"][norm].add(sid)
        for path, k in reads.items():
            if k > 5:
                s["rereads"][path] = max(s["rereads"][path], k)
    return s


def proposals(s: dict, root: Path, rows: list[dict], waste: bool) -> list[dict]:
    out, pats = [], allow_rules(root)
    utils = 0
    for p, sess in s["bash"].items():
        n = s["bash_n"][p]
        if p in UTILITIES and not covered(p + " x", pats):
            utils += n
        elif n >= 5 and len(sess) >= 2 and p in READONLY and not covered(p + " x", pats):
            out.append({"kind": "allow", "evidence": f"`{p} …` ran {n} times in {len(sess)} sessions, no allow rule covers it",
                        "proposal": f'add "Bash({p}:*)" to permissions.allow', "target": ".claude/settings.json"})
    if utils >= 50:
        out.append({"kind": "allow", "evidence": f"{utils} read-only utility calls (grep, head, cat, …) with no allow rule",
                    "proposal": "run /fewer-permission-prompts if they prompt you (Claude Code's own read-only sweep)",
                    "target": "~/.claude/settings.json or .claude/settings.local.json"})
    for what, n in s["rejected"].items():
        if n >= 2:
            out.append({"kind": "rejected", "evidence": f"rejected {n} times: {what}",
                        "proposal": "a deny or ask rule, or a playbook line saying why not", "target": ".claude/settings.json or a playbook"})
    for reason, n in s["hooks"].items():
        if n >= 3:
            seen = s["hook_cmds"].get(reason, [])[:3]
            examples = ("; refused: " + " | ".join(f"`{c}`" for c in seen)) if seen else ""
            out.append({"kind": "guard", "evidence": f"{n} refusals: {reason}{examples}",
                        "proposal": "fix what keeps walking into it (a script, a doc, a default), not the hook",
                        "target": "the step or doc that prompts the refused command"})
    if s["stop_fail"] >= 3:
        out.append({"kind": "stop", "evidence": f"the Stop hook's build check failed {s['stop_fail']} turns",
                    "proposal": "build after each change (scripts/ai/build.sh) instead of at turn end; read why it keeps failing",
                    "target": "ios-loop step 4"})
    for err, sess in s["errors"].items():
        if len(sess) >= 2:
            out.append({"kind": "build-error", "evidence": f"in {len(sess)} sessions: {err}",
                        "proposal": "a rule in .claude/rules/, a type that prevents it, or a test", "target": ".claude/rules/"})
    for test, k in history.test_flips(50, rows).items():
        out.append({"kind": "flaky", "evidence": f"{test} failed and passed on the same commit ({k}x)",
                    "proposal": "reproduce it in isolation and fix the race; never retry it green", "target": "the test"})
    by_gate = defaultdict(list)
    for run in history.runs(rows):
        for r in run:
            if r["result"] in ("PASS", "FAIL") and not r["gate"].startswith("fail:"):
                try:
                    by_gate[r["gate"]].append(float(r["secs"]))
                except ValueError:
                    pass
    for gate, secs in by_gate.items():
        if len(secs) >= 10:
            half = len(secs) // 2
            before, now = statistics.median(secs[:half]), statistics.median(secs[half:])
            if now > 60 and now > 1.5 * before:
                out.append({"kind": "slow-gate", "evidence": f"{gate} median {before:.0f}s → {now:.0f}s",
                            "proposal": "find what grew (more tests, a slower build, a cold cache)", "target": f"the {gate} gate"})
    if waste:
        for p, n in s["big"].most_common(3):
            if n >= 2:
                out.append({"kind": "waste", "evidence": f"{n} tool outputs over 20k characters from `{p}`",
                            "proposal": "filter or summarize that output, or hand it to a subagent", "target": "the script or call"})
        for path, k in s["rereads"].most_common(3):
            out.append({"kind": "waste", "evidence": f"{Path(path).name} read {k} times in one session",
                        "proposal": "keep what matters from it in the todo list or a note", "target": "the workflow"})
        if s["compactions"]:
            out.append({"kind": "waste", "evidence": f"{s['compactions']} compaction(s), {s['out_tokens']:,} output tokens",
                        "proposal": "route bulk reading and logs to subagents (principles: guard the context window)",
                        "target": "the workflow"})
    return out


def main(argv: list[str]) -> int:
    args = argv[1:]
    since_arg = args[args.index("--since") + 1] if "--since" in args else "7d"
    m = re.fullmatch(r"(\d+)([dh])", since_arg)
    since = time.time() - (int(m.group(1)) * (86400 if m.group(2) == "d" else 3600) if m else 7 * 86400)
    root = repo_root()
    files = transcripts(root, args[args.index("--transcripts") + 1] if "--transcripts" in args else None)
    s = scan(files, since)
    sd = state_dir(root, create=True)
    (sd / "friction.last").touch()
    if s["lines"] and s["bad"] / s["lines"] > 0.2:
        print(f"friction: {s['bad']} of {s['lines']} transcript lines could not be read; the transcript format "
              "changed, so nothing is proposed. Update friction.py.")
        return 0
    waste = "--waste" in args or time.localtime().tm_wday == 0
    props = proposals(s, root, history.rows(sd / "verify.tsv"), waste)
    if "--json" in args:
        print(json.dumps({"sessions": len(s["sessions"]), "proposals": props}, indent=1))
    elif props:
        print(f"friction: {len(props)} proposal(s) from {len(s['sessions'])} session(s) since {since_arg}")
        for p in props:
            print(f"  [{p['kind']}] {p['evidence']}\n      → {p['proposal']} ({p['target']})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
