# Core Primitives & Systems

**Status:** reference. This names the building blocks the product is made of and the systems they power, so new work composes existing primitives instead of minting parallel ones. `docs/task-model.md` remains the deep reference for the task primitive's four axes; the product spec (see `docs/README.md`) for product behaviour. Where those define a thing, this one only places it.

---

## 1. The people problem, and why primitives

The product exists for one failure mode: **life admin arrives as chaos — fragmentary, spoken, interruptive — and every existing tool makes the human do the organizing.** Ezra's answer is a small set of durable primitives and an AI that composes them, so the user's only jobs are *dump it* (capture), *glance at it* (confirm), and *do it* (the Brief). Everything else — filing, ranking, linking, remembering, escalating — is system work.

A **primitive** here is a noun or seam that earns its existence by deleting branching elsewhere (the bloat-watch test, §5). A **system** is a user-facing loop that delivers value by composing primitives. The discipline that keeps the set small:

1. **One writer per fact.** Every stored field has a named mutation seam; views and engines never write around it.
2. **Deterministic trigger, model content.** Whether a feature *appears* is a pure function; only what it *says* may need the model. This is what keeps the full core loop alive on every device.
3. **Computed over persisted.** Persistence is reserved for identity, human signals, relationships, provenance, and one system cache (the attention score). Everything else derives on read.
4. **Every AI output rides confirm or undo.** Nothing the model produces becomes durable state without a human boundary (confirm) or a reversal path (change log).
5. **A snapshot per AI seam.** Each prompt gets its own context value (`OpenTaskSnapshot`, `RetrievalCandidate`, `PlanTaskSnapshot`), shaped by that prompt's budget — never a shared kitchen-sink context.
6. **Validate decoded snapshots on read; never broadcast invalidation.** Anything decoded from `UserDefaults` (today's plan cache) names ids that Core Data's change notifications can't reach. The fix is a read-time check against the live set — `GeneratedPlan.validated(against:)`, `TodayPlanStore.hasOutlivedItsWork`, `BriefView`'s live action resolution — never a `Notification` posted by whoever deleted something. One read-time check covers every cause (a clear, a merge, an undo, a future sync) and can't be forgotten by the next deleter. A cross-cutting broadcast was tried for the Settings wipe and reversed (2026-08-11): it needed per-observer context scoping to be correct at all (the unit-test host runs the app in-process against a different store), and it still only covered the one cause that remembered to post it.
7. **Two graphs may join for display, never in storage.** `.blocks` (sequencing) and `.parent` (containment) answer different questions and stay unfused as data. They meet in exactly one function — `TaskChainGrouping.prerequisites(of:within:)` — because *ordering a stack* is one question: what must come first. Fusing them earlier (writing `.blocks` edges at split time) made the umbrella read as Blocked and cost two behavioural carve-outs before it was reversed.

---

## 2. The primitives — three tiers

### Tier 1 · Data primitives (persisted nouns — the small durable core)

| Primitive | Where | Role | Key invariant | Writer |
|---|---|---|---|---|
| **TaskItem** | `Models/TaskItem.swift` | The unit of work; four independent axes (lifecycle · type — INTERNAL, AI-owned since 2026-08-11 · flags · signal) | Axes never fuse; exists only from Confirm | `TaskMutations` + status setter |
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
| **StepProgress** (`openSteps` / `stepProgress`) | `Models/TaskItem.swift` | The container reading: how far a broken-down task's steps have got. Derived from the children's `.parent` edges — a container is **not** Blocked (see rule 7) |
| **TaskRanking / RankKey / currentRelevance** | `Models/TaskRanking.swift` | The strict-weak-order stack + the one live additive layer (±25) |
| **TaskChainGrouping** (+`prerequisites`) | `Models/TaskChainGrouping.swift` | Dependency chains for the stacked card — the ONE place `.blocks` and `.parent` join, and only for display order |
| **IntentResolver** | `AI/IntentResolver.swift` | Deterministic intents→drafts: dates, owners, backfill, learned rules — the half both engines share |
| **Segmentation** | `AI/Segmentation.swift` | Deterministic ramble→items: sentences, verb-gated spoken connectives, per-part commas, safe preamble strip — the heuristic path's parser AND the on-device timeout fallback's |
| **OpenTaskSnapshotCache** | `AI/OpenTaskSnapshotCache.swift` | The open working set as value snapshots, rebuilt on change (objects-did-change, TaskItem-filtered) instead of on read |
| **AutonomyPolicy** | `AI/AIEngine.swift` | silent / suggest / ask tiering; the judgment-call carve-out |
| **TaskCapabilities** + **BreakdownEligibility** + **StallDiagnosis** | `Models/` | Which help a task is offered — complexity / uncertainty / inertia; all triggers pure |
| **RecommendedAction** | `Models/TaskMutations.swift` | The single CTA, or none — lifecycle-driven |
| **OwnerProposer** | `AI/OwnerProposer.swift` | Total, deterministic ownership ladder; load modifies, never selects |
| **ContextRetrieval** | `AI/ContextRetrieval.swift` | The capture-graph candidate package (embedding + lexical + category + recency, cap 12) |
| **PlanRouting / GeneratedPlan.validated** | `AI/TodayPlanService.swift` | Tier chain (**cloud → on-device → deterministic**, the tail unconditional) + the anti-hallucination guard |
| **TodayQueries / TodayPlanStore.shouldReplay** | `Features/Brief/` | Recap/candidate queries + the one plays-once predicate |
| **ReasoningBudget / AdvisorRouting** | `AI/ReasoningBudget.swift` | *How much cognition does this judgment deserve?* — `none`/`shallow`/`deep` from facts alone; rung selection merely implements it |
| **DeterministicReading** | `AI/DeterministicReading.swift` | Rung 0's Advisor reading: fact-only, no model, so a worthy task is never a labelled empty surface |
| **CaptureRoute** | `AI/CaptureRoute.swift` | The one routing decision — did the user draw the boundaries? `.local` (deterministic) vs `.cloud` — plus per-ramble depth |

### Tier 3 · AI primitives (the Foundation Models seams — one model, many systems)

The iOS 27 on-device model is itself treated as a primitive with named capabilities, each wrapped once and reused:

| Primitive | Where | What it gives every consumer |
|---|---|---|
| **AIEngine seam** | `AI/AIEngine.swift` | Two engines, one contract: `triage(rawText:context:onPartial:)` → `[TaskIntent]`; graceful degradation is structural |
| **TaskIntent / TaskDraft / EdgeProposal** | `AI/TaskIntent.swift`, `AIEngine.swift` | The engine's output vocabulary — raw expressions, never resolved facts |
| **TriageContext** | `AI/AIEngine.swift` | Per-call personal context: learned instructions, roster, retrieval candidates, suppressions |
| **ModelRun / ModelDeadline / ModelResult / ModelMetrics** | `AI/ModelRun.swift` et al. | The one call seam: availability, deadline, cancellation, salvage, error vocabulary, local metrics — a service is only its prompt and its parsing |
| **Guided generation** (`@Generable` + `@Guide`) | every FM service | Typed model output; no JSON parsing; device-verify on schema change |
| **Streaming partials** (`streamResponse` + `PartialBox`) | capture, Brief plan | Deadline hits salvage the last viable partial. **Capture no longer renders partials** — since the Ramble re-architecture the composer shows no structure before the reveal, so partials feed salvage only, never the screen |
| **Tool calling** (`ResolvePersonTool`) | `AI/PersonalContextTools.swift` | Narrow, deterministic personal-context tools; attached only when useful |
| **Instructions personalization** | `AI/CorrectionProfile.swift` | Learned corrections as per-call instruction lines — and as `DynamicInstructions` content in the continuous session |
| **CaptureSessionPool** | `AI/CaptureSessionPool.swift` | Prewarmed single-use capture sessions, fingerprinted on instructions+roster; the REAL prefix (instructions + prompt head) warms behind the sheet animation |
| **CaptureConversation** | `AI/CaptureConversation.swift` | The continuous capture session (iOS 27 `DynamicProfile`/`DynamicInstructions`/`historyTransform`): one session per composer session, each parse a TURN (full text → suffix-only continuations → revision), history bounded. **Measured-not-shipped** — the `-CaptureDiagnostics` A/B arm; default flips on device evidence |
| **Token accounting** | `AI/Metrics.swift` + `tokenCount`/`contextSize` | Every on-device parse counts its exact prompt against the model's context (footer: `812/4096 tok`) — the evidence context budgets are designed on |
| **DuplicateSweep** | `AI/DuplicateSweep.swift` | Existing-pair dedupe: deterministic prefilter (embedding + lexical floors, suppression-aware, capped) → model judge via `ModelRun` → ≥0.85 kill-don't-delete merge, Activity-logged, undo reopens + suppresses. The auto-accept invariant's destructive tier extended to existing pairs; absent off-device |
| **Cloud rung** (`CloudModelProvider` → `GeminiProvider`) | `AI/CloudModelProvider.swift` | The one paid rung, behind one swappable slot. Nothing above it can name a provider; `isAvailable` never constructs a model and never touches the network. PCC was deleted, not left dormant |
| **IntelligenceLedger / CloudBudget** | `AI/IntelligenceLedger.swift`, `ReasoningBudget.swift` | Rung × workload counters, local-only, written where the routing decision lands — so the gate skip and the cache hit are counted too. The daily cap is a runaway backstop, not a ration |
| **Prewarm** | `AI/ModelWarmup.swift` + `CaptureSessionPool` | Cold-start amortized behind covers (Recap plays while the advisor reasons; capture warms its true instruction prefix at sheet-present) |
| **CapabilityProfiles** | `AI/CapabilityProfiles.swift` | Per-capability session configs (temperature · reasoning level · output caps) on the `DynamicProfile` pattern — priors pinned by tests |

---

## 3. The systems — where value is delivered

Each system is a loop the user feels; each is listed with the primitives it composes and its no-model fallback.

### S1 · Capture — the ramble pipeline (**the #1 system**)
*Dump everything in one breath; leave with real, linked, owned tasks — one glance, one tap.*
**Loop:** ramble (voice/text/**photo** — a voice-first listening state with level meter, visible silence countdown, two-tone volatile/finalized transcript; a library photo OCRs through `ImageTextExtractor` into the same field) → **one parse at submit** (there is no per-keystroke work: the rolling 400ms/1.2s cadence was deleted with the Ramble re-architecture, and the canvas has zero AI presence by contract) → `triage` runs behind the orb, hedged across rungs — **candidates ride the chain** (the first parse of a burst prompts candidate-blind; retrieval runs concurrently and feeds the next parse's prompt; a single-shot capture chains one enrichment re-parse) → `IntentResolver` drafts + backfills every field → **Confirm** ("Add N") → `commit` creates tasks, writes Corrections, merges duplicates, links edges, suppresses rejections.
**Composes:** AIEngine · TaskIntent/TaskDraft · TriageContext · ContextRetrieval · Segmentation · OpenTaskSnapshotCache · CaptureSessionPool · IntentResolver · OwnerProposer · AutonomyPolicy · Capture · Correction · Relationship/Suppression · ChangeLog.
**Fallback:** `HeuristicEngine` — instant, deterministic, with the same connective-aware `Segmentation` (a dictated run-on splits, never a mega-task) and an honest low-confidence class (a never-verified line renders the "?" card state); proposals and work-intent classification quietly absent.

### S2 · Brief — the advisor briefing
*Once a day: "given everything I'm carrying, what should I actually do?"*
**Loop:** Recap cover (pure query) plays while the advisor reasons → `AdvisorBriefing` (headline · chosen actions · tradeoffs · risks) → validated → tappable plan.
**Composes:** TaskRanking (candidate provider) · PlanRouting · ModelRun · the cloud rung · prewarm/salvage · TodayPlanStore · BriefSession (the on-device tier's transcript + tools) · ChangeLog ("planned").
**Fallback:** deterministic top-N by rank with fact lines — voiceless, never blocked.

### S3 · Attention & ranking — the ordered list
*The user never reorders; position is the system's honest opinion.*
**Composes:** AttentionMetadata (slow score) · currentRelevance (fast layer) · Flags · RankKey · SignalMarker.
**Fallback:** none needed — fully deterministic by construction.

### S4 · Advisor — the smallest useful intervention
*One judgment layer per task, and its usual verdict is silence.*
**Composes:** `advisorGateReason` (the cost gate) · BreakdownEligibility · StallDiagnosis · DecisionShape (the choice-wording lexicon — Decision retired from axis 2, 2026-08-08) · TaskAdvisorFacts (the sensors as FACT lines) · ReasoningBudget · ValidatedReading (the trust boundary) · Relationship (`.parent` on accept — the only edge a split writes) · StepProgress + TaskChainGrouping · ChangeLog ("split").
The three capability cards it replaced (Break it down · Thinking Partner · Unstick) collapsed into one surface on 2026-08-12; the model judges the *shape* of help (`AdvisorMove`), the deterministic system keeps the sensors, the gate and the fallback.
**Fallback:** `DeterministicReading` — a fact-only reading on every worthy task, so an off-device or failed judgment degrades to rung 0 rather than to an empty surface. Silence stays a first-class outcome and renders as nothing at all.

### S5 · Learning — the correction loop
*Every confirm-card edit teaches; attention required goes down over time, never up.*
**Composes:** Correction · CorrectionProfile (rules + instruction lines) · IntentResolver.applyRules (both engines) · Suppression (a "no" that sticks).
**Fallback:** rules apply deterministically on every engine.

### S6 · Trust — reversibility & data safety
*Every AI action visible, attributable, undoable; the store never silently loses work.*
**Composes:** ChangeLogEntry/Undo · Activity feed · Metrics (acceptance, local-only) · **DataReset** (the user's own wipe — two scopes, work vs everything) · StoreResetRecord (ONE receipt for every wipe, voluntary or not; only the tone branches) · DataExport · backups.
**Fallback:** n/a — this system is the fallback.

### S7 · Household — coordination (dormant, sync-gated)
*Built and inert by design until `HouseholdSync.isLive`.* Ownership plumbing, publish boundary, HouseholdEngine awareness. Deliberately receives **no further investment** until sync.

---

## 4. Primitive × system matrix

|  | S1 Capture | S2 Brief | S3 Ranking | S4 Advisor | S5 Learning | S6 Trust | S7 Household |
|---|---|---|---|---|---|---|---|
| TaskItem (4 axes) | creates | reads | reads | reads | — | logs | reads |
| Capture | ● owns | resting line | — | — | provenance | prune logged | — |
| Relationship (+Suppression) | proposes/links | risk facts | blocked/blocking | parent on split | suppression = "no" | linked/split undo | dependents |
| Correction → Profile | writes+applies | — | — | — | ● owns | — | — |
| AttentionMetadata + currentRelevance | stamps at commit | candidate order | ● owns | stall inputs | — | — | — |
| StepProgress (derived) | — | — | containerRecede | ● owns | — | resolution notice | — |
| ChangeLogEntry | filed/merged | planned | — | split | — | ● owns | feed |
| AIEngine + TriageContext | ● owns | — | — | — | instructions in | — | — |
| ModelRun seam + deadlines | (capture excluded, own cadence) | tiers+salvage | — | framing/breakdown | — | metrics | narrative |
| Cloud rung | ● default (ambiguous) | ● first tier | — | ● deep band | — | — | — |
| IntelligenceLedger | records | records | — | records | — | local metrics | — |
| OwnerProposer | at commit | filter (gated) | — | — | affinity denominator | assigned undo | ● when live |
| StateVisit timeline | — | recap/reconcile | startedBoost gate | stall clock | — | trail | — |

`●` = the system that owns the primitive's semantics.

---

## 5. The bloat-watch test, and the adjudications worth keeping

**The test:** a new noun earns its place only if minting it **deletes branching**. Suppression
did — it removed a phantom-edge concept from every consumer. An `EngagementRecord` would not:
it would add a codec and remove nothing.

Three adjudications from the 2026-07-24 review are still live law, because each names a
distinction the code would silently re-fuse without them. (They moved here when
`docs/task-primitive-v2-spec.md` was retired; two others in that review were point-in-time
fixes and did not survive the move.)

**Obligation ≠ observation — `needsDecision` and `WorkIntent` stay two primitives.** They have
disjoint writers and different lifetimes: `needsDecision` is a sticky *obligation* discharged
only by a human act (`resolveDecision`), while `workIntent` is a cached *observation* the
classifier may refresh at will. The classifier physically cannot read the flag. They meet at
exactly one kind of site — composition, never conversion.

**The importance cluster — three lanes, no legal crossing.** `confidence` is *epistemics* (the
AI's certainty about its own parse → the autonomy tier; never read by ranking). `aiImportance`
is *stakes* (an attention contributor only — not even a task column; it lives inside
`AttentionMetadata`). `isUrgent` is the *user's now-signal*. The law: **they may sum, as
independent contributors inside the attention score. They may never convert.** No conversion
site exists anywhere in the code, and adding one would fuse axis 4 into the AI's opinion.

**The engagement clocks are fields, not a noun.** `deferralCount` · `carriedOverCount` ·
`lastSurfacedAt` · `lastUnblockedAt` · `lastHumanTouchAt` are one *concept*, grouped and
documented as such, without being one *noun*. Each is fully seamed
(`TodayPlanStore.reconcileIfNeeded` raises the deferral count, `TaskMutations.touchHuman`
clears it, `TaskRanking.currentRelevance` reads them). Minting a record type around them would
be the test's exact definition of a field wearing a noun's clothes.

## 6. Rules for adding to this document

- A new noun must pass the bloat-watch test above.
- A new model call site must go through `ModelRun` (or, for capture, the engine seam) — never a raw `LanguageModelSession` in a feature.
- A new system must name its fallback in one sentence before it is built. "No feature may exist only at the cloud rung" is the standing form of this.
- Schema additions are frozen-by-default (generation 10 spent the clean-break budget); prefer derived layers and the existing blobs' versioned envelopes. A *diagnostic* must never touch the model at all — use a file sidecar, as `CaptureProvenance` does.
- Product behaviour does not belong in this file. It belongs in the product spec (`docs/README.md`).
