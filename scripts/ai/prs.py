#!/usr/bin/env python3
"""The lead's digest: every open unit of work, sorted by who has to act. Quiet when nothing changed.

A unit is not done when an agent starts it; it is done when its PR is merged, it is abandoned, or
you take it back. Each open PR you authored lands in exactly one bucket:

  needs-you   ready to merge (verified at its head, green, mergeable, no open threads) · stalled
              (no activity for LEAD_STALE_DAYS) · a review requested from you · fixes committed
              locally and not pushed · a cloud task that never opened a PR
  needs-work  conflicts · failing checks · changes requested or unresolved threads · behind a base
              that requires it · app code not verified at its head (the lead does these)
  healthy     checks running, mergeability being computed, a fresh draft: counted, never listed
  done        merged, closed or abandoned since you last looked: reported once

usage: prs.py [--json] [--quiet] [--mark-seen] [--all] [--abandon N | --take-back N | --ignore N]
       prs.py --from fixture.json        (classify recorded data; tests)
--quiet prints nothing when the actionable set is what --mark-seen last recorded (/loop /lead).
Always caches the digest to $STATE_DIR/prs.json for the SessionStart bearings. Never raises: with
no GitHub CLI it prints one line and exits 0.
"""
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True  # never leave __pycache__ in the project's scripts/ai
sys.path.insert(0, str(Path(__file__).resolve().parent))
import history  # noqa: E402
from kit import env, git, state_dir, write_atomic  # noqa: E402

# files and commits are fetched per PR: asking for them across a whole list exceeds GitHub's
# 500,000-node query limit (measured: 525,100 at --limit 50).
FIELDS = ("number,title,url,author,headRefName,headRefOid,baseRefName,isDraft,mergeable,mergeStateStatus,"
          "reviewDecision,reviewRequests,statusCheckRollup,labels,body,updatedAt")
SESSION = re.compile(r"https://claude\.ai/code/session_\w+")
APP_FILE = re.compile(r"\.(swift|m|mm|h|pbxproj|plist|xcprivacy|entitlements|storyboard|xib|xcstrings|strings|"
                      r"metal|xcconfig)$|\.xcassets/|\.xcdatamodeld/|Package\.(swift|resolved)$")
FAILED = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"}


def gh(*args: str, timeout: int = 60) -> str | None:
    try:
        r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=timeout)
        return r.stdout if r.returncode == 0 else None
    except Exception:
        return None


def checks(rollup: list) -> str:
    """'failing', 'pending' or 'ok' over both CheckRun and StatusContext shapes; no checks is 'ok'."""
    state = "ok"
    for c in rollup or []:
        conclusion, status, st = c.get("conclusion") or "", c.get("status") or "", c.get("state") or ""
        if conclusion in FAILED or st in FAILED:
            return "failing"
        if (status and status != "COMPLETED") or st in ("PENDING", "EXPECTED"):
            state = "pending"
    return state


def age_days(stamp: str, now: float) -> float:
    try:
        t = datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0
    return (now - t) / 86400


def session_link(pr: dict) -> str | None:
    texts = [pr.get("body") or ""] + [c.get("messageBody") or "" for c in pr.get("commits") or []]
    for t in texts:
        m = SESSION.search(t)
        if m:
            return m.group(0)
    return None


def touches_app(pr: dict) -> bool:
    files = pr.get("files")
    if files is None:  # older gh: assume it does, so nothing unverified slips through
        return True
    return any(APP_FILE.search(f.get("path", "")) for f in files)


