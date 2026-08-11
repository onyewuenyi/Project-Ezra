# The task model

**Status:** shipped (schema generation 10). This is the reference; `CLAUDE.md`, `docs/PRD.md`, and `docs/task-primitive-v2-spec.md` point here rather than restating it.

The governing principle: **lifecycle position, work type, attention condition, and human signal are four different questions.** Each axis is stored and read independently; behavior is computed from their combination, never from a fused field. Conflating them is what makes task models rot.

---

## The four axes

| Axis | Answers | Cardinality | Owner | Storage |
|---|---|---|---|---|
| **1 · Lifecycle** — `TaskStatus` | Where in the pipeline? | single | **human** | stored |
| **2 · Type** — `WorkIntent` | What kind of work is this? | single | **AI**, human-correctable | stored, refreshable |
| **3 · Attention flags** | Why does this need my eyes? | **multi** | system | `needsDecision` stored; `blocked`/`overdue` derived |
| **4 · Signals** | What did the human declare? | single | **human** | `isUrgent` stored |

Axis 4 exists because Urgent kept being filed informally under "flags." It is a human input feeding the attention score, not a derived condition — naming it separately stops the flag axis becoming a junk drawer.

**Type drives what the detail renders. Lifecycle gates which verbs exist. Flags and signals drive attention ranking.**

---

## Axis 1 — Lifecycle

```swift
enum TaskStatus: String { case todo, doing, done, canceled }
```

**A `TaskItem` comes into existence at Confirm and never before.** `AppBrain.commit` *is* the confirm: it turns parked drafts into tasks born `.todo` with `confirmedAt` stamped. There is no `confirm()` mutation, and no pre-task task.

The retired `.inbox` case was a ghost. Every production creation path confirmed in the same breath (`ComposerView.swift:287`, `OnboardingView.swift:327`), so nothing ever rested there — the only non-confirming path was a `-SeedSampleData` verification seam. Keeping it would have meant two representations of "not yet committed", since Phase 0 gives parked captures real storage.

`todo`/`doing` stays split rather than collapsing into one "active": it is what makes `stateTimeline` real cycle-time data ("In progress for 4h") instead of an undifferentiated dwell, and the In-Progress design token already ships. `done`/`canceled` stay split so the resolution-honesty signal survives — Recap counts completions, `Metrics.rotRate` counts kills.

`status.isLive` replaces the old `== .active` checks (~40 sites). Nothing stores it and nothing writes through it, so it is a read-through of the one axis, not a second one.

### What `.doing` means

> **`.doing` represents an explicit, *revocable* user commitment to actively execute this task.** It is not a progress percentage, nor merely a UI state. It is a **fast, live** attention signal that informs prioritization, Today planning, and collaboration — and *because* it is fast, it lives in the live relevance layer and **never** in the persisted attention score.

That last clause is the load-bearing one. `AttentionEngine`'s score reads slow inputs only (urgent, AI importance, effort shape, graph centrality), which is what makes "the AI never decides the band" true *by construction* rather than by discipline. `.doing` changes several times a day. It therefore enters ranking through `TaskRanking.startedBoost` (12.0, inside `currentRelevance`) and nowhere else.

Three consequences, all deliberate:

- **The boost expires** with `recentWindow` (48h), gated on the **current open visit** (`TaskItem.currentStateEnteredAt`) rather than `secondsIn(.doing)` — a task started, dropped, and resumed has a large *total* dwell but a fresh commitment, and those are different questions.
- **12.0, not 25.0.** `relevanceClamp` is a shared budget across every term in the layer; a boost the size of the clamp would saturate it alone and collapse a five-signal layer into a boolean.
- **No archive immunity.** `BrainSweeps` treats long-abandoned in-flight work like any other stale task. A boost *plus* immunity would produce a task that can never leave the system, and `.doing` would become where tasks hide from cleanup.

### The primary CTA — one slot, or none

`recommendedAction(among:in:)` returns the single next move, or **nil**. Read as a tree, not a ladder:

| Condition | CTA | Writes |
|---|---|---|
| resolved | Reopen | `reopenAndReblock` |
| `ownerID == nil` | That's mine | `claimAndLog` |
| owned by someone else | **— none —** | |
| has active blockers | Unblock | `unblock` |
| `.todo` | Start | `setStatus(.doing)` |
| `.doing` | Mark done | `completeAndResurface` |

