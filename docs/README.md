# Documentation map

**The product spec is not in this repo.** It is *Ezra Product Shape v8* (2026-09-03), and it is the
source of truth for what the product is, what each system is for, how the intelligence is
paid for, and what the MVP cuts:

> https://claude.ai/code/artifact/aa4e89a0-a1ff-4ed2-b0f8-c6e227ed7014
>
> (v7 stays readable at https://claude.ai/code/artifact/fbbfbae1-f7a5-4bdd-bd6f-19454dad89ad as history.)

Read it before changing product behaviour. Where anything in this repo disagrees with it,
the artifact wins and the repo file is a bug.


**This file deliberately contains no product claims.** That is the fix for what went wrong
before: a `PRD.md` here restated the vision, the vision moved, and the restatement quietly
became a second, wrong answer that agents and future-you kept reading. An index cannot
drift, because it asserts nothing that can become false.

---

## What still lives in this repo, and why

These survive because they answer questions the product spec deliberately doesn't — the
spec says *what* and *why*, and these say *how it is built* and *how it must look*.

| Doc | Scope | Status |
|---|---|---|
| `docs/task-model.md` | The four axes — lifecycle · type · flags · signal — and the rules that keep them unfused. The deep reference the code comments point at. | In force |
| `docs/primitives.md` | The small durable core features compose, and the test a new primitive must pass. Cited by the spec's §05. | In force |
| `docs/capture.md` | Ramble in full — the voice-first arc, routing history, the deleted confidence gate, the orb's tuning traps, the eval-instrument lessons. | In force |
| `docs/advisor.md` | The Advisor in full — rung 0's floor, the fingerprint, the validation contract, the lift metric, per-rung deadlines. | In force |
| `docs/surfaces.md` | The shell (one surface, two verbs — the tab bar, the Brief and the Ask tab are all gone as of 2026-09-02, with the archaeology kept), My Tasks, the parked-captures row, and the shape-driven task detail. | In force |
| `prev-docs/design-system-managing-chaos.md` | Palette, type scale, spacing, motion, the calm-intelligence principle. | In force |
| `prev-docs/product-guardrails.md` | What the product refuses to build. The daily-nudge carve-out **closed** on 2026-09-02 with the Brief; a NEW one — the Sunday household digest — was argued from scratch on 2026-09-12, with seven conditions that are code. Also home to the 2026-09-12 telemetry boundary: user data local-first, product telemetry not. Cited by the spec's §09. | In force |
| `docs/platform-notes.md` | The iOS 27 beta specifics verified the hard way — the four capability/profile traps, Liquid Glass, guided generation. Extracted from `CLAUDE.md` 2026-09-03. | In force |
| `docs/decisions.md` | The long form of every rule in `CLAUDE.md` — the 182 KB text the 2026-09-12 rulebook was compressed from, verbatim, same headings. Grep a rule's bold lead here for its dates, reversals and measurements. To be folded into the topical docs one subject at a time, never grown. | In force |
| `docs/kinly-launch-plan.md` | The 2026-09-12 launch positioning (Kinly) layered over Product Shape v8, verbatim, plus the map of its six build-order items onto the repo — what was already true, what was built that day (telemetry boundary, live sync + one-link invite, Sunday digest, activation derivations, onboarding screenshot input), and what is deliberately not done (the rename, until the name check). A go-to-market plan, not a spec: where it and v8 disagree, v8 wins. | In force |
| `docs/cohort0-checklist.md` | The flows and failure modes the Cohort 0 Readiness Audit checks, plus the findings already ruled on. The routine reads this file rather than carrying its own list — **update it in the same change that changes a flow.** | In force |
| `prev-docs/household-architecture.md` | The identity/ownership substrate multiplayer surfaces — LIVE since 2026-09-12 (`HouseholdSync.isLive`, the one-link invite in `HouseholdSharing`). | In force |

`docs/capture.md`, `docs/advisor.md` and `docs/surfaces.md` were extracted verbatim from
`CLAUDE.md` on 2026-09-02, when that file crossed its 150k-character limit. **CLAUDE.md keeps the invariants; these keep the
reasoning, the measurements and the archaeology behind them** — so the rules stay in the
always-loaded file and the evidence stays one hop away. A rule that changes in one changes
in the other.

`prev-docs/` keeps its name: it is the superseded *generation*, and these three are the
parts of it that outlived the generation.

## What was removed on 2026-08-24, so nobody goes looking

All seven restated a product direction the spec has since replaced, or recorded a decision
the spec's §09 ledger now carries. None of them described anything the code still does.

- `docs/PRD.md` — the consolidated spec, written around the Today sequence and a
  four-tab navigation. Superseded wholesale; this file replaces it.
- `docs/capture-roadmap.md` — two capture phases. Phase B (image capture) shipped;
  Phase A survives as a one-line entry in CLAUDE.md's deferred list.
- `docs/product-design-plan.md` — a dated audit of a roadmap that no longer exists;
  self-described as "a point-in-time record".
- `docs/product-readiness.md` — the argument for not enabling CloudKit sync yet. Still
  true, and now stated where it is enforced: CLAUDE.md's schema-freeze rule and
  `HouseholdSync.isLive`.
- `docs/task-primitive-v2-spec.md` — a draft whose contents shipped. Its durable half,
  the bloat-watch adjudications, moved into `docs/primitives.md`.
- `prev-docs/lean-prd-managing-chaos.md`, `prev-docs/product-strategy-managing-chaos.md` —
  the vision and strategy, now §01–§02 of the spec.
- `prev-docs/mock-data-user-flows.md` — a walkthrough written against a status vocabulary
  (`suggested`, `ready`, `inProgress`) that the four-axis model deleted. The launch
  arguments it documented are listed in CLAUDE.md.
- `prev-docs/*.html` — mockups of the Inbox / Review / Today navigation, all three cut.

## The rule that keeps this from happening again

Product behaviour changes land in the artifact. This repo's docs cover **architecture and
craft only** — the four axes, the primitives, the design system, the guardrails. If you
find yourself writing what the product *is* into a file under `docs/`, it belongs in the
spec instead, and the copy here will be wrong within a month.
