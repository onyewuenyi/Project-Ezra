# Mock Data for Core User Flows

How to reproduce every state needed to exercise the app's core user flows (see the ranked list in
`docs/lean-prd-managing-chaos.md`), **excluding onboarding**. Two independent seed paths exist; know which one
you're using:

| | `-SeedSampleData` | `-SeedFlowFixtures` |
|---|---|---|
| What it does | Runs a sample brain-dump through the **live triage engine** (`AppBrain.triage`) | Constructs `TaskItem`/`ActivityEntry` **directly**, bypassing triage entirely |
| Determinism | Depends on which engine is active (sim → `HeuristicEngine`, device → `FoundationModelsEngine`) | Exact and identical on every run, on sim or device |
| Source | `RootTabView.seedIfRequested()` | `RootTabView.seedFlowFixturesIfRequested()` → `SampleFlowFixtures.seed(into:)` |
| Use it for | Testing the triage engine itself / a realistic first-capture | Reliably reaching a specific state to check a view or demo a flow |

Both are guarded to only fire when the task store is empty, and both set `hasOnboarded = true` / skip the
onboarding cover — **neither seed path exercises onboarding**, per the flow this doc intentionally excludes.

```bash
SIM="iPhone 17 Pro"; BID="amanze-studios.Project-Ezra"
xcrun simctl launch "$SIM" "$BID" -SeedFlowFixtures -InitialTab 0   # 0 Today, 1 Tasks, 2 Inbox, 3 Review
```

To reset and reseed: `xcrun simctl uninstall "$SIM" "$BID"` first (the guard only fires on an empty store).

---

## Flow 1 — Daily Brief

**State needed:** more actionable tasks (workflow `.ready`/`.inProgress`, owned, unblocked) than the 3 the
Today screen surfaces. A suggest-tier item is deliberately *not* one of them any more: since the state-layer
split, only a silent-tier draft is filed straight to Ready — a suggest-tier item enters the **Suggested lane**
(Inbox) awaiting the user's "Make ready", so the confirm-card no longer renders inline on Today. Today shows
only work already accepted into the active flow.

`TodayView` computes `todaysFew` as `isActionable(among:) && isMine` (delegated tasks never enter the brief;
`isActionable` = workflow `.ready` or `.inProgress`, unblocked, and owned), sorted by `TaskItem.focusOrder` —
overdue first, then priority rank, then soonest due (undated last), then confidence — `.prefix(3)`. Everything
else non-done counts toward `heldCount` ("N more held for later"). `tidiedCount` (the "AI handled N items"
number) is `activity.filter { !$0.undone }.count`.

`SampleFlowFixtures` seeds these tasks — four filed straight to Ready, plus one suggest-tier item held in the
Suggested lane (see also Flow 8's overdue water-bill task, which participates in this ordering — the family's
delegated tasks, owned by Maya / Ezra / Nehemiah, are excluded from Today via `isMine`, so they don't):

| Title | Confidence | Tier (derived) | Workflow lane | Due | Priority |
|---|---|---|---|---|---|
| Pick up dry cleaning | 0.9 | silent | ready | +1 day | normal |
| Submit expense report | 0.85 | silent | ready | +2 days | normal |
| Renew car registration | 0.82 | silent | ready | +5 days | normal |
| Buy birthday gift for Sam | **0.7** | **suggest** | **suggested** | +3 days | **high** |
| Water the plants | 0.9 | silent | ready | none | normal |

With Flow 8's overdue+urgent water bill in the set, the top 3 **actionable** items by `focusOrder` are: **Pay
the water bill** (overdue wins), **Pick up dry cleaning** (soonest due), **Submit expense report**. The rest
count toward held. The birthday gift is *not* among them: its confidence (0.7) lands in the **suggest** band,
and since the state-layer split, `AutonomyPolicy.proposedWorkflow` files only the silent tier (confidence ≥ 0.8,
not a judgment call) straight to `.ready` — everything else, birthday gift included, enters `.suggested`. There
it waits in the Suggested lane / Inbox with a **Make ready** ("AI suggestion — Accept") affordance, instead of
surfacing inline on Today. Its high priority still demonstrates `focusOrder`'s rank-beats-due-date rule — but
only once accepted into Ready, when it rejoins the actionable set.

**Reproduce by hand:** construct a `TaskItem` with `workflow: .ready`, `confidence >= 0.8`, and not a judgment
call, for a plain filed card in the brief. A `TaskItem(workflow: .suggested, confidence:` in `0.5..<0.8)` gives
the suggest-tier card — but it now lands in the Suggested lane (Inbox), not the brief. (`autonomy` is no longer
an `init` argument; the tier is derived from confidence + `isJudgmentCall`.)

**Why "AI handled N items" reads what it does:** every silently-filed (silent-tier) item in the fixture set gets a matching
`ActivityEntry("Filed "<title>" under <category>")` inserted alongside it (mirroring what `AppBrain.commit` does
for real triage output) — see `SampleFlowFixtures.logSilentFiling`. Count the `.silent` items across *all* flows
below (not just this one) to predict the footnote number; with the full fixture set that's 7 (4 from this flow +
3 from the dependency chain in Flow 7).