The nil arm is the design, not an omission: someone else's task is not yours to advance — a button there is wrong by construction, and completing it would stamp *you* as the actor attesting their work. Its proxy moves ("Mark done for ‹name›", "Take it back") live in `TaskMoreMenu`, and the empty slot is reserved for **Nudge/Comment** once `HouseholdSync.isLive` flips.

**Claim precedes unblock** — you take the thing before you clear its path.

**The verb never voices the type.** The intent-voiced verbs are all retired: `.planning`'s "Break it down" was removed for lying (every arm runs `setStatus(.doing)`), and `.decision`'s "Decide" retired with the Decision type itself (2026-08-08). `.start` carries no associated value; the answer to "give each type its own lifecycle" is still one lifecycle — now with one honest verb.

**Start does not dismiss the detail.** The button relabels to "Mark done" in place, which is how the lifecycle teaches itself — no explanation, no new pixels. Only `.resolve` sets `dismissesDetail`.

### Verbs by state

| Verb | Todo | Doing | Done | Canceled |
|---|:--:|:--:|:--:|:--:|
| Start → Doing | ✓ | — | — | — |
| Stop → Todo | — | ✓ | — | — |
| Complete → Done | ✓ | ✓ | — | — |
| Kill → Canceled | ✓ | ✓ | — | — |
| Reopen | — | — | ✓ | ✓ |
| Defer | ✓ | ✓ | — | — |
| Resolve blocker | ✓ ¹ | ✓ ¹ | — | — |
| Edit fields | ✓ | ✓ | ✓ | ✓ |
| Reassign | ✓ | ✓ | ✓ ² | ✓ ² |
| Split into subtasks | **✗** | **✗** | — | — |

¹ only when blocked · ² attribution only; no assignment side effect fires on a resolved task
**✗ = specified, not built** (B1 in `docs/product-design-plan.md`)

`setStatus(_:in:)` is the single write seam — the row glyph menu and the detail picker both call it. A `todo ↔ doing` move logs a coalescing `"edited"` entry that stays OUT of the Inbox feed; Done/Canceled route through the resolution seams.

**Reopen's floor is `.todo`.** It restores the live status it left via the timeline, but the timeline stores raw strings and can outlive an enum change, so no value can route a task below the state every task is born into.

**Pre-Confirm has no verbs** because there is no task. A parked capture supports exactly two operations: edit a draft field, and Discard. Discarding a draft is not a task kill.

---

## Axis 2 — Type

```swift
enum WorkIntent: String { case action, planning }
```

**The whole axis went INTERNAL on 2026-08-11** — a change of ownership, not a hiding: users
maintain facts; the system maintains interpretations. No kind chip exists anywhere (confirm,
detail, Today); the write chain is exactly engine-classification / lexical backfill →
`reclassify`, with the no-user-write invariant DEBUG-asserted in `markEdited`. The field's
consumers are the Today advisor (`promptOnlyFacts`: "planning work") and the breakdown bias —
and because no human correction exists, the classifier is **evaluated**: `RambleEvalTests`
scores a labeled kind field with a regression floor. An AI-owned field earns trust through
evaluation, not invisibility.

**`decision` is cut too** (2026-08-08). Choosing is not a kind of work the user should classify — it is a capability the system brings. Choice-shaped wording is noticed at read time by `DecisionShape` (the one decision lexicon, hoisted from the resolver), which — together with the `needsDecision` flag — is what summons the Thinking Partner. Stored `"decision"` values decode as `.planning` (`WorkIntent.decode`), additively, with no store wipe; nothing writes the raw value again.

**`waiting` is cut.** It and the derived `blocked` flag were the same predicate on two axes — a task blocked on a person is both. External waits already store as an edge with a note and no target, so `blocked` covers it, and cutting it removes the type boundary a classifier would most reliably fumble.

**Type is single-value.** "Prepare for Japan" is `planning`; "should we even go" is a child task, or the parent carries `needsDecision` on Axis 3. A second type slot would be redundant with a flag that already exists.

**Type stops recomputing once a task resolves** — reclassifying something finished changes which module renders on it for no benefit, and burns a model call.

### Capabilities — what help does this task need?

A capability is **not** "the module for this work type". Each exists to reduce a specific kind of cognitive load, and the type only *biases* which one is offered:

| Friction | Capability | Trigger | You leave with |
|---|---|---|---|
| **Complexity** | Break this down | `BreakdownEligibility` — size and shape | *"I have smaller executable work."* |
| **Uncertainty** | Thinking Partner | the `needsDecision` flag **or** choice-shaped wording (`DecisionShape`) | *"I have clarity."* |
| **Inertia** | Unstick | `StallDetector` — deferred or gone quiet | *"I'm moving again."* |

