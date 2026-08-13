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
- **The Plan is AI-authored; there is no manual planning.** The Today Plan is generated, not arranged: no drag-to-plan, no rescheduling, no manual reorder — and no capacity question. The advisor decides membership, order, and size (§8); `TaskRanking` provides the candidate set and the deterministic fallback. This keeps "execution surface, not planning surface" honest — the AI absorbs the arranging, the user executes.
- **Today = *my* execution; Household = *our* coordination.** Household work enters my Today only when it needs *me* (assigned to me, up-for-grabs, or my task blocks someone). Team-level "are we coordinated?" lives on the Household surface. So a reason like "Blocks Maya's trip" belongs on my Today only because it's *my* task holding up hers.

---

## 4. Product Architecture

```
Capture
      ↓
Foundation Model (Heuristic fallback) → raw intents (TaskIntent)
      ↓
Deterministic resolver (IntentResolver) → drafts (parked on the Capture)
      ↓
Confirm-Creation glance  ← the one human-in-the-loop moment
      ↓
Tasks (system of record)
      ↓
TaskRanking → the capped candidate set (and the deterministic fallback)
      ↓
TodayPlanService (on-device | PCC | deterministic) → the advisor briefing
      ↓
Today (the cinematic sequence; validated(against:) is the anti-hallucination guard)
```

Confidence is **not** a gate at capture — it becomes a *visual state* on the confirm card (dimmed + "?"), never a separate held queue. The Today surface only consumes existing tasks, **never stores state on a task**, and is a personalized derived view: `TaskRanking` provides the candidates, the advisor selects/orders/sizes (§8), and `GeneratedPlan.validated(against:)` drops hallucinated ids, dedupes, and caps — it does **not** reorder.

---

## 5. The Task Entity — three dimensions, never fused

A task carries three separate dimensions (this replaces the old flat `Blocked/Ready/Needs Decision/Done` enum):

- **Lifecycle** (single-value, **user-owned**): `Todo → Doing → Done | Canceled` — `TaskStatus`. A task comes into existence at Confirm, born `.todo`; the AI never moves the lifecycle again except the reversible stale auto-archive. **Superseded by `docs/task-model.md`, which is now the reference for all four axes** — this section is kept for the surrounding product context only.
- **Attention** (replaces the retired user-facing Priority — see `docs/task-primitive-v2-spec.md`): one USER **Signal** (`isUrgent`, user-owned; the AI proposes it at capture) feeds a computed **system score** (`AttentionEngine` → persisted `AttentionMetadata`, 0–100 + explaining contributors). The score is **never a badge** and only breaks ties WITHIN the hard ranking bands; the Signal renders in the row's leading `SignalMarker` slot on the record surfaces only — one slot with two residents, Needs Decision winning over Urgent when both are set (`docs/task-model.md`). (Pinned was a second Signal in V1 and is retired — a manual float-to-top override competed with the score it was meant to complement.) Persist-slow/compute-fast: the score reads only slow inputs and never a fast fact.
- **Flags** (multi-value, stackable, conditions of attention): `Needs Decision, Blocked, Blocking, Overdue, Stale`.

**Headline rule: only Needs Decision is ever shown as a label** (the one chip), plus a small Overdue marker in the card's metadata line. Everything else is internal, expressed through position — never text or color.

### The flags

| Flag | Stored? | Set by | Visible? | Effect |
|---|---|---|---|---|
| Needs Decision | **Yes** (`needsDecision`) | Triage (judgment call OR confidence < 0.5) or `escalateToDecision()` | **Chip** | Forced crisp top of the stack, overriding the attention order and Blocked |
| Blocked | Derived (`activeBlockers` non-empty) | Adding a `Blocker` (task ref or external note) | No | Sinks toward the back regardless of attention (unless also Needs Decision) |
| Blocking | Derived (`isBlocking(among:)` reverse edge) | AI inference / dependency graph | No | Modest boost within the attention order |
| Overdue | Derived (`isOverdue()` — dueDate < today) | The calendar | **Small marker** | Boost within the attention order (never overriding it); named in the briefing's risks |
| Stale | Derived (`isStale()` — undated, no HUMAN touch past threshold) | The clock | No | No surface of its own; past `StalePolicy.archiveThreshold` triggers the silent, reversible auto-archive (`BrainSweeps`) |

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

