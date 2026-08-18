//
//  AdvisorSession.swift
//  Project-Ezra
//
//  The advisor is a SESSION, not a call. One `DynamicProfile`-backed conversation per
//  day (the `CaptureConversation` pattern): the morning generation is turn 1 in the
//  transcript, and a mid-day recompose is a DELTA TURN — the advisor re-reads its own
//  morning reasoning instead of the plan freezing at 7am. On-device only, at the
//  model's ceiling: `.deep` reasoning is the pinned prior (the 30s + salvage budget
//  absorbs it, prewarmed behind the Recap; the device A/B may demote it).
//
//  Tools, ungated (owner decision, 2026-08-11): two narrow READ-ONLY tools let the
//  advisor pull detail only when it is weighing a candidate, instead of every prompt
//  pre-packing everything. Snapshot-backed — a tool reads a value box built at request
//  time, never Core Data (the snapshot-per-seam discipline). `toolCallingMode(.allowed)`
//  plus an instructions bound is the over-calling mitigation; `PlanMetrics` counts the
//  calls, which is the tripwire.
//
//  ⚠️ Device-verify: reasoning latency, tool-call counts, and the delta turn's
//  complete-plan contract. The simulator may or may not exercise any of this.
//

import Foundation
import FoundationModels

// MARK: - Tool context (the value box tools read)

/// Snapshot state the tools serve — rebuilt before every turn, lock-guarded because
/// tool calls arrive off the main actor mid-generation.
final class AdvisorToolContext: @unchecked Sendable {
    private let lock = NSLock()
    private var _details: [String: String] = [:]
    private var _yesterday: String?
    private var _toolCalls = 0

    var details: [String: String] {
        get { lock.withLock { _details } }
        set { lock.withLock { _details = newValue } }
    }
    var yesterday: String? {
        get { lock.withLock { _yesterday } }
        set { lock.withLock { _yesterday = newValue } }
    }
    /// Incremented by the tools themselves — the over-calling tripwire's raw number.
    var toolCalls: Int {
        get { lock.withLock { _toolCalls } }
        set { lock.withLock { _toolCalls = newValue } }
    }
    func recordCall() { lock.withLock { _toolCalls += 1 } }
}

// MARK: - The tools (narrow, read-only, snapshot-backed)

/// Detail on ONE candidate, on demand: notes, provenance, blockers, children,
/// deferral facts. Ids outside the candidate set get the anti-hallucination answer.
struct TaskDetailsTool: Tool {
    let name = "task_details"
    let description =
        "Look up extra detail on one candidate task (notes, why it exists, what blocks it, "
        + "how it has been deferred). Use the exact [uuid] from the candidate list. "
        + "Consult it only when weighing a candidate — a few calls at most."

    let box: AdvisorToolContext

    @Generable
    struct Arguments {
        @Guide(description: "The candidate's id, copied exactly from the list.")
        let taskID: String
    }

    func call(arguments: Arguments) async throws -> String {
        box.recordCall()
        let key = arguments.taskID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let detail = box.details[key] { return detail }
        return "Unknown id — not one of today's candidates. Choose only from the given list."
    }
}

/// Yesterday's outcome as one deterministic digest — observable facts, never AI
/// internals. The A1 "advisor memory" read-side, delivered as a tool.
struct YesterdayOutcomeTool: Tool {
    let name = "yesterday_outcome"
    let description =
        "What happened yesterday: how much was completed, and which of today's candidates "
        + "carried over or slid. Call at most once, when composing the day."

    let box: AdvisorToolContext

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        box.recordCall()
        return box.yesterday ?? "No record of yesterday — likely a first run. Compose from today's facts."
    }
}

// MARK: - Profile

/// The advisor's session configuration — instructions bound to how it runs: the existing
/// 600-token output cap, `.allowed` tool calling, and a history window so a day of turns
/// never outgrows the context (the delta-turn contract makes every response complete on
/// its own).
///
/// **No reasoning level, and that is a finding (2026-08-17).** This asked for `.deep`,
/// which made every on-device Today generation fail with `unsupportedCapability` —
/// visible in the device log as `[TodayPlan] tier onDevice failed: unsupportedCapability
/// (availability: available)`, so the day's plan silently fell through to the
/// deterministic tail every single time. `SystemLanguageModel` reports
/// `capabilities.contains(.reasoning) == false`; Apple's own guidance is that models
/// differ in which capabilities they support and `contains()` exists to be checked first.
///
/// `.light`/`.moderate`/`.deep` belong to reasoning-capable paths, PCC among them — and
/// PCC is not the fix, because the product constraint is on-device. The lesson is the
/// same one the Task Advisor learned in the same hour: **quality here cannot be bought
/// with a reasoning dial.** What this path DOES have is `guidedGeneration` and
/// `toolCalling` (both true on device), which is why this profile's tools matter more
/// than its reasoning ever did.
struct AdvisorProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let box: AdvisorToolContext

    static let historyWindow = 6

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            TaskDetailsTool(box: box)
            YesterdayOutcomeTool(box: box)
        }
        .maximumResponseTokens(TodayPlanSession.responseTokenCap)
        .toolCallingMode(.allowed)
        .historyTransform { history in
            Array(history.suffix(Self.historyWindow))
        }
    }
}