That framing decides a real question. Because the breakdown reduces **complexity**, complexity triggers it — not `workIntent == .planning`, which would offer it to a 15-minute "plan birthday dinner" and withhold it from a genuinely multi-step "renew passport". `BreakdownEligibility` is an ordered ladder: large effort → compound title → planning intent *above a lower bar*. Intent alone is never sufficient.

**Unstick is the router, not a fourth module.** It diagnoses *why* a task stalled and hands off: blocked → resolve the blocker; too big → Break this down; reads as a choice → escalate it to a decision (`escalateToDecision()`, the axis-3 flag — a human act) — **but only where the Thinking Partner isn't already drawn**: the same lexicon fires both, so when the partner card is visible the rung folds through to the next diagnosis (one intervention per problem; the render layer passes `suppressChoiceRung`, keeping the trigger pure). The partner card itself carries the escalation for wording-only tasks ("Pin to top as a decision"); otherwise → do it · defer it · let it go. A big task that is *also* stalled gets **one** card — Unstick subsumes the breakdown and routes into it, because a bare "break this down" sitting above a "this keeps sliding" that says "break it into steps" is the same advice twice.

**Every card must be dismissable by its own actions.** `deferralCount` is the avoidance signal, and the rollover only ever *raises* it — so `touchHuman` clears it, making the count **consecutive rather than lifetime**. Without that reset, one task crossing the threshold would show "This keeps sliding" for the rest of its live life, surviving the very tap meant to dismiss it (every action Unstick offers routes through `touchHuman`). It also stops the `currentRelevance` pull-down from penalising a task the user has since picked back up. `carriedOverCount` — worked-but-unfinished — is deliberately **not** reset; the two answer different questions.

**Nothing is offered on a resolved task.** The breakdown and stall triggers guard this themselves, but the Thinking Partner arm cannot: a resolved task keeps its title and may keep its flag until resolution cleared it, so wording alone would still read as a choice. `TaskCapabilities.available` returns `[]` up front for a resolved task — otherwise a completed "Should we move to Lisbon?" would still offer to frame the choice, and spend a model call doing it.

**Deterministic where it matters.** Every *trigger* is a pure function, so eligibility is answerable in the simulator and for every user with Apple Intelligence off. Only the *content* needs the model — which is why the Thinking Partner and the breakdown are absent off-device, while **Unstick renders identically** (its diagnosis is deterministic too; the model may only phrase it).

**Absence is decided before rendering; failure after trying.** That absence is a *render-layer* decision (`AppBrain.onDeviceModelAvailable()` in `TaskDetailView`), never a capability trigger — the triggers must stay pure. The breakdown card is entirely model output, so off-device it is omitted whole; the decision section keeps its reason line and **Mark decided** (human affordances, and `resolveDecision()` is the only thing that clears the flag) and gates only the framing. This was previously wrong in both places: the header rendered, the button vanished on tap, and the user was left with an empty titled card.

**Every model call is bounded and cancellable** (`ModelDeadline` · `ModelResult` · `ModelRun`). A card's call gets 20s and a background re-classification 10s; whichever loses is cancelled. Swiping to a neighbouring task cancels in flight — keyed on `isActive`, **not** `.onDisappear`, because the pager keeps neighbours mounted. Because absence is settled up front, a failure reaching a card can only mean a real attempt that failed, so it offers *"That didn't finish · Try again"* rather than collapsing. `ModelResult` keeps `LanguageModelSession.GenerationError` out of SwiftUI entirely, and `ModelMetrics` records per-capability latency and outcomes into the DEBUG footer — local only, never transmitted — so the deadline is tuned on evidence.

**The Thinking Partner recommends — a deliberate reversal (2026-08-08) of "the AI frames, never recommends."** `DecisionFraming` returns options, per-option tradeoffs, a cost-of-waiting line, and a `recommendation` — contained three ways: the guides forbid inventing options; `groundedRecommendation` drops any recommendation that doesn't name one of the framing's own options verbatim (anti-hallucination at the read); and `resolveDecision()` stays the only clearer, so the human still decides. An empty recommendation is an honest abstention, instructed as better than a coin flip dressed as advice. **The recommendation is the decision surface** (2026-08-08 audit): on a flagged task each option carries a Decide tap — the Best fit wears the emphasized one, never auto-executed — and `resolveDecisionAndLog(choice:)` records WHAT was chosen in the trail (`Chose: …`) and on the task's notes (`Decided → …`), undo-completely.

