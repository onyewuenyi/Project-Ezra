---
name: ios-loop
description: The iOS development loop for this repo — build, test, run and verify on this checkout's own simulator, fix build and test failures, and prove UI changes with screenshots or Xcode's device interaction. Use when building, running, testing or debugging the app, after implementing a change, for "does it work", "test this", "fix this bug", "build this feature", a UI or design pass, parallel work in worktrees, or deciding whether a task can run in a cloud session.
---

# iOS loop

**Job:** take one change from idea to a proven, proposed PR on this checkout's own simulator.

**Not my job:** merging · pushing to the default branch · editing `*.pbxproj` by hand or build settings the task did not ask for · following a PR after it opens (`/lead` does) · reviewing someone else's diff (`/interrogate`).

**When there is nothing to report:** the gate results and the PR link, nothing more.

Every change goes through the same loop, one logical change per build. Your claim that something works is not evidence: a build result, a test run, a hierarchy assertion or a screenshot you looked at is.

## The loop

1. **Context.** `CLAUDE.md` is loaded. Run `scripts/ai/doctor.sh` if anything looks off. A broken simulator runtime or a stale toolchain looks exactly like an app bug.
2. **Locate and propose.** Grep and Glob find the files. State the smallest diff you plan, and why, before editing.
3. **Edit.** Use Edit and Write only. Never hand-edit `*.pbxproj`. With synchronized folders, a new `.swift` file in the target's folder compiles automatically. Otherwise, confirm target membership first.
4. **Build.** Run `scripts/ai/build.sh`. It prints only errors, new warnings and one summary line; the full log is in `.build/build.log`. For huge failures, hand the build to the `build-verify` agent.
5. **Fix.**
   - Fix the minimal cause and rebuild.
   - When an API is in doubt, consult Apple's exported skills (`swiftui-specialist`, `swiftui-whats-new-27`, …) or `DocumentationSearch`. Never guess.
   - When an error makes no sense, `rm -rf .build/dd` and rebuild before believing it.
6. **Test.**
   - Run `scripts/ai/test.sh [-only-testing:Target/Suite/test()]`. It reads the `.xcresult`, not the log.
   - A Swift Testing function id needs `()`.
   - "Nothing ran" is a failure, not a pass.
7. **Verify on the surface.**
   - Use the `ui-verify` agent. It prefers Xcode's device interaction (taps, plus assertions on the UI hierarchy) and falls back to `scripts/ai/visual.sh`, which takes screenshots at default, dark and the largest text size.
   - Run `python3 scripts/ai/blast-radius.py <files>` to list every screen the change reaches, and verify those, not just the one you edited.
8. **Gate.** `/verify` runs every gate. "Done" means it passed, and the report lists what was not verified.
9. **Commit.** One commit per logical change. The message says why, not only what.
10. **Propose.** Run `scripts/ai/pr.sh`. It never pushes to the default branch: commits made there move onto a new branch, which it pushes and opens as a PR, with `/verify`'s report as the body when it is fresh. A second run after more commits updates the same PR. Leave the merge to the owner.

## Xcode MCP or shell

- **Use the Xcode MCP tools (`mcp__xcode__*`) for:**
  - structured builds and tests: `BuildProject`, `GetBuildLog`, `RunSomeTests`;
  - previews: `RenderPreview`;
  - docs: `DocumentationSearch`;
  - project edits that keep target membership: `XcodeWrite`, `XcodeMV`, `XcodeRM`, `AddInfoPlist`, `AddEntitlement`;
  - device interaction.
- **Measured behavior (Xcode 27.0):**
  - `XcodeOpenWorkspace` opens the project. The first open is what asks the person to approve the agent.
  - Address the project by the `workspaceIdentifier` that `XcodeListWorkspaces` or `XcodeOpenWorkspace` returns. A path is rejected.
  - There is no `XcodeListWindows`. Match by `workspacePath` in `XcodeListWorkspaces`.
  - `DeviceInteractionStartWorkspaceSession` accepts `deviceIdentifier` = this checkout's UDID (`scripts/ai/sim.sh udid`). Always pass it, so Xcode never picks another session's device.
  - Taps, typing and captures go through `DeviceInteractionSynthesize`, and Xcode requires them to run in a subagent: use `ui-verify`.
  - End every session with `DeviceInteractionEndSession`.
- **Fixed checks:** `scripts/ai/xcui.py --udid … --container … --bundle … --args=<launch args> --expect "<label>"` asserts labels in the live UI hierarchy in one command. `/verify` runs it for every `expect:` in `.claude/ios-screens.txt`.
- **Everything also works from the shell.** Worktrees and parallel sessions use the shell scripts, or open their own workspace in Xcode.

