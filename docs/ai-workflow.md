# AI iOS workflow (ios-ai-kit)

<!-- ios-ai-kit:begin (managed by ios-ai-kit install.py: upgrades replace this block; write your team's notes outside it) -->
How this repo is developed with Claude Code. The rules Claude follows live in `CLAUDE.md` (the ios-ai-kit block) and `.claude/skills/`; this page is for people.

## Setup (once per Mac)

1. Xcode 27 installed and selected: `sudo xcode-select -s /Applications/Xcode.app`.
2. `scripts/ai/bootstrap.sh`: checks the toolchain, exports Apple's Xcode skills to `~/.claude/skills` (per developer, never committed), creates this checkout's simulator, and runs a smoke test (build, install, launch, screenshot). It fails loudly.
3. Optional, for previews and device interaction: Xcode ▸ Settings ▸ Intelligence ▸ Model Context Protocol ▸ Xcode Tools on, and keep the project open in Xcode. `.mcp.json` already registers `xcrun mcpbridge`. Xcode asks to approve each connection.

Per-machine overrides go in `CLAUDE.local.md` and `.claude/settings.local.json` (both gitignored). This checkout's simulator is recorded in `.claude/ios.local.env` (gitignored, created automatically).

### First run (the steps only a person can take)

`scripts/ai/doctor.sh` reports each one it can see, with its fix, and every session start repeats what is still open.

1. **Trust the folder:** run `claude` in the repo once and choose Yes on "Do you trust the files in this folder?". Until then the committed permission rules are ignored. Claude Code has no flag for it.
2. **GitHub CLI:** `brew install gh && gh auth login`.
3. **Lock the default branch (owner, once per repo):** `scripts/ai/protect-main.sh`. GitHub then refuses direct pushes, force pushes and deletion for everyone; changes arrive only through pull requests.
4. **Cloud sessions:** `/web-setup` in Claude Code, or install the Claude GitHub App on the repo. Cloud tasks run in the Default permission mode; Auto is not needed.
5. **Optional, for previews and device interaction:** approve the agent the first time `/verify` opens the project in Xcode.

## The loop and the gate

`.claude/skills/ios-loop/SKILL.md` routes every non-trivial task to a playbook (bug fix, feature, UI pass, prototype, investigation, perf, hillclimb, schema change, release, device run, delegate, autonomous run, handoff) whose steps end in evidence, with the principles behind them in `principles.md`. Done means `/verify` passed: format · build with no new warnings (`.claude/ios-warnings.txt` is the accepted baseline; `scripts/ai/build.sh --update-baseline` after review) · tests · no launch-argument read outside `#if DEBUG` · blast radius · each screen in `.claude/ios-screens.txt` at default, dark and the largest text size, judged by eye (`/map` builds and refreshes that list). Every gate of every run is kept in the repo's verify history (`python3 scripts/ai/history.py last`). The Stop hook runs the fast half (format lint + incremental build, cached per change) whenever a turn changed code, so a broken build cannot be reported as done; `IOS_AI_STOP_CHECK=0` turns it off for a session.

Review and lessons: `/interrogate` tears a diff apart through independent lenses (concurrency, persistence, lifecycle, extremes, accessibility, privacy, performance, slop), a second Claude model on the riskiest, and reports only verified findings. `/reflect` turns a session's lessons into a type, a test, a hook or a rule.

## How a change reaches the default branch

Always through a pull request. Commit (on any branch, even the default one), run `/verify`, then `scripts/ai/pr.sh`: it moves commits made on the default branch onto a new `claude/<topic>` branch, pushes it, and opens the PR with the `/verify` report as its body (a second run updates the same PR). The owner reviews and merges on GitHub. The guard hook refuses a direct push with this instruction, and GitHub's ruleset refuses it for everyone.

## The lead: work is done when it is merged

`/lead` reads every open PR you authored and sorts it: **needs you** (ready to merge, stalled, review requested, fixes waiting to be pushed, a cloud task that never opened a PR), **needs work** (conflicts, failing checks, review threads, app code not verified at its head), healthy (counted, never listed), done (reported once). It does the needs-work itself on each PR's own branch (`scripts/ai/worktree.sh pr <n>`): runs `/verify` on cloud-authored PRs, merges the base to resolve conflicts, fixes checks and threads. It never merges, closes, force-pushes or posts outside the terminal; `LEAD_COMMENT`, `LEAD_PUSH` and `LEAD_REBASE` in `.claude/ios.env` opt in. For a workday cadence leave a session running `/loop /lead`: it paces itself (about 10 minutes while checks run, 60 when all is healthy) and stays quiet unless something needs you. `python3 scripts/ai/prs.py` prints the same digest by hand; `--abandon N` and `--take-back N` tell the lead to let a PR go. Merged or closed PRs give back their worktree and simulator: `scripts/ai/worktree.sh prune` (the lead runs it).

## Delegating and parallel work

`.claude/skills/ios-loop/playbooks/delegate.md` splits a request into verifiable units and routes each: **cloud** (`scripts/ai/cloud.sh "<task>"` for anything needing no Xcode: docs, scripts, String Catalogs, audits, mechanical refactors, Foundation-only logic; it asks before launching, adds the no-Xcode footer and records the session for `/lead`), a **local worktree** (`claude --worktree <name>` or `scripts/ai/worktree.sh new <name>`: its own branch, `.build/dd` and simulator), or this session. Two or three sessions at most. Worktrees start from your HEAD; gitignored files the build needs are listed in `.worktreeinclude`. Remove with `scripts/ai/worktree.sh remove <path>` (deletes that simulator too). A follow-up goes to the same unit (`cloud.sh --branch <head>`), never a fresh session.

A cloud session has nobody to answer a permission prompt, so the **cloud gate** (`.claude/hooks/cloud-gate.py`, a `PermissionRequest` hook) answers in your place there, and only there: it approves a command made only of `git add/commit`, a push of explicit `claude/*` branches to `origin`, `gh pr create`, and read-only filters; it refuses everything else with a reason the session reads and follows. Locally it is silent. It never overrides a deny rule and never grants beyond the one call. The cloud branch merges only after `/verify` passes on a Mac.

## Healthchecks

- **Session start:** a few lines only when something is off: commits on the default branch that never went through a PR, a branch already merged (start the next change from main), uncommitted work, HEAD unverified or failing, PRs that need you, doctor warnings, a stale healthcheck. Silent otherwise.
- **Status line** (opt-in, this Mac: `python3 <kit>/install.py . --statusline`): the branch, HEAD's verify state and the PRs that need you, always under the prompt.
- **`/friction`** (weekly; `/lead` runs it quietly each weekday): what keeps costing sessions time, from this repo's transcripts and verify history: commands no rule allows, rejected calls, repeated hook refusals, recurring compiler errors, flaky tests, slowing gates, and on Mondays oversized outputs and token use. You pick which proposals to apply; each lands with a test, through a PR.

## Rollout

1. Pilot: one developer, one feature through the loop. Gate: `/verify` passes, no hand edits to `.pbxproj`, the change merged through a PR.
2. Team: everyone runs `bootstrap.sh`. Gate: the smoke test passes on every Mac.
3. Parallelism: two worktrees and one cloud task each, with `/lead` following them. Gate: no cross-worktree interference, every cloud branch passed `/verify`.
4. Lock in: pin the minimum Xcode (`MIN_XCODE` in `.claude/ios.env`) and Claude Code versions; `/friction` weekly; re-run `/doctor prompt-audit` after each upgrade.
<!-- ios-ai-kit:end -->
