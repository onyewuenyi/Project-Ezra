# Cohort 0 Readiness Checklist

**What this is.** The list of flows and failure modes the *Cohort 0 Readiness Audit* runs
against this repo. The routine reads this file and checks what it finds here — it does not
carry its own list. That is deliberate: the checklist lives beside the code it describes,
so it is versioned, diffable and reviewable like any other change, and a flow that ships,
changes or gets cut updates the checklist in the same commit instead of waiting for
somebody to remember to edit a prompt.

**The lens.** A household using this app for the first time tonight, unsupervised, with no
one to ask and no way to recover a mistake. Every check below is a way that person loses
data, loses trust, or gets stuck with no way forward.

**Scope.** Audit-only. The routine reports; it does not fix, and it does not edit this
file. See *Keeping this file current* at the bottom.

---

## 1. Capture — the front door

- **Capture never blocks.** Every route must land on something: an unreachable model, a
  denied microphone, a failed transcription, a cancelled parse, or a cloud call that times
  out must all end at the deterministic read or the canvas with the words — never a
  spinner with no exit, never an error string where a card belongs. (`CaptureRoute`,
  `CaptureTriageRace`, `AppBrain.triage`, `ComposerView`.)
- **The words are never lost.** Parked captures survive dismissal, backgrounding, a
  mid-listening interruption and a mid-parse cancel, and are findable afterwards
  (`ParkedCapturesRow`). Discard is the only path that destroys text.
- **Microphone and speech degrade honestly.** Permission denied, permission revoked
  mid-session, transcriber unavailable, and a warm-up that never resolves each settle to
  the typed canvas with whatever was heard — not a dead orb.
- **Photo / OCR import.** Decode failure, a timeout, and "no text found" are three
  different outcomes and must read as three different things; a discarded or auto-cleared
  photo capture leaves no orphaned file in `CaptureImageStore`.
- **Confirm is the only publish boundary — the grouped outcome included.** "Group as one
  outcome" on the reveal births its umbrella at Create and nowhere before (2026-09-12),
  as a reversible `"grouped"` entry whose undo unlinks the steps and removes an untouched
  umbrella. An umbrella written before Create, or a group with no Undo, is a finding.
  Nothing reaches the task list before Create —
  including the Siri / Action Button / Shortcuts entry (`CaptureIntent`), which must land
  on the confirm card, never write directly.
- **A revealed interpretation is final.** No AI-originated change to a card after reveal
  (`Interpretation.propose` refuses once revealed). Check any new writer into that path.
- **Every caller of `AppBrain.triage` names its route, and the router chose it.** The
  parameter has no default (2026-09-11) precisely so this is checkable: before that it
  defaulted to `.cloud`, and `OnboardingView.transform()` — a new user's FIRST brain dump —
  never mentioned it, so it transmitted structure the user had typed and skipped the
  deterministic read. A call site that hardcodes `.cloud`, or computes a route by any means
  other than `CaptureRoute.route(for:localRead:)` / `CaptureFlow.plan` /
  `CaptureFlow.route(for:posture:)`, is a finding. Holding the invariant inside
  `CaptureRoute` is not enough — the last one held perfectly while a view bypassed it.

- **The boundary pass can only ever REMOVE a transmission** (`OnDeviceSegmenter`, off by
  default until the GA report). It is reachable on exactly one escalation reason
  (`underSegmented`) and on the on-device posture's several-things envelope; it proposes
  nothing `CaptureEscalation.reason` has not re-cleared; every fragment is a substring of
  what the person said and the fragments tile the text, so it cannot invent or drop an
  outcome; and its file is grep-pinned against the cloud seam. A call site that runs it on
  another reason, that skips the re-validation, or that lets a refusal reach anything other
  than the read the capture would have had anyway, is a finding.

- **The duplicate merge is the only inference that destroys data, and its gate is measured.**
  `-DuplicateSweepEval` must show zero false merges on the paired corpus before the sweep runs
  on a new runtime, model, instruction set, schema or threshold. A change to any of those five
  invalidates the last run. The report's own vacuous-pass guard is part of the check: a zero
  false-merge count on a host that could not run the prefilter is not a pass.

