---
name: ios-loop
description: The iOS development loop for this repo — build, test, run and verify on this checkout's own simulator, fix build and test failures, and prove UI changes with screenshots or Xcode's device interaction. Use when building, running, testing or debugging the app, after implementing a change, for "does it work", "test this", "fix this bug", "build this feature", a UI or design pass, parallel work in worktrees, or deciding whether a task can run in a cloud session.
---

# iOS loop

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
- **Before believing a crash or a hang,** run `scripts/ai/sim.sh guard` (a plain launch must stay alive) and `sim.sh crashes <epoch>`. Some traps write no report, so also check `sim.sh alive`.
- **Motion:** start `sim.sh record` BEFORE the launch that triggers the motion. Then `sim.sh frames` gives a numbered strip; read it frame by frame.

## Bug fixes

1. **Reproduce first, on the surface the user saw.** Record how often it happens (for example, "fails 4 of 6").
2. **Separate three things:** the trigger, the masking condition (what makes it intermittent: text size, timing, data, device) and the symptom.
3. **Write the failing test first** and show it failing for the stated reason: a unit test for logic, a UI-hierarchy assertion or screenshot for UI.
4. **Make the smallest fix at the root.** No nil-guard, retry or delay that hides it.
5. **Prove it the same way, the same number of times.** Then run the full suite and re-check every screen `blast-radius.py` names.

## UI work: two passes

- **Pass 1 makes it work:** states, navigation, interaction, tests.
- **Pass 2 is a separate prompt and makes it good:** spacing and type against neighbouring screens, the largest text size, dark mode, Reduce Motion, and frame-level checks of transitions.
- One prompt asking for both does worse at each.

## Parallel work

- **Limits:** two or three sessions at once. Each gets its own worktree (`claude --worktree <name>`, or `scripts/ai/worktree.sh new <name>`), its own `.build/dd` and its own simulator, all automatic.
- **Worktree contents:**
  - Worktrees start from your current HEAD (`worktree.baseRef: "head"`).
  - Gitignored files the build needs are listed in `.worktreeinclude`.
- **Cleanup:** remove with `scripts/ai/worktree.sh remove <path>`, which also deletes that worktree's simulator.

## Cloud sessions (no Xcode there)

**Route to the cloud** (`claude --cloud "<task>"`) only work that needs no Xcode:
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
- push a branch.

**Back on the Mac:** that branch runs `/verify` before it merges.

## Reporting

Every reply that claims a change works names its evidence: the gate results, screenshot or frame-strip paths, test counts. It also says what was NOT verified: device-only behavior such as real notification delivery, push, camera or performance on older hardware.
