# Ask home (the day answer)

## What it is (user's point of view)

The app's root screen: "Ezra" with today's date, a composed answer to *what deserves me today* — one hero task with its reason and one verb, then up to three quiet rows under "Then, in order", "and N more in Tasks", a muted news line — and the ask bar with the capture orb and suggestions at the bottom.

## How a user reaches it

Launch the app (after onboarding). Tasks is a sheet behind the header's "Tasks" button; closing anything returns here.

## Driving it

```bash
xcrun simctl uninstall $U $B; $S install $U "$APP"          # empty store so the seed runs
$S launch $U $B -SeedFlowFixtures                             # seeded home
$S launch $U $B -SeedFlowFixtures -HomeHour 20                # evening voice: "still deserve you" / recap
$S record $U $EV/home-verb.mov 8 & $S launch $U $B -SeedFlowFixtures -PressHomeVerb   # the hero's verb, 1.5 s after seating
$S launch $U $B -SeedFlowFixtures -AskHousehold "What's overdue?"   # a floor question, answers with rows and no model
$S launch $U $B -SeedFlowFixtures -SendAsk "call the dentist tomorrow"   # to-do typed as a question -> capture offer
$S launch $U $B -SeedFlowFixtures -SeedGroupProposal          # the grouping row below the answer
```
Empty home: uninstall, then launch with no seed and finish onboarding… which needs taps — instead use `-ClearAllTasks -DismissAfterClear` on a seeded store (see `settings-activity.md`).

## Proof it works

- Seeded, `large`: navigation title "Ezra" (inline, not large) with the date as subtitle; a hero card with a title, a reason line and one blue verb capsule; up to three containerless rows under "Then, in order" with reasons and NO verbs; "and N more in Tasks" muted with a chevron; the bar with the orb and a suggestion line with an arrow. Every row has a reason — a row without one is a finding.
- `accessibility-extra-extra-extra-large`: the hero title wraps (never truncates mid-word); the hero's verb is glyph-only; one suggestion under the field; the bar is at the bottom, not floating.
- `-PressHomeVerb` frame sheet: glyph fills → row dims → hold → the next task rises into the hero slot, the count rolls down by one, an Undo pill appears above the bar. `$S alive` after.
- Store side effect for the verb: the task's status changed (Activity lists the act with Undo — `-OpenActivity`).

Last proved 2026-09-29 (iPhone 17 Pro, iOS 27.0 24A434): at `large` every point above held ("4 things deserve you first.", hero "Pay the water bill · 1 day overdue · Mark done", three reasoned rows, "and 19 more in Tasks", Maya's catch-up line, two suggestions). At AX5 the hero wrapped, the verb went glyph-only and one suggestion showed; the three quiet rows sat below the fold under the bar. **Open finding:** at AX5 the hero's status glyph overlaps the first letter of the title's second line ("water bill").

## Gotchas

- A home reading "Nothing is asking for you today. <names> have N open…" on a seeded store is the identity trap in SKILL.md (a plain launch before the seed), not the feature.
- The fixtures' dates are relative to *now*, so the hero and counts change day to day and hour to hour; compare structure, not titles, across days. `-HomeHour` is the only way to move the clock.
- The seeded home can show "Since you last looked…" on a fresh install (other members' acts); that is the news line, not a bug.
- `-PressHomeVerb` fires once; relaunching without uninstalling keeps the completion (the seed will not re-run).
