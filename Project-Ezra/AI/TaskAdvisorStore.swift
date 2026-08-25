//
//  TaskAdvisorStore.swift
//  Project-Ezra
//
//  The Advisor's judgment cache and its one ambient trigger. Every task detail has an
//  Advisor; this store holds its current judgment — often silence — keyed by the FACTS
//  FINGERPRINT, so the invariant holds: same task + same meaningful context → same
//  Advisor state. Continuously understanding ≠ continuously generating: `ensure` runs
//  on every page activation and is a no-op unless a meaningful fact changed.
//
//  Evaluation and visibility are separate dimensions, shipped as one practical enum —
//  read the case comments; the semantics matter more than the shape:
//  `.dismissed` is NOT "no opinion" (the Advisor had one; the human chose not to
//  engage — valuable state), and `.fallback` is an execution path, not a judgment.
//
//  In-memory only, deliberately: the schema froze at generation 10, judgments
//  regenerate on relaunch, and the per-launch `Hasher` seed in the fingerprint is
//  harmless because nothing here outlives the launch.
//

import Combine
import Foundation
import SwiftUI

/// Who concluded silence. Both are judgments — never "no Advisor here": the gate is
/// the deterministic (zero-model-cost) evaluation path, `.model` is the model's own
/// honest "nothing useful to add".
enum QuietOrigin: Equatable, Sendable {
    case gate
    case model
}

enum AdvisorState: Equatable {
    /// No judgment yet — this page has not been opened. The ONE case that is not a
    /// judgment at all, and deliberately distinct from `.quiet`: "never evaluated"
    /// and "evaluated, nothing to add" render identically and mean opposite things.
    /// If two states mean different things, model them separately.
    case unevaluated
    /// The Advisor judged silence — see `QuietOrigin`. Renders nothing.
    case quiet(QuietOrigin)
    /// Evaluation in flight.
    ///
    /// `deliberate` is the ONE thing the surface needs to know, and it distinguishes two
    /// genuinely different waits. A fast local read (R0–R2) stays INVISIBLE — the shipped
    /// reserved-rhythm decision, because latency should never become a product event and
    /// even a hairline announces "working". A deep read the user is present for is
    /// seconds long and cannot be hidden honestly, so it earns the small thinking mark:
    /// deliberate thought made visible, never a spinner and never a progress bar.
    ///
    /// A precomputed judgment is never `deliberate` — nobody is watching it, which is the
    /// A judgment in flight. Renders as reserved rhythm at every rung — including a
    /// deep read the user is present for. The page appears in its deterministic form,
    /// space is reserved, and the reading settles in when it lands; latency is never
    /// a product event, so there is no mark and no narration. (The associated
    /// `deliberate:` flag and its ThinkingLine died with the shape-driven detail
    /// pass: one loading treatment, invisible, everywhere.)
    case loading
    /// One coherent interpretation — immutable for this fingerprint (the reveal gate).
    case revealed(ValidatedReading)
    /// The Advisor HAD an opinion; the human chose not to engage. Bound to the
    /// fingerprint: it never resurfaces until the facts genuinely change.
    case dismissed
    /// No model on this device — rung 0's deterministic content renders instead.
    /// An execution path, not a judgment.
    ///
    /// The payload is `DeterministicReading.make`'s answer, or nil when the situation is
    /// already covered by the diagnosis template (which the view renders with its own
    /// action links) or when rung 0 has nothing factual to say. Carrying it here rather
    /// than recomputing in the view keeps the reading bound to the facts it was built
    /// from — the same rule `.revealed` follows. It is deliberately NOT counted as an
    /// offer: `.fallback` is an execution path, so folding it into the move stats would
    /// put model-free readings in the denominator progression lift is measured against.
    case fallback(ValidatedReading?)
    /// A real attempt that failed. Owes the user a retry when retryable.
    case failed(retryable: Bool)
}

