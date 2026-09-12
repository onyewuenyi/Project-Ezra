//
//  Metrics.swift
//  Project-Ezra
//
//  The PRD's success instrumentation, kept privacy-consistent: everything is
//  derived or counted on-device, nothing leaves it. Acceptance and rot are pure
//  derivations over data SwiftData already holds (the activity trail and task
//  timestamps), so they can't drift from reality; only opens and the first-payoff
//  stamp need tiny persisted counters. Surfaced on the AI trail's quiet diagnostics
//  footer so beta testers can report the numbers through TestFlight feedback.
//
//  Never optimized for engagement (product guardrail): these numbers exist to
//  measure trust — acceptance up, rot down, attention cost down.
//

import Foundation
import Observation

// MARK: - Derived signals (pure, testable)

enum Metrics {
    /// AI-suggestion acceptance rate — the PRD's primary metric. The change log
    /// records every visible AI action (silent filings, auto-unblocks, archives);
    /// an undo is the user rejecting one. Acceptance = the fraction left standing.
    /// Only AI-initiated entries count — folding human edits in would inflate the
    /// trust number.
    static func acceptanceRate(entries: [ChangeLogEntry]) -> Double? {
        // Excluded verbs (`ChangeLogEntry.nonAcceptanceActions`): a daily plan is not an
        // AI *action on a task* the user accepts or rejects, and neither is a capture
        // receipt. Both are AI-initiated and permanently irreversible, so both could only
        // ever score as KEPT — folding them in would let the trust number rise on volume
        // alone. The list lives on `ChangeLogEntry` so a future verb can't be excluded
        // from the feed and silently left inside the metric.
        let aiEntries = entries.filter {
            $0.initiatedBy == .ai
                && !ChangeLogEntry.nonAcceptanceActions.contains($0.action ?? "")
        }
        guard !aiEntries.isEmpty else { return nil }
        let kept = aiEntries.filter { !$0.undone }.count
        return Double(kept) / Double(aiEntries.count)
    }

    /// Rot rate — the share of resolved tasks that had already gone stale by the
    /// time they were acted on. Diagnostic for WHY acceptance moves, per the PRD.
    static func rotRate(tasks: [TaskItem], threshold: TimeInterval = 7 * 24 * 3600) -> Double? {
        let resolved = tasks.filter { $0.completedAt != nil }
        guard !resolved.isEmpty else { return nil }
        let rotted = resolved.filter { task in
            guard let done = task.completedAt else { return false }
            return done.timeIntervalSince(task.createdAt) > threshold
        }
        return Double(rotted.count) / Double(resolved.count)
    }
}

// MARK: - Counted signals (persisted)

/// The two signals that can't be derived after the fact: self-initiated opens and
/// time-to-first-payoff (install → first committed capture; the launch plan's target is
/// under five minutes, and `first_payoff` reports it as a `DurationBucket` whose edges
/// are that target).
@MainActor
@Observable
final class MetricsRecorder {
    private let defaults: UserDefaults

    private(set) var selfInitiatedOpens: Int
    private(set) var installedAt: Date
    private(set) var firstPayoffAt: Date?