// MARK: - The session

/// One per day, owned by `AppBrain`. Turn 1 is the morning briefing; later turns are
/// recompositions. When the process restarts mid-day the transcript is gone — the
/// caller reconstructs continuity with a morning digest in the prompt instead
/// (`TodayPlanRequest.deltaContext`), so the product behavior survives either way.
final class AdvisorSession {
    let dayKey: String
    let box: AdvisorToolContext
    private let session: LanguageModelSession
    private(set) var turn = 0

    /// The context-measured candidate budget, once the async measurement lands.
    /// Nil until then (callers fall back to the fixed cap).
    private(set) var measuredCandidateCap: Int?

    init(dayKey: String, instructions: String) {
        self.dayKey = dayKey
        let box = AdvisorToolContext()
        self.box = box
        self.session = LanguageModelSession(
            profile: AdvisorProfile(instructions: instructions, box: box))
        // Warm the REAL prefix — instructions + prompt head — behind the Recap cover,
        // so turn 1 isn't paying instruction processing against the deadline.
        session.prewarm(promptPrefix: Prompt("COMPLETED TODAY SO FAR:"))
        measureBudget()
    }

    /// One turn: update the tool box, send the prompt, stream the briefing. The shared
    /// `TodayPlanSession` driver does the schema mapping and validation.
    func respond(
        request: TodayPlanRequest,
        onPartial: (@MainActor (GeneratedPlan) -> Void)?
    ) async throws -> GeneratedPlan {
        box.details = Self.detailIndex(for: request)
        box.yesterday = request.yesterdayOutcome
        box.toolCalls = 0
        turn += 1
        return try await TodayPlanSession.generate(
            session: session, request: request, tier: .onDevice, onPartial: onPartial)
    }

    /// The candidate-detail index the `task_details` tool serves, keyed by lowercased
    /// uuid. Built from the request's own snapshots + the tool details the request
    /// carried — pure, testable.
    static func detailIndex(for request: TodayPlanRequest) -> [String: String] {
        var index: [String: String] = [:]
        for snapshot in request.candidates {
            let key = snapshot.id.uuidString.lowercased()
            index[key] = request.toolDetails[key] ?? snapshot.factLine
        }
        return index
    }

    /// Measure the fixed overhead (instructions + tools + a per-candidate estimate)
    /// against the model's real context size, and derive how many candidates fit.
    /// Async and best-effort: until it lands, the fixed cap serves.
    private func measureBudget() {
        Task { [weak self, session] in
            guard let self else { return }
            let model = SystemLanguageModel.default
            guard case .available = model.availability else { return }
            let overhead = (try? await model.tokenCount(for: session.transcript)) ?? 0
            let contextSize = model.contextSize
            self.measuredCandidateCap = AdvisorContextBudget.candidateCount(
                overheadTokens: overhead, contextSize: contextSize)
        }
    }
}

// MARK: - Context budget (pure)

/// How many ranked candidates fit the real context window. Replaces the fixed guess:
/// measure the fixed prompt overhead, keep a safety margin for reasoning + tool
/// round-trips + the response, and fill the remainder — floored so a heavy overhead
/// never starves the plan, ceilinged so a huge window doesn't drown the advisor.
enum AdvisorContextBudget {
    static let perCandidateTokens = 40
    static let safetyMargin = 1200
    static let floor = 8
    static let ceiling = 24

    static func candidateCount(overheadTokens: Int, contextSize: Int) -> Int {
        guard contextSize > 0 else { return TodayPlanRequest.candidateCap }
        let available = contextSize - overheadTokens - safetyMargin
        let fit = available / perCandidateTokens
        return min(max(fit, floor), ceiling)
    }
}

// MARK: - Yesterday digest (pure)

/// The deterministic outcome digest the `yesterday_outcome` tool serves — and the
/// continuity block a process-restart recompose falls back on. Observable facts only.
enum YesterdayDigest {
    static func make(tasks: [TaskItem], logs: [CapacityLog], now: Date) -> String? {
        let cal = Calendar.current
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: now) else { return nil }
        let completed = logs.first {
            $0.date.map { cal.isDate($0, inSameDayAs: yesterday) } ?? false
        }?.completedCount

        // Candidates that were surfaced yesterday and are still open: the ones that
        // carried (worked-but-unfinished) or slid (planned-and-untouched).
        let surfacedYesterday = tasks.filter { task in
            guard task.status.isLive, let surfaced = task.lastSurfacedAt else { return false }
            return cal.isDate(surfaced, inSameDayAs: yesterday)
        }
        let slid = surfacedYesterday.filter { $0.deferralCount > 0 }.map(\.title)
        let carried = surfacedYesterday.filter { $0.deferralCount == 0 }.map(\.title)

        var lines: [String] = []
        if let completed { lines.append("Yesterday: \(completed) completed.") }
        if !carried.isEmpty {
            lines.append("Carried into today: " + carried.prefix(4).joined(separator: "; ") + ".")
        }
        if !slid.isEmpty {
            lines.append("Slid without a touch: " + slid.prefix(4).joined(separator: "; ") + ".")
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