/// A reading can be revealed ONCE per fingerprint — the structural encoding of
/// "a revealed reading is immutable until the facts change" (the `Interpretation`
/// lesson: three rule-based attempts leaked; a type that refuses can't). Retries,
/// pager transitions, `.onAppear` re-fires and model latency structurally cannot
/// churn the screen: the reading arrives as a single thought.
struct AdvisorRevealGate: Equatable {
    private(set) var revealed: ValidatedReading?
    private(set) var fingerprint: Int?

    /// True when the proposal was accepted (first reveal for this fingerprint).
    /// A repeat for the same fingerprint is refused; a NEW fingerprint is the only
    /// reopener.
    @discardableResult
    mutating func propose(_ reading: ValidatedReading, fingerprint: Int) -> Bool {
        if revealed != nil, self.fingerprint == fingerprint { return false }
        revealed = reading
        self.fingerprint = fingerprint
        return true
    }
}

@MainActor
final class TaskAdvisorStore: ObservableObject {

    static let shared = TaskAdvisorStore()

    struct Entry {
        var fingerprint: Int
        var state: AdvisorState
        var gate = AdvisorRevealGate()
        var work: Task<Void, Never>?
        /// This judgment was produced off the open-moment, for a task nobody had opened.
        /// Clears the first time a human actually looks.
        var isSpeculative = false
        /// A move counted as OFFERED only once someone sees it — see `offer(_:on:)`.
        var pendingOffer: AdvisorMove?
    }

    @Published private(set) var entries: [UUID: Entry] = [:]

    /// How a judgment is produced. Injected so the LOOP — act → facts change →
    /// re-judge — is an automated test rather than a manual sim check: `ModelRun` is
    /// inert under XCTest, so without this seam the closed loop could only be verified
    /// by hand (the `CaptureSessionPool` injected-builder pattern).
    /// The rung is a parameter, not a fact: `TaskAdvisorFacts` is the model's INPUT and
    /// is fingerprinted, so folding routing into it would make "which rung judged this"
    /// part of the cache key and re-judge every task the moment the budget ticked over.
    typealias Judge =
        @MainActor (TaskAdvisorFacts, IntelligenceRung, Bool) async ->
        ModelResult<ValidatedReading>

    private let judge: Judge
    /// Asked BEFORE the judge, so an off-device run skips the retrieval enrichment
    /// rather than paying for it and then discovering there is no model. Injected
    /// alongside the judge because `AppBrain.onDeviceModelAvailable()` is hard-false
    /// under XCTest — leaving it unmockable would put the whole loop behind a gate the
    /// tests cannot open.
    private let isModelAvailable: @MainActor () -> Bool
    private let metrics: AdvisorMetrics
    /// Injectable for the same reason `metrics` is: a test that steps the loop must be
    /// able to read the rung it took without racing the shared singleton.
    private let ledger: IntelligenceLedger

    init(
        judge: @escaping Judge = {
            await TaskAdvisorService().read($0, rung: $1, presenceTime: $2)
        },
        isModelAvailable: @escaping @MainActor () -> Bool = { AppBrain.onDeviceModelAvailable() },
        metrics: AdvisorMetrics = .shared,
        ledger: IntelligenceLedger = .shared
    ) {
        self.judge = judge
        self.isModelAvailable = isModelAvailable
        self.metrics = metrics
        self.ledger = ledger
    }

    func state(for task: TaskItem) -> AdvisorState {
        guard let id = task.uuid, let entry = entries[id] else { return .unevaluated }
        return entry.state
    }

    /// The ambient trigger — called when a detail page becomes active. Recomputes the
    /// facts and their fingerprint; a settled entry for the same fingerprint is a
    /// no-op (the cache), and a changed fingerprint cancels stale work and re-judges.
    /// This function IS the Advisor's rung ladder, which is why the ledger is written
    /// here rather than around the model call: the cache hit and the gate skip are
    /// outcomes with no call attached, and they are the two the economics turn on.
    func ensure(task: TaskItem, among tasks: [TaskItem], now: Date = Date()) {
        evaluate(task: task, among: tasks, now: now, presence: .userIsLooking)
    }