    /// Seconds from install to the first committed capture, once it has happened.
    var timeToFirstPayoff: TimeInterval? {
        firstPayoffAt?.timeIntervalSince(installedAt)
    }

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        self.selfInitiatedOpens = defaults.integer(forKey: Key.opens)
        if let stamp = defaults.object(forKey: Key.installedAt) as? Date {
            self.installedAt = stamp
        } else {
            self.installedAt = now
            defaults.set(now, forKey: Key.installedAt)
        }
        self.firstPayoffAt = defaults.object(forKey: Key.firstPayoffAt) as? Date
    }

    /// Every foreground is self-initiated — the app sends no notifications, so there
    /// is nothing notification-driven to separate out.
    func recordOpen() {
        selfInitiatedOpens += 1
        defaults.set(selfInitiatedOpens, forKey: Key.opens)
    }

    /// Stamp the first committed capture; later commits are no-ops. Returns whether THIS
    /// call was the stamp, so the one-per-install telemetry event fires exactly once.
    @discardableResult
    func recordFirstPayoffIfNeeded(now: Date = Date()) -> Bool {
        guard firstPayoffAt == nil else { return false }
        firstPayoffAt = now
        defaults.set(now, forKey: Key.firstPayoffAt)
        return true
    }

    /// Wipe the counted signals (Settings ▸ Reset everything). The install stamp restarts
    /// at `now` rather than clearing: time-to-first-payoff is measured from a start, and a
    /// reset store is a new one — leaving the old stamp would report a payoff measured in
    /// weeks the moment the next capture lands.
    func reset(now: Date = Date()) {
        selfInitiatedOpens = 0
        firstPayoffAt = nil
        installedAt = now
        defaults.removeObject(forKey: Key.opens)
        defaults.removeObject(forKey: Key.firstPayoffAt)
        defaults.set(now, forKey: Key.installedAt)
    }

    private enum Key {
        static let opens = "metrics.selfInitiatedOpens"
        static let installedAt = "metrics.installedAt"
        static let firstPayoffAt = "metrics.firstPayoffAt"
    }
}

// MARK: - Today plan instrumentation (spec §7)

/// Per-capability model-call outcomes — the evidence behind `ModelDeadline.cardSeconds`.
///
/// Picking a 20-second deadline without data is guesswork, and the Today plan already
/// regressed once from a deadline that was too tight for a cold model. This records what
/// actually happens so the next adjustment is measured rather than argued.
///
/// **Local only, and that is a deliberate boundary.** Same shape as `MetricsRecorder`:
/// UserDefaults-backed, surfaced in the DEBUG diagnostics footer, never transmitted.
/// `prev-docs/product-guardrails.md` refuses vanity metrics and the store holds real
/// personal data, so shipping per-feature latency off-device would be a product-posture
/// change — one that deserves its own decision, not a ride along inside a timeout fix.
///
/// A singleton because `ModelRun` is a free function with no instance to hang off, unlike
/// `MetricsRecorder` which rides on `AppBrain`.
@MainActor
@Observable
final class ModelMetrics {
    static let shared = ModelMetrics()

    /// One capability's tally. `calls` is derived (`successes + timeouts + failures`)
    /// rather than stored, because cancellations are deliberately not counted — the user
    /// walking away says nothing about whether the deadline is well chosen.
    struct Stats: Sendable, Equatable {
        var successes = 0
        var timeouts = 0
        /// Deadline hits where streamed work was SALVAGED — the user got usable output.
        /// Split out from `timeouts` because collapsing them made the footer read
        /// "0 ok · 2 timeout" for two captures that both produced tasks the user could
        /// confirm. A metric that calls a served user a failure is the kind of lie this
        /// codebase keeps finding in itself.
        var salvaged = 0
        var failures = 0
        var lastLatencyMs = -1
        var lastError: String?
        /// Parse-shape diagnostics, IN-MEMORY ONLY (deliberately not persisted — the
        /// record path already pays five synchronous defaults writes, and these tune
        /// in-session behavior; -1/0 = not reported by this capability).
        var lastRetrievalMs = -1
        var lastFirstPartialMs = -1
        var lastPartialCount = 0
        /// Token accounting (iOS 26.4's `tokenCount(for:)`/`contextSize`) — the
        /// evidence chunking and context budgets are designed against.
        var lastPromptTokens = -1
        var lastContextSize = -1
        /// **Submit → stable confirmation** — the number that actually matters for
        /// Ramble. Not time-to-first-token, not time-to-first-card: time to a
        /// trustworthy result the user can act on. `source` says who decided the
        /// structure ("local" = a certain deterministic read, revealed at once;
        /// "model" = the orb held the screen until generation answered).
        var lastConfirmMs = -1
        var lastFirstCardSource: String?
        /// AI results refused because they arrived after the reveal (`Interpretation`).
        /// NOT an error — it is the guard working. It is evidence about the ROUTING policy:
        /// a high rate on the fast path means the model had something to say and we chose
        /// not to hear it, which is a product decision worth revisiting on numbers rather
        /// than on instinct.
        var refusedProposals = 0
        /// Model drafts dropped because nothing in the capture supports their existence
        /// (`AppBrain` grounding). This is the invented-task counter — the number that says
        /// whether the conservative capture prompt is actually holding.
        var ungroundedDrops = 0
        /// One provisional pass's cost — segmentation + resolve + owner proposal, on
        /// the thread the keyboard shares. The number the coalesce window is tuned on.
        var lastProvisionalMs = -1
        var provisionalPasses = 0
        /// The confirm tap: drafts → tasks in the store, synchronously.
        var lastCommitMs = -1
        /// Hedging (`CaptureTriageRace.hedged`): how often the free arm had to be started
        /// because the paid one was late, and how often it went on to WIN the reveal.
        ///
        /// These two numbers are what make `ModelDeadline.captureHedgeSeconds` tunable
        /// instead of a guess, and they say opposite things when they disagree. A high
        /// start rate with a low win rate means the delay is too short — the device is
        /// doing redundant work on ordinary captures and the cloud arm is answering
        /// anyway. A high win rate means the cloud arm is genuinely unreliable here, and
        /// the question stops being about the delay and becomes about the rung.
        /// Both near zero is the healthy state: the paid arm answers, and the hedge is
        /// insurance that never gets claimed.
        var hedgesStarted = 0
        var hedgesWon = 0

