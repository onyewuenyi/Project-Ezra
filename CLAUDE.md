# CLAUDE.md

**Project Ezra**: an AI-managed household task app for iOS (SwiftUI + Core Data, one app target). The product spec is the artifact *Ezra Product Shape v8* (https://claude.ai/code/artifact/aa4e89a0-a1ff-4ed2-b0f8-c6e227ed7014); where a file here disagrees, the artifact wins. **Kinly** is launch positioning over v8, not a rename.

Research preview on the newest SDKs: turn a capability on, then measure; never "wait for GA". Never relax **safe defaults for data** or **the guardrails** (`prev-docs/product-guardrails.md`).

## Toolchain
- Xcode 27 / iOS 27 SDK, deployment target iOS 27.0; `xcodebuild -version` must read 27.x (`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`). Apple silicon. The simulator runs the REAL on-device model when the host's Apple Intelligence is on.
- Swift 5 mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- firebase-ios-sdk is pinned to tag `12.19.2` up to next major; read the changelog before 13.x.

## Build and test
```bash
xcodebuild -project Project-Ezra.xcodeproj -scheme Project-Ezra \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' -configuration Debug build
# Tests: -parallel-testing-enabled NO is REQUIRED (fixtures share one in-memory context).
xcodebuild test -project Project-Ezra.xcodeproj -scheme Project-Ezra \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' -parallel-testing-enabled NO
```
- Submission: `scripts/submit.sh` (archive, audit the built bundle, export, validate; `--internal` for TestFlight; bump `CURRENT_PROJECT_VERSION` per upload). Store screenshots: `scripts/screenshots.sh`.
- Known flakes: `CaptureHedgeTests.totalBudgetIsSpentOnce` fails on a loaded machine (rerun with the sim idle); a run of all-green cases ending `TEST FAILED` via `Restarting after unexpected exit` with no `✘`, no `NSInvalidArgumentException`, needs a rerun.

## Traps that apply everywhere
- `Project-Ezra/` is a synchronized root group: add or delete `.swift` files and they compile. Never hand-edit `project.pbxproj` for files.
- swift-format runs on every edited `.swift` (PostToolUse hook, 4-space, 110 col); edits made through python or sed bypass it, so run `xcrun swift-format --in-place` on them.
- `schemaGeneration` is frozen: every Core Data change is a NEW model version, a superset of the last. Never edit the current version in place.
- Every launch-argument read sits inside `#if DEBUG` (`ReleaseSeamTests` walks the target).

## Where things are
- Area rules live in `.claude/rules/` and load when you open a file in that area: task model, sync/persistence, capture, Advisor, surfaces, notifications/telemetry, two-engine AI, device/cloud. Their history and long form: `docs/decisions.md`. Map of the docs: `docs/README.md`.
- Prove UI and behavior changes with `.claude/skills/verify-ezra/` (dedicated simulator, seams, evidence); every seam is in its `seams.md`.
- Owner-only steps: `TODO.md`.

## Workflow
- Start every local session with `git fetch && git status`. **Every change reaches `main` through a pull request, local and cloud alike (2026-10-03):** commit, then `scripts/ai/pr.sh` (commits made on `main` move to a `claude/<topic>` branch, which it pushes and opens as a PR); the owner merges. GitHub's ruleset refuses direct pushes to `main`. Reconcile with `git rebase origin/main`, never a local merge commit. Stage by path: another session may share this checkout.
- Update `docs/cohort0-checklist.md` in the same change that changes a flow.
- When a rule changes, change it in its `.claude/rules/` file and its long form in `docs/decisions.md`.

<!-- ios-ai-kit:begin (managed by ios-ai-kit install.sh; edit .claude/ios.env, not this block) -->
## iOS loop (ios-ai-kit)

- **Project:** Project-Ezra.xcodeproj · scheme `Project-Ezra` · app `amanze-studios.Project-Ezra` · iOS 27.0 · files: synchronized folders (a new .swift file in the target's folder compiles automatically).
- **Build / test / gate** (each checkout gets its own simulator and `.build/dd`, automatically): `scripts/ai/build.sh` · `scripts/ai/test.sh [-only-testing:Target/Suite/test()]` · `/verify` (format, build with no new warnings, tests, launch-argument safety, blast radius, visual matrix). New machine: `scripts/ai/bootstrap.sh`. Anything odd: `scripts/ai/doctor.sh`.
- **Hard rules:** never edit `*.pbxproj` by hand; never delete project files (disable instead); never change build settings unless the task says so; never print secrets; one logical change per build; drive simulators only through `scripts/ai/sim.sh` (by UDID, never `booted`).
- **Every change reaches the default branch through a pull request, never a direct push** (the guard refuses one; GitHub's ruleset from `scripts/ai/protect-main.sh` is the lock): commit, then `scripts/ai/pr.sh` (it moves commits made on the default branch onto a new branch, pushes, and opens the PR with the `/verify` report). Never merge your own PR; the owner merges.
- **Apple's exported skills win** on any API question (`swiftui-specialist`, `swiftui-whats-new-27`, …). The loop, MCP-versus-shell, bug-fix, UI two-pass and parallel rules: the `ios-loop` skill.
- **Cloud sessions have no Xcode:** never run `xcodebuild` or `simctl` there; say "not compiled with Xcode", list every unverified item, push only your own `claude/*` branch and open a PR (the cloud gate approves exactly that and refuses any other push or merge, with a reason; follow it, never retry around it); it merges only after `/verify` passes on a Mac.
<!-- ios-ai-kit:end -->
