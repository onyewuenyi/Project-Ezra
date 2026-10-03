---
name: verify-ezra
description: Drive Project Ezra on the iOS 27 simulator the way a user does and capture evidence: doctor, build, install, launch seams, screenshots at every text size, frame sheets, cleanup, plus a per-feature map. Use to prove any UI or behavior change in Ezra, to reproduce a bug, or to capture screens.
---

# Verify Ezra

Read this whole file before driving the app. Then read the feature file for what you are verifying (`features/README.md` is the index). The authoritative list of launch seams is `seams.md` in this skill (moved verbatim from CLAUDE.md on 2026-10-02); the table below is the short version, so `seams.md` is the one place to update.

All commands run from the repo root.

## Setup (once per machine)

```bash
V=.claude/skills/verify-ezra; S="bash $V/scripts/sim.sh"
# Dedicated simulator, created once, always addressed by UDID. Three iOS 27.0 runtimes share
# ONE identifier on this host (betas 24A5380i, 24A5390f and GA 24A434); `create` picked GA on
# 2026-09-29 — the Doctor block checks the build, because a beta runtime is a different model.
[ -f $V/.udid ] || xcrun simctl create "ezra-verify" "iPhone 17 Pro" com.apple.CoreSimulator.SimRuntime.iOS-27-0 > $V/.udid
U=$(cat $V/.udid); B=amanze-studios.Project-Ezra
# Isolated derived data and evidence. `build/` is gitignored. If another session may be
# verifying from this same checkout, give yourself your own paths (export both first).
DD=${EZRA_VERIFY_DD:-$PWD/build/verify-dd}; EV=${EZRA_VERIFY_EV:-$PWD/build/verify-evidence/$(date +%Y%m%d-%H%M)}
```

`.udid` is gitignored (`$V/.gitignore`). If `.udid` names a device that no longer exists, delete the file and create again.

## Doctor (first, and whenever anything looks off)

```bash
$S boot $U && $S doctor $U $B
xcodebuild -version | head -1                                   # must read Xcode 27.x (CLAUDE.md: Toolchain)
xcrun simctl getenv $U SIMULATOR_RUNTIME_BUILD_VERSION          # expect 24A434 (iOS 27.0 GA); a 24A5xxx is a beta runtime
ls Project-Ezra/GoogleService-Info.plist                        # absent = cloud rung dormant; the app still boots (by design)
```

`doctor` WARNs about other booted simulators and other `xcodebuild`s: on this host both are normal (other sessions run). They are the reason everything below is by UDID and into `$DD`. **Do not act on doctor's `shutdown-all` hint** — it shuts down every session's simulators. If *your* runtime cannot spawn a process: `xcrun simctl shutdown $U && $S boot $U`.

## Build and install

```bash
APP=$($S build $U $DD -- -project Project-Ezra.xcodeproj -scheme Project-Ezra)   # ~5 min cold, full log in $DD/build.log
xcrun simctl uninstall $U $B 2>/dev/null   # THIS simulator only: a known state needs an empty store
$S install $U "$APP"                        # verifies the installed binary is the one you built
$S privacy $U grant microphone $B           # else the permission alert covers the capture sheet
$S launch $U $B -SeedFlowFixtures           # the SEED IS THE FIRST LAUNCH — see below
$S launch $U $B -SeedFlowFixtures           # again: the first one may still show the name screen while it seeds
$S guard $U $B                              # a plain launch must stay alive; if not, nothing measured now counts
```

**Seed on the very first launch, then guard — never the other way round** (measured 2026-09-29). A plain launch on an empty store starts onboarding's "What should I call you?" and leaves an identity behind; the fixture seed then builds its own household beside it. The first seeded screen looks right, but every later launch treats someone else as "you": the home reads "Nothing is asking for you today. Charles has 25 open, Ezra has 1 open…", rows carry owner prefixes, and suggestions name the wrong person. Seeded first, the same store is stable across bare relaunches and text-size changes. If you see "Nothing is asking for you" on a seeded store, uninstall and redo this block; it is not your change.

Every seed except `-ResetAndSeedEvalCorpus` refuses a non-empty store and silently shows the old data.

## Drive

There are **no deep links** (no `CFBundleURLTypes`; `SceneDelegate` only receives CloudKit share URLs) and **no UI test target** (`Project-EzraTests` is Swift Testing, unit only). Synthetic taps are blocked on this host. Launch-argument seams are the only driver; every one is inside `#if DEBUG` (`ReleaseSeamTests` walks the target; `debug-fences.py` found 0 unfenced on 2026-09-29).

