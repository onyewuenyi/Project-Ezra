"""Helpers shared by the kit's Python scripts: where state lives and what the repo's config says.

Same rules as lib.sh: configuration is environment > .claude/ios.local.env > .claude/ios.env, and
state lives in git's common dir (shared by every worktree, never committed, survives rm -rf .build).
"""
import os
import re
import subprocess
from pathlib import Path


def git(*args: str, cwd: str | os.PathLike | None = None, timeout: int = 10) -> str:
    try:
        return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True,
                              timeout=timeout).stdout.strip()
    except Exception:
        return ""


def repo_root(cwd: str | os.PathLike | None = None) -> Path:
    top = git("rev-parse", "--show-toplevel", cwd=cwd)
    return Path(top) if top else Path(cwd or ".").resolve()


def state_dir(cwd: str | os.PathLike | None = None, create: bool = False) -> Path:
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd)
    d = Path(common or Path(cwd or ".") / ".git") / "ios-ai"
    if create:
        d.mkdir(parents=True, exist_ok=True)
    return d


def env(cwd: str | os.PathLike | None = None) -> dict[str, str]:
    """The repo's kit configuration, with the process environment winning."""
    root = repo_root(cwd)
    vals: dict[str, str] = {}
    for f in (root / ".claude/ios.env", root / ".claude/ios.local.env"):  # later file wins
        try:
            for line in f.read_text().splitlines():
                m = re.match(r"\s*([A-Z][A-Z0-9_]*)=(.*)", line)
                if m:
                    vals[m.group(1)] = m.group(2).strip().strip("'\"")
        except OSError:
            pass
    vals.update({k: v for k, v in os.environ.items() if re.fullmatch(r"[A-Z][A-Z0-9_]*", k)})
    return vals


def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    tmp.write_text(text)
    tmp.replace(path)
