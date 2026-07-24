# Task Primitive v2 — Identity, Relationships, Computed Reasoning

**Status:** Draft for product-owner review. Scope: the primitive changes that power the two P0s — **Capture Graph Awareness** and **Decision Framing** — plus the Attention Engine that replaces user-facing priority. Supersedes the "Priority" third of the three-dimensions model in `docs/PRD.md` when accepted; Status and Flags dimensions are untouched.

---

## 1. Principles

1. **The system proposes; the user decides.** Every AI output in this spec is a proposal surfaced through the existing confirm/undo machinery. High confidence may *pre-select* an option; it never *executes* one. (Always-confirm is unchanged and constitutional.)
2. **Computed, not persisted.** Reasoning layers (attention, intent-driven capabilities, decision framing) are derived. Persistence is reserved for identity, user signals, relationships, and one system-owned cache (the attention score) that exists solely so the product works when the AI doesn't.
3. **AI is optional at every layer.** Each feature declares its heuristic-fallback behavior (usually "quietly absent"). The sim and non-Apple-Intelligence devices keep the full core loop.
4. **Small durable core.** No speculative node types (locations, goals, habits, projects). The graph grows by adding edge kinds, not by widening the task.

---

## 2. The task primitive

### 2.1 Identity core (persisted, mostly unchanged)

`title`, `notes`, `dueDate`, `ownerID`, `creatorID`, `category`, `effortMinutes`, `status`/`stage` (unchanged, incl. every setter invariant), `needsDecision` (unchanged, constitutional — see §6), capture provenance (`reasoning`, raw-capture link, `aiOriginal` diffing), timestamps.

**No new `objective` field.** Decision framing draws on the existing provenance chain (raw capture text, `reasoning`, "You said"). Revisit only if framing demonstrably needs a user-stated goal the capture didn't contain — a cheap later bump under clean-break.

### 2.2 User signals (persisted, user-owned — NEW)

- `isUrgent: Bool` — the user's one-tap "this matters now."
- `dueDate` doubles as a signal (already exists).

*(`isPinned` shipped in V1 and was retired shortly after — see §11.1. A manual float-to-top override competed with the very score it was meant to complement, so Urgent is the only user Signal.)*

These replace the five-level priority picker everywhere in UI. They are inputs to the Attention Engine, never rankings themselves.

### 2.3 The attention score (persisted, SYSTEM-owned — renamed field)

`priorityRaw` → **`attentionScoreRaw`**. The cached output of the Attention Engine (§3). Users never see or set it; no UI renders it as a value. It exists so deterministic ranking, offline behavior, fallback paths, and future widgets survive AI absence.

**User-facing "priority" is removed as a concept**: retire `PriorityBadgeView` bars on rows, the detail priority chip, and the row context-menu Priority ▸. The row's leading signal slot renders only user signals (Urgent marker, Pin glyph) — nothing otherwise. *(Documented reversal of the Linear-parity badge, one week after shipping.)*

### 2.4 Cached inference (persisted, nullable — NEW)

`workIntentRaw: String?` — enum `action | decision | planning | waiting | reference`. Stamped at confirm by the engine, refreshed when title/notes materially change, **nil on the heuristic path** (detail simply shows no capability section). Never exposed as a label; it selects which computed capabilities the detail offers (thinking partner for `decision`, break-into-steps for `planning`, etc.).

**Guard:** intent inference must never write `needsDecision`. The judgment carve-out (confirm ≠ resolve; only `resolveDecision()` clears) applies to the flag exactly as today.

### 2.5 Computed layers (never persisted, unchanged mechanics)

`displayStatus`, Blocked/Blocking/Overdue/Stale, assessment — all stay derived on read. New: capability selection (from intent), decision framing content (§6), proposal chips (§5).

---

## 3. The Attention Engine

Replaces "AI sets a priority level once at capture" with "the system continuously owns attention."