| Seam | Reaches | Notes |
|---|---|---|
| (none) | Ask home — onboarding on a fresh install, else the day answer | a plain launch is also the guard |
| `-SeedFlowFixtures` | deterministic household + tasks, onboarding skipped | the default for every check; needs an empty store |
| `-SeedSampleData` | a real brain dump through the ACTIVE engine | non-deterministic by design (real on-device model on this host) |
| `-ResetAndSeedEvalCorpus` | wipes, then seeds the eval corpus | the only seed that works on a non-empty store |
| `-OpenTasks`, `-TasksPreset overdue\|dueToday\|inProgress\|waiting\|decisions\|done`, `-FilterStatus`, `-FilterCategory`, `-MyTasksTab everyone\|created`, `-OpenSearch ["q"]`, `-CompleteListRow N`, `-DeckPage N` | the Tasks sheet and its states | `features/tasks-sheet.md` |
| `-OpenCapture ["text"]` (+`-NoSubmit`, `-AutoCreate`, `-GroupAs "T"`), `-HoldListening`, `-DriveListeningLevel`, `-HoldUnderstanding` | the Ramble capture arc | `features/capture.md` |
| `-OpenTaskDetail N` (+`-PressPrimary`), `-OpenAdvisorChat` (+`-ChatFixture`, `-AskAdvisor "q"`) | detail pager, pinned CTA, task chat | `features/task-detail.md` |
| `-HomeHour N`, `-PressHomeVerb`, `-AskHousehold "q"`, `-SendAsk "t"`, `-DraftAsk "t"`, `-FocusAsk`, `-HouseholdChatFixture`, `-SeedGroupProposal`, `-AcceptGroupProposal` | the Ask home | `features/ask-home.md` |
| `-OpenSettings`, `-ClearAllTasks`, `-ResetEverything` (+`-DismissAfterClear`), `-OpenActivity`, `-OpenActivityDetail N`, `-OpenRoster` | Settings, destructive paths, Activity, household | `features/settings-activity.md` |
| `-OnboardingIntro`, `-OnboardingResult` | onboarding screens | fresh install only — `features/onboarding.md` |
| `-OnDeviceSegment` | not an eval: the runtime enable for the boundary pass (`OnDeviceSegmenter.isRoutingEnabled`) | dogfooding only |
| `-RambleEval`, `-HouseholdChatEval`, … `-EvalToFile` | the evals | `seams.md`; reports land in the container's `Documents/` |

Seams in source but NOT in `seams.md` (2026-09-29): `-SeedEvalCorpus` (seed the corpus into an EMPTY store), `-CaptureRepeats`, `-QuickRepeats`, `-EvalCaseLimit`, `-ReverseEvalOrder` (eval knobs), and `-InitializeCloudKitSchema` — **never pass that one**: it writes the schema to the real CloudKit development container.

```bash
$S launch $U $B -SeedFlowFixtures -OpenTasks
SIM_LOG=$EV/console.log $S launch $U $B -SeedFlowFixtures      # stream stdout/stderr (print-based diagnostics land here)
```

Arguments containing spaces or apostrophes: pass them as separate, quoted shell words exactly as above. Never build a launch line through `eval` — an apostrophe in an `eval`ed argument silently skips the launch.

## Evidence

- Screenshots: `$S shot $U $EV/<feature>-<state>-<size>.png` at `large` and `accessibility-extra-extra-extra-large` (`$S size $U <category>`). `.claude/rules/surfaces.md` asks every surface pass for `accessibility-extra-large` too; five of six defects on 2026-09-18 lived only there. Relaunch after changing the size — a running app reflows, but a seam fires only at launch.
- Wait before the shot: a seeded home is up in ~4 s; a capture reveal on the real model needs up to 30 s. Screenshot too early and you prove the orb, not the result.
- Motion: `$S record $U $EV/<name>.mov <secs> &` BEFORE the launch that triggers it, then `$S frames $EV/<name>.mov $EV/<name>-sheet.png`. The first ~1.3 s of black is simulator process spawn, not the app.
- Crashes: `T0=$(date +%s)` before the run, `$S crashes Project-Ezra $T0` after. Some faults (a SwiftUI `Index out of range` SIGTRAP) leave **no `.ips`** — pair it with `$S alive $U $B` after the action.
- Logs: `os_log` subsystem `com.projectezra.app` (categories `persistence`, `relationships`, …): `xcrun simctl spawn $U log show --last 5m --predicate 'subsystem == "com.projectezra.app"'`. Most diagnostics are `print`, so use `SIM_LOG` for those.
- Store and files: `C=$(xcrun simctl get_app_container $U $B data)`; eval reports in `$C/Documents/*-report.txt`; capture receipts are sidecar JSON files; the sqlite store is under `$C/Library/Application Support/`. Read a side effect there, not only on screen.
- Debug footer / Settings Diagnostics card (DEBUG only) says which engine actually ran. The simulator runs the REAL on-device model when the host's Apple Intelligence is on; read it, never assume.

