//
//  TodayPlanGenerator.swift
//  Project-Ezra
//
//  The seam for the Today advisor briefing. Unlike the prior pipeline (where
//  `TaskRanking` fixed membership/order and the model only narrated), the model now
//  acts as an **expert advisor**: it SELECTS which tasks matter today, ORDERS them,
//  decides HOW MANY, and reasons about them (headline · action plan · tradeoffs ·
//  risks). `TaskRanking` is demoted to two supporting jobs — it provides the capped
//  candidate set handed to the model, and it is the deterministic FALLBACK when no
//  model is available (sim / offline / on-device disabled).
//
//  The old mechanical `sanitized(against:)` (which re-imposed a deterministic order)
//  is replaced by `validated(against:)` — it no longer ranks; it only guards against
//  hallucination: keeps ids that are real candidates, dedupes, and caps at a sane
//  max. The advisor's headline/tradeoffs/risks pass through as its voice.
//
//  Value snapshots cross the seam, never `NSManagedObject`s (house rule, per
//  `OpenTaskSnapshot`).
//

import Foundation
import FoundationModels

// MARK: - Value snapshots across the seam

/// One task, snapshotted as a Sendable/Codable value for the plan seam. `facts`
/// are deterministic, observable-fact strings ("due today", "3d overdue", "blocks
/// 'Book flights'") — they ground the advisor (it reasons only from these) AND back
/// the deterministic fallback's per-action line.
struct PlanTaskSnapshot: Sendable, Codable, Hashable {
    let id: UUID
    let title: String
    let category: String
    let dueDate: Date?
    /// Whole days overdue (≥ 1) when overdue; nil otherwise.
    let overdueDays: Int?
    let needsDecision: Bool
    /// Titles of the open tasks that wait on this one (the reverse edge).
    let blocksTitles: [String]
    let effortMinutes: Int?
    /// The DISPLAY facts — user-visible: they back the deterministic fallback's line
    /// and the validated backfill. Calm, observable, never machinery.
    let facts: [String]
    /// Advisor-only facts — internal reasoning signals the model may weigh but the
    /// user never sees ("planning work", "set aside N×"). Internal signals must not
    /// become accidental UI just because the system reasons about them. Optional so
    /// day-cache rows written before this decode as nil (no shape break).
    let promptOnlyFacts: [String]?

    /// Build a snapshot from a live task, computing its observable facts against the
    /// working set and an injected `now`. Nil when the task has no stable id.
    static func from(_ task: TaskItem, among tasks: [TaskItem], now: Date) -> PlanTaskSnapshot? {
        guard let id = task.uuid else { return nil }
        let cal = Calendar.current
        let dueToday = task.dueDate.map { cal.isDate($0, inSameDayAs: now) } ?? false
        let overdueDays: Int? = {
            guard task.isOverdue(now: now), let due = task.dueDate else { return nil }
            // Shared due-delta derivation (negative = overdue) → whole days late, floor 1.
            return TaskItem.daysUntil(due, now: now).map { max(1, -$0) }
        }()
        let needsDecision = task.needsDecision && !task.status.isResolved
        let blocksTitles = task.dependents(among: tasks).map(\.title)

        var facts: [String] = []
        // Already picked up. Rides the existing facts array on purpose: it reaches
        // the advisor prompt via `promptLine` AND the deterministic fallback's line
        // via `factLine`, with no new stored property and no day-cache shape change.
        if task.status == .doing { facts.append("in progress") }
        if dueToday {
            facts.append("due today")
        } else if let days = overdueDays {
            facts.append("\(days)d overdue")
        }
        if needsDecision { facts.append("needs a decision") }
        for title in blocksTitles { facts.append("blocks ‘\(title)’") }
        if let effort = task.effortMinutes, effort > 0 { facts.append("~\(effort) min") }

        // Advisor-only signals. "planning work" = axis 2's internal classification
        // (a signal for composing the day, never a quota). The deferral fact is a
        // BOUNDED intervention: only the 2–3 band reaches the advisor — 0–1 is normal
        // ranking, and 4+ is StallDiagnosis/Unstick territory, so escalating advisor
        // pressure never becomes a defer → re-plan → defer loop.
        var promptOnly: [String] = []
        if task.workIntent == .planning { promptOnly.append("planning work") }
        if (2...3).contains(task.deferralCount) {
            promptOnly.append("set aside \(task.deferralCount)×")
        }

        return PlanTaskSnapshot(
            id: id, title: task.title, category: task.category, dueDate: task.dueDate,
            overdueDays: overdueDays, needsDecision: needsDecision, blocksTitles: blocksTitles,
            effortMinutes: task.effortMinutes, facts: facts,
            promptOnlyFacts: promptOnly.isEmpty ? nil : promptOnly)
    }

