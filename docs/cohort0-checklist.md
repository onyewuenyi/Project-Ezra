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
- **Every promise on the privacy screen is kept by the code, checked against the code.**
  Two were not, both found on 2026-09-20 by writing the privacy policy FROM the source
  rather than from the copy. "Your corrections and your history never leave this device"
  was false — the private store mirrors every entity to the person's own iCloud; the real
  guarantee is that they never reach us and never reach anyone invited. And "only
  structured task information goes out — titles, dates and flags, never your raw notes"
  was false on the Advisor's cloud rung, which was handed the facts whole: `NOTES:`,
  `THEY SAID:` (the verbatim capture) and `WHY IT EXISTS:`, unclipped. A finding here is
  any sentence in `DataBoundary` that the code does not keep — check the claim, not the
  comment above it. **Exactly two production workloads open a cloud session** (capture,
  and the Advisor), one sentence each; `CloudCallerTests` walks the target and fails on a
  third, because `CloudModel.provider` is a static slot and reaching it is one line from
  anywhere. Two false claims found in one afternoon is a pattern, and a pattern earns a
  tripwire rather than another careful reading.
- **Model output is untrusted transport.** Anything new the model can emit — a move, a
  step, a citation, an edge — passes a deterministic validator that drops or degrades,
  never substitutes. A new `@Generable` field with no validator is a finding. (2026-09-17:
  `GroupJudgment` → `GroupingSweep.validated` — a member title the model was not shown
  rejects the judgment; the proposal is a row that asks, never an edge.)