Proof standard:
- Drive the real user path; never an internal setter or a test-only shortcut that bypasses what the user touches.
- Capture the action and the resulting state; verify side effects alongside what is visible.
- Run `$S guard $U $B` before any crash or hang measurement and between batches (this runtime breaks on its own with `dyld: Library not loaded: /usr/lib/libSystem.B.dylib`, which reads exactly like an app crash).
- Record motion with `record` started BEFORE the launch that triggers it, then `frames`.
- A result from the wrong surface or an inconclusive run is reported as such, never as a pass.

## Cleanup

```bash
xcrun simctl terminate $U $B; $S size $U large; $S appearance $U dark; $S statusbar $U clear
```
The app is dark-only by design (`preferredColorScheme(.dark)`); `dark` is this simulator's resting appearance. Keep `$EV`. Leave `ezra-verify` booted or shut it down (`xcrun simctl shutdown $U`) — it is yours. Never shut down, erase or install onto a simulator this skill did not create.

## Gotchas
- **Crew agents cannot see this skill until it is pushed.** An isolated agent worktree starts from `origin`'s default branch; give a builder this checkout's path or push first. <!--seen:2026-09-29-->
- **Run the script as `bash $S …` freely:** its self-calls go through `$BASH`; an older copy called `"$0"` and made `guard` report a live app as dead when the file had no exec bit. <!--seen:2026-09-29-->

- **A brand-new simulator lays the system keyboard's "slide to type" tip over the bottom half of any screen with a focused field** (onboarding's name field, `-FocusAsk`). On `$U` only: `xcrun simctl spawn $U defaults write com.apple.Preferences DidShowContinuousPathIntroduction -bool true`, then relaunch. <!--seen:2026-09-29-->
- **A seeded launch changes data; a bare relaunch does not.** Change the text size, then relaunch *bare* (seeds refuse the now non-empty store anyway), and compare the same store at both sizes. <!--seen:2026-09-29-->
- **If `bash $V/scripts/sim.sh` is refused by the session's permissions**, run the `xcrun simctl` line each verb wraps (read the script — each verb is 1–5 lines). Do that for `install`'s binary check too (`cmp "$APP/Project-Ezra" "$(xcrun simctl get_app_container $U $B app)/Project-Ezra"`), don't skip it. <!--seen:2026-09-29-->
- **Name matching picks the wrong device.** This host has several `iPhone 17 Pro`s across iOS 26.x and 27.0, often several booted by other sessions; `simctl launch` by name then hangs or targets a 26.x device the deployment target (27.0) rejects. Always `$U`. <!--seen:2026-09-29-->
- **Shared DerivedData gets overwritten** by another session between your build and your install; `install` catches it by comparing binaries. Use `$DD`, never `~/Library/Developer/Xcode/DerivedData`. <!--seen:2026-09-29-->
- **Seeds refuse a non-empty store** and quietly show whatever is there — uninstall first (on `$U` only). <!--seen:2026-09-29-->
- **`simctl spawn … defaults write $B hasOnboarded …` writes the simulator's SHARED preferences**, not the app container, so it survives uninstall and a "fresh install" skips onboarding. `xcrun simctl spawn $U defaults delete $B hasOnboarded` before judging a first run. Every seed sets `hasOnboarded` in the container itself. <!--seen:2026-09-29-->
- **Onboarding seams act only while onboarding is on screen**: judge `-OnboardingIntro`/`-OnboardingResult` on a fresh install. <!--seen:2026-09-29-->
- **`-OpenAsk` and `-InitialTab` are no-ops** (a bare launch is the home; there is no tab bar), even though `run-sim` still mentions them. <!--seen:2026-09-29-->
- **Destructive seams** (`-ClearAllTasks`, `-ResetEverything`): measure with `guard` in the loop — three "0/6 crashed" batches on 2026-09-19 were the runtime, not the app. <!--seen:2026-09-29-->
- **`-FocusAsk` with the Simulator's hardware keyboard connected shows no keyboard.** Turning it off (`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false` + Simulator restart) is a host-wide change that affects other sessions — only with the owner's say-so. <!--seen:2026-09-29-->
- **Test flakes** (for `xcodebuild test`, `-parallel-testing-enabled NO` required): `CaptureHedgeTests.totalBudgetIsSpentOnce` fails under load (e.g. a simulator driving screenshots beside it); a `TEST FAILED` with every case green and `Restarting after unexpected exit` is the sim. Run tests on `$U` too, never while driving it. <!--seen:2026-09-29-->

## Retired

(none yet)
