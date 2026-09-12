# Kinly — launch plan (positioning layer over Ezra Product Shape v8)

*Recorded 2026-09-12 from the owner's plan, verbatim where it matters. Kinly is the launch
positioning and go-to-market for this codebase; it is NOT a new product spec — v8 remains
the source of truth for what the product is — and NOT a rename until the App Store and
trademark check below has been done (Kinly is already a video-conferencing brand). The
second half of this file maps the plan's build order onto the repo as of the same day.*

---

## Positioning

Kinly turns the messy stream of school emails, team texts, and screenshots into a shared
household plan that both caretakers can see and trust. The enemy is the status quo, not Cozi
or a shared calendar. The status quo is one parent carrying the mental load of translating
chaos into a plan. "Families deserve high quality software" is the mission line for the
build log. The line for parents is about splitting the load. The both-caretakers activation
metric and the positioning say the same thing.

Research preview means, stated in plain words on the landing page: free, changes weekly,
export your data any time, kids' names never leave the household except inside the AI
call, which is logged with names redacted. Open code and public build logs back the trust
claim. Ship the eval set publicly in the repo. "Here is how we know capture works" is a
credibility piece no competitor can copy. Kinly is a distribution seed and career proof,
not a monetization bet.

Before anything public, check name availability on the App Store and trademark registers.

## Launch

Two dates. Public TestFlight link at day 30. App Store submission by day 60. Build order
inside the first 30 days:

1. Analytics events and AI logging with PII redaction, before any feature work.
2. Eval set of 30 to 50 real captures gathered from the parent network with permission,
   with golden outputs, run in CI on every prompt change. Fail the build if acceptance on
   the set drops.
3. Onboarding that ends in a real result. The first screen asks for one real input — a
   forwarded school email, pasted text, or a screenshot — and the household board is born
   populated. No empty state, no setup wizard.
4. Second-caretaker invite flow. One link, install, land in a household that already has
   content. Instrument every step from invite sent to first action.
5. Privacy policy, AI disclosure, and a one-page install guide with screenshots, because
   TestFlight confuses non-technical parents.
6. A Sunday evening household digest notification. Family planning has a weekly rhythm and
   this is the retention mechanic that matches it.

Announcement leads with one human story, the moment chaos became a plan, then the ask. Two
asks to two audiences, never mixed. Parents get "try it with your partner this week." PMs
on LinkedIn get a specific critique request: the activation definition and the onboarding
flow. Pre-register the 90-day success numbers in the same post.

## Acquisition

Work the funnel backward from the household target. Assume half the parents asked will
install and half of those get their partner on; the named list therefore needs 40 to 60
parents. Target the organizer parent — the one who runs the team group chat or the class
list — because each one multiplies into other households. Their group chats are the second
ring.

Weekend is install time: sit with them, both phones at once. The feedback capture is a
five-minute script with three fixed questions: what did you paste in, was the result right,
would your partner use it. Acceptance is measured without asking (see the mapping below).
One 20-minute office-hours slot a week for any household.

Back-to-school and fall sports are the seasonal window: launch by mid-October or the next
spike is holiday planning in late November. Build referral into the product for months 4
to 6: when a captured event involves another family — a carpool, a playdate — offer to
share it with them.

Content stays secondary for users and primary for career proof. One build-log post a week
with one insight, one number, one ask. Never send PM content to the parent list. Open
source is a credibility signal only: MIT license, and the README says "issues welcome, PRs
by discussion first" so support load does not grow with stars.

## Constraints

iOS-only kills mixed-platform households, and those cannot activate under the definition.
Survey the named list for Android before launch; if a third or more are mixed, ship a
read-only web view or a daily SMS digest for the non-iOS caretaker so the household still
counts. AI cost on a free product needs a per-household daily cap and a small model for
capture. Time to first value is minutes from install to first accepted capture; target
under five.

## Growth targets

**Activated** = both caretakers each did a capture or completed an item within seven days
of household creation. **Retained** = the household had at least one action by either
caretaker in the week. Single-caretaker households are tracked separately — welcome, not
counted.

| Metric | Target |
|---|---|
| Activated households by day 45 | 10 to 15 |
| Monthly growth | double through month 3, then reassess against channel |
| Day-30 household retention | above 40 percent |
| Capture acceptance, no edit or minor edit | above 60 percent |
| Invite acceptance, sent → second caretaker active | above 50 percent |
| Word-of-mouth households by day 90 | at least 3 not asked |
| Install to first accepted capture | under 5 minutes |