- **The sentence embedding is AVAILABLE on the device, and the app says so.** On 2026-09-12 the
  dogfooding phone had 0 `EmbeddingCache` rows against 70 tasks: semantic retrieval and the
  duplicate sweep had been silently off for the whole period, every test green. A
  graceful degrade with no meter is a feature that can be off for a month — check that the
  DEBUG diagnostics card reports the embedding's availability and cached-vector count, and
  that a device eval (`-DuplicateSweepEval`) shows the prefilter MEASURED, not skipped.

## 2. AI paths — each rung, each failure, separately

- **On-device (Foundation Models).** Unavailable, model not downloaded, region-disabled,
  a timeout, a cancelled call and a refusal each have a defined landing. Check every call
  goes through `ModelRun.perform` with a deadline — an unbounded call is the bug this seam
  exists to prevent.
- **Cloud (Gemini via Firebase AI Logic).** Unconfigured Firebase, a 429, a network drop
  mid-stream, and a deadline hit each degrade to the rung below, silently and without
  exposing mechanics to the user. **Note: this is Gemini, not Private Cloud Compute —
  PCC is deleted; a finding written against `PCCProvider` is stale.**
- **App Check enforcement lands 2026-11-02** and cannot be un-enforced. The CLIENT half is
  wired (2026-09-11): `AppCheckSetup.install()` runs before `FirebaseApp.configure()`, App
  Attest with a DeviceCheck fallback on device, the debug provider on the SIMULATOR (fenced
  on `targetEnvironment`, never `DEBUG` — a device run is a Debug run), limited-use tokens
  on the AI instance, and a countdown in the DEBUG diagnostics card. `AppCheckSetupTests`
  pins the two silent traps. **What remains is not code**: enable the **App
  Attest capability** on the App ID and add
  `com.apple.developer.devicecheck.appattest-environment` (adding the entitlement first
  fails code signing and breaks the device build — verified 2026-09-11; until then the
  device attests via the **DeviceCheck fallback**, which needs no entitlement and survives
  enforcement, so the un-upgraded state is weaker but not broken), register the simulator
  debug token in the console, prove ONE attested call actually serves on device, and only
  then turn console enforcement on. Enforcing before that proof blocks a working app with no
  local way to tell whether the client half was ever right. An unproven attested call is
  still a **Cohort 0 blocker** if the cohort runs past that date.
- **Rung 0 always answers or is honestly silent.** An Advisor generation failure renders
  *nothing* — never an error string, never a labelled empty box (`DeterministicReading`,
  `ValidatedReading`).
- **Model output is untrusted transport.** Anything new the model can emit — a move, a
  step, a citation, an edge — passes a deterministic validator that drops or degrades,
  never substitutes. A new `@Generable` field with no validator is a finding.
- **Chat.** A stopped reply, a failed reply and a reply that never lands are distinct
  states with a way forward (Try again); the two chats stay on-device only
  (`Inquiry`, `TaskInquiryScope`, `HouseholdInquiryScope`).

## 3. Persistence — the user's real data

- **Every `saveChanges()` result is checked.** A discarded save is a silent data loss;
  list rows fire an error haptic, the detail routes through the retry alert. A new
  mutation site that ignores the return value is a finding.
- **Fetches and decodes fail soft.** A corrupt `relationshipsData` / `draftsData` blob, an
  absent sidecar, a truncated JSON file — none of them may crash a surface. Sidecars are
  bounded, versioned and atomic (`Sidecar`).
- **No store-destroying edit.** The current `.xcdatamodel` version is never edited in
  place (the DEBUG digest tripwire in `Project_EzraApp` catches it); `schemaGeneration`
  (currently 10) is bumped only when stored *meaning* changes.
- **Every wipe is backed up and reported.** `PersistenceStack.destroyStore(reason:)` takes
  a safety copy first, and `StoreResetRecord` surfaces it in Settings.
- **Undo restores every field its action wrote**, not just the headline one
  (`ChangeLogUndo`).

## 4. Sync and ownership — LIVE since 2026-09-12

