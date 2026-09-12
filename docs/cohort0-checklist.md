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
- **Confirm is the only publish boundary.** Nothing reaches the task list before Create —
  including the Siri / Action Button / Shortcuts entry (`CaptureIntent`), which must land
  on the confirm card, never write directly.
- **A revealed interpretation is final.** No AI-originated change to a card after reveal
  (`Interpretation.propose` refuses once revealed). Check any new writer into that path.

## 2. AI paths — each rung, each failure, separately

- **On-device (Foundation Models).** Unavailable, model not downloaded, region-disabled,
  a timeout, a cancelled call and a refusal each have a defined landing. Check every call
  goes through `ModelRun.perform` with a deadline — an unbounded call is the bug this seam
  exists to prevent.
- **Cloud (Gemini via Firebase AI Logic).** Unconfigured Firebase, a 429, a network drop
  mid-stream, and a deadline hit each degrade to the rung below, silently and without
  exposing mechanics to the user. **Note: this is Gemini, not Private Cloud Compute —
  PCC is deleted; a finding written against `PCCProvider` is stale.**
- **App Check enforcement lands 2026-11-02** and cannot be un-enforced. Until it is wired
  (`AppCheckSetup.install()` before `FirebaseApp.configure()`, App Attest on device, the
  debug provider on simulator), every cloud call after that date is blocked. Treat an
  unwired App Check as a **Cohort 0 blocker** if the cohort runs past that date.
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

## 4. Sync and ownership — currently OFF, and must say so

- `HouseholdSync.isLive` is `false` and `PersistenceStack.cloudKitContainerID` is `nil`.
  The check is not "does sync work" — it is **does anything claim it does**: no copy, no
  empty state, no invitation flow, no assignment side effect may promise another person
  will see something. A task assigned to someone with no device must not silently leave
  the user's own list.
- Flipping the gate is a one-way door (it closes the clean-break escape hatch). An audit
  finding must never propose flipping it as a fix.

## 5. Loading, empty and stuck states

- **Every wait has a ceiling and a landing.** No indeterminate state a user cannot leave;
  Advisor and Brief-era loading is reserved rhythm, not a spinner.
- **First run is not an error.** Empty store, no household, no tasks, no captures, no
  model — every surface renders something intentional. `—` means "not measurable", never
  zero.
- **Nothing narrates the model's internals** or exposes budgets, quotas, credits, token
  counts or vendor names to the user (DEBUG-only surfaces excepted).

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
  (`DataBoundary` is the sanctioned wording).

---

## Known and accepted — do not re-report

Findings here have been ruled on. Re-raising one is noise; if the *reasoning* has expired,
say why rather than restating the finding.

- **Firebase branch pin (`wwdc26-preview`)** — deliberate; a broken upstream commit
  breaking the build is the accepted cost.
- **Beta toolchain (Xcode 27 / iOS 27 SDK)** — deliberate posture, not a risk to manage
  down. "Wait for GA" is not a finding.
- **`CapacityLog` / `CapacityBaseline` are inert** — frozen schema after the Brief cut.
- **No notifications at all** — the carve-out closed 2026-09-02. Absence is the design.

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