**Break this down commits, and that is its one difference.** Framing changes nothing; accepting a breakdown creates real child tasks born `.todo` with `.parent` edges, one reversible `"split"` entry, and a `currentRelevance` pull-down so the parent recedes while it has open steps. It never splits on its own.

### Availability caveat

The *model's* classification is on-device only, and Apple Intelligence can be **off by user setting or unavailable by region** — not just absent on old hardware. Those users would otherwise get nil intent on every task, and no capability voiced by type.

`IntentResolver.inferredWorkIntent` closes that gap: it backfills lexically at resolve time (planning phrases — including choice-shaped wording, which lands `.planning` — else `.action`), so the confirm card's kind chip is populated on every engine. It **never reads `isJudgmentCall`/`needsDecision`**, which would fuse axes 2 and 3 — test-enforced by `IntentResolverTests.workIntentIgnoresJudgmentFlag`. Its `.action` default is behaviourally identical to nil (same CTA verb, same capability set), so the backfill is a naming, not a behaviour change.

A model-supplied classification always wins over the backfill.

---

## Axis 3 — Attention flags

| Flag | Storage | Source |
|---|---|---|
| `needsDecision` | **stored** | low confidence or judgment-category; only `resolveDecision()` clears a judgment call's |
| `blocked` | derived | non-empty active blocker edges |
| `overdue` | derived | unresolved and past due |
| `blocking` / `stale` | derived, **never labeled** | expressed through rank position only |

## Axis 4 — Signals

`isUrgent` — human-set, a contributor to `AttentionEngine`'s score.

### The row's leading marker

One slot, two residents, an explicit precedence: **Needs Decision** (`decisionAccent`) beats **Urgent** (`priorityUrgent`); nothing renders when neither is set. The slot means "the one thing most demanding your attention", which is honest about being a composite rather than pretending to encode a single axis.

**The task's TYPE never appears there.** `.decision` (Axis 2) and `needsDecision` (Axis 3) are different questions — what kind of work this is, versus why it needs your eyes — and one glyph for both would teach the user they are the same thing. Type differentiates in the detail, where the modules live. (This reverses the older "Needs Decision is detail-only, not on rows" rule, deliberately.)

---

## Ownership and the publish boundary

- `ownerID` — who it's for; `nil` means unassigned/shared. `creatorID` — who authored it, never rewritten.
- `ownerOrigin` — `.human` when the owner came from a spoken name or a human reassignment, `.inferred` otherwise.
- **Every task is born owned.** `ownerPending` is retired; the proposer ladder always terminates.

### The proposer ladder (`AI/OwnerProposer.swift`)

Pure and deterministic — no model call, which is why the heuristic path, the simulator, and every test exercise it. First rung that matches wins:

1. **`.spoken`** — the user said a name. Never overridden, **not sync-gated**.
2. **`.adjacency`** — a graph neighbour has a non-self owner: the `childOf` or `duplicateOf` target's. **`draft.blocks` is deliberately excluded** — a blocker is frequently owned by someone else *because* they are the bottleneck, so it points the wrong way as often as not. Sync-gated.
3. **`.affinity`** — within this category one member owns ≥ 3 prior tasks **and** ≥ 60% of them. Sync-gated.
4. **`.defaultSelf`** — the capturer. The default, not a fallback, and **total**.

**Load is a modifier, never a selector.** An overloaded rung-2/3 candidate yields to the next sharing the basis; ties go to the lighter plate. Load can never *originate* a proposal, so "give it to Maya because her number is lower" — on work she has no context for — is unreachable by construction.

**`.defaultSelf` claims nothing.** It carries no reason, so the confirm card's ✦ never appears on it. Rung 4 catches most captures; dressing that up as an inference would be worse for trust than the abstention it replaced.

**The affinity denominator counts human-established ownership only.** Rung 4 makes the capturer the owner of everything the earlier rungs miss, so a share computed over all tasks would be flooded by the proposer's own output and a genuinely-preferred owner could never cross the threshold — the rung would be unreachable by construction.

**`resolveOwners` mints nobody.** An unmatched spoken name leaves the task shared; a phantom `FamilyMember` would become an *existing* member that accrues category ownership and becomes proposable. The confirm card's "Add person…" is the explicit human step.

### Confirm is the single publish boundary

