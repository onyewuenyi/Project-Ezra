# AI iOS workflow (ios-ai-kit)

How this repo is developed with Claude Code. The rules Claude follows live in `CLAUDE.md` (the ios-ai-kit block), `.claude/skills/ios-loop` and `.claude/skills/verify`; this page is for people.

## Setup (once per Mac)

1. Xcode 27 installed and selected: `sudo xcode-select -s /Applications/Xcode.app`.
2. `scripts/ai/bootstrap.sh` — checks the toolchain, exports Apple's Xcode skills to `~/.claude/skills` (per developer, never committed), creates this checkout's simulator, and runs a smoke test (build, install, launch, screenshot). It fails loudly.
3. Optional, for previews and device interaction: Xcode > Settings > Intelligence > Model Context Protocol > Xcode Tools on, and keep the project open in Xcode. `.mcp.json` already registers `xcrun mcpbridge`. Xcode asks to approve each connection.

Per-machine overrides go in `CLAUDE.local.md` and `.claude/settings.local.json` (both gitignored). This checkout's simulator is recorded in `.claude/ios.local.env` (gitignored, created automatically).

## The loop and the gate

See `.claude/skills/ios-loop/SKILL.md`. Done means `/verify` passed: format · build with no new warnings (`.claude/ios-warnings.txt` is the accepted baseline; `scripts/ai/build.sh --update-baseline` after review) · tests · no launch-argument read outside `#if DEBUG` · blast radius · each screen in `.claude/ios-screens.txt` at default, dark and the largest text size, judged by eye. The Stop hook runs the fast half (format lint + incremental build, cached per change) whenever a turn changed code, so a broken build cannot be reported as done. Turn it off for a session with `IOS_AI_STOP_CHECK=0`.

## Parallel work

Two or three sessions at most. `claude --worktree <name>` or `scripts/ai/worktree.sh new <name>`: each worktree gets its own `.build/dd` and its own simulator on first build. Worktrees start from your HEAD (`worktree.baseRef: "head"`); gitignored files the build needs are listed in `.worktreeinclude`. The Xcode MCP serves the checkout open in Xcode only; worktrees use the shell path. Remove with `scripts/ai/worktree.sh remove <path>` (deletes that simulator too).

## Cloud sessions

`claude --cloud "<task>"` for work that needs no Xcode: docs, scripts and CI config, String Catalog edits, audits and log triage, mechanical refactors, Foundation-only package logic. The cloud branch merges only after `/verify` passes on a Mac; label the PR `cloud-authored`. Recurring chores: `/schedule`.

A cloud session has nobody to answer a permission prompt, so the **cloud gate** (`.claude/hooks/cloud-gate.py`, a `PermissionRequest` hook) answers in your place there, and only there: it approves a command made only of `git add/commit`, a push of explicit `claude/*` branches to `origin`, `gh pr create`, and read-only filters; it refuses everything else with a reason the session reads and follows. Locally it is silent and you get the prompt as before. It never overrides a deny rule and never grants anything beyond the one call. Prefix and on/off: `CLOUD_BRANCH_PREFIX` / `CLOUD_PUBLISH` in `.claude/ios.env`. The Stop hook's build check is skipped there (no Xcode); the report says "not compiled with Xcode" instead.

### First run (the steps only a person can take)

`scripts/ai/doctor.sh` reports each one it can see, with its fix.

1. **Trust the folder:** run `claude` in the repo once and choose Yes on "Do you trust the files in this folder?". Until then the committed permission rules are ignored. Claude Code has no flag for it.
2. **GitHub CLI:** `brew install gh && gh auth login`.
3. **Lock the default branch (owner, once per repo):** `scripts/ai/protect-main.sh`. GitHub then refuses direct pushes, force pushes and deletion for everyone; changes arrive only through pull requests.
4. **Cloud sessions:** `/web-setup` in Claude Code, or install the Claude GitHub App on the repo. Cloud tasks run in the Default permission mode; Auto is not needed.
5. **Optional, for previews and device interaction:** Xcode ▸ Settings ▸ Intelligence ▸ Xcode Tools on; approve the agent the first time `/verify` opens the project.

## How a change reaches the default branch

Always through a pull request. Commit (on any branch, even the default one), run `/verify`, then `scripts/ai/pr.sh`: it moves commits made on the default branch onto a new `claude/<topic>` branch, pushes it, and opens the PR with the `/verify` report as its body (a second run updates the same PR). The owner reviews and merges on GitHub. The guard hook refuses a direct push with this instruction, and GitHub's ruleset refuses it for everyone.

## Rollout

1. Pilot: one developer, one feature through the loop. Gate: `/verify` passes, no hand edits to `.pbxproj`, the change merged through a PR.
2. Team: everyone runs `bootstrap.sh`. Gate: the smoke test passes on every Mac.
3. Parallelism and auto mode: two worktrees and one cloud task each; review `/insights` for permission-prompt data. Gate: no cross-worktree interference, every cloud branch passed `/verify`.
4. Lock in: pin the minimum Xcode (`MIN_XCODE` in `.claude/ios.env`) and Claude Code versions; re-run `/doctor prompt-audit` after each upgrade.