---

## Flow 3 — Needs Decision Resolution

**State needed:** two distinct reasons a `.suggested` item wears a **Needs Decision** assessment. "Needs
Decision" is no longer a workflow state — it's a derived observation (`TaskAssessment.needsDecision`, a
`NeedsDecisionReason?`) that applies only while a task sits in the Suggested lane. `TaskItem.assessment(among:)`
computes it:

```swift
// on a .suggested task only; nil once the user accepts it (Ready/In Progress)
let reason: NeedsDecisionReason? =
    workflow == .suggested
    ? (isJudgmentCall ? .humanJudgment : (confidence < 0.5 ? .lowConfidence : nil))
    : nil
```

Both reasons reach the Suggested lane the same way — via `AutonomyPolicy.proposedWorkflow`, where anything not
silent-tier → `.suggested` — and the assessment then explains *why* each is deferred. The card wears the
gradient "Needs Decision" chip and surfaces the reason via its confidence row:

1. **Judgment call** — `isJudgmentCall: true` enters `.suggested` and reads `.humanJudgment` ("Your call to
   make") **regardless of confidence** (the judgment-category rule). Fixture: *"Figure out if the side project
   is still worth it"*, confidence **0.85**, `isJudgmentCall: true` — high confidence, still asked, on purpose.
2. **Plain low confidence** — `confidence < 0.5`, `isJudgmentCall: false`, reads `.lowConfidence` ("Needs your
   input"). Fixture: *"Deal with the thing from last week"*, confidence **0.3**.

Both show up in `InboxView`, which now shows the **full Suggested queue** — it filters `workflow == .suggested
&& completedAt == nil`, not just needs-decision items (the birthday gift from Flow 1 lands here too, as a plain
Suggested item with no Needs Decision reason).

**⚠️ Important asymmetry if you try to reproduce case 2 by live-typing into the Composer in the simulator:** the
simulator always uses `HeuristicEngine` (Foundation Models isn't available there), and its confidence floor for
*non-judgment* items is **0.6** (`HeuristicEngine.draft(from:)`: judgment → 0.4, Admin/Errands category → 0.6,
strong keyword hit → 0.85, generic → 0.65). There is no code path in the heuristic engine that produces a
non-judgment confidence below 0.5. **A plain low-confidence Needs Decision item cannot be produced by live typing
in the sim** — it only exists via direct seeding (as above) or, on a real device, via `FoundationModelsEngine`
genuinely returning a low confidence score.

**Reproduce by hand:** `TaskItem(title:, workflow: .suggested, confidence: 0.3)` for case 2 (low confidence,
not a judgment call → `.lowConfidence` reason); `TaskItem(title:, workflow: .suggested, confidence: 0.85,
isJudgmentCall: true)` for case 1. There's no `.needsDecision` state or `autonomy:` argument to set — the
assessment is derived from `workflow == .suggested` plus `isJudgmentCall`/`confidence`.

---

## Flow 4 — Triage Inbox (live capture, not seeded)

This flow is exercised **live** — type or paste into the Composer — rather than pre-seeded, since it's the
capture interaction itself. The sim always routes through `HeuristicEngine`, which is deterministic on exact
wording. Known-good phrases to type, with the workflow lane each lands in (`AutonomyPolicy.proposedWorkflow`)
plus any assessment chip it wears (traced from `HeuristicEngine.swift`):

| Type this | Category | Confidence | Tier | Lands in | Assessment chip | Why |
|---|---|---|---|---|---|---|
| `oil change is overdue` | Car | 0.85 | silent | Ready | — | "oil change" is a strong (phrase) keyword hit → silent tier → filed straight to Ready |
| `should I keep paying for the gym I never use` | Health | 0.4 | ask | Suggested | Needs Decision ("Your call to make") | "should i" trips `isJudgmentCall`; judgment calls are never silent, so it enters the Suggested lane |
| `book flights for the trip after passport is done` | Travel | 0.85 | silent | Ready | **Blocked** | "after" trips `isBlocked` and extracts "passport" as a blocker; silent tier still files it to Ready — Blocked is a derived assessment now, not a lane, so it sits in Ready wearing a Blocked chip |
| `deal with something` | Admin | 0.6 | **suggest** | Suggested | — (plain proposal, **Make ready**) | no category keyword hit → Admin/Errands 0.6 branch → suggest tier (not silent) → Suggested lane; confidence ≥ 0.5 and not a judgment call, so no Needs Decision reason — it just awaits acceptance |

The last row is the live-typing equivalent of Flow 1's suggest-tier card — useful if you want to demo the
Make ready / Accept confirmation in the Suggested lane without relying on seeded data.

**Reproduce by hand:** no model construction needed — type the phrase into the Composer (Inbox tab) and read the
resulting card.

---

## Flow 5 — Weekly Retro

**State needed:** items where `isStale()` is true — not `.done`, and `createdAt` more than 7 days in the past
(`TaskItem.isStale(now:threshold:)`, default threshold `7 * 24 * 3600`). Neither the workflow lane nor any
assessment (Blocked, Needs Decision) matters for staleness, only age and not-done — the fixture deliberately
mixes lanes and assessments to prove that:

| Title | Workflow lane / assessment | createdAt offset | Notes |
|---|---|---|---|
| Reorganize the garage | Ready (suggest-tier confidence 0.65) | −60 days | ancient/long-buried rot, not just fresh-past-threshold |
| Donate old clothes | Ready | −30 days | |
| Cancel unused streaming subscription | Suggested — Needs Decision (judgment call) | −21 days | |
| Get a quote from the contractor | Ready, wearing a **Blocked** chip (an *external* blocker — waits on the contractor calling back, which isn't a tracked task) | −18 days | permanently stuck — nothing auto-resurfaces an external blocker, so Review is the only way back to actionable/Killed |
| Fix the leaky faucet | Ready | −15 days | |
| Follow up with old client | Suggested — Needs Decision (low confidence, 0.35) | −10 days | |
| Schedule the dentist | Ready | −8 days | boundary case, just past the 7-day threshold |

`ReviewView` filters `isStale() && completedAt == nil` and sorts oldest-first (`createdAt` ascending), so all 7
show, garage first and dentist last. Two of these (subscription, client) also appear in Inbox simultaneously,
since being a `.suggested` proposal and being stale are independent conditions that can both be true of the same
item — this is expected, not a bug. None of the 7 log an `ActivityEntry`: the "AI handled 7 items" footnote on Today is scoped
to Flow 1 + Flow 7 only (see `SampleFlowFixtures.logSilentFiling` call sites) and stays exact no matter how much
Review data exists.

**Reproduce by hand:** set `createdAt: Date().addingTimeInterval(-N * 24 * 3600)` with `N > 7` on any non-done
`TaskItem`. For a permanently-stuck blocked item, add an **external blocker** —
`task.addExternalBlocker("the contractor to call back", among: [task])` — which leaves the workflow lane
untouched but makes the task *read* as Blocked, and never auto-resurfaces (the auto-machinery only clears
`.task` blockers whose target resolves). There is no `.blocked` you can set directly: Blocked is a derived
assessment off the `blockers` list (see below).

---

## Flow 6 — Learn (V1)

**Not implemented.** There is no adaptive/learning code in this codebase yet (no logic anywhere observes
completions/ignores/postponements/rejections to adjust future confidence or routing). Nothing to seed — this
flow has no state to reproduce until it's built.

---

## Flow 7 — Dependency Chain Resurfacing (real references)

**State needed:** blocked tasks whose `blockedBy: [UUID]` references another task's `uuid`, so completing the
blocker auto-unblocks the dependents that have no remaining active blockers (`TaskMutations.resurfaceDependents`,
triggered from `completeAndResurface`/`killAndResurface`). "Blocked" is derived from the *active* (not-done)
blockers; a done blocker stays referenced so a reopen re-blocks (`reopenAndReblock`).

A 3-link chain plus a two-blocker task. Every task's workflow lane is `.ready` — Blocked is a derived
assessment off the `blockedBy` references, never a lane, so a blocked task sits in Ready wearing a Blocked chip:

1. **Renew passport** — Ready, confidence 0.9, silent tier
2. **Book flights for the trip** — Ready, wearing a Blocked chip, `blockedBy: [passport.uuid]`
3. **Request time off work** — Ready, Blocked, `blockedBy: [flights.uuid]`
4. **Apply for travel visa** — Ready, Blocked, `blockedBy: [passport.uuid, flights.uuid]` (waits on **both**)

Plus a second, fully independent 2-task chain, in different categories/vocabulary on purpose:

5. **Schedule the movers** — Ready, confidence 0.85, silent tier
6. **Change our mailing address** — Ready, Blocked, `blockedBy: [movers.uuid]`

**In `TasksView`** (the Tasks tab — renamed from Runs, no longer grouped by category), `TaskChainGrouping.computeChains`
partitions the active set into connected components via the real `blockedBy` graph: tasks 1–4 form one 4-member
stack (rendered by `TaskChainStackView`, collapsed to the front card "Renew passport" + a "4" badge + 2 decorative
peek slivers), and tasks 5–6 form a **separate** 2-member stack — proving two independent chains render as two
distinct stacks, not one merged blob. Expanding a stack reveals every member as its own full, independently
tappable/completable `TaskCardView`, connected by a thin rail. Completing #1 unblocks #2 (and logs a resurfacing
`ActivityEntry` + undo notice); the visa (#4) **stays blocked** because flights is still open. Completing #2 then
unblocks both #3 and #4 — the 4-member stack now visibly shrinks. Reopen #1 from its detail sheet → #2 (and
transitively the rest) re-blocks. Neither chain's tasks call `logSilentFiling`, so Today's "AI handled 7" count is
unchanged regardless of how many chains exist.

**Reproduce by hand:** create task A, then `TaskItem(workflow: .ready, blockedBy: [A.uuid].compactMap { $0 })`
— the task sits in its Ready lane wearing a Blocked chip; there's no `.blocked` state to set. In-app, use a
task's detail sheet "Waiting on" → the picker lists only not-done tasks and excludes anything that would form a
cycle.

---

## Flow 8 — Metadata (owner / priority / effort) + the family roster

**State needed:** one urgent+overdue task (tops the daily brief and wears both the "1d overdue" and quiet
"Urgent" markers plus an "~15m" effort), and a real household — a `UserProfile` ("Charles Onyewuenyi"), a
`Household` ("The Onyewuenyis"), and three `FamilyMember`s (Maya, the partner; Ezra and Nehemiah, the children) —
each owning a delegated task, so the Tasks screen's owner filter has several real people to switch between.

| Title | State | Priority | Owner | Effort | Due |
|---|---|---|---|---|---|
| Pay the water bill | ready, 0.9 silent | **urgent** | — (mine) | 15m | **−1 day (overdue)** |
| Book venue for the offsite | ready, 0.85 silent | normal | **Maya** (`FamilyMember`) | 30m | none |
| Confirm caterer for the reunion | ready, 0.85 silent | normal | **Ezra** (`FamilyMember`) | 30m | none |
| Pack the soccer kit | ready, 0.85 silent | normal | **Nehemiah** (`FamilyMember`) | 10m | none |

None of these log a trail entry, so the "AI handled 7" count above stays exact. The water bill demonstrates
`focusOrder`'s overdue-first rule; the family's tasks demonstrate the 1→N owner seam: `ownerID != nil`
removes a task from `todaysFew` (not the user's to act on) while it stays visible in Tasks with a quiet person
chip, and the owner filter row (`TaskOwnerFilterRow`, backed by a live `@Query private var familyMembers:
[FamilyMember]`) offers "Everyone / Me / Maya / Ezra / Nehemiah" — selecting a person shows only their tasks.
Priority/effort are editable in the task detail sheet; the Owner row there is a real picker (`Menu` over
`familyMembers` plus "Add person…", not a text field) mirroring the "Waiting on" dependency picker's exact
pattern. Triage still infers an owner from wording as a plain name guess ("ask Maya to…" →
`HeuristicEngine.ownerName(from:)` / `FoundationModelsEngine`'s structured output), but that guess is resolved to
a real `FamilyMember` (matched case-insensitively, or auto-created if new) at the same `AppBrain.commit` seam that
resolves blocker phrases — see `AppBrain.resolveOwners`.

**Photo vs. initials (`OwnerAvatarBadge`):** every seeded member (and the user profile, and the household itself)
gets a synthesized `photoData` via `SampleFlowFixtures.samplePhotoData(for:)` — a deterministic two-tone gradient
behind a white silhouette, hue keyed to the name so each person is visibly distinct and stable across runs, and
deliberately generated rather than a bundled asset (mock data, not app content). So the fixtures exercise the real
photo path — `UIImage(data:)` → `.resizable().scaledToFill()` — for every avatar (owner filter row, card metadata
row, task detail's Owner picker). The initials-tile fallback is exercised instead by triage-created
`FamilyMember`s: `AppBrain.resolveOwners` never sets `photoData`, so a person auto-created from wording ("ask
Priya to…") falls back to her "P" tile until a real photo-capture UI exists (`TaskDetailView`'s "Add person…" is
a plain text-only `alert`, no `PhotosPicker` yet).

**Reproduce by hand:** `FamilyMember(name: "X", photoData: someData)` where `someData` decodes via `UIImage(data:)`
(any real PNG/JPEG bytes work; the fixture's `samplePhotoData(for:)` helper shows the minimal synthesized case).
Omit `photoData` to see the initials fallback.

**Reproduce by hand:** `TaskItem(title: "X", workflow: .ready, dueDate: yesterday, priority: .urgent,
effortMinutes: 15)` for the water bill shape. For a delegated task: create the person first —
`let person = FamilyMember(name: "Maya"); context.insert(person)` — then `TaskItem(title: "Y", workflow: .ready,
ownerID: person.uuid)`.

---

## Flow 9 — Workflow lanes + assessments (Up for Grabs / In Progress)

**State needed:** the Tasks board is a Kanban-lite over `WorkflowState.boardColumns` — exactly **three lanes**:
Suggested / Ready / In Progress (`.done` has no column, resolved work leaves the board). Blocked and Up for
Grabs are no longer lanes; they're derived assessments a card wears *inside* whichever lane it occupies. Two
fixtures exercise the newer surfaces:

| Title | Workflow lane / assessment | Notes |
|---|---|---|
| Plan the weekend trip | Ready lane, `ownerPending: true` → wears an **Up for Grabs** chip | Household already has other members (Flow 8) seeded, so this is a genuine "who does this belong to?" gap |
| Draft the Q3 report outline | **In Progress** lane | Seeded pre-started — In Progress is manual-only in the real app (never AI-inferred), so this simulates having already tapped "Start" |

Neither logs a trail entry, so "AI handled 7" (Flow 1's count) stays exact.

**Up for Grabs** is reached in the real app via `AppBrain.applyOwnershipGate`: a silent-tier draft that lands
`.ready`, with no delegation phrase detected (`ownerName == nil`), in a household that has other `FamilyMember`s
(`hasHousehold: true`, passed from `ComposerView`/`RootTabView` based on whether the roster is non-empty), gets
`ownerPending = true` set on it — the workflow lane stays `.ready`, and the task simply wears an Up for Grabs
chip. **Solo installs (empty roster) are a complete no-op** — no task ever gets flagged, exactly as before this
feature existed. From the card's detail sheet, the primary button reads "That's mine" and calls
`task.claim(ownerID: nil, among:)`, which clears `ownerPending` (the chip drops; the lane never moved). Picking
a specific person from the Owner menu calls the same `claim(ownerID:among:)`.

**In Progress** is reached only by tapping "Start" (a secondary link in the task detail sheet, shown only when
`workflow == .ready`) → `task.startProgress()`. There is no AI path to this lane and no path from Suggested or
an unowned/blocked task directly — a task must be Ready (accepted, owned, unblocked) first. "Back to Ready"
(shown only when `workflow == .inProgress`) calls `task.stopProgress()`. **Blocked no longer disturbs this:**
because Blocked is a derived assessment rather than a lane, an In Progress task that gains a new dependency
blocker *stays In Progress* (workflow unchanged) and simply wears a Blocked chip; clearing the blocker leaves it
In Progress — the user never has to re-tap Start. (This fixes the bounce-to-Ready gap this doc previously
described.)

**Reproduce by hand:** `TaskItem(title: "X", workflow: .ready, confidence: 0.8, ownerPending: true)` for Up
for Grabs (only reads as a genuine gap if `familyMembers` is non-empty in your test data — the flag itself
doesn't enforce that, only `applyOwnershipGate` does). `TaskItem(title: "Y", workflow: .inProgress, confidence:
0.85)` for In Progress — or start from `.ready` and call `task.startProgress()` to exercise the real transition.

---

## Where the code lives

- Fixture data: `Project-Ezra/AI/SampleFlowFixtures.swift`
- Launch-arg wiring: `Project-Ezra/Features/Root/RootTabView.swift` (`seedFlowFixturesIfRequested()`)
- Autonomy/workflow derivation being reproduced: `Project-Ezra/AI/AIEngine.swift` (`AutonomyPolicy.tier` and
  `AutonomyPolicy.proposedWorkflow` — the old `AutonomyPolicy.state` is gone)
- Model definitions: `Project-Ezra/Models/TaskItem.swift` (`TaskItem`, `WorkflowState`, the derived
  `TaskAssessment`/`NeedsDecisionReason`, `AutonomyTier`, `ActivityEntry`),
  `Project-Ezra/Models/FamilyMember.swift` (the roster), `Project-Ezra/Models/TaskChainGrouping.swift`
  (dependency-chain grouping for the Tasks screen)
- Dependency graph mutations + workflow/assessment mutations: `Project-Ezra/Models/TaskMutations.swift`
  (`blockedBy`, `addTaskBlocker`/`addExternalBlocker`, `resurfaceDependents`, `reopenAndReblock`, `reopen`,
  `makeReady`, `claim`, `startProgress`/`stopProgress`, `recommendedAction`)
- Ownership gate (Up for Grabs): `Project-Ezra/AI/AppBrain.swift` (`applyOwnershipGate`, `triage(_:hasHousehold:)`)
- The Tasks screen: `Project-Ezra/Features/Tasks/` (`TasksView.swift`, `TaskOwnerFilterRow.swift`,
  `TaskStateSwitcher.swift`, `TaskChainStackView.swift`) — renamed from `Features/Runs/`
- Live-capture rules for Flow 4: `Project-Ezra/AI/HeuristicEngine.swift`

To add a new scenario, add it inside `SampleFlowFixtures.seed(into:)` following the existing per-flow `// MARK:`
sections, and update the table above so this doc stays the source of truth for reproducing it later.
