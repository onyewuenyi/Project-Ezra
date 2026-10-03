# Task detail, CTA and task chat

## What it is (user's point of view)

A full-screen page per task inside a horizontal pager: the title, property chips (set values first), the page's shape (deciding / waiting / container / action), one pinned primary button (Start → Mark done, Unblock, That's mine, Reopen, or none on someone else's task), a single Advisor line under it that opens the task chat.

## How a user reaches it

Tap a row on the Tasks sheet or on the home.

## Driving it

```bash
$S launch $U $B -SeedFlowFixtures -OpenTaskDetail 0
$S launch $U $B -SeedFlowFixtures -OpenTaskDetail 2 -PressPrimary        # the moment after Start: relabel + "Started just now"
$S launch $U $B -SeedFlowFixtures -OpenTaskDetail 0 -OpenAdvisorChat -ChatFixture   # canned chat thread, no model
$S launch $U $B -SeedFlowFixtures -OpenTaskDetail 0 -OpenAdvisorChat -AskAdvisor "what's the first step?"
```

## Proof it works

- One primary button or none — never a second button under it. A decision page's button reads "I've decided". A task owned by someone else shows no CTA.
- `-PressPrimary` on a `.todo` task: the button relabels in place to "Mark done", a "Started just now" caption, then the kickoff line lands in the Advisor slot. Side effect: Activity has the start.
- Related rows wrap at accessibility sizes; the reading column is ≤700pt on iPad.

## Gotchas

- `N` indexes the visible rows of the Tasks list the shell presents for this seam, so it depends on the seeded order (which depends on today's date).
- `-PressPrimary` fires once per process.
- The Advisor reading may be the deterministic floor (rung 0) or the on-device model; a "Looked just now — nothing to add." line is a first-class answer, not a failure.