Pre-Confirm the capture is single-player even when the inferred owner isn't you: it exists only on the capturer's device, and there is no task at all. **Assignment side effects bind to the Confirm event, never to the owner field being populated** (`AppBrain.publishAssignments`) — that is the seam a future "Confirm all" fast-path would otherwise leak through.

### Notification — decided, blocked on sync

**Target behavior: notified.** On Confirm, if the owner isn't the capturer, the task publishes and the assignee is notified. Self-owned tasks publish silently. Three containment rules ship with it:

1. **One notification per assignment**, bound to the Confirm event — not per edit.
2. **Reassignment is the only re-notify.** Field edits that don't change owner stay silent.
3. **The notification names the source** — "Charles assigned you: book pediatrician". Attribution discourages frivolous assignment better than any rate limit.

**Status: unimplementable.** `PersistenceStack.cloudKitContainerID` is nil, the entitlement's container list is empty, and there is no `UNUserNotificationCenter` usage. **Interim: silent publish.** An engineering constraint, not a reversal.

**Open stance:** notified-without-decline means the task is theirs the moment you Confirm — informed, not asked. That mirrors a partner saying "can you book the pediatrician". It is a real position on household dynamics, worth revisiting on real usage; when delivery ships, the notification itself should surface the hand-back affordance.

### The sync gate

`HouseholdSync.isLive` (compile-time `false`) gates the proposer's **inferred** non-self rungs and Today's ownership filter. Without sync, a task assigned to Maya has nowhere to go — she has no device in the graph — so applying either now would let work leave your briefing and land nowhere anyone can act on it. Single-device installs keep everything in Today regardless of nominal owner.

---

## Capture durability

`ComposerView` held drafts in `@State` on a sheet with interactive dismissal, and the `Capture` row — the verbatim raw text the PRD promises is kept "forever" — was written only inside `commit`. Swiping down before Confirm destroyed the thought. With `.inbox` gone there is nothing else to catch it.

- The `Capture` row is written at **parse time**; `commit` adopts it rather than creating a second one.
- `Capture.draftsData` holds the unconfirmed drafts in an explicit **version envelope** (`ParkedDrafts`). A decode that *succeeds but means something different* is worse than one that throws, so an unrecognized version is discarded.
- A decode failure falls back to **re-parsing from `rawText`** — the raw text is irreplaceable, drafts are derived.
- **`TaskDraft.id` is `var`, not `let`.** Synthesized `Codable` silently skips an immutable property with an initial value: it compiles, encodes fine, and mints fresh ids on every restore.
- **Parking is a list, not a slot.** Opening the composer always starts a new capture; being interrupted twice is ordinary.
- **Swipe-down parks; only Discard destroys.**
- **A parked capture is not a task** — no ranking, no Today, no My Tasks, nobody's plate.
- **The surface decays.** "N captures waiting" on the Today resting surface is the one surface with no resolution path but reopening the composer, so `BrainSweeps` prunes a long-parked capture — dropping the derived drafts, keeping `rawText` forever — as a **logged, reversible** `.ai` action. A silent prune would reintroduce the exact failure this prevents, on a longer clock.

---

## Undo-completeness

A `ChangeLogUndo` arm restores **every field its action wrote**, not just the headline one.

The worked example is `"assigned"`: `claim` stamps `ownerOrigin = .human`, and the affinity denominator counts `.human` only. An arm restoring the owner id alone would leave an AI-inferred ownership marked human and quietly pollute the denominator — the exact failure the denominator rule exists to prevent. So the entry encodes `"<uuid>|<origin>"` (`TaskItem.encodeOwnership`) and the arm restores both. `"reclassified"` and the capture prune inherit the same rule.

---

## Schema

Generation **10**. The lifecycle collapses to one field (`stageRaw` gone, `TaskStage.swift`/`TaskDisplayStatus` deleted, `statusRaw`'s vocabulary re-meaninged), `ownerPending` → `ownerOriginRaw`, `workIntentRaw` loses `waiting`, `Capture` gains `draftsData`/`committedAt`.

**This spends most of the remaining clean-break budget.** The wipe-on-mismatch escape hatch closes the day `HouseholdSync.isLive` flips: a deployed CloudKit schema is additive-only, with no server-side reset, and every `NSPersistentCloudKitContainer` constraint lands at the same moment. The discipline from here is additive-in-practice, with a **schema-freeze review gated to that flip** rather than a declared final generation — real usage of this model is exactly what is most likely to reveal a shape mistake.