    /// The DISPLAY facts as one calm line — the deterministic fallback's per-action
    /// line. Reads `facts` only, never the advisor-only signals.
    var factLine: String { facts.joined(separator: " · ") }

    /// The prompt row: `1. [uuid] Title — due today · ~15 min · planning work`.
    /// The advisor sees display facts PLUS the internal signals.
    func promptLine(index: Int) -> String {
        let promptFacts = facts + (promptOnlyFacts ?? [])
        let suffix = promptFacts.isEmpty ? "" : " — \(promptFacts.joined(separator: " · "))"
        return "\(index). [\(id.uuidString)] \(title)\(suffix)"
    }
}

// MARK: - Request / response

/// Which intelligence produced (or will produce) a briefing. `.deterministic` is the
/// always-available tail — it can't fail, so the chain always terminates.
enum PlanTier: String, Codable, Sendable {
    case onDevice
    case pcc
    case deterministic
}

/// One action on the plan: a task id plus the advisor's one-line reasoning for it.
/// Codable so it can live in the day cache.
struct PlannedAction: Sendable, Codable, Hashable {
    let taskID: UUID
    var rationale: String?
}

/// The input to a briefing generation. The advisor chooses from `candidates`
/// (`TaskRanking` order, capped for context budget); `typicalCompleted` is advisory
/// context only (the user's rolling daily throughput), never a hard limit.
struct TodayPlanRequest: Sendable {
    let candidates: [PlanTaskSnapshot]
    let recapCount: Int
    /// The user's rolling completion average, when enough history exists — informs
    /// the advisor's sizing, never gates it. Nil = cold start (say nothing).
    let typicalCompleted: Int?
    let now: Date

    /// The context-budget cap on the candidate set handed to the advisor.
    static let candidateCap = 12

    /// The deterministic fallback's action count: the typical throughput when known,
    /// else a sane default, clamped to what exists.
    var fallbackCount: Int {
        let target = typicalCompleted ?? 5
        return min(max(1, min(target, GeneratedPlan.maxActions)), candidates.count)
    }

    /// Build a request from the ranked candidate items and the full working set (for
    /// reverse-edge facts).
    static func make(
        candidateItems: [TaskItem], allTasks: [TaskItem], recapCount: Int,
        typicalCompleted: Int?, now: Date
    ) -> TodayPlanRequest {
        let candidates =
            candidateItems
            .prefix(candidateCap)
            .compactMap { PlanTaskSnapshot.from($0, among: allTasks, now: now) }
        return TodayPlanRequest(
            candidates: Array(candidates), recapCount: recapCount,
            typicalCompleted: typicalCompleted, now: now)
    }
}

/// The advisor's briefing. `headline`/`tradeoffs`/`risks` are the advisor's voice;
/// `actions` are the tasks it chose (its order, its count). Codable for the day cache.
struct GeneratedPlan: Sendable, Codable, Hashable {
    var actions: [PlannedAction]
    var headline: String?
    var tradeoffs: String?
    var risks: String?
    var tier: PlanTier

    /// A sanity cap on how many actions the advisor can spotlight.
    static let maxActions = 7