Doubling through month 6 from a parent network alone does not hold; months 4 to 6 need the
App Store listing plus the carpool-share referral, or the target drops to doubling through
month 3.

**At 90 days, pre-committed:** continue feature investment if day-30 retention, capture
acceptance and word-of-mouth all hit. Otherwise maintenance-only with a stated budget of
hours per month and a fixed AI spend. Write it up publicly either way with the eval set and
the metrics dashboard linked.

---

## How the plan maps onto this repo (2026-09-12)

| Plan item | State | Where |
|---|---|---|
| 1. Analytics + AI logging with PII redaction | **Built, differently, on purpose.** Redaction was rejected for a typed allowlist: `TelemetryEvent` has no free-text parameter at all, so there is nothing to redact. Vendor is Statsig behind an app-owned protocol; one file imports it. Opt-out in Settings. Kill switches for each pillar's cloud arm and the digest. | `Models/Telemetry.swift`, `AI/StatsigSink.swift`, `TelemetryAllowlistTests`; the boundary in `prev-docs/product-guardrails.md` |
| 2. Eval set in CI, fail the build on a drop | **Already true.** `RambleEvalTests` holds `Floors.standard` and `Floors.real` and fails on regression; the 26-utterance real corpus is quarantined. What is missing is the 30–50 *parent-network* captures with golden outputs — a data-gathering task, not code. "Public" needs a LICENSE and a public remote. | `AI/RambleEvalSet.swift`, `RambleEvalTests` |
| 3. Onboarding ends in a real result | **Already true for pasted text; screenshot input added.** The intro screen now takes a screenshot (OCR through the composer's `ImageTextExtractor`) beside pasted text and the sample. A forwarded email arrives as pasted text or a screenshot. | `Features/Onboarding/OnboardingView.swift` |
| 4. Second-caretaker invite, one link, instrumented | **Built; the CloudKit half needs a two-phone sitting.** `HouseholdSync.isLive` flipped with the container and entitlement; `HouseholdSharing` makes a `CKShare` link per household and an `Invitation` per member; `SceneDelegate` receives the tap; identity links automatically when one invitation is pending, asks otherwise. Every stage is a `TelemetryInviteStage`. | `Features/Household/HouseholdSharing.swift`, `InviteViews.swift`, `Models/HouseholdStoreAffinity.swift`, model v4, `SchemaFreezeTests`, `HouseholdSharingTests` |
| 5. Privacy policy, AI disclosure, install guide | **Not code.** `DataBoundary`'s sentences are the in-app disclosure and the sanctioned wording to start from. | `Models/DataBoundary.swift` |
| 6. Sunday evening household digest | **Built as a new guardrail carve-out.** Deterministic, silent on an empty week, one identifier, passive, on by default only for two caretakers, excluded from the pull metric. | `Features/Digest/`, the carve-out in `prev-docs/product-guardrails.md`, `WeeklyDigestTests` |
| Activation / retention / single-caretaker | **Derived on device**, DEBUG-surfaced, one bit (`household_activated`) leaves once per install. Anchored on the accepted invitation, not household creation. | `Models/HouseholdActivation.swift`, `HouseholdActivationTests` |
| Capture acceptance without asking | **Already measured**: `RequiredAttention.capture` (corrections per confirmed task) is exactly "no edit or minor edit"; `capture_committed.corrected` is its telemetry bit. A thumbs control would be a second, weaker signal for the same number and has no surface — Create dismisses on the same beat. | `Models/RequiredAttention.swift` |
| Install → first accepted capture | **Already measured** (`MetricsRecorder.timeToFirstPayoff`), now also `first_payoff` with a duration bucket whose edges are the plan's targets. | `AI/Metrics.swift` |
| Per-household daily AI cap | **Exists per device** (`CloudBudget.dailyCallCap`, 500, silent degrade). Per-household needs the ledger to travel with the share — deferred until the metered usage (WS1) exists. | `AI/ReasoningBudget.swift` |
| Rename to Kinly | **Deliberately not done** until the name check the plan itself requires. | — |
| Android / web / SMS for mixed households | **Not started.** Survey first, as the plan says. | — |
| Carpool-share referral (months 4–6) | **Not started.** | — |

**What only a device can prove now:** the CloudKit share round trip (two signed-in phones),
the digest firing on a Sunday, and Statsig receiving an event (needs a client key in
`Info.plist` and the console's gates created: `kill_cloud_capture`, `kill_cloud_advisor`,
`kill_weekly_digest`).
