# Core Primitives & Systems

**Status:** reference. This names the building blocks the product is made of and the systems they power, so new work composes existing primitives instead of minting parallel ones. `docs/task-model.md` remains the deep reference for the task primitive's four axes; `docs/PRD.md` for product behavior. Where those documents define a thing, this one only places it.

---

## 1. The people problem, and why primitives

The product exists for one failure mode: **life admin arrives as chaos — fragmentary, spoken, interruptive — and every existing tool makes the human do the organizing.** Ezra's answer is a small set of durable primitives and an AI that composes them, so the user's only jobs are *dump it* (capture), *glance at it* (confirm), and *do it* (Today). Everything else — filing, ranking, linking, remembering, escalating — is system work.

A **primitive** here is a noun or seam that earns its existence by deleting branching elsewhere (the bloat-watch test in `docs/task-primitive-v2-spec.md` §14). A **system** is a user-facing loop that delivers value by composing primitives. The discipline that keeps the set small:

1. **One writer per fact.** Every stored field has a named mutation seam; views and engines never write around it.
2. **Deterministic trigger, model content.** Whether a feature *appears* is a pure function; only what it *says* may need the model. This is what keeps the full core loop alive on every device.
3. **Computed over persisted.** Persistence is reserved for identity, human signals, relationships, provenance, and one system cache (the attention score). Everything else derives on read.
4. **Every AI output rides confirm or undo.** Nothing the model produces becomes durable state without a human boundary (confirm) or a reversal path (change log).
5. **A snapshot per AI seam.** Each prompt gets its own context value (`OpenTaskSnapshot`, `RetrievalCandidate`, `PlanTaskSnapshot`), shaped by that prompt's budget — never a shared kitchen-sink context.

---

## 2. The primitives — three tiers

### Tier 1 · Data primitives (persisted nouns — the small durable core)

| Primitive | Where | Role | Key invariant | Writer |
|---|---|---|---|---|
| **TaskItem** | `Models/TaskItem.swift` | The unit of work; four independent axes (lifecycle · type · flags · signal) | Axes never fuse; exists only from Confirm | `TaskMutations` + status setter |
| **Capture** | `Models/Capture.swift` | One capture event: `rawText` verbatim forever + parked drafts (`draftsData`) | Raw text never mutates; a parked capture is not a task | parse writes, `commit` adopts |
| **Relationship** (blob) | `Models/Relationship.swift` | The graph: `.blocks` / `.parent` / `.related` edges, each with an `Origin` | Live edges are the only edges; human edges carry no confidence | `TaskMutations` helpers only |
| **RelationshipSuppression** | `Models/RelationshipSuppression.swift` | A remembered "no" to a proposed edge (capture-form + pair-form keys) | A rejection is a record, never a phantom edge; rows expire | resolver/commit |
| **Correction** | `Models/Correction.swift` | Free labeled pair `{field, aiValue, userValue}` from every confirm-card edit | Write-only signal; diffed against `TaskDraft.aiOriginal`; never uploaded | `commit` |
| **ChangeLogEntry** | `Models/ChangeLogEntry.swift` | One record backing both Undo and the activity trail | Undo-completeness: an arm restores *every* field its action wrote | mutation seams |
| **AttentionMetadata** | `Models/AttentionEngine.swift` | Persisted 0–100 score + contributors — the one system-owned cache | Slow inputs only; never a badge; AI never decides the band | `AttentionEngine` at seams |
| **StateVisit timeline** | `Models/TaskTimeline.swift` | One record per continuous lifecycle stay — real cycle-time data | Written only by `transition(to:now:)` | status setter |
| **EmbeddingCache** | `Models/…/EmbeddingStore.swift` | Title vectors for retrieval, revision-stamped | Implementation detail of retrieval, not a public index | triage seam |
| **CapacityLog / CapacityBaseline** | `Models/` | Daily throughput record → rolling average, advisory context only | The advisor sizes; the baseline never caps | day-rollover reconcile |
| **Household / FamilyMember / UserProfile** | `Models/` | The roster; `ownerID`/`creatorID`/`ownerOrigin` on tasks | Every task born owned; affinity counts human-established ownership only | human edits + `OwnerProposer` at commit |

### Tier 2 · Derived & policy primitives (pure functions — computed, testable, model-free)