    /// **Off the open-moment** — the answer to the Advisor's missing latency budget.
    ///
    /// Every other deep-thinking moment in Ezra has a cover: Ramble hides behind the orb,
    /// the Brief behind the Recap. The Advisor has neither — its user is standing in the
    /// task detail looking at the task — and deep reasoning on a hard question runs in
    /// tens of seconds. An in-place 30-second "thinking" state would make this the first
    /// surface in the product where the user waits while watching, and it would collide
    /// with a shipped decision: the Advisor's loading state is deliberately invisible.
    ///
    /// The architecture already contains the way out. Because a judgment is cached
    /// against the facts fingerprint, **it does not have to be computed while the user
    /// watches — it has to be right when they look.** So deep work is kicked off when the
    /// escalation signals fire (a meaningful fact change on a task that deserves real
    /// thought, entry into the day's Brief, a dismissal expiring), validated, cached, and
    /// revealed instantly on the next visit.
    ///
    /// Call this from anywhere that learns a task's facts moved. It is safe to call
    /// often: the fingerprint cache makes a repeat a no-op, the gate makes a trivial task
    /// free, and `.shallow` judgments are skipped entirely — **speculative work is capped
    /// to the band that actually needs it**, so unopened tasks never burn spend.
    func precompute(task: TaskItem, among tasks: [TaskItem], now: Date = Date()) {
        evaluate(task: task, among: tasks, now: now, presence: .speculative)
    }

    /// Whether the user is standing there, which changes two things and nothing else:
    /// whether a `.shallow` judgment is worth starting at all, and which budget a deep
    /// one draws from.
    private enum Presence {
        case userIsLooking
        case speculative
    }

    private func evaluate(
        task: TaskItem, among tasks: [TaskItem], now: Date, presence: Presence
    ) {
        guard let id = task.uuid else { return }
        let facts = TaskAdvisorFacts.make(task: task, among: tasks, now: now)
        let fingerprint = facts.fingerprint
        if let entry = entries[id], entry.fingerprint == fingerprint {
            // Rung 1 — re-served. Precompute reaching a warm entry is the SUCCESS case,
            // not a wasted call: it means the work already happened off the open-moment.
            // It is not counted, though — a speculative pass over the same unchanged task
            // every time the Brief runs would inflate the memory rung into meaninglessness.
            if presence == .userIsLooking {
                ledger.record(.memory, for: .advisor, now: now)
                // The precompute payoff: a judgment prepared before they arrived is being
                // seen for the first time, so now it counts as offered.
                recordPendingOfferIfNeeded(id)
            }
            return
        }
        entries[id]?.work?.cancel()

        guard TaskCapabilities.advisorWorthy(for: task, among: tasks, now: now) else {
            if presence == .userIsLooking {
                ledger.record(.facts, for: .advisor, now: now)  // rung 0 — the gate answered
                settle(id, fingerprint: fingerprint, state: .quiet(.gate))
            }
            return
        }
        guard isModelAvailable() else {
            // Also rung 0: the deterministic reading is fact-only content, and
            // `.fallback` is an execution path rather than a judgment. Nothing to
            // precompute — it is already instant.
            if presence == .userIsLooking {
                ledger.record(.facts, for: .advisor, now: now)
                settle(
                    id, fingerprint: fingerprint,
                    state: .fallback(DeterministicReading.make(from: facts)))
            }
            return
        }

        // How much thought this deserves, from facts alone — decided before any model is
        // chosen, and never by a model.
        let budget = AdvisorRouting.budget(for: facts)

        // Speculative work exists to remove a WAIT, and a shallow judgment has no wait
        // worth removing: it is fast, local and free, so precomputing it would spend
        // battery to save nothing. This is the cap that keeps precompute honest.
        guard presence == .userIsLooking || budget == .deep else { return }

        let allowance =
            presence == .speculative
            ? CloudBudget.allowsPrecompute(ledger: ledger, now: now)
            : CloudBudget.allows(ledger: ledger, now: now)
        let rung = AdvisorRouting.rung(
            for: budget, cloudAvailable: CloudModel.isAvailable, budgetAllows: allowance)

        // A speculative shallow read is pointless (above), and a speculative DEEP read
        // that has degraded to on-device is the same thing wearing a different hat — the
        // wait it would remove is a second or two. Let the open-moment handle it.
        guard presence == .userIsLooking || rung == .cloud else { return }

        ledger.record(rung, for: .advisor, now: now)
        read(
            id: id, facts: facts, fingerprint: fingerprint, among: tasks, rung: rung,
            speculative: presence == .speculative)
    }