- `HouseholdSync.isLive` is `true`, `PersistenceStack.cloudKitContainerID` names the
  container, and the entitlement names the same one (`SyncGateTests.gateIsOpenAsOneAct`).
  The three must agree; a live gate over a missing container or entitlement is a finding.
- **The invite is one link** (`HouseholdSharing`, the roster row's "…" menu): a `CKShare`
  URL with public read-write permission. The owner's phone records an `Invitation` naming
  the member; the arriving phone links its identity to that member without asking when
  exactly one invitation is pending, and asks (`IdentityLinkSheet`) otherwise — it never
  guesses from a name. A tasks list that reaches the second phone with the assigned tasks
  NOT theirs is a finding.
- **Every new object lands in the right store, decided once** (`HouseholdStoreAffinity`,
  a `willSave` observer): a task or trail entry saved with no household is given the
  working one and assigned to that household's store. A creation site that assigns a
  store itself, or an entity that belongs to the household without a `household` edge, is
  a finding. `Correction`, `Capture`, `EmbeddingCache`, `SuppressionRecord` and
  `UserProfile` have NO household edge on purpose — they never travel.
- **The schema is frozen additive-only** (`SchemaFreezeTests`): `schemaGeneration` is 10
  for good, every model change is a new version that is a superset of the last, every
  attribute optional or defaulted, every relationship inverse-paired. A generation bump, an
  in-place model edit or a removed attribute is a finding of the highest severity.
- **The device sitting this file cannot replace:** two signed-in phones, invite from one,
  accept on the other, see the assigned tasks arrive owned; complete one on each side and
  watch the trail on both. The simulator has no iCloud account and proves none of it.
  Until that sitting has happened, this section describes what the code intends.

## 5. Loading, empty and stuck states

- **Every wait has a ceiling and a landing.** No indeterminate state a user cannot leave;
  Advisor and Brief-era loading is reserved rhythm, not a spinner.
- **First run is not an error.** Empty store, no household, no tasks, no captures, no
  model — every surface renders something intentional. `—` means "not measurable", never
  zero.
- **Everyone shows the household, and every row says whose.** The Everyone scope (2026-09-12)
  renders every owner's tasks and the unowned; a row that is not yours carries the owner's
  avatar (or the dashed unassigned ring), the leading swipe is ABSENT on someone else's task
  (`recommendedAction` is nil there), and the title reads "Our Tasks". A row in Everyone with
  no way to tell whose it is, or a swipe, long-press menu or deck glyph that advances
  someone else's task, is a finding — the three row-level lifecycle channels follow one
  rule, `recommendedAction != nil` (2026-09-12).
- **A group's front card is always actionable, and its umbrella is never a card.** A deck
  (`TaskDeckView`, 2026-09-12) leads with the first member that waits on nothing; a blocked
  step leading while an open one exists, an umbrella rendered as a card while it has open
  steps, or a done member still in the deck is a finding. The deck's cards carry NO
  lifecycle swipes (horizontal is navigation there) — the glyph is the completion target
  and must route through the undo-aware complete/cancel seams like every other row.
- **The home survives accessibility text sizes.** Render My Tasks with
  `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL`: the header
  wraps rather than pushing the filter off screen, no caption folds into a column of
  letters (the parked row's age did, 2026-09-12), decks keep their caption and card. A
  control that leaves the screen or a word that breaks per letter is a finding.
- **An empty list under a filter names the filter and offers the way out.** A filtered
  My Tasks that matches nothing is indistinguishable from a list with tasks missing — a
  trust failure, not a discoverability one. The empty state must say which filter is on
  (`MyTasksHeader.filteredEmptyMessage`) and carry **Clear filters** in place (2026-09-12);
  the menu's own Clear filters is not enough, because nothing connects that control to the
  emptiness. A filtered-empty state that only says "no matches" is a finding.
- **Nothing narrates the model's internals** or exposes budgets, quotas, credits, token
  counts or vendor names to the user (DEBUG-only surfaces excepted).
- **The Sunday digest is silent on an empty week** (`WeeklyDigest.compose` → nil →
  nothing scheduled), one identifier, no badge, passive, off for a household of one, and
  its opens are excluded from `selfInitiatedOpens`. A second notification type, a digest
  that fires with nothing to say, or a badge is a finding — see the carve-out in
  `prev-docs/product-guardrails.md`.
- **The onboarding intro accepts a screenshot** as well as pasted text (OCR through
  `ImageTextExtractor`); an image with no text says so in place rather than bouncing.

## 6. Crashes and uncaught errors reachable from a user action

- `fatalError`, `try!`, force-unwraps and array-index assumptions on any path a real user
  can reach. Preview, test, fixture and DEBUG-only paths are out of scope — say which when
  excluding one.
- Thrown errors that escape to no handler; `Task {}` bodies that swallow a failure the
  user needed to see.
- Main-actor / concurrency traps on a background write path.
- Debug `print` output reachable from a real user action.

## 7. Release hygiene

- Diagnostic launch seams (`-SeedSampleData`, `-RambleEval`, `-ResetAndSeedEvalCorpus`,
  every `-Open*`) are inert or compiled out in Release, and none of them can destroy a real
  store on a device a cohort member is holding. **Compiled out, not argument-guarded** —
  "nobody passes launch arguments to a shipped app" is a property of how the app is
  usually started, not of the binary (fenced 2026-09-11; `ReleaseSeamTests` greps the
  shell, and `RootTabView.seedFixturesIfRequested` is the one gate a new seed goes
  behind). A new seam guarded only on its own name is a finding.
- No vendor name, model id, token count or spend figure in customer-facing copy
  (`DataBoundary` is the sanctioned wording — including its telemetry and sync sentences).
- **Product telemetry stays inside its allowlist** (`TelemetryAllowlistTests`): no
  `String`/`Int`/`Date`/`UUID` payload on `TelemetryEvent`, the vendor imported in exactly
  one file, the opt-out honoured before the sink, kill switches failing closed. A
  `Telemetry.log` call site that reaches for a title, a name or a raw number — or a second
  file importing the vendor — is a finding.

---

## Known and accepted — do not re-report

Findings here have been ruled on. Re-raising one is noise; if the *reasoning* has expired,
say why rather than restating the finding.

- **Firebase `GeminiLanguageModel` is a public preview on a tagged release (12.19.2)** —
  the `wwdc26-preview` branch pin it replaced broke on the GA SDK (2026-09-17); a preview
  API on a tag is the accepted posture, a branch pin is a bridge to the first such tag.
- **Newest toolchain (Xcode 27.0 GA / iOS 27 SDK)** — deliberate posture, not a risk to manage
  down. "Wait for GA" is not a finding.
- **`CapacityLog` / `CapacityBaseline` are inert** — frozen schema after the Brief cut.
- **One notification, the Sunday digest** — the 2026-09-02 closure stands for the daily
  nudge; the weekly household digest is a NEW carve-out argued from scratch on 2026-09-12
  (`prev-docs/product-guardrails.md`). Its conditions are code; audit those, not its existence.
- **Telemetry leaves the device** — by design since 2026-09-12 (user data local-first,
  product telemetry not). Audit the allowlist, not the transmission.

---

## Keeping this file current

**Update this file in the same change that changes a flow.** A new surface, a new AI path,
a new persistence writer, or a retired feature all move the audit's ground truth, and a
checklist that lags the code produces a clean report about an app that no longer exists.
Specifically:

- **New surface or sheet** → add its stuck/empty/failure states.
- **New model call or rung** → add its unavailable / timeout / degrade landing.
- **New persistence writer or sidecar** → add its save-failure and decode-failure check.
- **Feature cut** → delete its checks in the same commit, and add a line to *Known and
  accepted* only if the absence itself is the thing to verify.
- **A finding ruled "won't fix"** → move it to *Known and accepted* with the reason.

**The routine may propose additions; it may never write them.** If the audit finds a flow
with no corresponding check, it says so in the issue body ("no check covers the Household
invite flow — suggested wording: …") and stops there. Editing this file stays a human act,
so the audit-only line holds and the checklist cannot grow by a robot's own opinion of what
matters.

**On product rename.** This file says "this repo" rather than a product name on purpose; a
rename should not require a checklist edit.
