# Managing Chaos, Effortlessly: Product Strategy & Vision

## Mission Statement

An AI-managed personal task system that takes over the operational overhead of staying organized, so people make progress on what matters instead of maintaining a list that slowly rots.

## Problem Statement

Every personal task app has converged on the same feature set (fast capture, reminders, recurring tasks, calendar sync, natural-language and AI capture) and people still churn out of all of them, which means the bottleneck was never capability. The real failure is trust decay: capture is effortless, so tasks pile up faster than they resolve, backlogs turn into graveyards of overdue items, and the user stops believing the app reflects reality or that opening it will help. At that point starting over in a new app feels easier than cleaning up the old one, and the cycle repeats. The status quo doesn't cost the user a missing feature; it costs them a system they can no longer trust, and the recurring effort of migrating and rebuilding from scratch.

## Solution Summary

The product inverts the mental model: today the user manages tasks, here the AI manages the task system and the user just manages their life. Every management decision that today falls on the user (which project this belongs to, what priority it is, whether it's stale, whether to defer or break it down or archive it) is handled automatically when the system is confident and the action is safe, and surfaced for a one-tap confirmation only when confidence is low or the action is costly. The result is a list that stays continuously current, honest, and bounded, so that every time the user opens the app it answers "here's what to do next," not "here are 437 tasks." Progress is the goal; management is overhead the product absorbs.

## Target User

The initial acquisition beachhead is the productivity-app graveyard crowd: people who have downloaded and abandoned Todoist, TickTick, Things, or Notion at least once (often more), who feel the pain of list rot most acutely and are actively skeptical that another task app can help. The broader served market is left intentionally open to be shaped by real usage; the beachhead exists because a narrow, high-pain first audience is what makes the product's core transformation land and gives the founder-led content a specific person to speak to, not because the product is limited to them.

## Strategic Positioning

The product wins on a single principle no competitor is built around: the system takes responsibility for its own integrity instead of outsourcing maintenance to the user. Competitors optimize for capture (how much you can put in) and become storage; this product optimizes for honesty and bounded attention (surfacing the right few, letting dead work disappear, keeping everything actionable) which is the thing that actually retains people. AI is the mechanism, not the pitch, in the same way Linear runs on Postgres but nobody buys Linear for its database, so the marketing promise is an always-trustworthy system, and the AI is what quietly makes that promise keepable every session. The moat is experiential and compounding: the value shows up in week three, not in a screenshot, which is a hard acquisition problem but an enormous retention advantage once a user is in.

## North Star Metric

**Rot rate: the percentage of tasks that go stale (untouched past a defined threshold) before being acted on, trending down over time.** This is the truest single measure of the thesis, because it directly quantifies whether the system is staying trustworthy rather than becoming a graveyard, and it is the leading indicator of the churn that plagues the entire category. It must be paired with a guardrail (undo/reversal rate on AI-initiated tidying) so the AI can't game rot rate by aggressively auto-archiving things users actually wanted, which would drive the number down while destroying the trust it's meant to measure.

---

## Supporting Definitions (not part of the core one-pager, but load-bearing for execution)

These are the decisions made while shaping the strategy above. They belong in specs and PRDs downstream, but are recorded here so the reasoning isn't lost.

### The two-part trust thesis
Trust has two distinct components that must both be designed for, because nailing one without the other still fails:
- **Accuracy** — the system reflects reality; nothing silently lies (no task marked "today" that's actually three weeks overdue, no dead project still shown as active).
- **Bounded attention** — out of everything that's true, the system shows only what the user can act on now. Honesty without curation is just despair with better data; an accurate 437-item list still destroys trust.

### The three-tier autonomy model
Autonomy is gated on **both** confidence (a numeric score returned per AI decision) **and** reversibility of the action, set per action-class rather than one global switch (mirroring agentic coding agents' YOLO vs. confirm modes):
- **Silent** — high confidence AND reversible (e.g. re-tagging, re-prioritizing). Runs without asking.
- **Suggest** — high confidence but costly/hard to reverse (e.g. archiving, un-scheduling something time-sensitive). Surfaces a one-tap confirmation.
- **Ask** — low confidence or ambiguous intent. Asks before acting.
Silent actions still need a lightweight, non-nagging "recently tidied" trail the user can glance at and reverse, so autonomy never reads as loss of control.

### The retention loop
Friction reduction lowers the barrier to forming the habit but does not create the habit; a reward and a trigger are still required.
- **Reward** — every open reliably delivers the payoff: "it told me the one thing to do, I did it, and I trust it caught everything else." The reward is the payoff moment, never the act of capturing.
- **Trigger (key open risk)** — succeeding at making the user feel calm removes anxiety, which is the trigger most task apps secretly rely on. A positive pull trigger (well-timed proactive surfacing of "your 3 for today") must replace it, or the app gets forgotten precisely because it worked. Watch whether opens are self-initiated vs. AI-prompted; only self-initiated opens prove the habit is real.

### Acquisition: one transformation, reused three times
The product's core strength (invisible, cumulative value) is also its acquisition weakness (you can't screenshot trust). The resolution is to make one concrete, visible transformation carry the whole funnel:
- **Content hook / anchor** — a screen recording of a 200-task graveyard collapsing into 5 honest, actionable items. This is the wow moment, and it is a moment *of the actual product*, not a bolted-on AI media generator (which would acquire users on a promise the core product isn't about, reintroducing churn through the front door).
- **Onboarding aha** — the same transformation performed on the user's real, imported data (paste from notes, forward emails, import from Todoist/Reminders) within the first 60 seconds, solving the empty-state problem.
- **Channel** — founder-led build-in-public content (hub-and-spoke), which pre-sells the philosophy so users arrive already believing it.
The anchor is downstream of surfacing quality: a beautiful animation around a dumb prioritization is a lie users catch in session two. Build the brain, then make it beautiful to watch.

### Metric family (diagnostics beneath the north star)
- **Surfacing latency** — time from captured to first surfaced as a next-action. The real, instrumentable "decision latency." High means capture works but prioritization is failing.
- **Resolution honesty** — ratio of tasks ending in explicit done/killed vs. those that silently evaporate. Low means the app is becoming storage.
- **Time-to-first-payoff** — install to first experienced transformation. Must be under a minute or acquisition leaks before the habit loop engages.
- **Self-initiated open rate** — the truest retention signal (see trigger risk above).

### Open risks to revisit
1. **The return trigger** — how to make the app worth opening on a calm day without reintroducing anxiety.
2. **Time-to-first-payoff** — keeping the aha moment inside the first session rather than behind setup.
3. **Surfacing quality** — the entire strategy assumes the AI's chosen "few" are actually the right few; everything downstream of that is theater if it isn't true.

### Core loop mechanics
- **Triage inbox** — every errand starts as a quick capture (voice, text, or forwarded email/receipt) landing in one inbox, processed in a batch rather than as it arrives.
- **State, not category, is the organizing axis** — originally pitched as weekly/trip-based "runs" (e.g. "Saturday errands"); in practice that shipped as flat category grouping, which read as a second backlog next to Today rather than a real batching model. Revised to workflow-state lanes (Suggested / Ready / In Progress — a mobile-friendly Kanban-lite) with dependency chains rendered as stacked card groups — category is still there, just demoted to card metadata rather than the grouping key. Blocked and Up for Grabs aren't lanes; they're derived AI assessments a card wears inside its lane.
- **States mirror real life, not dates** — the workflow lanes (Ready, In Progress, Done) replace date-driven organization with context-driven organization, since most errands are context-bound rather than time-bound; Blocked is an observation the AI layers on top rather than a lane of its own. No location-based state; this was deliberately decided against (battery, privacy, complexity).
- **Voice/keyboard-first speed** — capture (including natural-language voice parsing) must take under a second, matching Linear's core speed edge.

### Dependency chains
Errands frequently block each other ("renew passport" blocks "book flight" blocks "request time off"), and no competitor models this. Linked errands stay hidden while blocked, and automatically resurface once their blocker clears. This is a genuinely uncontested feature gap.

### Review cadence (each tier has a distinct job, not three scales of the same summary)
- **Daily brief** — pure surfacing, today's small bounded set, no retro or reflection, purely the next-action payoff.
- **Weekly retro** — forces a decision on stalled items ("this sat for 3 weeks, still relevant?": do it, kill it, or explicitly defer). This is the direct rot-fighting mechanism.
- **Monthly review** — pattern-level, not item-level: recurring themes, neglected areas of life. Only earns its place if it surfaces trends the weekly retro can't; if it just repeats the weekly retro at larger scale, cut it.

### Optional input data as confidence levers, not just features
Calendar data and personalization inputs are optional, but they should be framed structurally as inputs to the confidence score, not bolt-on conveniences: more granted context raises the ceiling on what the AI can safely act on silently (e.g. knowing about a calendar conflict before auto-rescheduling). With no optional context granted, the system should gracefully fall back to asking more often rather than guessing.

### Monetization tension (Things 3 comparison)
Things 3's one-time-per-platform pricing (no subscription) isn't a solution to the retention problem, it's a bet that assumes retention isn't the company's problem to solve: paid once, no recurring revenue to lose if a user churns. What the model actually protects is a design philosophy, no subscription means no incentive to bolt on engagement-bait features (streaks, notification hooks, habit trackers) to fight churn, and that restraint is what makes the app feel calm and trustworthy.

This product can't copy that model. The AI performs real, recurring work (inference cost) every session, so a one-time purchase doesn't cover marginal cost the way static local software does; some recurring revenue model is structurally required. That pushes the product toward the exact incentive trap Things sidesteps: subscription revenue tempts feature bloat to reduce churn, and bloat is what turns a calm, trustworthy app into an anxious one. The resolution has to come from the core loop itself, the honest, bounded, self-tidying list, being valuable enough every session to justify the subscription on its own, without leaning on engagement mechanics to retain users. Pricing model choice (subscription tiers, usage-based, etc.) is still open, but whatever it is, it must not create pressure toward engagement features that contradict the trust thesis.