Values-laden decisions ("should I keep paying for the gym?") are always `.ask` tier, carry `needsDecision` from birth, and are the user's alone. The clearing rule preserves this: a non-judgment draft **materializes with `needsDecision = isJudgmentCall`** — the confirm tap is the human validating every field, so the model's low confidence about its own parse is discharged at creation — but a **judgment call's flag survives creation-confirm**: confirming that "figure out if X" exists is not making the call. Only `resolveDecision()` (the human explicitly deciding) clears it. `BrainSweeps` never touches a judgment call or open decision. Autonomy tier is **derived** from confidence + `isJudgmentCall`, never stored.

---

## 6. Capture & Creation (always-confirm)

There is **no low-confidence Review gate and no Review destination.** Every capture is filed into the Inbox and surfaces one lightweight **Confirm-Creation** glance where the work is (contextually in the composer), never a separate tab.

### The Ramble thesis

> **Ramble turns unstructured thought into trusted work.** The user unloads everything without organizing it first; Ramble silently processes it, then reveals **one** coherent interpretation to confirm. The AI may iterate internally as much as it needs — the interface presents only stable states.

The magic is not watching AI create tasks. The magic is watching chaos become clarity. The arc is `THINK → DUMP → RELEASE → UNDERSTAND → REVEAL → CONFIRM → DONE`; emotionally, *messy → effortless → anticipation → clarity → trust → relief.*

**The hard UX invariant — the most important acceptance criterion in this document:**

> At no point before confirmation may the user see an intermediate AI interpretation presented as truth.

**The central AI-trust invariant (2026-08-12, product-wide):**

> **The system can think as much as it wants before showing you the answer. Once it shows you the answer, it owns that interpretation until you change it.**

Revealed means **UI-committed**, not database-committed. Once visible, no AI-originated change to title, count, order, owner, date, type, relationships, splits or merges — **the user may always edit their own cards**, because immutability constrains the system, never the person. Enforced structurally in `Interpretation`, not by convention: three earlier attempts held it as a rule and all three leaked, reaching the user each time as the same defect — a card changing after they started reading it. Scoped to Capture today; it extends to Today recommendations, the Thinking Partner, breakdowns, ownership suggestions and relationships. The generalization: **never expose an AI intermediate as user truth** — show activity, never intermediate semantic conclusions.

**The coupled invariant** (the first is meaningless if a background job undoes it):

> Background intelligence may improve organization, but must never surprise the user by changing an object they have already seen without an attributable explanation and an undo path.

**The separation of AI responsibilities.** Capture is conservative precisely so everything downstream can be ambitious:

| System | AI job |
|---|---|
| **Capture** | Understand what I said |
| **Context** | Ground it in my life |
| **Ranking / Today** | Decide what deserves attention |
| **Capabilities** | Help me overcome friction |
| **Learning** | Learn how I work |
| **Trust** | Keep AI actions inspectable and reversible |

"Now that capture is safe, make the model smarter at capture" is the wrong optimization: capture gets fast + trustworthy + frictionless, and the compounding intelligence goes to Context → Ranking → Today → Capabilities → Learning.

**The engineering rule that makes it affordable:** *progressively enrich; never progressively reinterpret.* Structure — how many tasks and in what order — is decided once and never changes under the user; metadata may fill in afterwards, quietly. And more generally: **fast deterministic work can happen invisibly; slow probabilistic work happens behind a stable UI boundary.**

**The metric is time to trustworthy result, not time to first token.**

| Stage | Target |
|---|---|
| Capture keystroke → frame | <100ms (no work on that path by construction) |
| Submit → Understanding visible | <200ms |
| Submit → **stable confirmation** | **≤3s** |
| Full enrichment | ≤5s |
| Worst case | graceful at ≥10s (the 8s reassurance line; salvage bounds it) |

