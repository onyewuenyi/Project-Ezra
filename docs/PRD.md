# Project Ezra — Product Spec (PRD)

> **Managing Chaos, Effortlessly.** An AI-managed personal task system for iOS — "Linear for Life."

This is the single, authoritative product spec. It consolidates what were four documents — the Today/Now surface PRD, the Attention Architecture, the Flags & Priority spec, and the Task Entity & Actions spec. Field names map to the Swift implementation (`Models/`, `AI/`, `Features/`). The **design system** (`prev-docs/design-system-managing-chaos.md`), **product guardrails** (`prev-docs/product-guardrails.md`), and **household architecture** (`prev-docs/household-architecture.md`) remain in force except where this spec overrides them.

---

## 1. Overview & Vision

Ezra is **not** a dashboard or a task list. It is a **daily briefing from an AI advisor**: AI continuously organizes captured work in the background, and the primary surface — **Today** — plays a short, cinematic two-scene sequence once a day that answers a single question:

> **"Given everything I'm carrying, what should I actually do today?"**

Two scenes: **Recap** (what you just wrapped up) — which doubles as the cinematic cover while the advisor reasons your day in the background — then, the moment the plan is ready, a data-driven transition into the **advisor briefing**: a headline, the **action plan** (the tasks it chose, in the order it chose, however many it judged worth doing), the **reasoning**, the **tradeoffs** (what it set aside), and the **risks** (what's overdue / blocked / undecided). The action steps are tappable and open the task. There is no capacity question and no timer — the AI decides scope, and the transition lands when the briefing is ready. It plays once; repeat opens land on the resting briefing.

The user should never have to organize their work manually. The product embodies **Linear's** principles — opinionated, calm, fast, execution-focused — adapted for everyday life, with AI absorbing the complexity.

---

## 2. Design Principles

- Today is an **execution** surface, not a planning surface.
- AI **reduces cognitive load** rather than adding features.
- Prioritize **attention over information density**.
- Hide system complexity.
- Everything should feel **immediate, calm, and trustworthy**.
- Borrow Linear's opinionated workflow while adapting it for everyday life.

---

## 3. Boundaries (keep these deliberate)

The differentiation is **"attention manager, not task manager."** Four edges keep it honest:

- **AI owns *order*, the user owns *decisions*.** "The user never reprioritizes" means they never reorder the ranking — Priority is AI-set and shows only as position. It does **not** mean the AI decides *for* them: Status stays user-owned (confirm, complete, kill, defer), and judgment calls are always the user's. The three data dimensions are never fused.
- **Due-date is a *signal*, not the organizing question.** "Due today" is one input to attention, never the sort key. Ranking is *Needs Decision → Blocked → attention score → Blocking → Overdue → dueDate* (dueDate is a low-order tiebreak). Never let "due today" quietly become the primary sort.
- **The Plan is AI-authored; there is no manual planning.** The Today Plan is generated, not arranged: no drag-to-plan, no rescheduling, no manual reorder. Membership and order are `TaskRanking`'s; the user's one input is Capacity (how much today). This keeps "execution surface, not planning surface" honest — the AI absorbs the arranging, the user executes.
- **Today = *my* execution; Household = *our* coordination.** Household work enters my Today only when it needs *me* (assigned to me, up-for-grabs, or my task blocks someone). Team-level "are we coordinated?" lives on the Household surface. So a reason like "Blocks Maya's trip" belongs on my Today only because it's *my* task holding up hers.

---

## 4. Product Architecture

```
Capture
      ↓
Foundation Model (Heuristic fallback) → raw intents (TaskIntent)
      ↓
Deterministic resolver (IntentResolver) → drafts (ALL land Inbox)
      ↓
Confirm-Creation glance  ← the one human-in-the-loop moment
      ↓
Tasks (system of record)
      ↓
TodayQueries (recap / docket)  +  TaskRanking (membership & order)
      ↓
CapacityBaseline (deterministic, from CapacityLog) → sizes the plan
      ↓
TodayPlanGenerator (on-device | PCC | deterministic) → narrates only
      ↓
Today (the cinematic sequence; sanitized(against:) enforces "narrates, never ranks")
```

Confidence is **not** a gate at capture — it becomes a *visual state* on the confirm card (dimmed + "?"), never a separate held queue. The Today surface only consumes existing tasks, **never stores state on a task**, and is a personalized derived view: the pure queries and `TaskRanking` decide the plan; the model attaches rationales, which `GeneratedPlan.sanitized(against:)` re-imposes order and membership over.

---

## 5. The Task Entity — three dimensions, never fused

A task carries three separate dimensions (this replaces the old flat `Blocked/Ready/Needs Decision/Done` enum):

- **Lifecycle** (single-value, **user-owned**): `Todo → Doing → Done | Canceled` — `TaskStatus`. A task comes into existence at Confirm, born `.todo`; the AI never moves the lifecycle again except the reversible stale auto-archive. **Superseded by `docs/task-model.md`, which is now the reference for all four axes** — this section is kept for the surrounding product context only.
- **Attention** (replaces the retired user-facing Priority — see `docs/task-primitive-v2-spec.md`): one USER **Signal** (`isUrgent`, user-owned; the AI proposes it at capture) feeds a computed **system score** (`AttentionEngine` → persisted `AttentionMetadata`, 0–100 + explaining contributors). The score is **never a badge** and only breaks ties WITHIN the hard ranking bands; the Signal renders as a leading `SignalMarker` (Urgent) on the record surfaces only. (Pinned was a second Signal in V1 and is retired — a manual float-to-top override competed with the score it was meant to complement.) Persist-slow/compute-fast: the score reads only slow inputs and never a fast fact.
- **Flags** (multi-value, stackable, conditions of attention): `Needs Decision, Blocked, Blocking, Overdue, Stale`.

**Headline rule: only Needs Decision is ever shown as a label** (the one chip), plus a small Overdue marker in the card's metadata line. Everything else is internal, expressed through position — never text or color.

### The flags

| Flag | Stored? | Set by | Visible? | Effect |
|---|---|---|---|---|
| Needs Decision | **Yes** (`needsDecision`) | Triage (judgment call OR confidence < 0.5) or `escalateToDecision()` | **Chip** | Forced crisp top of the stack, overriding the attention order and Blocked |
| Blocked | Derived (`activeBlockers` non-empty) | Adding a `Blocker` (task ref or external note) | No | Sinks toward the back regardless of attention (unless also Needs Decision) |
| Blocking | Derived (`isBlocking(among:)` reverse edge) | AI inference / dependency graph | No | Modest boost within the attention order |
| Overdue | Derived (`isOverdue()` — dueDate < today) | The calendar | **Small marker** | Boost within the attention order (never overriding it); surfaces on the Today Docket |
| Stale | Derived (`isStale()` — undated, no HUMAN touch past threshold) | The clock | No | Surfaces on the Docket; past `StalePolicy.archiveThreshold` triggers the silent, reversible auto-archive (`BrainSweeps`) |

**Blocked is always derived, never written.** A task reads as blocked iff `activeBlockers(among:)` is non-empty — there is no `block()`. An Active task that gains a blocker STAYS Active. **Blocking, Overdue, and Stale are likewise derived** from data already on the record. Stale reads the **human clock** (`lastHumanTouchAt`, stamped only by `touchHuman()` on human-initiated edits; `createdAt` while nil) — `updatedAt` is also bumped by system paths (capture-time edge writes), which must never reset a task's staleness.

### Stack precedence (resolved)

Implemented exactly in `Models/TaskRanking.swift` (`stackOrder` — every band term a lexicographic sort-key component, so the comparator stays a strict weak ordering, property-tested; the ONE deliberate additive layer lives *inside* the attention component only):

1. **Needs Decision** → always crisp / top, full stop.
2. **Blocked** → sinks, regardless of attention (rule 1 wins if both).
3. **Effective attention** (the persisted score + live `currentRelevance`, clamped ±25, precomputed per snapshot into `RankKey`) → primary sort among the rest.
4. **Blocking** → minor boost within equal attention.
5. **Overdue** → similar boost; then soonest-due, then stable tiebreak.

There is **no manual "bump to top" override** — ranking is fully the AI's call. The compensating human control is the Confirm-Creation flow (§6).

### The judgment-call carve-out (permanent)

Values-laden decisions ("should I keep paying for the gym?") are always `.ask` tier, carry `needsDecision` from birth, and are the user's alone. The clearing rule preserves this: `confirm()` clears a *low-confidence* flag (the human validated the fields), but a **judgment call's flag survives creation-confirm** — confirming that "figure out if X" exists is not making the call. Only `resolveDecision()` (the human explicitly deciding) clears it. `BrainSweeps` never touches a judgment call or open decision. Autonomy tier is **derived** from confidence + `isJudgmentCall`, never stored.

---

## 6. Capture & Creation (always-confirm)

There is **no low-confidence Review gate and no Review destination.** Every capture is filed into the Inbox and surfaces one lightweight **Confirm-Creation** glance where the work is (contextually in the composer), never a separate tab.

### Capture entity (`Models/Capture.swift`)

One voice/text event can yield multiple tasks; if the raw text lived on Task, that grouping would be lost. Capture is a lightweight record tasks reference (`TaskItem.captureID`):

- `rawText` — the original transcript/text, kept **verbatim forever, never mutated**. Ground truth for "the AI got something wrong."
- `source` — voice / text / forward / image / siri / widget / watch (only voice/text produced today; the rest are reserved entry points).
- `parsedTaskIDs`, `processingPath` (localOnly / escalated), `escalatedAt`, `imageRef` — instrumentation shipped now; escalation/image deferred.

### Intent → deterministic resolver

Engines emit **`TaskIntent`** (`AI/TaskIntent.swift`), never finished tasks: `dateExpression` and `personReference` stay **raw, verbatim**. **`IntentResolver`** (`AI/IntentResolver.swift`) converts intents to `TaskDraft`s in app code — date resolution is a testable rule, not a generation artifact; person resolution happens against the roster in `AppBrain.resolveOwners`. The resolver freezes the AI's field values (`TaskDraft.aiOriginal`); a draft carries **no lifecycle position at all**, because a draft is not a task — `AppBrain.commit` is what creates one, born `.todo`.

**Metadata completeness guarantee.** No candidate reaches the confirm card with a hole: whatever the engine extracted wins, and whatever it left empty the resolver **backfills deterministically** — `inferredImportance` (consequence signals and imminent dates read high, ordinary reads middling; the slow AI-importance input to the attention score); `estimatedEffort` (quick-touch 15 / errand 30 / focused 60, the same bands the on-device model is instructed to use). The one deliberate exception is the **due date**: inventing a date with no time signal manufactures a future false Overdue, so an undated task stays honestly undated (the card shows an add-affordance instead). Backfill runs **before** the `aiOriginal` snapshot, so an un-edited confirm never records phantom corrections. The card renders **every** field — category, due, owner ("You" is a value, not an empty state), urgent, effort, and any captured wait — each editable.

### Confirm-Creation flow

The single human-in-the-loop moment. "Add N tasks" after the per-field glance → `confirm()` per task: Inbox → Active, stamps `confirmedAt`, writes any Corrections. This keeps a human in the loop at the one moment that matters — creation — while everything after is AI-**ranked**, not AI-**decided**. A judgment call's Needs Decision flag survives (§5).

Live parse in `ComposerView`: candidates appear as you type/speak, nothing withheld on confidence. Low confidence is a *visual* state (dimmed + "?") that resolves as more speech firms it up. On device, Foundation Models streams partial generation (`onPartial`), so candidates fill in mid-generation; the sim's heuristic path is instant.

### Correction — the compounding loop (`Models/Correction.swift`, `AI/CorrectionProfile.swift`)

Every field edited on the confirm card is a free labeled pair `{fieldCorrected, aiValue, userValue}`, diffed against `TaskDraft.aiOriginal` at commit. **Stored locally, never uploaded.** It is a **write-only learning signal.**

The loop is live: corrections aggregate into `LearnedRule`s — `categoryOverride` (keyword→category), `ownerAlias` (spoken→actual), `titleRewrite` — with hard guardrails: a rule needs the **same correction ≥ 2 times**, the set is capped at **8**, and rules only touch fields the engine produced. Rules apply in two places: deterministically in `IntentResolver.applyRules` (uniform across engines, so the simulator's heuristic path learns too), and as instruction lines injected into the Foundation Models session (`CorrectionProfile.instructionLines`; `LanguageModelSession.DynamicInstructions` is the API when the session becomes continuous). `aiOriginal` snapshots **after** rule application, so an un-edited confirm never re-records a learned rule as a fresh correction. **Guardrail: this loop must reduce required user attention over time, not increase engagement.**

---

## 7. Records & Actions

### ChangeLogEntry (`Models/ChangeLogEntry.swift`)

Backs **both Undo and the Activity Trail**: field-level old/new where applicable, `initiatedBy: ai | human`, `isReversible`, `undone`. The trail and the "AI handled N" count render **AI entries only** (must never count human edits). Every AI action is reversible and logged; `Metrics.acceptanceRate` counts AI entries only, **excluding** `action == "planned"` (the daily plan is not a per-task action the user accepts — its undo just clears the day cache).

### Actions (with autonomy tiers)

Autonomy tiers gate what happens *after* a task exists (creation always gets the one-tap confirm): **silent** (high confidence + reversible → runs without asking), **suggest** (high confidence but costly → one-tap confirm), **ask** (low confidence or values-laden → asks first).

| Action | Tier | Implementation |
|---|---|---|
| Capture | n/a — data entry | Live parse in `ComposerView`; `confidence` recorded, not enforced. |
| Confirm-Creation | Human, every task | "Add N tasks" → `confirm()` per task: Inbox → Active, `confirmedAt`, Corrections written. A judgment call's flag survives. |
| Triage (ongoing) | silent/suggest/ask | `BrainSweeps` (narrow today: stale auto-archive only). |
| Split-Into-Subtasks | suggest only | Deferred — `parentTaskID` plumbing ships now. |
| Merge-Duplicate | suggest only | Deferred. |
| Complete | Human only | `complete()` — the AI never marks work done on the user's behalf. |
| Kill | Human, or silent past the long stale threshold | `kill()` / `BrainSweeps` auto-archive — always reversible via the trail. |
| Defer | Human | `deferTask(until:)` / `touch()` from the detail sheet or Today. |
| Resolve-Blocker | Silent | `resurfaceDependents` — purely mechanical, logged, reversible. |
| Escalate-to-Decision | The ask-tier mechanism itself | `escalateToDecision()` — setting the flag IS the routing. |
| Undo | Human, always | Trail → `ChangeLogEntry` revert (back to Inbox; archived tasks reopen). |

Every status change funnels through `TaskItem.status`'s setter → `transition(to:now:)`, which records the `StateVisit` timeline and bumps `updatedAt`. Never write `statusRaw` directly; never expose `$task.status` as a two-way binding.

### Captured waits & reverse dependencies

**Captured waits are never lost.** A blocker phrase that matches an existing task becomes a `.task` blocker at commit; one that matches nothing becomes an **`.external` blocker in the user's own words** ("waiting on receipts"). This is confirm-sanctioned, not a breach of the no-silent-external rule: the phrase rode the visible, removable confirm card. The AI still **never authors an external blocker on an already-existing task** — on an existing task it only ever authors `.task` blockers.

**Reverse dependencies at creation.** When a task is captured, the pipeline also asks the inverse question — *should anything already open wait on this new task?* Two sources, deduplicated in `IntentResolver.detectDependents`: (1) **deterministic upgrade** — an open task carrying an external note matching the new title ("Book flights" waiting on "passport" when "Renew passport" is captured) gets its note replaced by a real `.task` edge (works on every engine incl. the sim); (2) **model inference** — the FM prompt includes open-task titles (capped at 25) and the schema's `blocksExistingTasks` returns the ones that logically can't proceed; unmatched titles drop rather than guess. Detected links ride the confirm card as removable "blocks '…'" chips; at commit each becomes a cycle-safe edge with a **reversible `"linked"` change-log entry whose Undo removes exactly that edge** (never reopens the task). Refused (cycle-closing) edges log nothing.

*(Note: the old `run_id` concept has no counterpart — Runs were retired; `category` is the grouping.)*

---

## 8. The Today Surface (the advisor briefing)

Today is a **daily briefing from an AI advisor that plays once**, not a live feed. Two scenes, then it rests.

```
Capture → Tasks (system of record) → TaskRanking (candidate set) → TodayPlanService
        → AI advisor (AdvisorBriefing) → validated(against:) → Today briefing
```

### The two scenes

1. **Scene 1 — Recap ("what you got done").** The count of what you just wrapped up (a bold count-up numeral, `Font.heroDisplay`) then the titles cascade in — deliberately **monochrome** (green success check only). A pure query (`TodayQueries.recap`, window from the store's recap cutoff). Crucially it doubles as the **cover while the advisor reasons your day in the background** — no spinner. If nothing was completed, Scene 1 is a graceful "Reading your day…" cover instead of a count.
2. **Scene 2 — the advisor briefing.** The moment generation completes AND the Recap entrance has played, a data-driven transition reveals: a **headline**, the **action plan** (the tasks the advisor chose, in its order, however many it judged worth doing — each a tappable step that opens the task, the top one wearing the accent-gradient hero edge), the **tradeoffs** (what it set aside and why), and the **risks** (overdue / blocked / undecided). A primary accent-gradient CTA opens the first action. Repeat opens land on this as a resting surface (rows resolve **live TaskItems by cached UUID**, so completions from the Tasks tab show through; killed/missing IDs drop silently).

### The advisor selects — TaskRanking is the candidate-provider + fallback

**This reverses the prior "the model narrates, never ranks" rule for the Today plan (a deliberate pivot).** The model is now an **expert advisor**: given the candidate tasks with their observable facts, it decides **which** matter today, **in what order**, and **how many** — and reasons about them (headline · tradeoffs · risks). `TaskRanking` is demoted to two supporting jobs:

- **Candidate provider** — the open, actionable working set (active + open decisions) in `TaskRanking` order, capped for the context budget, is what the advisor chooses from.
- **Deterministic fallback** — when no model is available (sim / offline / Apple Intelligence off), the briefing degrades to the top-N candidates by rank with fact-line lines and **no headline/tradeoffs/risks** (a plainer read; the deterministic tier never blocks or apologizes).

`GeneratedPlan.validated(against:)` is the only mechanical guard, and it does **not** rank: it drops actions whose id isn't a real candidate (anti-hallucination), dedupes, backfills an empty line from the candidate's fact string, and caps at `maxActions` (7). The advisor's headline/tradeoffs/risks pass through as its voice.

### Sizing, tiers, cache

- **Sizing:** the advisor decides the count. `CapacityLog` still logs daily throughput (the capacity dimension is vestigial `.steady` now the input is gone), and `CapacityBaseline(for: .steady)` — the rolling completion average, when ≥ 5 samples exist — is passed to the advisor as *context only* ("typically finishes ~N/day"), never a hard limit.
- **Tier routing** (`PlanRouting`, pure & ordered): **on-device → PCC → deterministic**, deterministic always the tail so `AppBrain.todayPlan` never fails. Timeouts race generation against a deadline (~12s on-device, ~20s PCC).
- **Plays once — reset & cache:** the reset trigger is ONE swappable predicate, `TodayPlanStore.shouldReplay(now:)` (V0: first open each day); nothing else tests the date. `TodayPlanCache` stores the briefing (headline/tradeoffs/risks/actions); it fail-softs to nil if the shape changes. Day-rollover reconciliation resolves yesterday's plan against live tasks → one `CapacityLog` row → then clears (reuses the Recap moment, no new surface).

### Motion & the data-driven transition

The scene transition is **data-driven, never timed** — it fires when generation completes AND the Recap entrance has played (via `withAnimation`'s completion, not `DispatchQueue.asyncAfter`). There is no auto-advance timer, no Docket screen, no capacity capsules, no progress bars. A soft cobalt glow backdrop (`TodayBackdrop`, off under Reduce Transparency) sets the atmosphere. Accessibility: Reduce Motion → cross-fades, no count-up/bounce; Reduce Transparency → no glow; Differentiate Without Color → borders; VoiceOver reads the briefing as structured text with reachable task links.

### Explainability

The advisor's per-action line is grounded in the same observable **facts** the candidate snapshot carries (due today, N days overdue, blocks '…', ~N min) — never AI internals; the fallback uses those fact strings directly as the line.

---

## 9. AI System — two engines + personal context

`AI/AIEngine.swift` defines the seam. **`FoundationModelsEngine`** (real on-device LLM, iOS 27) and **`HeuristicEngine`** (deterministic fallback) both conform and emit `[TaskIntent]` via `triage(rawText:context:onPartial:)`. `AppBrain` selects the engine at launch via `SystemLanguageModel.default.availability` and degrades to the heuristic on failure. Foundation Models is unavailable in the simulator, so **the sim always exercises the heuristic path.** Both engines stay behaviorally consistent — the shared derivation lives in `AutonomyPolicy.tier` + `IntentResolver` (including `applyRules`, the learned-correction half both engines get for free). Use guided generation (`@Generable` + `@Guide`), not JSON parsing; **device-verify any `@Generable` schema change.**

**`TriageContext`** carries personal context per call: `personalization` (top-N learned corrections as instruction lines, built by `CorrectionProfile`) and `roster` (value snapshots backing `ResolvePersonTool`).

### Personal context as a tool (`AI/PersonalContextTools.swift`)

`ResolvePersonTool` ("resolve_person") exposes the household roster to the on-device model as a narrow, deterministic `Tool` — attached only when a roster exists. "Call Sarah about the thing" resolves to the one Sarah in the household, with the relationship as context; the returned name is used verbatim as `personReference`. The data never leaves the device. `resolveTimeframe`/`resolveProject` are deliberately absent — dates stay OUT of the model (deterministic resolution is the resolver's whole point) and there is no project concept. **Known Xcode 27 beta caveat:** guided generation can over-call tools — tighten prompt wording before assuming a code bug if triage gets erratic or slow.

### PCC escalation (shipped — the Today Plan's stronger tier)

The Today Plan generator ships a real **Private Cloud Compute** tier (`PrivateCloudComputeLanguageModel`, `AI/TodayPlanService.swift`) alongside on-device. `PlanRouting` chooses it per call (see §8's routing table) — a bigger/chained/Light day, or a newly-divergent baseline, escalates to PCC first; a small calm day stays on-device. Any PCC error — including an ungranted `com.apple.developer.private-cloud-compute` entitlement — reads as **unavailability**, so the router simply falls through to on-device/deterministic and the feature never breaks.

- **Privacy is explicit and sanctioned:** on the PCC path, **task titles leave the device** to Apple's private compute (verifiable, non-retained). This is a deliberate trade for the stronger tier on the hardest days; the on-device and deterministic tiers keep everything local. The generator sends only the ranked shortlist and the **aggregated** baseline sentence — never raw `CapacityLog` history.
- Personalization uses fresh per-call instructions (the `DynamicInstructions` API is the mechanism if the session ever becomes continuous); today's stateless-per-call sessions get the same freshness from a rebuilt instructions string.

*(Capture-time escalation of low-confidence candidates remains **deferred** — the shipped PCC integration is the Plan generator's, not the composer's.)*

### Eval harness (`Project-EzraTests/RambleEvalTests.swift`)

~40 hand-labeled rambles (single errands, run-ons, judgment calls, delegation, dependencies, dates, messy speech) scored per field: segmentation, title, category, judgment, owner, blocked, due. Floors are **regression floors** calibrated under first-run heuristic numbers — they catch degradation, they are not targets. Engine-agnostic: the benchmark to run against the FM path on device. Re-run: `xcodebuild test … -only-testing:Project-EzraTests/RambleEvalTests`.

### Device-verify checklist (the sim can't exercise these)

1. Capture on device with Apple Intelligence on → candidates fill **progressively** during one parse (streaming), and cancel cleanly when you keep typing.
2. Mention a roster name ("ask Maya to…") → `personReference` resolves via the tool; watch for tool over-calling (triage suddenly slow).
3. Teach a correction twice (recategorize two "gym" tasks) → the third capture applies it on device too (instructions); the sim already proves the resolver half.
4. **Today Plan, streamed:** the `@Generable` `TodayPlanSchema` fills in progressively, partial rows map cleanly (known-uuid + non-empty rationale), and `sanitized(against:)` holds order/membership.
5. **Tier fallthrough:** an on-device guardrail failure falls to PCC; an absent PCC entitlement falls through to on-device/deterministic without breaking; the divergence one-shot escalates exactly once per capacity.
6. **Dynamic instructions & usage:** the personalized baseline sentence re-evaluates as the average shifts; wire `Response.usage` into `PlanMetrics` tokens (−1 until verified); profile latency with the Foundation Models Instruments template.
7. **Motion review:** frame-by-frame check of the §4.3 spring values (starting points, not locked), and confirm the haptic and visual land on the same frame (numeral, capacity selection, final plan item).

---

## 10. Navigation

Deliberately minimal — **three tabs + global Capture**:

- **Today** — the cinematic daily briefing (execution). Where "given everything I'm carrying and how much I have today, what should I do?" is answered.
- **Tasks** — the **system of record** for all work (trust / retrieval). Deliberately un-fused from Today.
- **Household** — shared execution and coordination: ownership, handoffs, blockers, household operational health.
- **Capture** — a persistent global action riding the tab bar's Liquid Glass accessory. Supports voice, text, photos, natural language (voice/text today; the rest reserved).

**Review / Inbox / Retro are NOT destinations.** The retro is gone — its rot-fighting job is absorbed by the Docket (stale/overdue surface there) and the day-rollover reconciliation. Screens open the composer via the `\.openCapture` environment action, never their own sheet.

---

## 11. Success Metrics

Users should be able to:

- Understand today's plan within **5 seconds** of the sequence resting.
- Reach their next task in **one tap**.
- Complete most daily interactions **without leaving Today**.
- Spend **less time organizing, more executing**.
- Maintain trust by **only being interrupted when AI confidence is low**.

**Instrumentation (spec §7, `PlanMetrics` + `CapacityLog`):** generation tier counts (`today.gen.count.{onDevice,pcc,deterministic}`), last latency and token usage (`−1` when the model doesn't expose usage — device-verify), planned-task skips (`today.plan.skips`), and beat **interruptions** (`today.seq.interruptions` — a high count on first playthrough means §4 pacing is too slow). `CapacityLog` rows (one per day) are themselves non-optional instrumentation and the personalization substrate. `Metrics.acceptanceRate` **excludes** `action == "planned"` — a plan isn't a per-task action the user accepts. V0 has no manual reorder (the AI owns order), so there is no reorder metric.

---

## 12. Deferred (recorded deliberately, not forgotten)

*(PCC escalation is **shipped** for the Today Plan — see §9. Capture-time escalation of low-confidence candidates remains deferred.)*

- **Inbox-confirm surfacing gap:** V0 ships **without a daily surface for unconfirmed inbox items** — the Today sequence does not port NowView's confirm section. Captures still confirm contextually via the composer, but there is no once-a-day "you have N to confirm" nudge. Open product gap.
- **Stale-undated-work gap:** with the retro removed, the retro's do/kill/defer moment for stale undated work is gone; the Docket surfaces stale/overdue and `BrainSweeps` auto-archive is the only path for genuinely buried undated rot. Watch whether that's enough.
- **Final reset mechanism + mid-day re-entry:** the plays-once trigger is one swappable predicate (`shouldReplay(now:)`, V0 = per-day); the final mechanism and any mid-day regenerate behavior are held open pending separate input.
- Rationale voice pass (the model's tone across many days), swipe-to-advance (V0 is tap-only), multi-profile plan orchestration, and Household-level capacity (capacity is per-user in V0).
- Image capture (`Attachment` multimodal input is a confirmed API — Vision-OCR-to-text is the sim-friendly first step), Siri / App Intents / widgets / Action Button / watch entry points, a continuous capture session (`DynamicInstructions`), Split-Into-Subtasks & Merge-Duplicate UI (`parentTaskID` plumbing exists), `recentPatterns` tool, location/calendar triggers, visible cycle progress/burndown (stays rejected — solo apps have no standup audience).

---

## 13. Future Opportunities (iOS 27 + Foundation Models)

As Apple Foundation Models and iOS mature, Today can evolve **without changing its structure**: morning/afternoon/evening framings · on-device contextual prioritization · intelligent summaries of household activity · context-aware ordering based on location, time, routines, recent interactions · privacy-preserving reasoning kept on-device whenever possible.

---

## Guiding Principle

> **Today is not a dashboard. It is an adaptive daily briefing.**

Users should leave the sequence knowing exactly what to do next — without thinking about projects, folders, priorities, or AI. The system absorbs that complexity so execution feels as effortless as using Linear for everyday life.