def classify(pr: dict, ctx: dict) -> tuple[str, str, str]:
    """(bucket, action, why) for one open PR. ctx: now, stale_days, me, verified, threads, behind,
    unpushed, cloud_authored, lead (the lead.json state)."""
    n, lead = pr.get("number"), ctx.get("lead", {})
    if n in lead.get("abandoned", []):
        return "done", "abandoned", "abandoned"
    if n in lead.get("taken_back", []) or n in lead.get("ignored", []):
        return "skip", "", "yours to drive" if n in lead.get("taken_back", []) else "ignored"
    if ctx.get("unpushed"):
        return "needs-you", "push-ready", f"{ctx['unpushed']} local commit(s) not pushed: git -C <worktree> push"
    idle = age_days(pr.get("updatedAt", ""), ctx["now"])
    if pr.get("isDraft") and idle < 1:
        return "healthy", "", "draft in progress"
    if idle > ctx.get("stale_days", 3):
        return "needs-you", "abandon-or-take-back", f"no activity for {idle:.0f}d"
    if pr.get("mergeable") == "CONFLICTING" or pr.get("mergeStateStatus") == "DIRTY":
        return "needs-work", "resolve", f"conflicts with {pr.get('baseRefName')}"
    ck = checks(pr.get("statusCheckRollup"))
    if ck == "failing":
        return "needs-work", "fix-checks", "a check is failing"
    threads = ctx.get("threads") or 0
    if pr.get("reviewDecision") == "CHANGES_REQUESTED" or threads:
        return "needs-work", "address-threads", (f"{threads} unresolved thread(s)" if threads else "changes requested")
    if pr.get("mergeStateStatus") == "BEHIND":
        return "needs-work", "update-branch", f"behind {pr.get('baseRefName')} (required to be up to date)"
    if ck == "pending" or pr.get("mergeable") in ("UNKNOWN", None, ""):
        return "healthy", "", "checks or mergeability pending"
    if any((r.get("login") or "") == ctx.get("me") for r in pr.get("reviewRequests") or []):
        return "needs-you", "review", "your review is requested"
    if pr.get("isDraft"):
        return "healthy", "", "draft"
    if touches_app(pr) and not ctx.get("verified"):
        who = "cloud-authored" if ctx.get("cloud_authored") else "app code"
        return "needs-work", "verify", f"{who}, not verified at {str(pr.get('headRefOid', ''))[:7]}"
    proof = "verified at " + str(pr.get("headRefOid", ""))[:7] if ctx.get("verified") else "no app code changed"
    return "needs-you", "merge-ready", f"{proof}, mergeable, no open threads"


def fetch(everyone: bool) -> dict:
    who = [] if everyone else ["--author", "@me"]
    raw = gh("pr", "list", "--state", "open", "--limit", "50", *who, "--json", FIELDS)
    if raw is None:
        raise RuntimeError("the GitHub CLI could not list pull requests (gh auth login?)")
    prs = json.loads(raw)
    for pr in prs:
        extra = gh("pr", "view", str(pr["number"]), "--json", "files,commits")
        try:
            pr.update(json.loads(extra or "{}"))
        except ValueError:
            pass
    closed = json.loads(gh("pr", "list", "--state", "all", "--limit", "30", *who, "--json",
                           "number,title,state,url,headRefName,body,updatedAt") or "[]")
    me = (gh("api", "user", "-q", ".login") or "").strip()
    threads: dict[int, int] = {}
    repo = (gh("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner") or "").strip()
    if "/" in repo and prs:
        owner, name = repo.split("/", 1)
        q = ("query($o:String!,$n:String!){repository(owner:$o,name:$n){pullRequests(states:OPEN,first:50)"
             "{nodes{number reviewThreads(first:100){nodes{isResolved}}}}}}")
        data = gh("api", "graphql", "-f", f"query={q}", "-f", f"o={owner}", "-f", f"n={name}")
        try:
            for node in json.loads(data or "{}")["data"]["repository"]["pullRequests"]["nodes"]:
                threads[node["number"]] = sum(not t["isResolved"] for t in node["reviewThreads"]["nodes"])
        except Exception:
            pass  # unknown thread counts read as none; never crash the digest
    return {"prs": prs, "closed": closed, "me": me, "threads": threads}


def unpushed_by_branch() -> dict[str, int]:
    """Local branches with commits their origin branch lacks (the lead's batched pushes)."""
    out = {}
    for line in git("for-each-ref", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)",
                    "refs/heads").splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[1]:
            m = re.search(r"ahead (\d+)", parts[2])
            if m:
                out[parts[0]] = int(m.group(1))
    return out


def cloud_rows(sd: Path) -> list[dict]:
    rows = []
    try:
        for line in (sd / "cloud.tsv").read_text().splitlines():
            p = line.split("\t")
            if len(p) >= 5:
                rows.append({"ts": float(p[0]), "slug": p[1], "branch": p[2], "url": p[3], "task": p[4]})
    except (OSError, ValueError):
        pass
    return rows