| Primitive | Where | Role |
|---|---|---|
| **Flags** (Blocked · Blocking · Overdue · Stale) | `TaskItem` reads | Attention conditions derived on read, never stored |
| **TaskRanking / RankKey / currentRelevance** | `Models/TaskRanking.swift` | The strict-weak-order stack + the one live additive layer (±25) |
| **IntentResolver** | `AI/IntentResolver.swift` | Deterministic intents→drafts: dates, owners, backfill, learned rules — the half both engines share |
| **Segmentation** | `AI/Segmentation.swift` | Deterministic ramble→items: sentences, verb-gated spoken connectives, per-part commas, safe preamble strip — the heuristic path's parser AND the on-device timeout fallback's |
| **OpenTaskSnapshotCache** | `AI/OpenTaskSnapshotCache.swift` | The open working set as value snapshots, rebuilt on change (objects-did-change, TaskItem-filtered) instead of on read |
| **AutonomyPolicy** | `AI/AIEngine.swift` | silent / suggest / ask tiering; the judgment-call carve-out |
| **TaskCapabilities** + **BreakdownEligibility** + **StallDiagnosis** | `Models/` | Which help a task is offered — complexity / uncertainty / inertia; all triggers pure |
| **RecommendedAction** | `Models/TaskMutations.swift` | The single CTA, or none — lifecycle-driven |
| **OwnerProposer** | `AI/OwnerProposer.swift` | Total, deterministic ownership ladder; load modifies, never selects |
| **ContextRetrieval** | `AI/ContextRetrieval.swift` | The capture-graph candidate package (embedding + lexical + category + recency, cap 12) |
| **PlanRouting / GeneratedPlan.validated** | `AI/TodayPlanService.swift` | Tier chain (on-device → PCC → deterministic) + the anti-hallucination guard |
| **TodayQueries / TodayPlanStore.shouldReplay** | `Features/Today/` | Recap/candidate queries + the one plays-once predicate |

### Tier 3 · AI primitives (the Foundation Models seams — one model, many systems)

The iOS 27 on-device model is itself treated as a primitive with named capabilities, each wrapped once and reused:

| Primitive | Where | What it gives every consumer |
|---|---|---|
| **AIEngine seam** | `AI/AIEngine.swift` | Two engines, one contract: `triage(rawText:context:onPartial:)` → `[TaskIntent]`; graceful degradation is structural |
| **TaskIntent / TaskDraft / EdgeProposal** | `AI/TaskIntent.swift`, `AIEngine.swift` | The engine's output vocabulary — raw expressions, never resolved facts |
| **TriageContext** | `AI/AIEngine.swift` | Per-call personal context: learned instructions, roster, retrieval candidates, suppressions |
| **ModelRun / ModelDeadline / ModelResult / ModelMetrics** | `AI/ModelRun.swift` et al. | The one call seam: availability, deadline, cancellation, salvage, error vocabulary, local metrics — a service is only its prompt and its parsing |
| **Guided generation** (`@Generable` + `@Guide`) | every FM service | Typed model output; no JSON parsing; device-verify on schema change |
| **Streaming partials** (`streamResponse` + `PartialBox`) | capture, Today plan | Progressive candidates; deadline hits salvage the last viable partial |
| **Tool calling** (`ResolvePersonTool`) | `AI/PersonalContextTools.swift` | Narrow, deterministic personal-context tools; attached only when useful |
| **Instructions personalization** | `AI/CorrectionProfile.swift` | Learned corrections as per-call instruction lines — and as `DynamicInstructions` content in the continuous session |
| **CaptureSessionPool** | `AI/CaptureSessionPool.swift` | Prewarmed single-use capture sessions, fingerprinted on instructions+roster; the REAL prefix (instructions + prompt head) warms behind the sheet animation |
| **CaptureConversation** | `AI/CaptureConversation.swift` | The continuous capture session (iOS 27 `DynamicProfile`/`DynamicInstructions`/`historyTransform`): one session per composer session, each parse a TURN (full text → suffix-only continuations → revision), history bounded. **Measured-not-shipped** — the `-CaptureDiagnostics` A/B arm; default flips on device evidence |
| **Token accounting** | `AI/Metrics.swift` + `tokenCount`/`contextSize` | Every on-device parse counts its exact prompt against the model's context (footer: `812/4096 tok`) — the evidence context budgets are designed on |
| **DuplicateSweep** | `AI/DuplicateSweep.swift` | Existing-pair dedupe: deterministic prefilter (embedding + lexical floors, suppression-aware, capped) → model judge via `ModelRun` → ≥0.85 kill-don't-delete merge, Inbox-logged, undo reopens + suppresses. The auto-accept invariant's destructive tier extended to existing pairs; absent off-device |
| **PCC tier** | `AI/TodayPlanService.swift` | The stronger private tier for the hardest generations; absence reads as unavailability |
| **Prewarm** | `AI/ModelWarmup.swift` + `CaptureSessionPool` | Cold-start amortized behind covers (Recap plays while the advisor reasons; capture warms its true instruction prefix at sheet-present) |

---

## 3. The systems — where value is delivered

Each system is a loop the user feels; each is listed with the primitives it composes and its no-model fallback.

