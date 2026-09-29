# Feature map

One file per user-facing feature. Each says how a user reaches it, which seams drive it, and what end state proves it. The full seam table lives in the repo's `CLAUDE.md` (**Verification launch arguments**); the rules each surface must satisfy live in `CLAUDE.md` › *Rules — surfaces* and `docs/surfaces.md`. The flow ground truth is `docs/cohort0-checklist.md`.

| Feature | File | Primary seam | Last proved |
|---|---|---|---|
| Ask home (the day answer) | [ask-home.md](ask-home.md) | `-SeedFlowFixtures` | 2026-09-29 (large + AX5) |
| Capture (Ramble) | [capture.md](capture.md) | `-OpenCapture "text"` | not yet |
| Tasks sheet | [tasks-sheet.md](tasks-sheet.md) | `-OpenTasks` | not yet |
| Task detail, CTA and task chat | [task-detail.md](task-detail.md) | `-OpenTaskDetail N` | not yet |
| Settings, Activity, household, destructive paths | [settings-activity.md](settings-activity.md) | `-OpenSettings` | not yet |
| Onboarding | [onboarding.md](onboarding.md) | fresh install | not yet |

Features with no driver at all: real taps/swipes/typing (no UI test target, synthetic taps blocked), the live microphone (the simulator has no speech transcriber — the composer degrades to the typed canvas), CloudKit sharing between two accounts (two-phone sitting, `TODO.md`), the Sunday digest notification's delivery.