- **Score:** a small bounded scalar (recommend an ordinal 0–100; internal only). Written by deterministic base rules — urgency signal, due proximity, effort, judgment flag — plus AI-derived adjustment when a model pass runs (capture, replan, reflection). AI adjustments are change-logged (`.ai`, reversible) like any AI action.
- **Comparator:** `TaskRanking` stays a lexicographic strict-weak-ordering. The attention score replaces **only the priority component**. Precedence becomes: Needs Decision forced top → Blocked sinks → attention score → Blocking boost → Overdue boost. Blocked/Blocking/Overdue remain **derived live at compare time — never baked into the cached score** (no midnight staleness, no stale-after-blocker-change).
- **Recompute triggers:** capture commit, confirm, any signal/due edit, first open of the day, reflection pass. Deterministic rules always run; AI adjustment only when available.
- **Property tests:** the existing strict-weak-ordering suite extends to the new components.

---

## 4. The Relationship entity (NEW — the graph's edges)

One entity replaces and generalizes the current blocker storage:

```
Relationship { id, kind, sourceTaskID, targetTaskID,
               provenance (.ai | .human), confidence (Double),
               dismissed (Bool), createdAt }
```

- **Kinds and their semantics (semantics live in code, per kind):**
  - `blocks` — hard. Derives the Blocked flag; sinks in ranking. Absorbs today's `Blocker` (external waits keep their existing representation or become a `blocks` edge with a nil target + phrase — implementer's choice, behavior identical).
  - `parent` — hard. Subtask containment (absorbs `parentTaskID`); drives future decomposition UI.
  - `duplicate` — proposal-only. Exists only as an undismissed AI proposal or a human-confirmed merge record; **never auto-merges**.
  - `related` — soft. Inferred, display-only. **Never hand-curated**: users can dismiss, not create.
- **`dismissed` is a tombstone:** a rejected proposal is never re-proposed for the same pair.
- All AI-authored edges carry confidence and ride the confirm card (creation-time) or the change log (post-hoc), reversibly.

---

## 5. Capture Graph Awareness

The capture pipeline gains a retrieval step and a proposal channel; parsing is unchanged.

1. **Context package** (built deterministically, before the model call): top-N candidate tasks by a blend of lexical overlap, **`NLEmbedding` sentence similarity** (on-device, deterministic, solves "Renew passport ≈ Passport renewal paperwork" without model tokens), shared category, and recency; plus the roster and the last few captures. Sent as context lines, not the database. Cap N hard (~12).
2. **Model output extends `TaskIntent`** with proposed edges: `duplicateOf(candidateID, confidence)`, `childOf(candidateID, confidence)`, `blocks/blockedBy(candidateID, confidence)` — ids restricted to the context package (anti-hallucination: `validated(against:)`-style guard drops unknown ids).
3. **Confirm card chips**, confidence-tiered:
   - **High (≈ ≥0.85):** chip rendered with the action **pre-selected** ("Merge into 'Passport renewal paperwork' ✓ / Keep both") — one tap to reject, zero taps to accept along with the normal confirm. Never executes without the confirm.
   - **Mid (≈ 0.5–0.85):** chip rendered unselected, asks.
   - **Low:** suppressed entirely.