    /// The page stopped being the one on screen (the pager keeps neighbours mounted, so
    /// `.onDisappear` is not a signal). An in-flight judgment is spend with nobody
    /// waiting — cancel it and drop the entry so the next activation re-judges.
    func cancel(taskID: UUID?) {
        guard let id = taskID, let entry = entries[id] else { return }
        entry.work?.cancel()
        if case .loading = entry.state { entries[id] = nil }
    }

    /// Only meaningful from `.failed` — the retry the failure owes.
    func retry(task: TaskItem, among tasks: [TaskItem], now: Date = Date()) {
        guard let id = task.uuid else { return }
        guard case .failed = entries[id]?.state else { return }
        entries[id] = nil
        ensure(task: task, among: tasks, now: now)
    }

    /// Collapse the reading for the CURRENT fingerprint. It never resurfaces until the
    /// facts genuinely change — and the dismissal is counted: repeated dismissals are a
    /// judgment-quality signal, not an engagement problem.
    func dismiss(taskID: UUID?) {
        guard let id = taskID, let entry = entries[id] else { return }
        guard case .revealed(let reading) = entry.state else { return }
        metrics.recordDismissed(reading.move)
        entries[id]?.state = .dismissed
    }

    // MARK: - Internals

    private func settle(_ id: UUID, fingerprint: Int, state: AdvisorState) {
        let previousGate = entries[id]?.gate ?? AdvisorRevealGate()
        entries[id] = Entry(fingerprint: fingerprint, state: state, gate: previousGate)
        // A gate skip is NOT the same outcome as the model judging silence, and folding
        // them together would distort the honesty denominator: gate skips accumulate on
        // every fingerprint change of every trivial task. They answer different
        // questions — "are we skipping too much?" vs "does the Advisor know when to shut
        // up?" — so they get different counters. (`.quiet(.model)` is recorded in
        // `apply`, where the model actually answered.)
        if case .quiet(.gate) = state { metrics.recordGated() }
    }

    /// Await the in-flight judgment for a task, if any — the seam the golden-scenario
    /// tests use to step the loop deterministically. A no-op once settled.
    func awaitPendingJudgment(for taskID: UUID?) async {
        guard let taskID, let work = entries[taskID]?.work else { return }
        await work.value
    }

    private func read(
        id: UUID, facts: TaskAdvisorFacts, fingerprint: Int, among tasks: [TaskItem],
        rung: IntelligenceRung, speculative: Bool
    ) {
        // Visible thinking is the presence-time DEEP exception only: the user is here,
        // and the wait is real. Everything else keeps its invisible reserved rhythm.
        var entry = Entry(
            fingerprint: fingerprint,
            state: .loading,
            gate: entries[id]?.gate ?? AdvisorRevealGate())
        // A judgment nobody is waiting for is still bounded work, but the thing being
        // protected is different: presence-time work guards the user's patience,
        // speculative work guards the battery and the bill. `.loading` renders as nothing
        // either way, so a precompute in flight is invisible by construction.
        entry.isSpeculative = speculative
        let work = Task { [judge] in
            var enriched = facts
            enriched.relatedLines = await TaskAdvisorService.relatedLines(
                for: facts, among: tasks)
            // `presenceTime` is the inverse of speculative: it decides the deadline, and
            // a precomputed judgment gets the generous one precisely because nobody is
            // waiting for it.
            let outcome = await judge(enriched, rung, !speculative)
            guard !Task.isCancelled else { return }
            // Rung 0's answer for THESE facts, or nil when rung 0 has nothing either.
            // A diagnosed stall counts as a floor even though `make` returns nil for it,
            // because the view renders the richer diagnosis template in that case.
            let deterministic = DeterministicReading.make(from: facts)
            let floor: AdvisorState? =
                (facts.diagnosis != nil || deterministic != nil)
                ? .fallback(deterministic) : nil
            // The status the judgment was made AT, carried from the facts rather than
            // re-read: progression is measured against where the Advisor found the task,
            // and re-reading it here would compare the task to itself after whatever the
            // user did in the meantime.
            self.apply(
                outcome, id: id, fingerprint: fingerprint, statusAtJudgment: facts.status,
                floor: floor)
        }
        entry.work = work
        entries[id] = entry
    }

