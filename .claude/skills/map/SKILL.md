---
name: map
description: Build or refresh .claude/ios-screens.txt, the list of screens /verify captures at default, dark and the largest text size: finds how the app is reached (DEBUG launch-argument seams, deep links, UI tests), proposes one line per primary surface with the accessibility labels each must show (probed from the live UI hierarchy), and repairs drift. Offers a minimal LaunchSeams.swift when the app has no seams. Use for /map, a new app, "the visual gate checks nothing useful", or `/map refresh` after screens changed.
argument-hint: "[refresh]"
disable-model-invocation: true
---

# Map

**Job:** make `.claude/ios-screens.txt` name the screens that matter, each reachable by a seam the app really reads and asserted by labels the screen really shows.

**Not my job:** adding seams or any other app code without a yes · screens nobody would judge (eval seams, debug-only tools) · verifying behavior (that is `/verify` and the playbooks) · editing the kit's scripts.

**When there is nothing to report:** "ios-screens.txt is current: N screens, all reachable, none stale."

With `refresh`, skip to **Refresh**.

## 1. Find how the app is reached (from the code, not the owner)

- **Seams:** `python3 scripts/ai/screens-drift.py --seams` lists every `-Flag` the app reads and which are already in the matrix. Read where each is handled to learn what state it reaches. `python3 scripts/ai/debug-fences.py <sources>` confirms they are all inside `#if DEBUG`.
- **Deep links:** `CFBundleURLTypes` in Info.plist, `onOpenURL` handlers (driven with `scripts/ai/sim.sh openurl`).
- **First launch:** what a plain launch writes (onboarding, an identity, a default record). If a seed is needed before every launch, it belongs in `BASE_LAUNCH_ARGS` in `.claude/ios.env`, not on each line.
- **No seams at all:** propose adding `LaunchSeams.swift` (next to this skill: a DEBUG-only flag reader) with two seams, seed sample data and open the primary screen, wired where the app builds its root view. It changes the app, so show the diff and ask first.

## 2. Choose the screens

The 3 to 6 surfaces a person spends their time on, plus the states that break most often: the root, the main list (with data, and empty), a detail, settings, and any screen the last bug lived on. One line each: `name | launch arguments | expect: label; label | absent: label`.

## 3. Probe the labels

For each line, launch it and read the live hierarchy (Xcode running; the first open asks you to approve the agent):
`python3 scripts/ai/xcui.py --udid "$(scripts/ai/sim.sh udid)" --container <PROJECT or WORKSPACE from .claude/ios.env> --bundle <APP_BUNDLE_ID> --args="<launch arguments>" --name probe`
Read the printed hierarchy file and choose 1 to 3 labels that prove the screen is the right one in the right state (accessibility labels, which can differ from visible text). Without Xcode, write the line without `expect:` and say the assertions are owed.

## 4. Write and prove

Write the lines, each preceded by `#seen:<today>`. Run `scripts/ai/visual.sh <names>`: every assertion passes and you looked at every sheet. Commit, then `scripts/ai/pr.sh`.

## Refresh

1. `python3 scripts/ai/screens-drift.py`: fix each `broken` line (find the seam's new name in the code, or retire the line) and re-probe each `stale` one; re-date what still holds.
2. `--seams`: add a line for any new seam that reaches a primary surface.
3. Prove with `scripts/ai/visual.sh <changed names>`, commit, `scripts/ai/pr.sh`.