### The four phases (`ComposerView.RamblePhase`)

1. **Capture** — a thought canvas, not a task field. "What's on your mind?" / "Dump it all here. I'll sort it out." Mic and photo stay. **No cards, no counts, no classification, no processing state, no AI of any kind** — during capture the user owns the conversation and the AI stays quiet. Calm at any length. CTA: **Ramble ✦**.
2. **Understanding** — submit is a deliberate moment: the keyboard releases and the input collapses into a single morphing orb (*"Got it. I'll take it from here."*). One line, **"Making sense of it"**. No spinner, no progress bar, no percentage, no counts, no candidate titles. At ~8s one quiet reassurance line so long work reads as calm rather than stuck.
3. **Reveal → Confirm** — the orb unfolds into the card composition. **"Here's what I understood"**, N things, the result arriving as ONE coherent composition (a capped stagger is allowed; the perception must be *"here is the answer"*, never *"watch it being generated"*). Tasks own the viewport: no field, no keyboard. Nothing is committed. Footer: **Create N tasks** · Add another · Back (to Capture, raw text intact).
4. **Created** — ✓ **"N tasks added"**, then dismiss **back to wherever the user was**. Capture is something you do mid-life, not a place you go.

**Structure is decided once, at submit — and one item is not evidence of one thought.** `Segmentation.confidence` returns three states. `.typed`: the split came from punctuation and layout the *user typed* (`explicitItems` — lines, bullets, sentence marks, list commas, with **no** connective-clause inference). `.singleThought`: exactly one item that passes `readsAsOneThought`. `.ambiguous`: everything else, which waits behind the orb, because splitting prose is a judgement and a judgement must never be presented as the answer.

That middle state is a **correction shipped 2026-08-11**. The gate previously called *any* one-item read certain, which is backwards: one item out of a long dictation means every boundary test failed. A four-errand dictation ("cook dinner at 3pm make a reservation tonight take my wife to dinner next week…") therefore revealed instantly as a single task titled with the raw transcript — then rewrote that title twenty seconds later and discarded three errands. `readsAsOneThought` now requires positive evidence: it rejects a sentence carrying an **interior action verb able to start a task** (errands butted together without connectives, which is how people dictate) or simply too many words. Verbs in subordinate positions — after a determiner, a modal, an infinitive marker, a conjunction — don't count, so "figure out whether we should book the hotel this week" stays one thought.

**The clamp is conditional on provenance.** Enrichment fills metadata onto the shown set via **`DraftMerge.enrich`** — pure, so the rule is property-tested — and `holdStructure` is true only for `.typed`: the result is rebuilt from what is on screen, one entry per shown draft, and the model **cannot add, drop, or move a card**. For a `.singleThought` read the model wins any structural disagreement, because holding *our own* fallback guess against the model is not stability, it is data loss. Both halves are counted (`restructures` / `structureDisagreements`); the acted-on number is the one the user saw, and it should reach zero first.

**Selective explanation.** The reveal exposes the user-relevant *consequence*, not the classifier. Default: title plus only what is consequential — a due date, an owner who isn't you, urgent, blocked, dependents, a merge or child proposal. Category, effort and the empty affordances sit behind a per-card **Details** toggle. `workIntent` is never rendered as a label: it reads **"Needs a plan"**, and a genuine judgment call reads **"Needs a decision"** — read from `isJudgmentCall` ONLY. The draft-level `needsDecision` folds in `confidence < 0.5`, which is right for the flag a task is born with and false as a sentence: it told users that cooking dinner required a decision because the model was unsure of its own parse. Model uncertainty says so in its own words (a **"Not sure"** chip) instead of borrowing the user's. This is a **documented revision** of "the confirm glance only works if the user can SEE every field" → **"every field is reachable in one tap; the glance shows what's consequential."** Rendering all eight chips made the two that carried information look identical to the six that were empty invitations, which is the opposite of a glance. Nothing became uneditable; it became uncluttered.

