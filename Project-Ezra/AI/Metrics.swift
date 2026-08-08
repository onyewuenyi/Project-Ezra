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
        // "planned" entries (the daily Today plan) are excluded: a plan is not an
        // AI *action on a task* the user accepts or rejects, so folding it in would
        // distort the trust number. It is not reversible and not inbox-visible for
        // the same reason — see `ChangeLogEntry.plannedAction`.
        let aiEntries = entries.filter {
            $0.initiatedBy == .ai && $0.action != ChangeLogEntry.plannedAction
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
/// time-to-first-payoff (install → first committed capture, target <60s).
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

    /// Stamp the first committed capture; later commits are no-ops.
    func recordFirstPayoffIfNeeded(now: Date = Date()) {
        guard firstPayoffAt == nil else { return }
        firstPayoffAt = now
        defaults.set(now, forKey: Key.firstPayoffAt)
    }

    private enum Key {
        static let opens = "metrics.selfInitiatedOpens"
        static let installedAt = "metrics.installedAt"
        static let firstPayoffAt = "metrics.firstPayoffAt"
    }
}

// MARK: - Today plan instrumentation (spec §7)

/// The Today sequence's own instrumentation, kept next to `MetricsRecorder` and the
/// same shape: injectable `UserDefaults`, on-device only, counted signals that can't
/// be derived after the fact. Which tier produced a plan, its latency and token
/// cost (−1 when the model doesn't expose usage), how many planned tasks got
/// skipped, and how often the user tapped through the cinematic beats before the
/// stagger finished (a high count on first playthrough ⇒ §4 pacing is too slow).
/// V0 has no manual reorder — the AI owns order — so there is no reorder signal.
@MainActor
@Observable
final class PlanMetrics {
    private let defaults: UserDefaults

    private(set) var onDeviceCount: Int
    private(set) var pccCount: Int
    private(set) var deterministicCount: Int
    private(set) var lastLatencyMs: Int
    private(set) var lastPromptTokens: Int
    private(set) var lastOutputTokens: Int
    private(set) var skips: Int
    private(set) var interruptions: Int
    /// The tier that produced the last returned plan ("on-device"/"pcc"/"rules").
    private(set) var lastTier: String?
    /// The typed label of the last *swallowed* model-tier failure (timedOut,
    /// guardrailViolation, exceededContextWindowSize, modelNotReady, …) — the one signal
    /// that tells us WHY the advisor fell back. Cleared on a successful on-device plan.
    private(set) var lastError: String?
    /// `SystemLanguageModel.default.availability` at the last generation attempt.
    private(set) var lastAvailability: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.onDeviceCount = defaults.integer(forKey: Key.onDeviceCount)
        self.pccCount = defaults.integer(forKey: Key.pccCount)
        self.deterministicCount = defaults.integer(forKey: Key.deterministicCount)
        self.lastLatencyMs = defaults.object(forKey: Key.lastLatencyMs) as? Int ?? -1
        self.lastPromptTokens = defaults.object(forKey: Key.lastPromptTokens) as? Int ?? -1
        self.lastOutputTokens = defaults.object(forKey: Key.lastOutputTokens) as? Int ?? -1
        self.skips = defaults.integer(forKey: Key.skips)
        self.interruptions = defaults.integer(forKey: Key.interruptions)
        self.lastTier = defaults.string(forKey: Key.lastTier)
        self.lastError = defaults.string(forKey: Key.lastError)
        self.lastAvailability = defaults.string(forKey: Key.lastAvailability)
    }

    /// Record a completed generation: bump the tier's count and stamp the latest
    /// latency/token readings. `promptTokens`/`outputTokens` are −1 when the model
    /// surface doesn't expose usage (device-verify wires the real numbers).
    func recordGeneration(tier: PlanTier, latencyMs: Int, promptTokens: Int, outputTokens: Int) {
        switch tier {
        case .onDevice:
            onDeviceCount += 1
            defaults.set(onDeviceCount, forKey: Key.onDeviceCount)
            // A successful on-device plan means the advisor worked — clear the last
            // failure so a stale error doesn't linger in the diagnostics.
            lastError = nil
            defaults.removeObject(forKey: Key.lastError)
        case .pcc:
            pccCount += 1
            defaults.set(pccCount, forKey: Key.pccCount)
        case .deterministic:
            deterministicCount += 1
            defaults.set(deterministicCount, forKey: Key.deterministicCount)
        }
        lastTier = tierLabel(tier)
        defaults.set(lastTier, forKey: Key.lastTier)
        lastLatencyMs = latencyMs
        lastPromptTokens = promptTokens
        lastOutputTokens = outputTokens
        defaults.set(latencyMs, forKey: Key.lastLatencyMs)
        defaults.set(promptTokens, forKey: Key.lastPromptTokens)
        defaults.set(outputTokens, forKey: Key.lastOutputTokens)
    }

    /// Record a *swallowed* model-tier failure (the tier threw and the chain fell
    /// through). This is what surfaces WHY the advisor voice is missing.
    func recordFailure(tier: PlanTier, label: String, availability: String) {
        lastError = "\(tierLabel(tier)):\(label)"
        lastAvailability = availability
        defaults.set(lastError, forKey: Key.lastError)
        defaults.set(availability, forKey: Key.lastAvailability)
    }

    private func tierLabel(_ tier: PlanTier) -> String {
        switch tier {
        case .onDevice: return "on-device"
        case .pcc: return "pcc"
        case .deterministic: return "rules"
        }
    }

    /// A task that was on today's plan but got deferred or killed that day (§7).
    func recordSkip() {
        skips += 1
        defaults.set(skips, forKey: Key.skips)
    }

    /// The user tapped through a beat before its stagger finished — the §4 pacing
    /// signal.
    func recordInterruption() {
        interruptions += 1
        defaults.set(interruptions, forKey: Key.interruptions)
    }

    private enum Key {
        static let onDeviceCount = "today.gen.count.onDevice"
        static let pccCount = "today.gen.count.pcc"
        static let deterministicCount = "today.gen.count.deterministic"
        static let lastLatencyMs = "today.gen.lastLatencyMs"
        static let lastPromptTokens = "today.gen.lastPromptTokens"
        static let lastOutputTokens = "today.gen.lastOutputTokens"
        static let skips = "today.plan.skips"
        static let interruptions = "today.seq.interruptions"
        static let lastTier = "today.gen.lastTier"
        static let lastError = "today.gen.lastError"
        static let lastAvailability = "today.gen.lastAvailability"
    }
}

