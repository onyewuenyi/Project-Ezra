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