**One object carries the arc.** `RambleOrb` + `matchedGeometryEffect(id: "ramble")`: the field's rect → the breathing gradient orb → the card composition. It is **deliberately not a spinner and must never become one** — no rotation, no track, no determinate arc, no percentage. If it ever reads as a loader, the fix is slower and more organic motion, never a progress affordance. Reduce Motion holds it still and crossfades.

### Capture entity (`Models/Capture.swift`)

One voice/text event can yield multiple tasks; if the raw text lived on Task, that grouping would be lost. Capture is a lightweight record tasks reference (`TaskItem.captureID`):

- `rawText` — the original transcript/text, kept **verbatim forever, never mutated**. Ground truth for "the AI got something wrong."
- `source` — voice / text / forward / image / siri / widget / watch (only voice/text produced today; the rest are reserved entry points).
- `parsedTaskIDs`, `processingPath` (localOnly / escalated), `escalatedAt`, `imageRef` — instrumentation shipped now; escalation/image deferred.

### Intent → deterministic resolver

Engines emit **`TaskIntent`** (`AI/TaskIntent.swift`), never finished tasks: `dateExpression` and `personReference` stay **raw, verbatim**. **`IntentResolver`** (`AI/IntentResolver.swift`) converts intents to `TaskDraft`s in app code — date resolution is a testable rule, not a generation artifact; person resolution happens against the roster in `AppBrain.resolveOwners`. The resolver freezes the AI's field values (`TaskDraft.aiOriginal`); a draft carries **no lifecycle position at all**, because a draft is not a task — `AppBrain.commit` is what creates one, born `.todo`.

**Metadata completeness guarantee.** No candidate reaches the confirm card with a hole: whatever the engine extracted wins, and whatever it left empty the resolver **backfills deterministically** — `inferredImportance` (consequence signals and imminent dates read high, ordinary reads middling; the slow AI-importance input to the attention score); `estimatedEffort` (quick-touch 15 / errand 30 / focused 60, the same bands the on-device model is instructed to use). The **due date** is proposed from a task's *nature*, not only from a spoken phrase — a deliberate reversal of the earlier "an undated task stays honestly undated" rule, contained four ways: `IntentResolver.inferredDueDate` is a short explicit table (recurring bills → month end; renewals → +14 days; filings/deadlines → +7), never a general guess; it is **suppressed for any task carrying a blocker phrase** (a task that can't start is exactly where an invented date becomes a false Overdue); it returns a `dueReason` rendered under the chip *and persisted into the task's reasoning at commit*, so the proposal explains itself before and after confirm while staying one tap to clear; and it **never feeds `inferredImportance`** (which reads the spoken date only). Accepted cost: a proposed date takes the task out of undated-stale detection. Backfill runs **before** the `aiOriginal` snapshot, so an un-edited confirm never records phantom corrections. Every field is still populated and editable at confirm; what changed is how many are *shown at rest* (see selective explanation above) — the backfill guarantee is about holes in the data, not chips on the screen.

### Confirm-Creation flow

The single human-in-the-loop moment. "Add N tasks" after the per-field glance **is the confirm**: `AppBrain.commit` creates each task — born `.todo` with `confirmedAt` stamped at creation — and writes any Corrections. There is no `confirm()` mutation and no Inbox→Active transition (retired vocabulary from before the four-axis model; a `TaskItem` comes into existence at Confirm and never before). This keeps a human in the loop at the one moment that matters — creation — while everything after is AI-**ranked**, not AI-**decided**. A judgment call's Needs Decision flag survives (§5). The confirm closes with the Create moment’s ✓ receipt ("N tasks added"); the post-dismiss toast survives only for what the ✓ cannot say — a merge target ("Merged into “X”"), since "where did my thought go?" is the one question a count leaves open.

**Retired: the live parse.** Candidates used to appear as you typed, re-parsed on a rolling cadence, with streamed partials rendering into cards. That work made intermediate AI states render *faster* when the answer was to stop rendering them — cards appearing, splitting, merging and vanishing reads as "this thing is slow and confused" even when the final result is excellent. The per-keystroke provisional pass, the rolling cadence, `parseEpoch`, and the streamed partials into cards were deleted rather than tuned; `CaptureTriageRace`'s deadline and salvage remain, salvage becoming the timeout path into the reveal. Low confidence is still a *visual* state on the revealed card (dimmed + "?"), never a held queue.

