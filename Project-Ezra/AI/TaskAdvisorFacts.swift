//
//  TaskAdvisorFacts.swift
//  Project-Ezra
//
//  The deterministic FACTS the Advisor judges over. Sensors feed facts; the Advisor is
//  the judge: `StallDetector`, `BreakdownEligibility` and `DecisionShape` are stated to
//  the model as SENSOR lines it interprets but cannot invent (the `UnstickNarration`
//  pattern), and the graph neighbourhood is pre-packed deterministically — the model
//  never sees Core Data and never owns the diagnosis.
//
//  The FINGERPRINT is the invariant that makes the Advisor calm: same task + same
//  meaningful context → same Advisor state. Continuously understanding ≠ continuously
//  generating — the state is maintained on every visit, the intelligence regenerates
//  only when a meaningful fact changes. Deliberately excluded: the raw staleness clock
//  (it ticks daily and would churn the cache — the diagnosis CASE flipping is the fact
//  that matters), owner, and category (they don't change what help is needed).
//  In-memory only, so `Hasher`'s per-launch seed is fine: the cache the fingerprint
//  keys doesn't outlive the launch either.
//

import Foundation

struct TaskAdvisorFacts: Sendable, Equatable {
    var id: UUID?
    var title: String
    var notes: String?
    var category: String
    var rawCapture: String
    var reasoning: String
    var status: TaskStatus
    var effortMinutes: Int?
    var dueDate: Date?
    /// Days past due (positive), nil when not overdue. Prompt-only; NOT in the
    /// fingerprint — it ticks with the calendar, and `dueDate` carries the fact.
    var overdueDays: Int?
    var isUrgent: Bool
    var needsDecision: Bool
    var isJudgmentCall: Bool
    var decisionShaped: Bool
    /// Full count — this IS the stall surface now; the Today advisor's 2–3 band
    /// deliberately does not apply here.
    var deferralCount: Int
    /// Prompt-only; NOT in the fingerprint (the raw clock churns daily).
    var quietDays: Int
    var blockerTitles: [String]
    var blockerIDs: [UUID]
    var dependentTitles: [String]
    var childIDs: [UUID]
    var openStepTitles: [String]
    var stepLabel: String?
    var parentTitle: String?
    var diagnosis: StallDiagnosis?
    var breakdownReason: BreakdownEligibility.Reason?
    /// Axis 2, prompt-only — never rendered as a label anywhere.
    var workIntent: WorkIntent?
    /// The relevant surrounding work (`ContextRetrieval`). Filled by the service right
    /// before generation, NOT in `make` — retrieval may run embedding inferences, and
    /// the facts build must stay cheap enough to run on every page activation. Never
    /// part of the fingerprint.
    var relatedLines: [String] = []

    /// How many retrieved neighbours reach the prompt.
    static let relatedCap = 5

    static func make(
        task: TaskItem, among tasks: [TaskItem], now: Date = Date()
    )
        -> TaskAdvisorFacts
    {
        let blockers = task.activeBlockerTasks(among: tasks)
        let children = task.children(among: tasks)
        let overdue = task.dueDate.flatMap { due -> Int? in
            guard let days = TaskItem.daysUntil(due, now: now), days < 0 else { return nil }
            return -days
        }
        return TaskAdvisorFacts(
            id: task.uuid,
            title: task.title,
            notes: task.notes,
            category: task.category,
            rawCapture: task.rawCapture,
            reasoning: task.reasoning,
            status: task.status,
            effortMinutes: task.effortMinutes,
            dueDate: task.dueDate,
            overdueDays: overdue,
            isUrgent: task.isUrgent,
            needsDecision: task.needsDecision,
            isJudgmentCall: task.isJudgmentCall,
            decisionShaped: DecisionShape.reads(title: task.title),
            deferralCount: Int(task.deferralCount),
            quietDays: max(0, Int(now.timeIntervalSince(task.humanTouchedAt) / 86_400)),
            blockerTitles: blockers.map(\.title),
            blockerIDs: blockers.compactMap(\.uuid).sorted { $0.uuidString < $1.uuidString },
            dependentTitles: task.dependents(among: tasks).map(\.title),
            childIDs: children.compactMap(\.uuid).sorted { $0.uuidString < $1.uuidString },
            openStepTitles: task.openSteps(among: tasks).map(\.title),
            stepLabel: task.stepProgress(among: tasks)?.label,
            parentTitle: task.parentTaskID.flatMap { id in tasks.first { $0.uuid == id }?.title },
            // The RAW sensor reading — no `suppressChoiceRung`, because one-intervention-
            // per-problem is solved by construction here: a single-move response can't
            // stack cards, so the model sees every sensor and picks one shape of help.
            diagnosis: StallDetector.diagnose(task, among: tasks, now: now),
            breakdownReason: BreakdownEligibility.evaluate(task, among: tasks),
            workIntent: task.workIntent
        )
    }