    /// The anti-hallucination guard — it does NOT rank. Keeps the advisor's order and
    /// selection intact, but drops any action whose id isn't a real candidate,
    /// collapses duplicates, backfills an empty line from the candidate's fact line,
    /// and caps at `maxActions`. Narrative fields pass through, trimmed.
    func validated(against request: TodayPlanRequest) -> GeneratedPlan {
        let byID = Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, $0) })
        var seen: Set<UUID> = []
        var cleaned: [PlannedAction] = []
        for action in actions {
            guard let snapshot = byID[action.taskID], seen.insert(action.taskID).inserted else {
                continue
            }
            let line =
                action.rationale?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? snapshot.factLine.nilIfEmpty
            cleaned.append(PlannedAction(taskID: action.taskID, rationale: line))
            if cleaned.count >= Self.maxActions { break }
        }
        return GeneratedPlan(
            actions: cleaned,
            headline: headline?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            tradeoffs: tradeoffs?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            risks: risks?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            tier: tier)
    }

    /// True when the briefing carries advisor voice (headline/tradeoffs/risks) — the
    /// deterministic fallback has none, so the UI can render a plainer layout.
    var hasAdvisorVoice: Bool {
        headline != nil || tradeoffs != nil || risks != nil
    }
}

// MARK: - Generator protocol

/// The generation seam. `onPartial` streams progressively validated briefings (device
/// tiers only); the deterministic tail ignores it and never throws.
protocol TodayPlanGenerator: Sendable {
    var tier: PlanTier { get }
    func generate(
        _ request: TodayPlanRequest,
        onPartial: (@MainActor (GeneratedPlan) -> Void)?
    ) async throws -> GeneratedPlan
}

// MARK: - Guided-generation schema

/// The advisor briefing the on-device / PCC model fills in. It selects and orders the
/// actions itself — the schema does not constrain it to a given order.
@Generable
struct AdvisorBriefing {
    @Guide(
        description:
            "A short, sharp headline for the day — an expert's one-line read (e.g. \"A focused morning, then breathing room\"). No exclamation marks, no pep talk."
    )
    let headline: String

    @Guide(
        description:
            "The tasks that actually matter today, in the priority order YOU choose — could be two, could be six. Only include what's worth doing today; leave the rest off. Each is a task id from the list plus one line on why it made the plan."
    )
    let actions: [AdvisorActionSchema]

    @Guide(
        description:
            "One or two plain sentences on what you're deliberately NOT prioritizing today, and why — the honest tradeoff."
    )
    let tradeoffs: String

    @Guide(
        description:
            "One or two plain sentences on the real risks in the day — what's overdue, blocked, or an open decision that could bite if ignored. Ground it in the given facts; never invent a deadline."
    )
    let risks: String
}

@Generable
struct AdvisorActionSchema {
    @Guide(
        description:
            "The task's id, copied verbatim from the bracketed [uuid] in the prompt. Only ids from the given list — never invent one."
    )
    let taskID: String

    @Guide(
        description:
            "One short line on why this task is on today's plan, grounded ONLY in the given facts (overdue, blocks, decision, effort). Never invent motivation, urgency, or a deadline."
    )
    let line: String
}

// MARK: - Deterministic generator (the always-available fallback)

/// The tier the simulator exercises and the chain ends on. With no model it can't be
/// an advisor — it degrades to the top `fallbackCount` candidates (TaskRanking order)
/// with fact-line reasoning and no headline/tradeoffs/risks. Never throws.
struct DeterministicPlanGenerator: TodayPlanGenerator {
    let tier: PlanTier = .deterministic

    func generate(
        _ request: TodayPlanRequest,
        onPartial: (@MainActor (GeneratedPlan) -> Void)?
    ) async throws -> GeneratedPlan {
        let actions =
            request.candidates
            .prefix(request.fallbackCount)
            .map { PlannedAction(taskID: $0.id, rationale: $0.factLine.nilIfEmpty) }
        return GeneratedPlan(
            actions: Array(actions), headline: nil, tradeoffs: nil, risks: nil, tier: tier)
    }
}

extension String {
    /// Nil when empty, self otherwise — for optional narration fields.
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