### Correction — the compounding loop (`Models/Correction.swift`, `AI/CorrectionProfile.swift`)

Every field edited on the confirm card is a free labeled pair `{fieldCorrected, aiValue, userValue}`, diffed against `TaskDraft.aiOriginal` at commit. **Stored locally, never uploaded.** It is a **write-only learning signal.**

The loop is live **for three of the ten recorded field kinds** — category, owner, and title feed rules today; due date, urgency, kind, effort, blocker, and the graph-proposal decisions are recorded but write-only until their rule kinds exist (candidates with the same ≥2-occurrence guardrail: effort-band override, urgency-keyword learning). Corrections aggregate into `LearnedRule`s — `categoryOverride` (keyword→category), `ownerAlias` (spoken→actual), `titleRewrite` — with hard guardrails: a rule needs the **same correction ≥ 2 times**, the set is capped at **8**, and rules only touch fields the engine produced. Rules apply in two places: deterministically in `IntentResolver.applyRules` (uniform across engines, so the simulator's heuristic path learns too), and as instruction lines injected into the Foundation Models session (`CorrectionProfile.instructionLines`; the continuous session is now BUILT on `DynamicProfile`/`DynamicInstructions` — `AI/CaptureConversation.swift`, measured via the `-CaptureDiagnostics` A/B arm, default-flips on device evidence). `aiOriginal` snapshots **after** rule application, so an un-edited confirm never re-records a learned rule as a fresh correction. **Guardrail: this loop must reduce required user attention over time, not increase engagement.**

---

## 7. Records & Actions

### ChangeLogEntry (`Models/ChangeLogEntry.swift`)

Backs **both Undo and the Activity Trail**: field-level old/new where applicable, `initiatedBy: ai | human`, `isReversible`, `undone`. The trail and the "AI handled N" count render **AI entries only** (must never count human edits). Every AI action **with an effect to reverse** is reversible and logged; an entry that merely *narrates* a fact the human confirmed in the same breath is informational — the silent-tier `"filed"` entry is the named example (there is no pre-AI category to restore, since commit is the confirm; a reversible flag on it minted no-op undos that read as rejections in the metric). Suppression writes are logged and reversible. `Metrics.acceptanceRate` counts AI entries only, **excluding** `action == "planned"` (the daily plan is not a per-task action the user accepts — its undo just clears the day cache).

### Actions (with autonomy tiers)

Autonomy tiers gate what happens *after* a task exists (creation always gets the one-tap confirm): **silent** (high confidence + reversible → runs without asking), **suggest** (high confidence but costly → one-tap confirm), **ask** (low confidence or values-laden → asks first).

| Action | Tier | Implementation |
|---|---|---|
| Capture | n/a — data entry | Live parse in `ComposerView`; `confidence` recorded, not enforced. |
| Confirm-Creation | Human, every task | "Add N tasks" → `AppBrain.commit` creates each task born `.todo`, `confirmedAt` stamped, Corrections written. A judgment call's flag survives. |
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
- **Tier routing** (`PlanRouting`, pure & ordered): a **simple ordered chain** — **on-device → PCC → deterministic**, deterministic always the tail so `AppBrain.todayPlan` never fails. There is no per-day escalation logic; each available tier is simply tried in order. Timeouts race generation against a deadline (30s on-device with partial salvage, 20s PCC).
- **Plays once — reset & cache:** the reset trigger is ONE swappable predicate, `TodayPlanStore.shouldReplay(now:)` (V0: first open each day); nothing else tests the date. `TodayPlanCache` stores the briefing (headline/tradeoffs/risks/actions); it fail-softs to nil if the shape changes. Day-rollover reconciliation resolves yesterday's plan against live tasks → one `CapacityLog` row → then clears (reuses the Recap moment, no new surface).

### Motion & the data-driven transition

The scene transition is **data-driven, never timed** — it fires when generation completes AND the Recap entrance has played (via `withAnimation`'s completion, not `DispatchQueue.asyncAfter`). There is no auto-advance timer, no Docket screen, no capacity capsules, no progress bars. A soft cobalt glow backdrop (`TodayBackdrop`, off under Reduce Transparency) sets the atmosphere. Accessibility: Reduce Motion → cross-fades, no count-up/bounce; Reduce Transparency → no glow; Differentiate Without Color → borders; VoiceOver reads the briefing as structured text with reachable task links.

### Explainability

The advisor's per-action line is grounded in the same observable **facts** the candidate snapshot carries (due today, N days overdue, blocks '…', ~N min) — never AI internals; the fallback uses those fact strings directly as the line.

---

### 8a. The advisor session & internal signals (product decision, 2026-08-11)

**`workIntent` is an internal, AI-owned signal, not a user-facing classification.** Users
maintain **facts** (status · owner · due · urgent · category · effort); the system maintains
**interpretations** (workIntent, deferral band, other inference); the advisor turns both into
action. Binding corollaries:

- It never leaks into user-facing metadata or deterministic Today copy — **advisor-only facts
  and display facts derive separately** from the same task state (`PlanTaskSnapshot.facts` vs
  `promptOnlyFacts`). Internal reasoning signals must not become accidental UI.
- Planning classification **informs** the advisor's composition (a signal, never a quota, never
  an override of deterministic ranking). Repeated deferral is a **bounded** intervention: the
  advisor sees only the 2–3 band; 4+ is StallDiagnosis / Task-Advisor territory — never
  escalating re-plan pressure.
- The advisor is told candidates arrive **already ranked** — a strong prior to deviate from.
- `workIntent` is **system-owned by construction** (one write chain, no user-editing path,
  DEBUG-asserted) and its classifier is **evaluated**: a labeled kind field with a regression
  floor in the ramble eval. An internal AI-owned field earns trust through evaluation, not
  invisibility.

**The advisor is a session, not a call** (`AI/AdvisorSession.swift`): one `DynamicProfile`-backed
conversation per day — `.deep` on-device reasoning (a pinned prior for the device A/B), the
600-token cap, a bounded history window, and two ungated read-only tools (`task_details(id)`,
`yesterday_outcome()` — snapshot-backed, candidate-ids-only, call counts in `PlanMetrics`).
Mid-day re-entry is a **delta turn** ("SINCE THIS MORNING: …" → the complete updated plan) with
the morning transcript as continuity — reconstructed from a digest after a process restart. The
candidate cap is **context-measured** (floor 8 / ceiling 24) instead of a fixed guess. On-device
only; PCC stays dormant.

**The Task Advisor** (2026-08-12, the S4 → Advisor pivot; full spec in `docs/task-model.md`)
is the per-task counterpart on the detail screen: a judgment layer that replaced the three
capability cards with one surface answering *"what would make this task easier right now?"*.
The pivot mirrors this section's shape — "deterministic triggers decide which card" is reversed
the way "the model never ranks" was reversed for the Today plan: the **model judges the shape of
help** (`AdvisorMove`: nothing / advise / decide / createSteps / openBlocker), the deterministic
system stays authoritative as sensors + gate + fallback, `ValidatedReading` is the trust
boundary (drop/degrade, never substitute), a **facts fingerprint** keeps the judgment cached and
calm (same task + same meaningful context → same reading; revealed = structurally immutable
until the facts change), and **silence is a first-class outcome** at two independent tiers (the
free deterministic gate, and the model's own `nothing`). Today answers *what deserves
attention*; the Task Advisor answers *what is the best next move*. The quality signal is
**progression, not AI activity** (`AdvisorMetrics`: % of advised tasks that later moved, plus a
re-intervention rate); the acceptance test is the `-AdvisorDiagnostics` judgment eval. V1 is
deliberately call-shaped: tool calling, streaming + salvage, and per-task sessions are each
deferred behind a named tripwire until judgment quality is proven on device.

## 9. AI System — two engines + personal context

`AI/AIEngine.swift` defines the seam. **`FoundationModelsEngine`** (real on-device LLM, iOS 27) and **`HeuristicEngine`** (deterministic fallback) both conform and emit `[TaskIntent]` via `triage(rawText:context:onPartial:)`. `AppBrain` selects the engine at launch via `SystemLanguageModel.default.availability` and degrades to the heuristic on failure. **The simulator is no longer guaranteed to exercise the heuristic path** — on Xcode 27 the sim follows the host Mac's Apple Intelligence and can run the real on-device model (verified 2026-07-26); read the Inbox diagnostics footer rather than assuming. Both engines stay behaviorally consistent — the shared derivation lives in `AutonomyPolicy.tier` + `IntentResolver` (including `applyRules`, the learned-correction half both engines get for free). Use guided generation (`@Generable` + `@Guide`), not JSON parsing; **device-verify any `@Generable` schema change.**

**`TriageContext`** carries personal context per call: `personalization` (top-N learned corrections as instruction lines, built by `CorrectionProfile`) and `roster` (value snapshots backing `ResolvePersonTool`).

### Personal context as a tool (`AI/PersonalContextTools.swift`)

`ResolvePersonTool` ("resolve_person") exposes the household roster to the on-device model as a narrow, deterministic `Tool` — attached only when a roster exists. "Call Sarah about the thing" resolves to the one Sarah in the household, with the relationship as context; the returned name is used verbatim as `personReference`. The data never leaves the device. `resolveTimeframe`/`resolveProject` are deliberately absent — dates stay OUT of the model (deterministic resolution is the resolver's whole point) and there is no project concept. **Known Xcode 27 beta caveat:** guided generation can over-call tools — tighten prompt wording before assuming a code bug if triage gets erratic or slow.

### PCC escalation (shipped — the Today Plan's stronger tier)

The Today Plan generator ships a real **Private Cloud Compute** tier (`PrivateCloudComputeLanguageModel`, `AI/TodayPlanService.swift`) alongside on-device. `PlanRouting` is a simple ordered chain (§8): on-device is tried first, PCC second when entitled and available — the earlier per-day escalation logic (day shape, divergent baseline) was retired with the capacity input. Any PCC error — including an ungranted `com.apple.developer.private-cloud-compute` entitlement — reads as **unavailability**, so the router simply falls through and the feature never breaks. (On device the construction itself is gated behind the compile-time `PCCEntitlement.isGranted`, because an unentitled construction traps.)

- **Privacy is explicit and sanctioned:** on the PCC path, **task titles leave the device** to Apple's private compute (verifiable, non-retained). This is a deliberate trade for the stronger tier on the hardest days; the on-device and deterministic tiers keep everything local. The generator sends only the ranked shortlist and the **aggregated** baseline sentence — never raw `CapacityLog` history.
- Personalization uses fresh per-call instructions (the `DynamicInstructions` API is the mechanism if the session ever becomes continuous); today's stateless-per-call sessions get the same freshness from a rebuilt instructions string.

*(Capture-time escalation of low-confidence candidates remains **deferred** — the shipped PCC integration is the Plan generator's, not the composer's.)*

### Eval harness (`Project-EzraTests/RambleEvalTests.swift`)

47 hand-labeled rambles (single errands, run-ons — including six dictated no-comma run-ons the connective-aware splitter (`AI/Segmentation.swift`) exists for — judgment calls, delegation, dependencies, dates, messy speech) scored per field: segmentation, title, category, judgment, owner, blocked, due. Floors are **regression floors** re-baselined just under observed numbers (segmentation/title/judgment/blocked/due observed 100% after the splitter rebuild) — they catch degradation, they are not targets, and the harness names each miss so recalibration stays evidence-based. Engine-agnostic: the benchmark to run against the FM path on device. Re-run: `xcodebuild test … -only-testing:Project-EzraTests/RambleEvalTests`.

### Device-verify checklist (the sim can't exercise these)

1. Capture on device with Apple Intelligence on → **one final interpretation** arrives and never changes afterwards (model reasoning streams internally; the user sees no partial cards). Check `-CaptureDiagnostics` for ungrounded drops and refused late proposals.
2. Mention a roster name ("ask Maya to…") → `personReference` resolves via the tool; watch for tool over-calling (triage suddenly slow).
3. Teach a correction twice (recategorize two "gym" tasks) → the third capture applies it on device too (instructions); the sim already proves the resolver half.
4. **Today Plan, streamed:** the `@Generable` `TodayPlanSchema` fills in progressively, partial rows map cleanly (known-uuid + non-empty rationale), and `validated(against:)` drops unknown ids without reordering.
5. **Tier fallthrough:** an on-device guardrail failure falls to PCC; an absent PCC entitlement falls through to on-device/deterministic without breaking; the divergence one-shot escalates exactly once per capacity.
6. **Dynamic instructions & usage:** the personalized baseline sentence re-evaluates as the average shifts; wire `Response.usage` into `PlanMetrics` tokens (−1 until verified); profile latency with the Foundation Models Instruments template.
7. **Motion review:** frame-by-frame check of the §4.3 spring values (starting points, not locked), and confirm the haptic and visual land on the same frame (numeral, capacity selection, final plan item).

---

## 10. Navigation

Deliberately minimal — **four tabs + a floating Capture button** (`RootTabView`):

- **Today** (0) — the cinematic daily briefing (execution). Where "given everything I'm carrying, what should I actually do today?" is answered.
- **Inbox** (1) — the household activity feed, absorbing the old AI Activity Trail: all change-log entries with action-aware Undo. This is the trust surface, not a triage destination — nothing waits there for processing.
- **My Tasks** (2) — the **system of record** for all work (trust / retrieval). Deliberately un-fused from Today.
- **Household** (3) — shared execution and coordination: ownership, handoffs, blockers, household operational health.
- **Capture** — a circular button overlaid at the bottom-trailing corner, inline with the floating tab-bar capsule. Supports voice, text, photos, natural language (voice/text today; the rest reserved).

**Review / Retro are NOT destinations, and the Inbox is a feed, not a queue.** The retro is gone — its rot-fighting job is absorbed by the briefing's risks line and the day-rollover reconciliation. Screens open the composer via the `\.openCapture` environment action (and jump to the feed via `\.openInbox`), never their own sheet.

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
- **Stale-undated-work gap:** with the retro removed, the retro's do/kill/defer moment for stale undated work is gone; the briefing's risks line names overdue/blocked/undecided work, and `BrainSweeps` auto-archive is the only path for genuinely buried undated rot. Watch whether that's enough.
- **Final reset mechanism:** the plays-once trigger is one swappable predicate (`shouldReplay(now:)`, V0 = per-day); the final mechanism is held open. *(Mid-day re-entry SHIPPED 2026-08-11: the resting briefing's "Your day changed" hint — fired by new candidates or completed planned work — sends a delta turn on the per-day advisor session; see §8a.)*
- Rationale voice pass (the model's tone across many days), swipe-to-advance (V0 is tap-only), multi-profile plan orchestration, and Household-level capacity (capacity is per-user in V0).
- Image capture (`Attachment` multimodal input is a confirmed API — Vision-OCR-to-text is the sim-friendly first step), Siri / App Intents / widgets / Action Button / watch entry points, a continuous capture session (`DynamicInstructions`), Split-Into-Subtasks & Merge-Duplicate UI (`parentTaskID` plumbing exists), `recentPatterns` tool, location/calendar triggers, visible cycle progress/burndown (stays rejected — solo apps have no standup audience).

---

## 13. Future Opportunities (iOS 27 + Foundation Models)

As Apple Foundation Models and iOS mature, Today can evolve **without changing its structure**: morning/afternoon/evening framings · on-device contextual prioritization · intelligent summaries of household activity · context-aware ordering based on location, time, routines, recent interactions · privacy-preserving reasoning kept on-device whenever possible.

---

## Guiding Principle

> **Today is not a dashboard. It is an adaptive daily briefing.**

Users should leave the sequence knowing exactly what to do next — without thinking about projects, folders, priorities, or AI. The system absorbs that complexity so execution feels as effortless as using Linear for everyday life.
