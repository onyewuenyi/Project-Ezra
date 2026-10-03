# Tasks sheet

## What it is (user's point of view)

The whole list, as a sheet over the home: "My Tasks"/"Our Tasks", ownership scopes (Mine · Everyone · Created, once someone else is on the roster), a filter capsule, cross-cutting counts (overdue, waiting, decisions), sections by status, a capture orb bottom-trailing. Tap opens detail; leading swipe performs the row's recommended action; trailing swipe cancels; long-press is a menu.

## How a user reaches it

The "Tasks" button in the home's header, or "and N more in Tasks".

## Driving it

```bash
$S launch $U $B -SeedFlowFixtures -OpenTasks
$S launch $U $B -SeedFlowFixtures -TasksPreset overdue            # as a count tap: Everyone scope, filter named in the capsule
$S launch $U $B -SeedFlowFixtures -OpenTasks -MyTasksTab everyone
$S launch $U $B -SeedFlowFixtures -OpenTasks -FilterStatus doing
$S launch $U $B -SeedFlowFixtures -OpenSearch "passport"
$S record $U $EV/complete.mov 8 & $S launch $U $B -SeedFlowFixtures -OpenTasks -CompleteListRow 0
$S launch $U $B -SeedFlowFixtures -OpenTasks -DismissTasksAfter 3   # the return to the home
$S launch $U $B -SeedFlowFixtures -OpenTasks -DeckPage 1           # a chain deck on its 2nd card
```

## Proof it works

- Rows have the reserved leading marker column, one title line at reading sizes and two at accessibility sizes, a trailing due label on live rows only, no dividers. Resolved sections cap at 5 with "Show all N".
- `-CompleteListRow`: the row completes, the list reflows, the Undo pill sits ABOVE the orb and reads "Undo" in full.
- `-DismissTasksAfter`: the sheet closes onto the home and `$S alive $U $B` is still true (Back from a pushed list once faulted).

## Gotchas

- The swipe gestures themselves have no driver; the seams reach their end states.
- `-FilterStatus` takes the raw status value (`todo`, `doing`, `done`, `canceled`).