        var calls: Int { successes + salvaged + timeouts + failures }
        /// Calls that put usable output in front of the user, however they got there.
        var served: Int { successes + salvaged }
    }

    enum Outcome {
        case success
        /// The deadline fired but the streamed partial was viable and was returned.
        case salvaged
        case timedOut
        case failed(String)
    }

    private let defaults: UserDefaults
    private(set) var stats: [ModelFeature: Stats] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for feature in ModelFeature.allCases {
            stats[feature] = Stats(
                successes: defaults.integer(forKey: Key.successes(feature)),
                timeouts: defaults.integer(forKey: Key.timeouts(feature)),
                salvaged: defaults.integer(forKey: Key.salvaged(feature)),
                failures: defaults.integer(forKey: Key.failures(feature)),
                lastLatencyMs: defaults.object(forKey: Key.lastLatencyMs(feature)) as? Int ?? -1,
                lastError: defaults.string(forKey: Key.lastError(feature)))
        }
    }

    func record(
        _ feature: ModelFeature, _ outcome: Outcome, latencyMs: Int,
        retrievalMs: Int = -1, firstPartialMs: Int = -1, partialCount: Int = 0
    ) {
        var entry = stats[feature] ?? Stats()
        entry.lastLatencyMs = latencyMs
        entry.lastRetrievalMs = retrievalMs
        entry.lastFirstPartialMs = firstPartialMs
        entry.lastPartialCount = partialCount
        switch outcome {
        case .success:
            entry.successes += 1
            // A success means the capability is working; clear the stale failure so the
            // footer shows the CURRENT state rather than an error from days ago.
            entry.lastError = nil
            defaults.removeObject(forKey: Key.lastError(feature))
        case .salvaged:
            entry.salvaged += 1
            // NOT an error: the user was served. The deadline is still worth knowing
            // about (it bounds how complete the result was), which is what the
            // separate tally is for.
            entry.lastError = nil
            defaults.removeObject(forKey: Key.lastError(feature))
        case .timedOut:
            entry.timeouts += 1
            entry.lastError = "timedOut"
            defaults.set("timedOut", forKey: Key.lastError(feature))
        case .failed(let label):
            entry.failures += 1
            entry.lastError = label
            defaults.set(label, forKey: Key.lastError(feature))
        }
        stats[feature] = entry
        // The product-telemetry mirror of this tally: the feature, served-or-not and a
        // latency BUCKET — never the prompt, never the answer (`Telemetry`'s allowlist).
        let served: Bool
        switch outcome {
        case .success, .salvaged: served = true
        case .timedOut, .failed: served = false
        }
        Telemetry.log(
            .modelCall(
                feature: feature, served: served,
                latency: DurationBucket(seconds: Double(max(latencyMs, 0)) / 1000)))
        defaults.set(entry.successes, forKey: Key.successes(feature))
        defaults.set(entry.timeouts, forKey: Key.timeouts(feature))
        defaults.set(entry.salvaged, forKey: Key.salvaged(feature))
        defaults.set(entry.failures, forKey: Key.failures(feature))
        defaults.set(latencyMs, forKey: Key.lastLatencyMs(feature))
    }

    /// Token accounting for the last call — recorded separately from the outcome
    /// because the tokenizer runs AFTER the parse returns (an async count must never
    /// sit inside the user's wait). In-memory only, like the parse-shape trio.
    func recordTokens(_ feature: ModelFeature, promptTokens: Int, contextSize: Int) {
        var entry = stats[feature] ?? Stats()
        entry.lastPromptTokens = promptTokens
        entry.lastContextSize = contextSize
        stats[feature] = entry
    }

    /// Submit → the confirmation the user can act on: Ramble's headline number.
    /// In-memory like the rest of the parse-shape diagnostics.
    func recordConfirmReached(latencyMs: Int, source: String) {
        var entry = stats[.captureTriage] ?? Stats()
        entry.lastConfirmMs = latencyMs
        entry.lastFirstCardSource = source
        stats[.captureTriage] = entry
    }

    /// One hedged capture's shape: did the free arm start, and did it win?
    ///
    /// Recorded only when a hedge arm actually existed, so the rates are over hedgeABLE
    /// captures rather than over all of them — an on-device-route capture that could
    /// never have hedged would otherwise dilute both numbers toward zero and make the
    /// delay look better tuned than it is.
    func recordHedge(started: Bool, won: Bool) {
        var entry = stats[.captureTriage] ?? Stats()
        if started { entry.hedgesStarted += 1 }
        if won { entry.hedgesWon += 1 }
        stats[.captureTriage] = entry
    }

    /// An AI result arrived after the reveal and was refused. See `Interpretation`.
    func recordRefusedProposal() {
        var entry = stats[.captureTriage] ?? Stats()
        entry.refusedProposals += 1
        stats[.captureTriage] = entry
    }

    /// A model draft was dropped because the capture contains no evidence for it.
    func recordUngroundedDrop(_ count: Int = 1) {
        guard count > 0 else { return }
        var entry = stats[.captureTriage] ?? Stats()
        entry.ungroundedDrops += count
        stats[.captureTriage] = entry
    }

    /// The confirm tap's wall clock — draft(s) → tasks in the store, synchronously,
    /// before the sheet dismisses.
    func recordCommit(latencyMs: Int) {
        var entry = stats[.captureTriage] ?? Stats()
        entry.lastCommitMs = latencyMs
        stats[.captureTriage] = entry
    }

    /// The LOCAL route's own cost — segmentation, resolve and owner proposal, with no
    /// model anywhere in it.
    ///
    /// This was dead for a while: it measured a per-keystroke provisional pass that the
    /// submit-once arc deleted, and nothing called it. It is live again because that same
    /// code is now the local ROUTE — the whole answer whenever the user typed the
    /// boundaries themselves — so its latency stopped being a curiosity and became the
    /// number the routing split is justified by. Measured p50: 3ms, against a cloud arm
    /// at roughly a second.
    func recordProvisionalPass(latencyMs: Int) {
        var entry = stats[.captureTriage] ?? Stats()
        entry.lastProvisionalMs = latencyMs
        entry.provisionalPasses += 1
        stats[.captureTriage] = entry
    }

    /// One line per capability that has actually been exercised, for the DEBUG footer.
    /// Features with no calls are omitted — an all-zero list is noise, not information.
    func footerLines() -> [String] {
        ModelFeature.allCases.compactMap { feature in
            guard let entry = stats[feature], entry.calls > 0 else { return nil }
            var line = "\(feature.label): \(entry.successes) ok"
            if entry.salvaged > 0 { line += " · \(entry.salvaged) salvaged" }
            if entry.timeouts > 0 { line += " · \(entry.timeouts) timeout" }
            if entry.failures > 0 { line += " · \(entry.failures) fail" }
            if entry.lastLatencyMs >= 0 {
                line += String(format: " · last %.1fs", Double(entry.lastLatencyMs) / 1000)
            }
            // The parse-shape trio, present only when the capability reported it —
            // the numbers the deadline and streaming cadence are tuned on.
            if entry.lastFirstPartialMs >= 0 {
                line += String(format: " · first %.1fs", Double(entry.lastFirstPartialMs) / 1000)
            }
            if entry.lastRetrievalMs >= 0 { line += " · retr \(entry.lastRetrievalMs)ms" }
            if entry.lastPartialCount > 0 { line += " · \(entry.lastPartialCount) partials" }
            // The Ramble contract, first because it is what the user feels.
            if entry.lastConfirmMs >= 0 {
                line += " · confirm \(entry.lastConfirmMs)ms"
                if let source = entry.lastFirstCardSource { line += "(\(source))" }
            }
            // Only when the hedge has fired at all — an unclaimed insurance policy is the
            // healthy state and doesn't need a line in the footer to say so.
            if entry.hedgesStarted > 0 {
                line += " · hedge \(entry.hedgesWon)/\(entry.hedgesStarted)"
            }
            if entry.refusedProposals > 0 { line += " · \(entry.refusedProposals) refused" }
            if entry.ungroundedDrops > 0 { line += " · \(entry.ungroundedDrops) ungrounded" }
            if entry.lastCommitMs >= 0 { line += " · commit \(entry.lastCommitMs)ms" }
            if entry.lastPromptTokens >= 0 {
                line += " · \(entry.lastPromptTokens)"
                if entry.lastContextSize > 0 { line += "/\(entry.lastContextSize)" }
                line += " tok"
            }
            if let error = entry.lastError { line += " · \(error)" }
            return line
        }
    }

    /// Wipe every capability's tally (Settings ▸ Reset everything). The evidence stream is
    /// about THIS store's behaviour, so it starts over with it.
    func reset() {
        for feature in ModelFeature.allCases {
            stats[feature] = Stats()
            for key in [
                Key.successes(feature), Key.timeouts(feature), Key.salvaged(feature),
                Key.failures(feature), Key.lastLatencyMs(feature), Key.lastError(feature),
            ] {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private enum Key {
        static func successes(_ f: ModelFeature) -> String { "model.\(f.rawValue).successes" }
        static func timeouts(_ f: ModelFeature) -> String { "model.\(f.rawValue).timeouts" }
        static func salvaged(_ f: ModelFeature) -> String { "model.\(f.rawValue).salvaged" }
        static func failures(_ f: ModelFeature) -> String { "model.\(f.rawValue).failures" }
        static func lastLatencyMs(_ f: ModelFeature) -> String { "model.\(f.rawValue).lastLatencyMs" }
        static func lastError(_ f: ModelFeature) -> String { "model.\(f.rawValue).lastError" }
    }
}

// MARK: - Advisor outcomes (judge the judgment, not the activity)

/// What became of each Advisor reading, per move — the half `ModelMetrics` can't see.
/// That class measures whether the *model* worked; this one measures whether the
/// *judgment* did. Three per-move outcomes plus two derivations:
///
/// - **offered / acted / dismissed** — a reading revealed on an active page, its action
///   tapped, or explicitly dismissed. `nothing` counts offered-only: silence is a
///   first-class outcome, and its count is the honesty denominator. Dismissal is
///   information — repeated dismissals signal a judgment-quality problem, not an
///   engagement problem.
/// - **Progression** (the north star): % of advised tasks that later PROGRESSED —
///   status advanced or resolved since the intervention. Derived lazily from a capped
///   acted-event list; AI activity is not the quality signal, moved work is.
/// - **Re-intervention rate** (diagnostic): interventions per advised task before it
///   progressed. One intervention → progress reads like an intelligent coworker;
///   advise→act→advise→act reads agentic and annoying.
///
/// Local-only, never transmitted, same charter as `ModelMetrics`.
@MainActor
final class AdvisorMetrics {
    static let shared = AdvisorMetrics()

    struct Stats: Equatable {
        var offered = 0
        var acted = 0
        var dismissed = 0
    }

    /// One advisor action, with the lifecycle position it acted FROM — progression is
    /// judged against this, so an action that itself moved the task (Do-it-now →
    /// `.doing`) still needs the task to move FURTHER to count as progressed.
    struct ActedEvent: Codable, Equatable {
        var taskID: UUID
        var date: Date
        var move: String
        var statusAtAction: String
    }

    /// One judged SILENCE, with the lifecycle position it was judged at.
    ///
    /// This is the control cohort, and without it the north star is not falsifiable.
    /// "62% of advised tasks later moved" sounds like evidence and is not: tasks the
    /// Advisor speaks on are selected — they are the stuck, decision-shaped,
    /// repeat-deferred ones — so their movement rate has no meaning until it is compared
    /// against something. The honest comparison is tasks the Advisor **looked at and
    /// judged not worth speaking on**: same gate, same facts pipeline, same kind of work,
    /// differing only in the intervention.
    ///
    /// Gate skips are deliberately NOT the control. A task the gate declined is trivial
    /// by construction — comparing "renew the passport" against "water the plants" would
    /// measure task difficulty and call it Advisor quality.
    struct SilentEvent: Codable, Equatable {
        var taskID: UUID
        var date: Date
        var statusAtJudgment: String
    }

    /// The acted-event list is evidence, not history — enough for the derivations,
    /// never a transcript.
    static let maxActedEvents = 200

    private let defaults: UserDefaults
    private(set) var stats: [AdvisorMove: Stats] = [:]
    private(set) var actedEvents: [ActedEvent] = []
    /// The control cohort — tasks the Advisor judged and chose silence on.
    private(set) var silentEvents: [SilentEvent] = []
    /// Judgments the deterministic gate answered for free — deliberately NOT folded
    /// into `nothing`. "We skipped this" and "the model looked and declined" answer
    /// different questions (*are we skipping too much?* vs *does the Advisor know when
    /// to shut up?*), and gate skips accumulate on every fingerprint change of every
    /// trivial task, so merging them would swamp the honesty denominator.
    private(set) var gated = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        gated = defaults.integer(forKey: Key.gated)
        for move in AdvisorMove.allCases {
            stats[move] = Stats(
                offered: defaults.integer(forKey: Key.offered(move)),
                acted: defaults.integer(forKey: Key.acted(move)),
                dismissed: defaults.integer(forKey: Key.dismissed(move)))
        }
        if let data = defaults.data(forKey: Key.actedEvents),
            let events = try? JSONDecoder().decode([ActedEvent].self, from: data)
        {
            actedEvents = events
        }
        if let data = defaults.data(forKey: Key.silentEvents),
            let events = try? JSONDecoder().decode([SilentEvent].self, from: data)
        {
            silentEvents = events
        }
    }

    /// The Advisor looked at a worthy task and judged silence — one control-cohort
    /// sample. Recorded only for MODEL-judged silence; the deterministic gate's skips are
    /// a different population (see `SilentEvent`).
    func recordJudgedSilence(taskID: UUID?, status: TaskStatus, now: Date = Date()) {
        guard let taskID else { return }
        silentEvents.append(
            SilentEvent(taskID: taskID, date: now, statusAtJudgment: status.rawValue))
        if silentEvents.count > Self.maxActedEvents {
            silentEvents.removeFirst(silentEvents.count - Self.maxActedEvents)
        }
        if let data = try? JSONEncoder().encode(silentEvents) {
            defaults.set(data, forKey: Key.silentEvents)
        }
    }

    func recordOffered(_ move: AdvisorMove) {
        Telemetry.log(.advisorOffered(move: move))
        stats[move, default: Stats()].offered += 1
        defaults.set(stats[move]?.offered ?? 0, forKey: Key.offered(move))
    }

    func recordActed(_ move: AdvisorMove, taskID: UUID?, status: TaskStatus, now: Date = Date()) {
        Telemetry.log(.advisorActed(move: move))
        stats[move, default: Stats()].acted += 1
        defaults.set(stats[move]?.acted ?? 0, forKey: Key.acted(move))
        guard let taskID else { return }
        actedEvents.append(
            ActedEvent(taskID: taskID, date: now, move: move.rawValue, statusAtAction: status.rawValue))
        if actedEvents.count > Self.maxActedEvents {
            actedEvents.removeFirst(actedEvents.count - Self.maxActedEvents)
        }
        if let data = try? JSONEncoder().encode(actedEvents) {
            defaults.set(data, forKey: Key.actedEvents)
        }
    }

    func recordDismissed(_ move: AdvisorMove) {
        Telemetry.log(.advisorDismissed(move: move))
        stats[move, default: Stats()].dismissed += 1
        defaults.set(stats[move]?.dismissed ?? 0, forKey: Key.dismissed(move))
    }

    /// The deterministic gate answered — no model call was spent.
    func recordGated() {
        gated += 1
        defaults.set(gated, forKey: Key.gated)
    }

    /// One DEBUG-footer line: `advisor: gated 12 · zip 6 · dec 2/3` (acted/offered;
    /// `gated` and `nothing` show a bare count — silence has no action to take).
    /// Nil when nothing has ever been judged — no line beats a row of zeros.
    var footerLine: String? {
        var parts: [String] = []
        if gated > 0 { parts.append("gated \(gated)") }
        parts += AdvisorMove.allCases.compactMap { move -> String? in
            guard let entry = stats[move], entry.offered > 0 else { return nil }
            if move == .nothing { return "\(Self.label(move)) \(entry.offered)" }
            return "\(Self.label(move)) \(entry.acted)/\(entry.offered)"
        }
        guard !parts.isEmpty else { return nil }
        return "advisor: " + parts.joined(separator: " · ")
    }

    /// One cohort's progression rate, and how many tasks it was measured over.
    struct Cohort: Equatable {
        var moved = 0
        var total = 0
        var rate: Double? { total == 0 ? nil : Double(moved) / Double(total) }
    }

    /// **Progression lift** — the north star, and the only form of it that can be wrong.
    ///
    /// The earlier number was "% of advised tasks that later moved", which reads like
    /// evidence and isn't: the Advisor speaks on *selected* tasks — the stuck,
    /// decision-shaped, repeat-deferred ones — so 62% has no meaning on its own. It could
    /// mean the interventions work, or it could mean hard tasks move anyway, and the
    /// number cannot tell those apart. A metric that cannot fail cannot support the claim
    /// the whole product rests on.
    ///
    /// Lift compares against tasks the Advisor **looked at and judged not worth speaking
    /// on**: same gate, same facts pipeline, same kind of work, differing only in whether
    /// an intervention happened. Positive lift is the falsifiable form of "does Ezra make
    /// stalled work move?"
    ///
    /// Both cohorts are measured over the LIVE set, so deleted tasks leave both
    /// denominators, and a task that appears in both (advised once, silent later) counts
    /// as advised — the intervention is the thing whose effect is being measured.
    func progression(among tasks: [TaskItem]) -> (advised: Cohort, silent: Cohort, lift: Double?) {
        let advisedByTask = Dictionary(grouping: actedEvents, by: \.taskID)
        var advised = Cohort()
        for (taskID, events) in advisedByTask {
            guard let task = tasks.first(where: { $0.uuid == taskID }) else { continue }
            advised.total += 1
            let first = events.min(by: { $0.date < $1.date })!
            if Self.hasProgressed(task, since: first.statusAtAction) { advised.moved += 1 }
        }

        var silent = Cohort()
        for (taskID, events) in Dictionary(grouping: silentEvents, by: \.taskID) {
            // Contaminated control: a task that was also advised belongs to the treatment
            // group. Leaving it in both would dilute the difference towards zero and make
            // a working Advisor look ineffective.
            guard advisedByTask[taskID] == nil else { continue }
            guard let task = tasks.first(where: { $0.uuid == taskID }) else { continue }
            silent.total += 1
            let first = events.min(by: { $0.date < $1.date })!
            if Self.hasProgressed(task, since: first.statusAtJudgment) { silent.moved += 1 }
        }

        // Nil rather than zero when either cohort is empty: "no difference measured" and
        // "no measurement possible" are different claims, and reporting the second as the
        // first is how a product talks itself into believing an unproven thing.
        let lift: Double? = {
            guard let a = advised.rate, let s = silent.rate else { return nil }
            return a - s
        }()
        return (advised, silent, lift)
    }

    /// The DEBUG footer line: `moved 62% (13) · silent 31% (9) · lift +31pt · re-int 1.3`.
    /// Nil until something has been judged.
    func progressionLine(among tasks: [TaskItem]) -> String? {
        guard !actedEvents.isEmpty || !silentEvents.isEmpty else { return nil }
        let (advised, silent, lift) = progression(among: tasks)
        var parts: [String] = []
        if let rate = advised.rate {
            parts.append("moved \(Int((rate * 100).rounded()))% (\(advised.total))")
        }
        if let rate = silent.rate {
            parts.append("silent \(Int((rate * 100).rounded()))% (\(silent.total))")
        }
        if let lift {
            // Signed, always. A negative lift is the most important number this footer can
            // ever show — it says the interventions are not helping — and an unsigned
            // percentage would let it hide in plain sight.
            let points = Int((lift * 100).rounded())
            parts.append("lift \(points >= 0 ? "+" : "")\(points)pt")
        } else {
            // Named rather than omitted: a missing control is a gap in the evidence, and
            // a footer that simply drops the row looks like a product with no opinion.
            parts.append("lift n/a")
        }
        // Re-intervention over LIVE tasks only, so every number in this line describes
        // the same population — `progression(among:)` already intersects its cohorts
        // with the live set, and deleted or merged tasks would otherwise inflate this
        // one denominator while moved% answered a different cohort. (Cherry-picked
        // intent from a parallel review branch; the code it patched predates v5's
        // cohort rework, so the fix is translated rather than merged.)
        let liveIDs = Set(tasks.compactMap(\.uuid))
        let liveEvents = actedEvents.filter { liveIDs.contains($0.taskID) }
        if !liveEvents.isEmpty {
            let byTask = Dictionary(grouping: liveEvents, by: \.taskID)
            let reIntervention = Double(liveEvents.count) / Double(byTask.count)
            parts.append("re-int \(String(format: "%.1f", reIntervention))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Did the task move past where the intervention found it? Resolution always
    /// counts; `.todo → .doing` counts; anything else is standing still.
    static func hasProgressed(_ task: TaskItem, since statusAtAction: String) -> Bool {
        if task.status.isResolved { return true }
        return statusAtAction == TaskStatus.todo.rawValue && task.status == .doing
    }

    /// The move's footer label. Short, stable, and never user-facing.
    static func label(_ move: AdvisorMove) -> String {
        switch move {
        case .nothing: return "zip"
        case .advise: return "adv"
        case .decide: return "dec"
        case .createSteps: return "steps"
        case .openBlocker: return "blk"
        }
    }

    /// Wipe everything (Settings ▸ Reset everything), for the same reason
    /// `ModelMetrics.reset` does: the judgments were made against work that is now gone.
    func reset() {
        for move in AdvisorMove.allCases {
            stats[move] = Stats()
            defaults.removeObject(forKey: Key.offered(move))
            defaults.removeObject(forKey: Key.acted(move))
            defaults.removeObject(forKey: Key.dismissed(move))
        }
        actedEvents = []
        silentEvents = []
        gated = 0
        defaults.removeObject(forKey: Key.actedEvents)
        defaults.removeObject(forKey: Key.silentEvents)
        defaults.removeObject(forKey: Key.gated)
    }

    private enum Key {
        static func offered(_ m: AdvisorMove) -> String { "advisor.\(m.rawValue).offered" }
        static func acted(_ m: AdvisorMove) -> String { "advisor.\(m.rawValue).acted" }
        static func dismissed(_ m: AdvisorMove) -> String { "advisor.\(m.rawValue).dismissed" }
        static let actedEvents = "advisor.actedEvents"
        static let silentEvents = "advisor.silentEvents"
        static let gated = "advisor.gated"
    }
}