4. **The minimal merge verb ships with this feature** (not later): accepting a duplicate chip folds the draft into the existing task (title kept, capture provenance appended, no new task created) with a reversible change-log entry. Retroactive/NL merge workflows remain out of scope.
5. **Missing-structure proposals** ("schedule taxes after W-2 arrives" → propose creating "Receive W-2" + edge) ride the same card as an additional draft + edge chip.
6. **Heuristic fallback:** `NLEmbedding` + lexical duplicate detection still runs (it's deterministic); only the model-inferred relations are absent. Chips render identically.
7. **Beta caveat:** tool-calling is deliberately NOT used here — retrieval is pre-computed into the prompt (avoids the documented iOS 27 guided-generation tool-over-calling bug). Revisit tools when the bug clears.

---

## 6. Decision Framing (the Thinking Partner)

- **Trigger:** `workIntent == .decision` OR `needsDecision` (flag wins; see §2.4 guard).
- **Content (computed on demand, never persisted):** the decision's 2–3 real options, what each trades away, and the cost of waiting — generated on-device from the task's provenance chain + related edges. Rendered in the existing `decisionSection` as a "Thinking partner" expansion.
- **The user resolves.** The section's only actions are the existing `resolveDecision()` affordances; framing text is never a button that decides.
- **Fallback:** section absent (today's plain decision section remains).
- **Latency:** generate on section expand (not on detail open); reuse the prewarmed session from the Today reliability work.

---

## 7. Learning re-aim

Priority-level corrections retire with the picker. New labeled pairs, all flowing into the existing `Correction` store: Urgent taps (and removals), due-date edits, duplicate-chip accept/reject, edge dismissals. `CorrectionProfile` consumes them unchanged in mechanism. `RambleEvalTests` drops the priority-field floor and gains duplicate-detection precision/recall fixtures (extend the fixture set with near-duplicate rambles).

---

## 8. Migration & rollout

- **One clean-break bump: `schemaGeneration` 6 → 7** (renamed/repurposed `attentionScoreRaw`, new `Relationship` entity, new signal fields, `workIntentRaw`). No data migration, per policy.
- **Order of implementation:** (0) Today-pipeline reliability fix (already planned — prewarm/salvage/typed errors; everything here reuses it) → (1) schema + Attention Engine + ranking swap + signal UI (retiring the priority UI) → (2) Decision Framing (small, independent, demo-able) → (3) Capture Graph Awareness (retrieval → proposals → merge verb).
- **Device-verify** every `@Generable` change (sim can't exercise them), per house rule.

## 9. Resolved design questions

1. **Related tasks:** inferred + dismissible, never hand-curated (§4).
2. **BlockedBy:** distinct `kind` on shared storage; hard semantics stay per-kind in code (§4).
3. **Objective:** not a field; provenance chain serves framing (§2.1).
4. **Work intent:** cached at confirm, invalidated on material edit, nil on heuristic path (§2.4).

## 10. Out of scope

Location/goal/habit/project nodes; auto-merge at any confidence; any manual-reordering handle (position is always computed, never dragged); retroactive merge UI; Today advisor changes beyond consuming the new edges as candidate context.

## 11. Open items — RESOLVED (V1 implemented)

1. **Pin vs. Needs Decision precedence** — **MOOT: the Pin signal is retired.** It was resolved as "Needs Decision forced top, then Pinned (floating even above a blocked sink), then Blocked, then attention score", and shipped that way; Pin was then removed outright, because a manual float-to-top override competed with the score it was meant to complement. Precedence is now Needs Decision → Blocked → attention score → Blocking → Overdue. Judgment still surfaces first. (`TaskRanking.stackOrder`.)
2. **Attention score domain** — RESOLVED: ordinal **0–100** (`AttentionMetadata.score`), additive within-band only.
3. **Who writes attention** — RESOLVED: **capture-time only initially** (`AppBrain.commit` stamps; the mutation seams recompute on signal/graph changes). Reflection/replan write is deferred (smaller blast radius) until reflection ships.

## 12. Implementation status (V1 shipped)

The whole primitive is built and green:
- **Storage (locked, §0):** one `relationshipsData` JSON blob of `[Relationship]` on TaskItem, versioned (`RelationshipStore`, v1), absorbing the old `blockersData` + `parentTaskID`. `blockers`/`parentTaskID` are read-only derived views; the four hardening measures ship (mutation choke point via `TaskMutations`, versioned payload, DEBUG `Relationship.validate`, and the `RelationshipTests` operation-sequence property test).
- **Persist-slow / compute-fast:** `AttentionMetadata` persists only slow inputs (urgent signal, AI importance, effort shape, graph centrality). Fast facts (overdue/blocked/blocking/needsDecision) stay live comparator components in `TaskRanking`. "The AI never decides the band" holds by construction; `AttentionEngineTests` proves fast facts are absent from the score.
- **Vision (recorded, not built):** the five-primitives north star (Knowledge / Context / Reasoning / Execution / Learning — every surface is a UI onto those); a future **Knowledge Engine** is the home of graph enrichment / entities / goals; **unified Reason objects are deferred** until a second explanation consumer exists (rule of three — today only attention explains itself); **reflection is the immediate next plan after Phase 3**; and the day-level optimizer remains the Today advisor (attention feeds it — no ExecutionEngine wrapper needed).

## 13. V2 addendum — relevance + suppression substrate (2026-07-23, schemaGeneration 9)

External review of this spec + the V1 implementation drove one further clean-break release. Adopted by the decision rule *"everything that adds user value or removes friction, regardless of effort"*; only the `aiImportance` → `intrinsicImportance` rename was declined (pure cosmetics).

1. **`Relationship` v2 — `Origin`, and tombstones leave the type.** `provenance` + `confidence` became `Origin` (`.human` | `.inferred(confidence:)`): a human edge structurally cannot carry a confidence, an inferred one cannot omit it. `dismissed` is gone — live edges are the only edges; every derived view and guard reads the list unfiltered. **Blob-over-entity expiry condition (explicit):** revisit `relationshipsData` when a consumer needs edges without the task set loaded, when `Kind` exceeds ~6 cases, or when household sync needs edge-level granularity — it expires deliberately, not by surprise.
2. **Pair-owned suppression (`RelationshipSuppression` / `SuppressionRecord`).** A rejected merge/link is a suppression record, never a phantom edge. Two key forms because the capture path can never match a pair key (every capture mints a new task id): the **capture form** keys on (target, normalized **draft title** — never the raw Ramble text, which would never exact-match twice), closing the user-visible "I rejected this and it keeps suggesting it" recurrence; the **pair form** (duplicate: symmetric canonical key; parent: directional) serves both-tasks-exist consumers (future dedupe sweeps). Bounded: rows expire past `SuppressionStore.maxAge` (~180d) and orphaned rows prune lazily at load. This also fixed a live gap: V1's tombstone→retrieval wiring was half-connected (`excluding:` never passed; `dismissedDuplicateIDs` never consumed) and directional.
3. **The auto-accept invariant, and the `childOf` carve-out.** Capture-time inference is auto-accepted; no confidence value gates whether an inferred field is applied — the Confirm-Creation card is the only human-in-the-loop boundary. The single exception is inference that destroys or merges user data: `duplicateOf` keeps the 0.85/0.5 tiering; `childOf` (additive + reversible) is auto-accepted at ≥0.5, so `.undecided` is duplicate-only (V1's undecided-child silently did nothing at commit).
4. **Deferral facts + `currentRelevance` (the decay fix — one mechanism, both problems).** No persisted decay term; importance stays slow, relevance is computed live. New TaskItem facts: `deferralCount` (planned-and-untouched — the true skip), `carriedOverCount` (planned-worked-unfinished; **written but deliberately unread** by ranking until real data justifies a weight — the distinction can't be backfilled), `lastSurfacedAt`, `lastUnblockedAt` (stamped at the unblock/resurface moment — nothing else survives edge removal), and `lastHumanTouchAt` (the **human clock**, stamped only by `touchHuman()`; `updatedAt` is bumped by system paths like capture-time edge writes, so staleness, Stale detection, and the reconcile discriminator all read the human clock). `TodayPlanStore.reconcileIfNeeded` is the write seam. `TaskRanking.currentRelevance` (staleness/deferral pull-downs; recent-unblock/new-dependent/related-due-proximity pull-ups; clamped ±25) is summed with the persisted score into `RankKey.effectiveAttention` — **precomputed once per snapshot, never evaluated in the comparator** — the one deliberate additive layer, inside precedence component 3 only. The reserved `deferralPattern` contributor was deleted: deferral lives in the live layer where it belongs. Starting weights are uncalibrated priors; recalibrate against accrued deferral data.
5. **`EmbeddingCache`** — retrieval title vectors in their own entity (never riding a task-list fetch): `taskID` / Float32 `vector` / `sourceHash` (hash of the normalized title actually embedded — staleness with no edit hooks) / `revision` (`NLEmbedding.currentRevision`; cross-revision cosine is meaningless, mismatched rows are deleted unread) / `computedAt`. Read-through in-process memo keeps `ContextRetrieval` a sync pure function; a bounded fresh-embed budget (~20/capture) + lexical fallback keeps capture latency flat. Persistence rides the app's single write context at the debounced triage seam — a deliberate deviation from a background context, because this codebase is single-coordinator by design (multi-coordinator variants corrupt class binding; see `PersistenceStack`). Evict-on-completion happens lazily at warm-up; a reopened task re-embeds on its next capture (accepted cost, not a bug). The cache is an implementation detail of retrieval, not a public index, until a second consumer needs raw vectors.
6. **Objectives-lite.** Parent titles now ride as explicit context — the retrieval fact line gains `step of "<parent>"`, and `DecisionFraming` names the umbrella ("Part of the larger goal: …") instead of flattening it into related titles. Still no `objective` field (§9.3 stands).

## 14. Bloat-watch adjudications (2026-07-24)

The primitives field-guide raised five flags — "a couple of nouns that are secretly the same noun wearing two hats." Adjudicated against the code; two were real, three pass the primitive test:

1. **Correction "priority" ghost — REAL, fixed.** `Correction.fieldCorrected`'s doc still listed `"priority"`; the diff writes `"urgent"` (full vocabulary: title, category, dueDate, urgent, owner, effort, blocker, blocks, duplicate, parent). `docs/PRD.md` claimed an `inferredPriority` backfill (no such symbol) and priority as a rendered confirm field. Both corrected; a `TaskRow` comment naming a "Priority" menu item (the menu actually renders Urgent) fixed too.
2. **WorkIntent vs needsDecision — KEPT; the wall is structural, not prose.** `WorkIntentContext` physically excludes the flag (the classifier *cannot* read it); the two have disjoint writers and different lifetimes — `needsDecision` is a sticky **obligation** discharged only by a human act (`resolveDecision`), `workIntent` is a cached **observation** the classifier may refresh at will. They meet at exactly one site, the OR in `TaskCapabilities.available` — composition, never conversion. Obligation ≠ observation: different lifetime, different consumer → two primitives, per the test.
3. **Snapshot proliferation — NOUNS KEPT, derivations unified.** `OpenTaskSnapshot` / `RetrievalCandidate` / `PlanTaskSnapshot` stay separate: a snapshot per AI seam, shaped by that prompt's context budget, is the discipline (merging would smuggle context across prompts). The *real* rot was underneath: the due-day-delta calendar math existed in four independent copies and the reverse-edge walk in two. Now `TaskItem.daysUntil(_:now:)` is the one due-delta derivation (retrieval fact lines, plan snapshots, ranking due-proximity, importance backfill) and `TaskItem.dependents(among:)` the one reverse walk (`isBlocking` + `PlanTaskSnapshot.blocksTitles`). Fact-line output strings are byte-identical.
4. **Importance cluster — KEPT; three lanes, one legal crossing.** `confidence` is *epistemics* (the AI's certainty about its own parse → autonomy tier + the birth `needsDecision` derivation; never read by ranking). `aiImportance` is *stakes* (an attention contributor only — not even a task column; it lives inside `AttentionMetadata` as `carriedImportance`). `isUrgent` is the *user's now-signal* (attention contributor + `RankBand`). No conversion site exists anywhere in the code. The law: **they may sum (as independent contributors inside the attention score), never convert.**
5. **The five facts — FIELDS, not a noun.** `deferralCount` / `carriedOverCount` / `lastSurfacedAt` / `lastUnblockedAt` / `lastHumanTouchAt` are Facts on the existing task noun, fully seamed (`TodayPlanStore.reconcileIfNeeded`, `TaskMutations.touchHuman`, `TaskRanking.currentRelevance`) and tested. A stored `EngagementRecord` would add a codec and remove zero branching — the test's exact definition of a field. They are one *concept* (the engagement clocks, grouped and documented as such) without being one *noun*; suppression earned its noun precisely because minting it deleted branching, and this wouldn't.
