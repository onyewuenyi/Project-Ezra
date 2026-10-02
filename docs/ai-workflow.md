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

`claude --cloud "<task>"` for work that needs no Xcode: docs, scripts and CI config, String Catalog edits, audits and log triage, mechanical refactors, Foundation-only package logic. One-time: `/web-setup` (or install the Claude GitHub App). The cloud branch merges only after `/verify` passes on a Mac; label the PR `cloud-authored`. Recurring chores: `/schedule`.

## Rollout

1. Pilot: one developer, one feature through the loop. Gate: `/verify` passes, no hand edits to `.pbxproj`.
2. Team: everyone runs `bootstrap.sh`. Gate: the smoke test passes on every Mac.
3. Parallelism and auto mode: two worktrees and one cloud task each; review `/insights` for permission-prompt data. Gate: no cross-worktree interference, every cloud branch passed `/verify`.
4. Lock in: pin the minimum Xcode (`MIN_XCODE` in `.claude/ios.env`) and Claude Code versions; re-run `/doctor prompt-audit` after each upgrade.
