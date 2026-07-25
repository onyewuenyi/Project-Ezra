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
enum WorkIntent: String { case action, decision, planning, reference }
```

**`waiting` is cut.** It and the derived `blocked` flag were the same predicate on two axes — a task blocked on a person is both. External waits already store as an edge with a note and no target, so `blocked` covers it, and cutting it removes the type boundary a classifier would most reliably fumble.

**Type is single-value.** "Prepare for Japan" is `planning`; "should we even go" is a child task, or the parent carries `needsDecision` on Axis 3. A second type slot would be redundant with a flag that already exists.

**Type stops recomputing once a task resolves** — reclassifying something finished changes which module renders on it for no benefit, and burns a model call.

### Type → detail module

| Type | Primary module | Built? |
|---|---|---|
| `action` | standard detail | ✓ |
| `decision` | **Thinking Partner** — framed options, tradeoffs, cost-of-waiting | ✓ |
| `planning` | subtask breakdown | **✗** B1 |
| `reference` | notes-forward | **✗** |

The gate is `TaskCapabilities.available(for:)` — `.decision` **or** the `needsDecision` flag. Independent by design: an intent never reads or writes the flag.

**The Thinking Partner does not recommend.** `DecisionFraming` returns options, per-option tradeoffs, and a cost-of-waiting line, with guides that forbid inventing options. There is no recommendation field, so "the AI frames, the human decides" holds by construction.

### Availability caveat

`workIntent` is on-device only, and Apple Intelligence can be **off by user setting or unavailable by region** — not just absent on old hardware. For those users every task has nil intent, `countsAsWorkload` is universally true, and the Thinking Partner never appears. This is why `HeuristicEngine.isReference` is **not a test seam**: it is the fallback classification path for every non-AI user.

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

## `reference` leaves the workload systems

A reference item ("the wifi password is hunter2") is owned, live, and **does not need to complete**. Left in the workload systems it silently corrupts three: it inflates `MemberLoad.activeCount`, which feeds *both* `OwnerProposer`'s overload modifier and the affinity denominator — so a user with fifteen saved notes reads as overloaded and stops receiving proposals — and it sits in Today candidacy as permanently unresolvable. `BrainSweeps` would archive it as stale, backwards for something whose whole job is to persist.

One derived predicate, `TaskItem.countsAsWorkload` (`workIntent != .reference`), gates five sites:

| Site | Effect |
|---|---|
| `HouseholdEngine.memberLoads` | excluded from every count and the overload median |
| `OwnerProposer` affinity denominator | excluded — reference items don't establish category ownership |
| `TodaySequenceModel.candidateTasks` | excluded from the briefing |
| `TaskRanking` quick-win / stack membership | excluded |
| `BrainSweeps` auto-archive | excluded — never stale by construction |

**Unknown counts as work** (nil intent → `true`), the safe direction.

**Deliberately NOT gated**, so silence doesn't read as omission: `ContextRetrieval` candidates (a wifi password must be findable as a duplicate/child target), `AttentionEngine` graph centrality (edges still describe real structure), and search / My Tasks (visible is the whole point).

**Pruning path:** Complete and Kill both stay available — a house move makes an old password dead. Auto-archive is what's wrong for them, not resolution.

**A reclassification across that boundary is logged.** `TaskItem.reclassify` writes a reversible `.ai` `"reclassified"` entry when a classifier move changes `countsAsWorkload`, because otherwise a model call would silently remove a task from five operational systems with no human action and nothing in any log. Moves that don't cross the boundary (`action → decision`) stay silent — they change rendering, not accounting.

**Reference gets its own My Tasks section**, not a status section. Filing a saved password under "Todo" claims it is queued work.

### Recognized, not solved: a deferred knowledge-vs-execution split

A wifi password is not work. Keeping it in the task primitive means the execution system is also a knowledge store, and `countsAsWorkload` patches the *accounting* without changing the fact that one primitive is doing two jobs. Keeping it is defensible — capture stays simple, you can ramble anything and it lands somewhere — but this is the Knowledge Engine question arriving through a side door, and it is **deferred, not avoided**. The separate section is the seam a future split would cut along.

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
