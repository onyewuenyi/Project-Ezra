# Product Design Plan — the AI roadmap, audited against the shipped product

**Status:** Product design (no implementation). Date: 2026-07-24.
**Superseded in part (2026-08-12):** the per-task capability cards this audit names (`DecisionFramingService`/`ThinkingPartnerView`, the breakdown card, Unstick) were replaced by the **Task Advisor** judgment layer — see `docs/task-model.md` and `docs/PRD.md` §8. The verdicts below are a point-in-time record.
**Inputs:** the Head-of-Product Reach×Impact prioritization (12 features), `docs/PRD.md`, `docs/task-primitive-v2-spec.md` (V1+V2 shipped), `prev-docs/product-guardrails.md`, `prev-docs/product-strategy-managing-chaos.md`, and a full code audit (AI/, Models/, Features/, tests).

---

## 1. The audit — the prioritization vs. what actually exists

Verdicts are from code, not docs.

| Original priority | Feature | Verdict | Evidence |
|---|---|---|---|
| P0 | Capture graph awareness | **SHIPPED** | `ContextRetrieval` (embedding+lexical+category+recency, cap 12), `EdgeProposal` tiering, confirm-card chips, merge-at-commit with undo-resurrect, `SuppressionStore`, `EmbeddingCache`. Schema gen 9. Tested. |
| P0 | Decision framing (Task Detail) | **SHIPPED** | `DecisionFramingService` (options · tradeoffs · cost-of-waiting, computed on expand, never persisted, never recommends), `ThinkingPartnerView` in the detail's decision section, `resolveDecisionAndLog`. |
| P0 | End-of-day / next-day reflection | **PARTIAL — the write half only** | Next-open Recap scene + `TodayPlanStore.reconcileIfNeeded` write `CapacityLog`, `deferralCount`, `carriedOverCount`, `lastSurfacedAt`. But almost nothing *reads* the outcome: `carriedOverCount` is deliberately unread, the advisor prompt is stateless day-to-day, and there is no evening moment. |
| P1 | Correction learning → generalized preferences | **SHIPPED (more than the table assumed)** | `CorrectionProfile` already generalizes — `categoryOverride` (keyword-keyed), `ownerAlias`, `titleRewrite` — applied in `IntentResolver.applyRules` (both engines) *and* as model instruction lines. Threshold ≥2, cap 8. What's missing is only *broader preference classes*, not the mechanism. |
| P1 | Task decomposition | **ABSENT (plumbing ready)** | No UI, no generation. `.parent` edges, `linkParent`, `dependents(among:)` all shipped and exercised by capture child-linking; `TaskCapabilities` names break-down as an explicit placeholder. |
| P1 | Household delegation reasoning | **PARTIAL — awareness, not advice** | `HouseholdEngine` computes loads/overload/waiting/up-for-grabs; `householdNarrative` phrases it. No "who should take this" proposal anywhere. |
| P2 | Weekly review / stale reasoning | **PARTIAL — the silent half only** | `BrainSweeps` auto-archives long-stale non-judgment tasks, reversibly. No surfaced review moment; PRD §12 records the **stale-undated-work gap** as an open watch item. |
| P2 | Household operational insights | **PARTIAL** | The coordination feed already says who's waiting on whom, live. Longitudinal patterns ("this keeps happening") absent. |
| P3 | Provenance reasoning | **SHIPPED** | Verbatim `Capture.rawText`, "You said" section, `reasoning`, per-task activity timeline with per-entry Undo. Nothing further worth building. |
| P3 | Predictive suggestions | **ABSENT** | No recurrence detection, no follow-up generation. Correctly deferred. |
| P4 | NL duplicate merge workflows | **Mostly covered** | Capture-time merge + undo-resurrect + suppression ship; only a two-existing-tasks merge UI is absent, and deliberately so. |
| P4 | Narrative household summaries | **Effectively shipped** | The one-sentence `householdNarrative` *is* this feature at the right size. Growing it would violate the guardrails. |

**Score: 4 shipped, 5 partial, 3 absent.** The original roadmap's Phase 1 ("Build Trust") is complete. Phase 2 is half-built. The spec itself already points at the frontier: *"reflection is the immediate next plan after Phase 3"* (`task-primitive-v2-spec.md` §12).

### What the audit changes