def digest(data: dict, cfg: dict, lead: dict, verify_rows: list, cloud: list, unpushed: dict, now: float) -> dict:
    stale = float(cfg.get("LEAD_STALE_DAYS") or 3)
    no_pr_hours = float(cfg.get("LEAD_NO_PR_HOURS") or 6)
    items, healthy = [], 0
    cloud_urls = {c["url"] for c in cloud}
    for pr in data["prs"]:
        link = session_link(pr)
        ctx = {
            "now": now, "stale_days": stale, "me": data.get("me"), "lead": lead,
            "threads": data.get("threads", {}).get(pr.get("number")),
            "verified": history.verified(pr.get("headRefOid", ""), verify_rows),
            "unpushed": unpushed.get(pr.get("headRefName", ""), 0),
            "cloud_authored": bool(link) or link in cloud_urls
            or any(lb.get("name") == "cloud-authored" for lb in pr.get("labels") or []),
        }
        bucket, action, why = classify(pr, ctx)
        if bucket == "healthy":
            healthy += 1
        elif bucket != "skip":
            items.append({"number": pr.get("number"), "title": pr.get("title"), "url": pr.get("url"),
                          "head": pr.get("headRefName"), "sha": pr.get("headRefOid"), "bucket": bucket,
                          "action": action, "why": why, "session": link})
    open_nums = {p.get("number") for p in data["prs"]}
    reported = set(lead.get("reported_done", []))
    since = lead.get("seen_at") or (now - 86400)
    for c in data.get("closed", []):
        if c.get("number") in open_nums or c.get("state") not in ("MERGED", "CLOSED") or c.get("number") in reported:
            continue
        if age_days(c.get("updatedAt", ""), now) * 86400 <= now - since:
            items.append({"number": c["number"], "title": c.get("title"), "url": c.get("url"), "head": c.get("headRefName"),
                          "sha": None, "bucket": "done", "action": c["state"].lower(), "why": c["state"].lower(),
                          "session": session_link(c)})
    bodies = " ".join((p.get("body") or "") for p in data["prs"] + data.get("closed", []))
    for c in cloud:
        if c["url"] not in bodies and c["branch"] not in {p.get("headRefName") for p in data["prs"] + data.get("closed", [])} \
                and (now - c["ts"]) / 3600 > no_pr_hours:
            items.append({"number": None, "title": c["task"][:80], "url": c["url"], "head": c["branch"], "sha": None,
                          "bucket": "needs-you", "action": "no-pr",
                          "why": f"cloud task started {(now - c['ts']) / 3600:.0f}h ago, no PR yet: open the session",
                          "session": c["url"]})
    order = {"needs-you": 0, "needs-work": 1, "done": 2}
    items.sort(key=lambda i: (order[i["bucket"]], i["number"] or 0))
    return {"generated": now, "items": items, "healthy": healthy}


def signature(d: dict) -> list:
    """What --quiet compares: the open, actionable state. Done items are excluded: they are
    reported once and then drop out, which is not a change worth speaking about."""
    return sorted([str(i["number"] or i["url"]), i["bucket"], i["action"], i["sha"] or ""]
                  for i in d["items"] if i["bucket"] != "done")


def render(d: dict) -> str:
    out, titles = [], {"needs-you": "Needs you", "needs-work": "Needs work (the lead takes these)", "done": "Done"}
    for bucket in ("needs-you", "needs-work", "done"):
        rows = [i for i in d["items"] if i["bucket"] == bucket]
        if rows:
            out.append(titles[bucket])
            for i in rows:
                num = f"#{i['number']}" if i["number"] else "cloud"
                out.append(f"  {num} {i['action']}: {i['why']} · {(i['title'] or '')[:60]} · {i['url']}")
    if d["healthy"]:
        out.append(f"{d['healthy']} healthy")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    args, sd = argv[1:], state_dir(create=True)
    lead_path = sd / "lead.json"
    try:
        lead = json.loads(lead_path.read_text())
    except (OSError, ValueError):
        lead = {}
    for flag, key in (("--abandon", "abandoned"), ("--take-back", "taken_back"), ("--ignore", "ignored")):
        if flag in args:
            n = int(args[args.index(flag) + 1])
            lead.setdefault(key, [])
            if n not in lead[key]:
                lead[key].append(n)
            write_atomic(lead_path, json.dumps(lead, indent=1))
            hint = f" (close it on GitHub if it should go: gh pr close {n})" if key == "abandoned" else ""
            print(f"prs: #{n} {key.replace('_', ' ')} in the lead's view{hint}")
            return 0
    now = time.time()
    if "--from" in args:
        data = json.loads(Path(args[args.index("--from") + 1]).read_text())
    else:
        try:
            data = fetch("--all" in args)
        except Exception as e:
            print(f"prs: {e}")
            return 0
    d = digest(data, env(), lead, history.rows(sd / "verify.tsv"), cloud_rows(sd), unpushed_by_branch(), now)
    write_atomic(sd / "prs.json", json.dumps(d, indent=1))
    news = any(i["bucket"] == "done" for i in d["items"])  # finished work is always worth one line
    quiet_and_same = "--quiet" in args and signature(d) == lead.get("seen_sig") and not news
    if "--json" in args:
        print(json.dumps(d, indent=1))
    elif not quiet_and_same:
        text = render(d)
        if text:
            print(text)
    if "--mark-seen" in args:
        lead["seen_sig"], lead["seen_at"] = signature(d), now
        lead["reported_done"] = sorted(set(lead.get("reported_done", [])) |
                                       {i["number"] for i in d["items"] if i["bucket"] == "done" and i["number"]})
        write_atomic(lead_path, json.dumps(lead, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