### S1 · Capture — the ramble pipeline (**the #1 system**)
*Dump everything in one breath; leave with real, linked, owned tasks — one glance, one tap.*
**Loop:** ramble (voice/text/**photo** — a voice-first listening state with level meter, visible silence countdown, two-tone volatile/finalized transcript; a library photo OCRs through `ImageTextExtractor` into the same field) → **rolling parse** (400ms debounce · 1.2s max-wait · chain-on-completion; a running parse is never cancelled by new input) → engine `triage` streams `TaskIntent`s on a pooled, prefix-warmed session — **candidates ride the chain** (the first parse of a burst prompts candidate-blind; retrieval runs concurrently and feeds the next parse's prompt; a single-shot capture chains one enrichment re-parse) → `IntentResolver` drafts + backfills every field → **Confirm** ("Add N") → `commit` creates tasks, writes Corrections, merges duplicates, links edges, suppresses rejections.
**Composes:** AIEngine · TaskIntent/TaskDraft · TriageContext · ContextRetrieval · Segmentation · OpenTaskSnapshotCache · CaptureSessionPool · IntentResolver · OwnerProposer · AutonomyPolicy · Capture · Correction · Relationship/Suppression · ChangeLog.
**Fallback:** `HeuristicEngine` — instant, deterministic, with the same connective-aware `Segmentation` (a dictated run-on splits, never a mega-task) and an honest low-confidence class (a never-verified line renders the "?" card state); proposals and work-intent classification quietly absent.

### S2 · Today — the advisor briefing
*Once a day: "given everything I'm carrying, what should I actually do?"*
**Loop:** Recap cover (pure query) plays while the advisor reasons → `AdvisorBriefing` (headline · chosen actions · tradeoffs · risks) → validated → tappable plan.
**Composes:** TaskRanking (candidate provider) · PlanRouting · ModelRun · PCC · prewarm/salvage · TodayPlanStore · CapacityBaseline (context only) · ChangeLog ("planned").
**Fallback:** deterministic top-N by rank with fact lines — voiceless, never blocked.

### S3 · Attention & ranking — the ordered list
*The user never reorders; position is the system's honest opinion.*
**Composes:** AttentionMetadata (slow score) · currentRelevance (fast layer) · Flags · RankKey · SignalMarker.
**Fallback:** none needed — fully deterministic by construction.

### S4 · Capabilities — help where the task is stuck
*Complexity → Break it down · Uncertainty → Thinking Partner · Inertia → Unstick.*
**Composes:** TaskCapabilities · BreakdownEligibility · StallDiagnosis · DecisionShape (the choice-wording lexicon — Decision retired from axis 2, 2026-08-08) · ModelRun services (framing incl. the grounded recommendation, breakdown) · Relationship (`.parent` on accept) · ChangeLog ("split").
**Fallback:** triggers identical everywhere; model-authored cards absent off-device, Unstick renders identically.

### S5 · Learning — the correction loop
*Every confirm-card edit teaches; attention required goes down over time, never up.*
**Composes:** Correction · CorrectionProfile (rules + instruction lines) · IntentResolver.applyRules (both engines) · Suppression (a "no" that sticks).
**Fallback:** rules apply deterministically on every engine.

### S6 · Trust — reversibility & data safety
*Every AI action visible, attributable, undoable; the store never silently loses work.*
**Composes:** ChangeLogEntry/Undo · Inbox feed · Metrics (acceptance, local-only) · StoreResetRecord · DataExport · backups.
**Fallback:** n/a — this system is the fallback.

### S7 · Household — coordination (dormant, sync-gated)
*Built and inert by design until `HouseholdSync.isLive`.* Ownership plumbing, publish boundary, HouseholdEngine awareness. Deliberately receives **no further investment** until sync.

---

## 4. Primitive × system matrix

|  | S1 Capture | S2 Today | S3 Ranking | S4 Capabilities | S5 Learning | S6 Trust | S7 Household |
|---|---|---|---|---|---|---|---|
| TaskItem (4 axes) | creates | reads | reads | reads | — | logs | reads |
| Capture | ● owns | resting line | — | — | provenance | prune logged | — |
| Relationship (+Suppression) | proposes/links | risk facts | blocked/blocking | parent on split | suppression = "no" | linked/split undo | dependents |
| Correction → Profile | writes+applies | — | — | — | ● owns | — | — |
| AttentionMetadata + currentRelevance | stamps at commit | candidate order | ● owns | stall inputs | — | — | — |
| ChangeLogEntry | filed/merged | planned | — | split | — | ● owns | feed |
| AIEngine + TriageContext | ● owns | — | — | — | instructions in | — | — |
| ModelRun seam + deadlines | (capture excluded, own cadence) | tiers+salvage | — | framing/breakdown | — | metrics | narrative |
| PCC | deferred | ● shipped | — | — | — | — | — |
| OwnerProposer | at commit | filter (gated) | — | — | affinity denominator | assigned undo | ● when live |
| StateVisit timeline | — | recap/reconcile | startedBoost gate | stall clock | — | trail | — |

`●` = the system that owns the primitive's semantics.

---

## 5. Rules for adding to this document

- A new noun must pass the bloat-watch test: it earns its place only if minting it **deletes branching** (suppression did; an `EngagementRecord` wouldn't).
- A new model call site must go through `ModelRun` (or, for capture, the engine seam) — never a raw `LanguageModelSession` in a feature.
- A new system must name its fallback in one sentence before it is built.
- Schema additions are frozen-by-default (generation 10 spent the clean-break budget); prefer derived layers and the existing blobs' versioned envelopes.