/// Per-capability model-call outcomes — the evidence behind `ModelDeadline.cardSeconds`.
///
/// Picking a 20-second deadline without data is guesswork, and the Today plan already
/// regressed once from a deadline that was too tight for a cold model. This records what
/// actually happens so the next adjustment is measured rather than argued.
///
/// **Local only, and that is a deliberate boundary.** Same shape as `PlanMetrics`:
/// UserDefaults-backed, surfaced in the DEBUG diagnostics footer, never transmitted.
/// `prev-docs/product-guardrails.md` refuses vanity metrics and the store holds real
/// personal data, so shipping per-feature latency off-device would be a product-posture
/// change — one that deserves its own decision, not a ride along inside a timeout fix.
///
/// A singleton because `ModelRun` is a free function with no instance to hang off, unlike
/// `PlanMetrics` which rides on `AppBrain`.
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
            if entry.lastPromptTokens >= 0 {
                line += " · \(entry.lastPromptTokens)"
                if entry.lastContextSize > 0 { line += "/\(entry.lastContextSize)" }
                line += " tok"
            }
            if let error = entry.lastError { line += " · \(error)" }
            return line
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

// MARK: - Capability-card outcomes (does anyone USE these cards?)

/// Whether a capability card is ACTED ON, per kind — the half `ModelMetrics` can't see.
/// That class measures whether the *model* worked; this one measures whether the *offer*
/// did. An ignored card costs attention on every render, and every S4 threshold
/// (the 60/30-minute breakdown bars, deferral ≥ 3, the subsumption rules) is currently
/// a guess — these counters are the evidence they get tuned or pruned on.
///
/// Local-only, never transmitted, same charter as `ModelMetrics`: this exists so the
/// offer heuristics are argued from numbers, not intuition. Offered = the card rendered
/// on an ACTIVE page (once per visit — the pager keeps neighbours mounted, and a
/// mounted neighbour nobody looked at is not an offer). Acted = any of the card's own
/// actions tapped.
@MainActor
final class CapabilityMetrics {
    static let shared = CapabilityMetrics()

    /// The card kinds, deliberately flattened from `Capability` (which carries per-case
    /// payloads): the question here is "which OFFER", not "which diagnosis".
    enum Kind: String, CaseIterable {
        case thinkingPartner
        case breakDown
        case unstick

        var label: String {
            switch self {
            case .thinkingPartner: return "tp"
            case .breakDown: return "bd"
            case .unstick: return "un"
            }
        }
    }

    struct Stats: Equatable {
        var offered = 0
        var acted = 0
    }

    private let defaults: UserDefaults
    private(set) var stats: [Kind: Stats] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for kind in Kind.allCases {
            stats[kind] = Stats(
                offered: defaults.integer(forKey: Key.offered(kind)),
                acted: defaults.integer(forKey: Key.acted(kind)))
        }
    }

    func recordOffered(_ kind: Kind) {
        stats[kind, default: Stats()].offered += 1
        defaults.set(stats[kind]?.offered ?? 0, forKey: Key.offered(kind))
    }

    func recordActed(_ kind: Kind) {
        stats[kind, default: Stats()].acted += 1
        defaults.set(stats[kind]?.acted ?? 0, forKey: Key.acted(kind))
    }

    /// One DEBUG-footer line: `cards: tp 3/9 · bd 1/7 · un 4/5` (acted/offered).
    /// Nil when nothing has ever been offered — no line beats a row of zeros.
    var footerLine: String? {
        let parts = Kind.allCases.compactMap { kind -> String? in
            guard let entry = stats[kind], entry.offered > 0 else { return nil }
            return "\(kind.label) \(entry.acted)/\(entry.offered)"
        }
        guard !parts.isEmpty else { return nil }
        return "cards: " + parts.joined(separator: " · ")
    }

    private enum Key {
        static func offered(_ k: Kind) -> String { "cards.\(k.rawValue).offered" }
        static func acted(_ k: Kind) -> String { "cards.\(k.rawValue).acted" }
    }
}

extension Capability {
    /// The telemetry bucket this offer lands in — diagnosis payloads flattened away.
    var metricsKind: CapabilityMetrics.Kind {
        switch self {
        case .thinkingPartner: return .thinkingPartner
        case .breakDown: return .breakDown
        case .unstick: return .unstick
        }
    }
}