The maturity ladder (Understand → Advise → Learn → Coordinate → Anticipate) survives — but the product is standing on rung 3, not rung 1. **Understand and Advise are shipped. Learn is half-shipped: the system diligently *records* outcomes and almost never *consults* them.** That asymmetry is the single highest-leverage fact in the codebase: `deferralCount`, `carriedOverCount`, `CapacityLog`, `skips`, `acceptanceRate`, and `rotRate` all exist today with essentially one small consumer (`currentRelevance`'s pull-down). Closing the read side is cheap in surface area and enormous in felt intelligence — it is what makes day 14 feel different from day 1, which is the entire retention thesis ("the value shows up in week three").

---

## 2. The revised roadmap

Design principles held throughout (from the guardrails — non-negotiable):

- **No new destinations.** Every feature lands on an existing surface (briefing, confirm card, detail, Household). Review/Retro tabs stay refused.
- **Computed, not persisted; proposal, not execution.** AI output rides the existing confirm/undo machinery. The auto-accept invariant governs capture-time inference; suggest-tier governs post-hoc actions.
- **Every feature declares its heuristic fallback** (usually "quietly absent").
- **No engagement mechanics.** The reflection loop must reduce required attention over time; a feature that adds a daily interaction is a regression.

| Phase | Theme | Features |
|---|---|---|
| **A** | **The system remembers** (finish Learn) | A1 Advisor memory · A2 Deferral escalation · A3 The reset moment · A4 Read the carryover |
| **B** | **The system helps you start** | B1 Break-this-down · B2 Inbox-confirm nudge |
| **C** | **The system coordinates** (gated on the multi-user beta) | C1 Delegation proposals · C2 Operational insights |
| **D** | **The system anticipates** (V2, needs history) | D1 Completion follow-ups · D2 Recurrence detection |

Phase C is deliberately *after* B despite its strategic appeal: `product-readiness.md` holds CloudKit/CKShare until the schema settles and a real two-person beta is staged. Delegation reasoning on a single-device household has near-zero reach; designing it now and shipping it with the beta is the right order.

---

## 3. Design briefs

### A1 — Advisor memory (the reflection loop's read side)

**Job:** make the Today briefing *continuous* — the advisor demonstrably remembers yesterday, which is the moment the product stops feeling stateless.

- **Trigger & surface:** no new surface. `TodayPlanRequest` gains a small deterministic **outcome digest** computed at generation time from data that already exists: yesterday's plan resolution (completed / carried / skipped counts + the specific carried titles), each candidate's `deferralCount` and `carriedOverCount`, and streak-style facts ("planned 3 times, untouched"). Sent as fact lines, same discipline as `PlanTaskSnapshot` — observable facts only, never AI internals.
- **AI shape:** the `AdvisorBriefing` schema is unchanged. The instructions gain one clause: the advisor may *acknowledge* continuity ("You carried 'passport renewal' over — it goes first today") and must weigh repeated deferral when selecting. The voice change is the feature.
- **Recap upgrade:** Scene 1 already reconciles the day; it may now speak one honest line from the digest ("2 done, 1 carried") instead of a bare count. Monochrome, no judgment, no streaks — reporting, not scoring.
- **Autonomy/reversibility:** none needed — generation still mutates zero task fields; the digest is read-only context.
- **Fallback:** deterministic tier ignores the digest (fact lines already carry deferral pressure via ranking). Quietly absent.
- **Guardrail check:** removes attention cost (the user stops re-explaining their day to a goldfish). No new interaction. ✅
- **Open questions:** how many days of digest (recommend: yesterday only + per-task counters — a window invites narrative bloat); whether the carried-task callout should be mandatory when a carry exists (recommend: yes, it's the trust moment).

### A2 — Deferral escalation → decision (stale work becomes a judgment call)

**Job:** answer the PRD's recorded stale-work gap *without* a review surface, and give the north-star rot-rate metric its missing mechanism: work that keeps sliding gets **converted into a decision**, because chronic deferral *is* information — the user is avoiding a call.

- **Trigger:** deterministic rule, not a model: `deferralCount ≥ N` (start N=3) or stale-past-half-the-archive-threshold, and not already `needsDecision`, not a judgment call, not blocked.
- **Surface & shape:** the existing machinery, end to end. The task gains `needsDecision` via the existing `escalateToDecision()` seam — which already forces it crisp-top of the stack, already renders the decision section, and already unlocks the Thinking Partner. `DecisionFraming` gets one new context input (`deferralCount`, days quiet) so the framing can say what this actually is: *"You've set this aside four times. Options: do it first thing while it's small · kill it — four skips may be the answer · defer it honestly to a date."* Resolution paths are the existing ones: complete, kill, defer-with-date, or resolve.
- **Autonomy:** the escalation itself is **suggest-tier in effect but silent in mechanics** — setting a flag is reversible, logged (`.ai`, "escalated"), and undoable from the trail; nothing is destroyed. `BrainSweeps` remains the eventual silent archive for what the user ignores even then — but now the archive is never the *first* thing the system says about a task.
- **Fallback:** fully deterministic — works in the sim; the framing text is the only model-dependent part (quietly absent → plain decision section).
- **Learning signal:** the resolution (did they do / kill / defer?) is a labeled outcome for future weight calibration on `currentRelevance`.
- **Guardrail check:** this is the "forces a decision on stalled items" job from the strategy doc's weekly retro, relocated into the stack instead of a ceremony. Trust checklist passes (understand/undo/correct/ignore/recover). ✅
- **Open questions:** cap on simultaneous escalations (recommend: 1 per day — the stack must not flood with forced-top items); whether escalation pauses `BrainSweeps`' clock for that task (recommend: yes — one system speaks at a time).

### A3 — The reset moment (the weekly review that isn't one)

**Job:** the periodic backlog-honesty pass, folded into a surface that already plays.

- **Trigger & surface:** on the first briefing of the week (predicate lives beside `shouldReplay` — same swappable-predicate discipline), the **risks section** of the briefing carries a *quiet-work line*: "3 things went quiet last week." Tapping it opens My Tasks filtered to those items — no new screen, no card ceremony. Each is one tap from the existing do/kill/defer affordances (and A2 will already have escalated the worst offender).
- **AI shape:** none required — the line is deterministic. The advisor may phrase it when voiced.
- **Fallback:** identical (it's deterministic).
- **Guardrail check:** monthly-review-style pattern reporting stays cut (the strategy doc's own bar: "if it just repeats the weekly retro at larger scale, cut it"). No streaks, no score. ✅
- **Open question:** whether the line belongs in risks (advisor voice) or as a resting-surface footer (always visible after the play). Recommend risks — it should be *said once*, not ambient.

### A4 — Read the carryover (calibration, invisible)

`carriedOverCount` graduates from write-only once ~4 weeks of real data accrue: a small *positive* term in `currentRelevance` (carried work was touched — it's alive, the opposite of deferral), and recalibrate the uncalibrated priors noted in spec §13.4 against observed deferral data. Invisible feature; ships as a tuning change with property tests. The distinction was recorded precisely so this moment could happen — honor it.

### B1 — Break this down — **SHIPPED**

Built, with one deliberate change from the sketch below and one addition.

- **The trigger inverted.** The sketch offered it "when `workIntent == .planning`, or effort is large, or the title reads compound". That has the primary and secondary signals backwards: the capability reduces *complexity*, so complexity triggers it. `BreakdownEligibility` is an ordered ladder — large effort → compound title → planning intent **above a lower bar** — and intent alone is never sufficient. A 15-minute "plan birthday dinner" now gets nothing; a 90-minute "renew passport" gets the card. Suppressed once the task has children.
- **Everything else landed as specced:** `TaskBreakdownService` on the `DecisionFramingService` model (on-device, generated on expand, never persisted, absent off-device), deselectable chips, one accept creating real children via `linkParent`, one reversible `"split"` entry, `Correction` rows on deselection, one level of depth, never auto-splits.
- **The undo is stricter than specced.** It spares any child the user has since completed or edited — undo promised to reverse the split, not to destroy work done since.
- **Ranking:** the parent recedes while it has open children, via a named `currentRelevance` term (`containerRecede`), not a band change.

**A2 also shipped, as the third capability.** "Unstick" is the inertia counterpart: a deterministic trigger (`deferralCount >= 3`, or quiet past half the archive threshold) and a deterministic *diagnosis* that routes into the other capabilities rather than just reflecting the deferral count back. See `docs/task-model.md`.

### B2 — Inbox-confirm nudge

**Job:** close the PRD §12 recorded gap — unconfirmed captures currently have no daily surface and can rot invisibly, which is a trust leak in the product whose thesis is honesty.

- **Design:** one line on the briefing's **resting surface** (not the played sequence): "N captures waiting for a confirm" → opens the composer's existing confirm flow. Deterministic, dismissible by acting, never a notification.
- **Guardrail check:** it's bounded-attention honesty, not re-engagement — it appears only when N > 0 and costs one line. ✅

### C1 — Delegation proposals — **SHIPPED** (schema generation 10)

Built, with the design settled differently from the sketch below in four ways worth recording. The reference is `docs/task-model.md`; this entry is the changelog.

- **The gate was reversed, not narrowed.** `AppBrain.applyOwnershipGate` is deleted and `ownerPending` retired. The proposer ladder is **total** — every task is born owned — so "unowned" now has exactly one spelling (`ownerID == nil`) produced only by a deliberate human hand-back.
- **Load is a modifier, never a selector.** `OwnerProposer` picks on *fit* (spoken name → graph adjacency → category affinity → the capturer); load can only demote an overloaded candidate or break a tie. Assigning by lower headcount, to someone with no context, is unreachable by construction. The affinity rung counts **human-established** ownership only, or rung 4's own output floods the denominator and the rung never fires.
- **The real prerequisite was not CloudKit.** It was `TodaySequenceModel.candidateTasks`, which filtered on status and never on `ownerID` — so delegated work kept appearing in the capturer's own briefing. That is fixed, and both it and the *inferred* non-self rungs are gated on `HouseholdSync.isLive` rather than roster non-emptiness: without sync, a task handed to Maya would leave your briefing and land nowhere anyone can act on it.
- **Notification is decided, not cut.** Target behavior is *notified*, with three containment rules (one per assignment, re-notify only on reassignment, source-attributed copy). It is unimplementable until sync, so the interim is a silent publish — and `AppBrain.publishAssignments` exists now purely to hold the rule that **assignment side effects bind to the Confirm event, never to the owner field being populated**.

Also shipped alongside: capture durability (a swipe-away no longer destroys an unconfirmed thought), the lifecycle collapse to four states, and the `.reference` workload exclusion. The `TaskOwner` enum migration this section used to list as a prerequisite was **already done semantically in generation 3** — `prev-docs/household-architecture.md:79-100` is stale.

Still open from the original sketch: the post-hoc Household suggestion ("'Pharmacy run' is unowned and Maya's plate is double yours") and the delegation-suppression record behind a declined suggestion. Both are sync-gated and worth building with the beta.

### C2 — Operational insights

Longitudinal patterns over the coordination feed ("the school category always ends up up-for-grabs"). **Hold until the beta produces real multi-user history**; the live feed already covers the acute case ("everyone is waiting on Alex" is computable today from `dependents(among:)` + ownership). Ship nothing speculative here.

### D — Anticipation (deferred, but with a defined first slice)

Full prediction stays V2 — it needs behavioral history that doesn't exist yet. The first slice, when it comes, is **completion follow-ups**: on `complete()`, an on-device pass over the completed task + its graph may propose *one* follow-up as a normal capture draft through the normal confirm flow ("Booked flights → check-in opens Aug 3?"). It reuses the entire capture pipeline — proposals, confirm, corrections, suppression — which is exactly why the substrate was worth building. Recurrence detection (same title cadence in capture history) rides the same channel. Nothing here requires new machinery; that's the definition of ready-later.

---

## 4. Cut list (explicit, so it stays cut)

- **NL / retroactive merge workflows** — capture-time merge + suppression covers the recurring case; a two-existing-tasks merge UI waits for evidence of real dupes surviving capture. (Original P4 — agree.)
- **Narrative household summaries beyond one sentence** — the sentence is the feature. Growth here is bloat by the guardrails' own test.
- **Provenance reasoning** — shipped in a stronger form (verbatim capture + timeline) than the proposal imagined. No further work.
- **A monthly/pattern review** — fails the strategy doc's own bar until the weekly reset demonstrably misses trends.
- **Any new tab, timer, streak, score, or notification** — standing refusals, restated.

## 5. Hygiene (surfaced by the audit — cheap, do alongside Phase A)

- `Correction.swift` header and `AppBrain.swift` comment still say correction consumption is "deferred/write-only" — contradicted by the live `CorrectionProfile` wiring. Fix the comments; they'll misdirect future work.
- When A4 lands, update `TaskRanking.swift`'s "deliberately unread" note and spec §13.4.
- PRD §12 should be re-cut after Phase A: the stale-undated-work and inbox-confirm gaps close; reflection moves from "deferred" to shipped.

## 6. What Phase A is worth (the product argument)

The strategy doc names the retention loop's reward: *"it told me the one thing to do, I did it, and I trust it caught everything else."* Today the product delivers the first two clauses. Phase A delivers the third — the system visibly *catches* what slid, remembers what carried, and forces honesty about what's dying, all through surfaces that already exist. It is the smallest set of changes that makes week three feel different from day one, and every brief in it reads existing data through existing seams. That is the definition of a substrate paying off.
