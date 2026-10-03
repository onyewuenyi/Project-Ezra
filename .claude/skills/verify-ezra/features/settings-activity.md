# Settings, Activity, household and the destructive paths

## What it is (user's point of view)

Activity: the trail of every change, AI and human, each with Undo. Settings: profile row, digest, "What leaves this device", data export, and the two destructive buttons (Clear all tasks, Reset everything). Manage household: members and the invite link.

## How a user reaches it

Header "…" menu on the home (Activity, Settings, Manage household).

## Driving it

```bash
$S launch $U $B -SeedFlowFixtures -OpenActivity
$S launch $U $B -SeedFlowFixtures -OpenActivity -OpenActivityDetail 0
$S launch $U $B -SeedFlowFixtures -OpenSettings
$S launch $U $B -SeedFlowFixtures -OpenRoster
# Destructive — guard before and after, check for a crash report and the store:
$S guard $U $B; T0=$(date +%s)
$S launch $U $B -SeedFlowFixtures -ClearAllTasks -DismissAfterClear; sleep 6
$S alive $U $B && $S crashes Project-Ezra $T0; $S guard $U $B
```

## Proof it works

- Clear all tasks: the app is still alive, no new `.ips`, the rebuilt home shows the empty state ("Tell me everything on your mind." + one CTA), and Settings leads with a reset receipt. Side effect: a safety copy exists under the container (`PersistenceStack.destroyStore` keeps the last 5).
- Activity's AI tile is neutral with an accent glyph (not the gradient); the detail offers the same Undo as the row.
- Settings' Diagnostics card is DEBUG-only; its engine line says which engine ran.

## Gotchas

- The confirmation dialogs cannot be tapped here; the seams perform the confirmed action.
- A destructive measurement without `guard` around it is not evidence: the runtime's dyld breakage reads as an app crash.
- Settings shows the host user's real name on the profile row — do not put its screenshot in anything public.
