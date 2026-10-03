#!/usr/bin/env python3
"""The verify history: the only reader of $STATE_DIR/verify.tsv, which verify.sh appends to.

Columns: ts run_id sha branch dirty gate result secs summary. A gate row per gate per run, plus a
`fail:<test id>` row per failing test. Shared by every worktree of the repo (git's common dir).

  history.py last [sha]     the latest run on that commit (default HEAD): one line per gate
  history.py verified [sha] exit 0 if the latest clean-tree run on that commit passed every gate
  history.py flips [n]      tests that failed AND passed on the same commit within the last n runs
  history.py stats [n]      per-gate median seconds over the last n runs
Imported by prs.py, friction.py and bearings.py, so the format is parsed in one place.
"""
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

sys.dont_write_bytecode = True  # never leave __pycache__ in the project's scripts/ai
sys.path.insert(0, str(Path(__file__).resolve().parent))
from kit import state_dir  # noqa: E402

FIELDS = ["ts", "run_id", "sha", "branch", "dirty", "gate", "result", "secs", "summary"]




def rows(path: Path | None = None) -> list[dict]:
    path = path or state_dir() / "verify.tsv"
    out = []
    try:
        for line in path.read_text(errors="replace").splitlines():
            parts = line.split("\t")
            if len(parts) == len(FIELDS):
                out.append(dict(zip(FIELDS, parts)))
    except OSError:
        pass
    return out


def runs(rs: list[dict]) -> list[list[dict]]:
    """Rows grouped by run, oldest run first."""
    by, order = defaultdict(list), []
    for r in rs:
        if r["run_id"] not in by:
            order.append(r["run_id"])
        by[r["run_id"]].append(r)
    return [by[k] for k in order]


def last_run(sha: str, rs: list[dict] | None = None) -> list[dict] | None:
    """The newest run on this commit, or None."""
    matching = [run for run in runs(rows() if rs is None else rs) if run[0]["sha"] == sha]
    return matching[-1] if matching else None


def verified(sha: str, rs: list[dict] | None = None) -> bool:
    """The newest run on this commit was on a clean tree and no gate failed (SKIPPED is not a failure)."""
    run = last_run(sha, rs)
    if not run or run[0]["dirty"] != "0":
        return False
    gates = [r for r in run if not r["gate"].startswith("fail:")]
    return bool(gates) and all(r["result"] in ("PASS", "SKIPPED") for r in gates) \
        and any(r["result"] == "PASS" for r in gates)


def test_flips(n: int = 50, rs: list[dict] | None = None) -> dict[str, int]:
    """Tests that failed on a commit where the same test also passed (a later run without its fail row
    and with the tests gate run). Value: how many commits it flipped on. A flake, not a regression."""
    recent = runs(rows() if rs is None else rs)[-n:]
    by_sha = defaultdict(list)
    for run in recent:
        by_sha[run[0]["sha"]].append(run)
    flips: dict[str, int] = defaultdict(int)
    for sha, rns in by_sha.items():
        tested = [r for r in rns if any(g["gate"] == "tests" and g["result"] in ("PASS", "FAIL") for g in r)]
        failed_in = [{g["gate"][5:] for g in r if g["gate"].startswith("fail:")} for r in tested]
        for t in set().union(*failed_in) if failed_in else set():
            if any(t not in f for f in failed_in):
                flips[t] += 1
    return dict(flips)


def gate_stats(n: int = 20, rs: list[dict] | None = None) -> dict[str, float]:
    """Median seconds per gate over the last n runs that ran it."""
    secs = defaultdict(list)
    for run in runs(rows() if rs is None else rs):
        for r in run:
            if not r["gate"].startswith("fail:") and r["result"] in ("PASS", "FAIL"):
                try:
                    secs[r["gate"]].append(float(r["secs"]))
                except ValueError:
                    pass
    return {g: statistics.median(v[-n:]) for g, v in secs.items() if v}


def head() -> str:
    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "last"
    arg = argv[2] if len(argv) > 2 else None
    if cmd == "last":
        run = last_run(arg or head())
        if not run:
            print("history: this commit has not been verified")
            return 1
        for r in run:
            print(f"{r['gate']:<10} {r['result']:<7} {r['secs']:>4}s  {r['summary'][:100]}")
        return 0
    if cmd == "verified":
        return 0 if verified(arg or head()) else 1
    if cmd == "flips":
        for t, k in sorted(test_flips(int(arg or 50)).items(), key=lambda x: -x[1]):
            print(f"{k}\t{t}")
        return 0
    if cmd == "stats":
        for g, m in sorted(gate_stats(int(arg or 20)).items()):
            print(f"{g:<10} median {m:.0f}s")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