- **Chat.** A stopped reply, a failed reply and a reply that never lands are distinct
  states with a way forward (Try again); the two chats stay on-device only
  (`Inquiry`, `TaskInquiryScope`, `HouseholdInquiryScope`). **Try again must WORK after a
  timeout** — the session the deadline abandoned may still be generating, and a retry on it
  is rejected; `InquiryService` moves the thread to a fresh session (metered in
  `rebuilds`). A "Try again" that fails instantly after a timeout is a finding (2026-09-17).

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
- **A bulk delete happens in the store, and the interface is rebuilt, not refreshed**
  (fixed 2026-09-19 — Settings ▸ "Clear all tasks" and "Reset everything" crashed with
  SIGSEGV on every tap, from the screen that holds live fetches for the entities it
  deletes). `DataReset` deletes with `NSBatchDeleteRequest`, tells the live context
  nothing, and parks `registeredObjects` for the process's life; `DataGeneration.rebuild()`
  re-keys the root view so every `@FetchRequest` re-reads the emptied store. A finding
  here is any new `mergeChanges(fromRemoteContextSave:)`, `refreshAllObjects()` or
  `context.reset()` on this path (each one was measured crashing), a view deriving from
  `FetchedResults` without an `isLiveRow` filter, or a clear that leaves the list
  populated until relaunch. Re-measure with `-ClearAllTasks` / `-ResetEverything`
  (+ `-DismissAfterClear`), always in a loop that launches with no arguments first — this
  simulator's runtime breaks on its own and reads exactly like an app crash.
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
- **Every surface survives accessibility text sizes.** Set the simulator with
  `xcrun simctl ui <udid> content_size accessibility-extra-large` (reset to `medium`
  after) and walk the home, the detail, the capture canvas and reveal, Activity, Ask,
  Settings: the header wraps rather than pushing the filter off screen, no caption folds
  into a column of letters (the parked row's age did, 2026-09-12), decks keep their
  caption and card, row titles get a second line rather than "Pay th…" (2026-09-17), a
  due token never splits ("1d / over", 2026-09-18), the reveal and the canvas stay on
  screen with no text clipped (a fixed-width capsule row slid the whole reveal off the
  left edge, and the field's fixed floor clipped the first typed line, 2026-09-18). A
  control that leaves the screen, a word that breaks per letter, a heading that
  truncates, or a column that shifts off an edge is a finding — five of six defects on
  2026-09-18 lived only at this size.
- **Wide surfaces keep a readable column.** On an iPad simulator (the app ships to iPad,
  device family 1,2) the home and the detail must hold their content in the leading
  700pt column (`LayoutMetrics.readableWidth`, 2026-09-18) — a due label a screen-width
  from its title or a 1300pt CTA is a finding. Sheets are form sheets there and need
  nothing. iPhone landscape is unverified on this host.
- **An empty reveal has no primary button.** "Nothing actionable in that" shows the
  hint and "Keep it as one task" only (2026-09-18) — a gradient "Create 0 tasks" is a
  finding. A filler-only line ("hmm ok so") reaches that reveal instantly, never the
  understanding orb.
- **A new person's empty list is about capture, not assignment.** Clean install, onboarding
  done, no tasks: the home must read "Nothing here yet" and point at saying what's on
  your mind (`AssignedSectionsView.emptyCopy`, 2026-09-18) — it read "Nothing assigned
  to you / Work assigned to you shows up here", framing the product as someone else's
  inbox to a person alone in the app. "Assigned" appears only once a household exists.
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

## 7b. First run — the first sixty seconds (added 2026-09-20)

Every check here was a real defect on 2026-09-20, and every one of them was invisible to
the whole suite and to a green build. Re-walk this section on a device, with
`simctl ui <sim> content_size accessibility-extra-large` for half of it.

- **No screen names the engine.** The onboarding settling screen rendered
  `brain.status.description` to every new user — "Apple Intelligence · on-device", or on
  an ineligible phone "Rules engine · device not eligible". A finding is any
  customer-facing surface reading `brain.status`, `AppBrain.Status`, a provider name or a
  model id. Seams: `-OnboardingIntro`, `-OnboardingResult`.
- **Every capture surface says where the words are read.** The composer carries the
  posture chip; Settings carries `DataBoundary`'s sentences; onboarding's paste screen
  carries `DataBoundary.captureShort(cloudReachable:)`. A new capture entry point with
  none of the three is a finding — that screen is usually the one receiving the most raw
  text.
- **Both buttons are reachable at accessibility-extra-large.** The paste screen overflowed
  top and bottom at once: the hero ran under the status bar, and "Start empty" — the only
  way past for someone with nothing to paste — was off the display. A fixed `VStack` with
  a `Spacer` at each end around a fixed-height editor is the shape to look for.
- **No picker passes `photoLibrary:`.** It makes the picker in-process, which needs
  `NSPhotoLibraryUsageDescription`; the app declares none, so iOS terminates it on open.
  All four sites carried it. `SubmissionGateTests` greps it, comments stripped.
- **A stop stops the microphone, including during warm-up.** `start()` suspends on the
  permission prompt and again on the first-run model download; neither honours
  cancellation. Tap "Type instead" while "Getting the mic ready…" is showing and confirm
  no recording indicator appears afterwards.
- **Voice works for a region Apple does not ship.** Set the device to a locale like
  `en-NG` and confirm dictation still runs (a sibling English model), rather than
  "Voice capture isn't available for your language yet".
- **Every product invariant holds for VoiceOver too.** Checked 2026-09-20 and one did
  not: "not yours to advance" removed the swipe and inerted the menu on someone else's
  task while the spoken action list still offered Complete. A finding is any lifecycle
  channel — swipe, long-press menu, glyph, accessibility action — that disagrees with the
  other three about whose task it is. Also check: nothing faded with `.opacity(0)` is
  still in the accessibility tree; every timed affordance outlives its own announcement;
  the capture sheet says the microphone is live; a horizontal pager has named actions.
- **No framework error text reaches a person.** The canvas printed AVFoundation's own
  sentence verbatim. A failure that could plausibly work next time offers Try again.
- **The longest wait has a way out.** Onboarding's settling screen had no back edge and
  the budget behind it is the full 30 seconds for an escalated first paste; a captive
  Wi-Fi turned screen two into half a minute of no-exit spinner holding the person's
  whole mental list. A way back appears after nine seconds, keeps every word, and names
  which of the two things happened. Any new surface that can wait on a model without a
  back edge is a finding.

## 8. Launch gates — the things that block submission, not the experience

- **The privacy manifest ships.** `Project-Ezra/PrivacyInfo.xcprivacy` must appear inside
  the BUILT `.app` in Debug and Release (`ls "$APP" | grep -i privacy`). Absent is an App
  Store rejection, and it is absent silently — nothing in a green build says so. Its
  contents must still match `Models/DataBoundary.swift`; if a workload starts sending
  something new, both change together (2026-09-18).
- **The Release binary carries no verification seam.** The gate is
  `ReleaseSeamTests`, which walks every file in the app target that reads
  `ProcessInfo.processInfo.arguments` and requires each read to sit inside `#if DEBUG`.
  **Do not use `strings` for this.** It was the gate until 2026-09-20 and it lies:
  Swift stores any string of 15 UTF-8 bytes or fewer inside the `String` value itself,
  so it never reaches the binary as a searchable literal. `-SeedSampleData` is exactly
  15 characters, `-OpenSettings` 13, `-OpenRoster` 11 — every one of them invisible to
  the check that names them. The 2026-09-11 leak was caught only because
  `-ResetAndSeedEvalCorpus` happens to be 23 characters long. When the walk replaced the
  hand-written two-file list on 2026-09-20 it immediately found six more unfenced seams
  in three files, including `-CaptureDiagnostics`, which runs a fourteen-item corpus
  through `brain.triage` (a path that can TRANSMIT) and tees stdout into the app's
  Documents. `strings` remains useful as a second opinion for a name over 15 characters,
  and for nothing else.
- **A sharing failure reads as a sentence, not a code.** With no iCloud account on the
  device, tapping Invite must say "Sign in to iCloud on this device to share your
  household", never "CKErrorDomain error 9" (`HouseholdSharingError.naming`, 2026-09-18).
  The arriving phone's accept path follows the same rule.
- **The invite is reachable without a hunt.** Manage household (`-OpenRoster`) shows
  **Invite** inline on every adult who can be invited and has not been; children and pets
  show none. The fixture household must have exactly one owner, or the flow cannot be
  rehearsed at all.
- **Export compliance is answered in the binary.** `ITSAppUsesNonExemptEncryption` is
  `false` in `Project-Ezra/Info.plist` and must stay true to the code: the app ships no
  cryptography of its own, only HTTPS. Without the key, App Store Connect stops every
  upload on the question and TestFlight will not distribute (2026-09-20). If the app ever
  encrypts anything itself, the answer changes and so does this line.
- **The privacy policy is reachable from inside the app.** Guideline 5.1.1(i), because the
  app collects data. `Models/SupportLinks.swift` holds the URL; while it is `nil` the app
  renders no link at all — deliberate, a dead link is worse — and the DEBUG diagnostics
  card reads `privacy policy blocks submission`. The gate is met when that line reads
  `links: ready` and the link opens from "What leaves this device" (2026-09-20).
- **The CloudKit schema is deployed to PRODUCTION.** The gate with no symptom: a
  development-signed build uses the container's Development environment, TestFlight and
  the App Store use Production, and the schema has only ever existed in the first. Sync
  degrades silently by design, so an undeployed schema looks exactly like a quiet app.
  Re-check after every model version. Owner step in `TODO.md` (2026-09-20).
- **Run `scripts/submit.sh`.** It is this section, executed: it stops at the first
  human-only blocker, audits the archived bundle for the manifest, the encryption key and
  the seams, exports with `method: app-store-connect` and validates. A gate you have to
  remember six flags to run is a gate nobody runs.
- **Screenshots exist at both required sizes.** 6.9" iPhone and — because the app ships to
  iPad — 13" iPad. `scripts/screenshots.sh` generates them from the seams; look at every
  one before uploading. The reveal shot is the one to check hardest: the first version of
  it advertised a misread (a three-outcome sentence read as one), which is how that
  defect was found at all.
- **The archive can actually be exported.** `xcodebuild archive` succeeding proves
  nothing about submission: with only an Apple Development identity it produces a build
  carrying `get-task-allow` and `aps-environment: development`. The gate is an
  `-exportArchive` with `method: app-store-connect` that succeeds (2026-09-20).
