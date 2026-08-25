# Documentation map

**The product spec is not in this repo.** It is *Ezra — Product Shape v6*, and it is the
source of truth for what the product is, what each system is for, how the intelligence is
paid for, and what the MVP cuts:

> https://claude.ai/code/artifact/fbbfbae1-f7a5-4bdd-bd6f-19454dad89ad

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
| `prev-docs/design-system-managing-chaos.md` | Palette, type scale, spacing, motion, the calm-intelligence principle. | In force |
| `prev-docs/product-guardrails.md` | What the product refuses to build, and the one notification carve-out. Cited by the spec's §09. | In force |
| `prev-docs/household-architecture.md` | The identity/ownership substrate multiplayer will surface. | In force, dormant |

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
