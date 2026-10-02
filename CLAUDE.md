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
- Start every local session with `git fetch && git status`. Local sessions commit to `main` and push; cloud sessions use a `claude/<name>` branch and open a PR. Reconcile with `git rebase origin/main`, never a local merge commit. Stage by path: another session may share this checkout.
- Update `docs/cohort0-checklist.md` in the same change that changes a flow.
- When a rule changes, change it in its `.claude/rules/` file and its long form in `docs/decisions.md`.