    private func apply(
        _ outcome: ModelResult<ValidatedReading>, id: UUID, fingerprint: Int,
        statusAtJudgment: TaskStatus, floor: AdvisorState?
    ) {
        guard var entry = entries[id], entry.fingerprint == fingerprint else { return }
        switch outcome {
        case .success(let reading):
            if reading.move == .nothing {
                entry.state = .quiet(.model)
                offer(.nothing, on: &entry)
                // The CONTROL COHORT. The Advisor looked at a task worth advising and
                // judged silence — which is exactly the comparison group progression lift
                // needs, and the only one that isolates the intervention rather than the
                // difficulty of the task. Recorded here, where the model actually
                // answered, and never for gate skips (a different, trivial population).
                metrics.recordJudgedSilence(taskID: id, status: statusAtJudgment)
            } else if entry.gate.propose(reading, fingerprint: fingerprint) {
                entry.state = .revealed(reading)
                offer(reading.move, on: &entry)
            }
        case .unavailable:
            entry.state = floor ?? .fallback(nil)
        case .cancelled:
            // The user left mid-judgment; `cancel` already dropped or will drop the
            // entry. Writing a state for a page nobody is on would be noise.
            return
        // A generation that timed out or threw is NOT the end of the ladder. §07's rule
        // is "cloud fails → on-device; on-device fails → facts", and until now the last
        // arm was missing: the model reported `.available`, the call failed anyway (an
        // empty model catalog, a 429), and the user got "That didn't finish. Try again."
        // — an error string in place of a fallback, offering a retry that cannot succeed.
        // Fall to the floor when there is one; keep `.failed` only when rung 0 is also
        // empty, so the retry seam still exists for the genuinely blank case.
        case .timedOut:
            entry.state = floor ?? .failed(retryable: true)
        case .failed:
            entry.state = floor ?? .failed(retryable: true)
        }
        entry.work = nil
        entries[id] = entry
    }

    /// Count a judgment as OFFERED — but only once a human could actually have seen it.
    ///
    /// This is the metric-integrity half of precompute, and it is easy to get wrong in a
    /// way that quietly destroys the north star. "Offered" is the denominator of every
    /// Advisor quality number: acted/offered, dismissed/offered, and the honesty
    /// denominator that says how often the Advisor chose silence. Precompute produces
    /// judgments for tasks nobody has opened — counting those at generation time would
    /// inflate the denominator with readings no human ever saw, and every ratio built on
    /// it would drift downward for a reason that has nothing to do with quality.
    ///
    /// So a speculative judgment parks its move and is counted on the first user-facing
    /// look (`evaluate` under `.userIsLooking`). The rule in one line: **generated is not
    /// offered; seen is offered.**
    private func offer(_ move: AdvisorMove, on entry: inout Entry) {
        guard !entry.isSpeculative else {
            entry.pendingOffer = move
            return
        }
        metrics.recordOffered(move)
    }

    /// The user reached a judgment that was prepared before they arrived — the payoff
    /// case for precompute, and the moment it becomes real for the metrics.
    private func recordPendingOfferIfNeeded(_ id: UUID) {
        guard var entry = entries[id], let move = entry.pendingOffer else { return }
        entry.pendingOffer = nil
        entry.isSpeculative = false
        entries[id] = entry
        metrics.recordOffered(move)
    }
}