## Simulators

- **Each checkout has its own simulator,** created on first build and recorded in `.claude/ios.local.env`.
- **Address it by UDID:**
  - `scripts/ai/sim.sh udid | install | launch <args> | shot <png> | size <category> | appearance dark | record | frames | compare | guard | crashes <since>`.
  - Never use `booted`, and never a bare device name. The guard hook blocks both when they're ambiguous.
- **Before believing a crash or a hang,** run `scripts/ai/sim.sh guard` (a plain launch must stay alive) and `scripts/ai/sim.sh crashes <epoch>`. Some traps write no report, so also check `sim.sh alive`.
- **Motion:** start `sim.sh record` BEFORE the launch that triggers the motion. Then `sim.sh frames` gives a numbered strip; read it frame by frame.

## Playbooks

A task that is more than one obvious edit gets a playbook. Read its file (paths relative to this skill), copy its steps into the todo list before any task-specific items, and keep a skipped step as `skip: <reason>`. No playbook fits: write one in the same shape (numbered steps, each ending in a check, and the reply) and say so. The principles behind them, each with its trigger: `principles.md`.

| Playbook | When | File |
|---|---|---|
| Bug fix | A defect to reproduce, root-cause and fix | `playbooks/bug-fix.md` |
| Feature | New or changed behavior | `playbooks/feature.md` |
| UI pass | Design, layout, motion or accessibility audit of a surface (pass 2 of UI work) | `playbooks/ui-pass.md` |
| Prototype arena | A design fork a screenshot can settle: build variants, compare side by side | `playbooks/prototype.md` |
| Investigation | A read-only question; the deliverable is a report | `playbooks/investigation.md` |
| Perf | A measured slowness: launch, scroll, hitch, memory, energy | `playbooks/perf.md` |
| Hillclimb | Move one metric (eval score, model latency, accuracy) against a baseline | `playbooks/hillclimb.md` |
| Schema change | Core Data or SwiftData model, migration, CloudKit schema | `playbooks/schema-change.md` |
| Release | Archive, audit, submit, TestFlight, App Review prep | `playbooks/release.md` |
| Device run | Anything only a physical device can prove | `playbooks/device-run.md` |
| Delegate | Work bigger than one change, split across sessions | `playbooks/delegate.md` |
| Autonomous run | The owner steps away: "run until done", overnight | `playbooks/autonomous.md` |
| Handoff | Pausing work, or picking up another session's | `playbooks/handoff.md` |

## Parallel work

- **Splitting a request across sessions:** `playbooks/delegate.md`. Every unit is tracked to a merged PR by `/lead`.
- **Limits:** two or three sessions at once. Each gets its own worktree (`claude --worktree <name>`, or `scripts/ai/worktree.sh new <name>`), its own `.build/dd` and its own simulator, all automatic.
- **Worktree contents:**
  - Worktrees start from your current HEAD (`worktree.baseRef: "head"`).
  - Gitignored files the build needs are listed in `.worktreeinclude`.
- **Cleanup:** remove with `scripts/ai/worktree.sh remove <path>`, which also deletes that worktree's simulator.

## Cloud sessions (no Xcode there)

**Route to the cloud** (`scripts/ai/cloud.sh "<task>"`: it adds the no-Xcode footer and `/lead` tracks the session to a merged PR) only work that needs no Xcode:
- docs, README, changelog;
- scripts and CI config;
- String Catalog edits;
- audits and triage of pasted logs;
- mechanical refactors that a local build will then check;
- Foundation-only package logic.

**In a cloud session:**
- never run `xcodebuild` or `simctl`;
- say "not compiled with Xcode";
- list every unverified item;
- commit, push your own branch with `git push -u origin claude/<name>` (explicit remote and branch), and open a PR with `gh pr create`.
- Nobody is there to answer a permission prompt, so the cloud gate answers: it approves exactly that publish shape, and refuses anything else (pushing to the default branch, force, delete, merge, `rm -rf`, an edit that needs approval) with a reason. Follow the reason; never retry the same thing in another form. Anything you could not do goes in the report as not done.

**Back on the Mac:** that branch runs `/verify` before it merges.

## Reporting

Every reply that claims a change works names its evidence: the gate results, screenshot or frame-strip paths, test counts. It also says what was NOT verified: device-only behavior such as real notification delivery, push, camera or performance on older hardware.