    /// The exact fields whose change warrants a NEW judgment — pinned by
    /// `TaskAdvisorFactsTests`, because every addition here is a cache-invalidation
    /// decision, not a convenience.
    var fingerprint: Int {
        var hasher = Hasher()
        hasher.combine(status.rawValue)
        hasher.combine(title)
        hasher.combine(notes)
        hasher.combine(effortMinutes)
        hasher.combine(dueDate.map { Calendar.current.startOfDay(for: $0) })
        hasher.combine(isUrgent)
        hasher.combine(needsDecision)
        hasher.combine(isJudgmentCall)
        hasher.combine(deferralCount)
        hasher.combine(blockerIDs)
        hasher.combine(childIDs)
        hasher.combine(openStepTitles.count)
        hasher.combine(diagnosis)
        hasher.combine(breakdownReason)
        return hasher.finalize()
    }

    /// The whole volatile prompt — pure fact lines, pinned by tests so the facts the
    /// model may use are exactly the facts the sensors used. Starts with "FACTS:" —
    /// the prewarm prefix.
    var promptBlock: String {
        var lines = ["FACTS:", "TASK: \(title)", "AREA: \(category)"]
        lines.append("STATUS: \(status == .doing ? "in progress" : "not started")")
        if let effort = effortMinutes { lines.append("ESTIMATED: ~\(effort) min") }
        if let overdueDays {
            lines.append("DUE: \(overdueDays) day\(overdueDays == 1 ? "" : "s") overdue")
        } else if let dueDate {
            let days = TaskItem.daysUntil(dueDate, now: Date()) ?? 0
            lines.append(days == 0 ? "DUE: today" : "DUE: in \(days) day\(days == 1 ? "" : "s")")
        }
        if isUrgent { lines.append("URGENT: flagged by the person") }
        if needsDecision {
            lines.append(
                isJudgmentCall
                    ? "DECISION FLAG: open — a values call only the person can make"
                    : "DECISION FLAG: open — filed with low confidence")
        }
        if decisionShaped { lines.append("WORDING: reads as a choice") }
        if let diagnosis {
            lines.append("SENSOR: stalled — \(Self.sensorLine(for: diagnosis))")
            if deferralCount > 0 {
                lines.append(
                    "Set aside \(deferralCount) time\(deferralCount == 1 ? "" : "s") in a row")
            }
            if quietDays > 0 { lines.append("No touch in \(quietDays) days") }
        }
        if let reason = breakdownReason {
            lines.append("SENSOR: looks decomposable — \(reason.rationale.lowercased())")
        }
        if !blockerTitles.isEmpty {
            lines.append("WAITING ON: " + blockerTitles.joined(separator: "; "))
        }
        if !dependentTitles.isEmpty {
            lines.append("BLOCKS: " + dependentTitles.joined(separator: "; "))
        }
        if let stepLabel {
            var line = "STEPS: \(stepLabel)"
            if !openStepTitles.isEmpty { line += " — open: " + openStepTitles.joined(separator: "; ") }
            lines.append(line)
        }
        if let parentTitle { lines.append("PART OF: \(parentTitle)") }
        if let notes, !notes.isEmpty { lines.append("NOTES: \(notes)") }
        if !rawCapture.isEmpty { lines.append("THEY SAID: \(rawCapture)") }
        if !reasoning.isEmpty { lines.append("WHY IT EXISTS: \(reasoning)") }
        if !relatedLines.isEmpty {
            lines.append("RELATED OPEN TASKS: " + relatedLines.joined(separator: " · "))
        }
        if workIntent == .planning { lines.append("INTERNAL: planning work") }
        return lines.joined(separator: "\n")
    }

    /// The fixed statement of each diagnosis — the same vocabulary the retired
    /// narration prompt pinned, so the model interprets a reading it cannot re-diagnose.
    static func sensorLine(for diagnosis: StallDiagnosis) -> String {
        switch diagnosis {
        case .blocked: return "waiting on something else"
        case .tooBig: return "too big to start"
        case .reallyADecision: return "worded as a choice, not a doable step"
        case .dying: return "repeatedly set aside"
        }
    }
}
