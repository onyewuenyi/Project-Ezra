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
    /// Days until due (non-negative), nil when overdue or no due date. Precomputed at
    /// `make()` time so `promptBlock` never calls `Date()` at render time. Prompt-only;
    /// NOT in the fingerprint.
    var daysUntilDue: Int?
    var isUrgent: Bool
    var needsDecision: Bool
    var isJudgmentCall: Bool
    var decisionShaped: Bool
    /// Full count — this IS the stall surface now; the Today advisor's 2–3 band
    /// deliberately does not apply here.
    ///
    /// **Permanently zero since 2026-09-02.** Its one writer was the Brief's day-rollover
    /// and the Brief was cut; it is kept because the field is still read by the stall
    /// diagnosis's headline and by `TaskRanking`, and removing it is a schema decision
    /// rather than a router one. The depth router no longer reads it — see
    /// `abandonedStarts`.
    var deferralCount: Int
    /// **How many times the person picked this task up and put it back down** (closed
    /// `.doing` visits). The depth router's third input, and the live replacement for
    /// `deferralCount`: same hypothesis — *the obvious approach already failed* — with
    /// evidence that still exists.
    ///
    /// **In the fingerprint**, unlike the two clocks beside it: abandoning a start is a
    /// discrete human act that genuinely changes what the right reading is, so it SHOULD
    /// buy a new judgment. A clock that ticks on its own must not.
    var abandonedStarts: Int = 0
    /// Prompt-only; NOT in the fingerprint (the raw clock churns daily).
    var quietDays: Int
    var blockerTitles: [String]
    var blockerIDs: [UUID]
    /// The phrases on `.externalWait` blockers — "the vendor to call back".
    ///
    /// Separate from `blockerTitles` because these are the blockers with **no task to
    /// open**: `activeBlockerTasks` resolves `taskID`, so an external wait was dropped
    /// before it reached any rung. The task read as blocked to the gate and as unblocked
    /// to every consumer of the facts — including the prompt, which never mentioned it.
    /// The Advisor was blind to exactly the blocker the user cannot see as a row.
    var externalWaits: [String] = []
    var dependentTitles: [String]
    /// The dependents' ids, aligned with `dependentTitles` — what lets a reading that
    /// cites freed-up work render it as a tappable reference instead of prose.
    /// Derived, and deliberately NOT in the fingerprint (titles aren't either).
    var dependentIDs: [UUID] = []
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

    /// What this person has been declining lately, as INTERNAL guidance for the model —
    /// enriched by the store before judging, never fingerprinted (a preference is not a
    /// fact about the task, and it must not re-judge every task the moment it changes).
    /// Built by `Learned.advisorPreferences(from:)` over `HumanVerdicts.collect` (F-10).
    var advisorPreferences: [String] = []

    /// How many retrieved neighbours reach the prompt.
    static let relatedCap = 5

    static func make(
        task: TaskItem, among tasks: [TaskItem], now: Date = Date()
    )
        -> TaskAdvisorFacts
    {
        let blockers = task.activeBlockerTasks(among: tasks)
        // The external waits, kept apart: `.blocks` edges with no `targetID`, carrying a
        // free-text note instead of a task.
        let waits = task.activeBlockers(among: tasks)
            .filter { $0.taskID == nil }
            .compactMap(\.note)
        let children = task.children(among: tasks)
        let overdue = task.dueDate.flatMap { due -> Int? in
            guard let days = TaskItem.daysUntil(due, now: now), days < 0 else { return nil }
            return -days
        }
        let daysUntil =
            overdue == nil
            ? task.dueDate.flatMap { due -> Int? in
                guard let days = TaskItem.daysUntil(due, now: now), days >= 0 else { return nil }
                return days
            } : nil
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
            daysUntilDue: daysUntil,
            isUrgent: task.isUrgent,
            needsDecision: task.needsDecision,
            isJudgmentCall: task.isJudgmentCall,
            decisionShaped: DecisionShape.reads(title: task.title),
            deferralCount: Int(task.deferralCount),
            abandonedStarts: task.recentAbandonedStarts(
                within: StallDetector.quietThreshold, now: now),
            quietDays: max(0, Int(now.timeIntervalSince(task.humanTouchedAt) / 86_400)),
            blockerTitles: blockers.map(\.title),
            blockerIDs: blockers.compactMap(\.uuid).sorted { $0.uuidString < $1.uuidString },
            externalWaits: waits,
            dependentTitles: task.dependents(among: tasks).map(\.title),
            dependentIDs: task.dependents(among: tasks).compactMap(\.uuid),
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
        hasher.combine(abandonedStarts)
        hasher.combine(blockerIDs)
        // External waits have no id, so `blockerIDs` cannot see them — without this,
        // adding or resolving one would never invalidate the cached reading.
        hasher.combine(externalWaits)
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
        } else if let days = daysUntilDue {
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
        // A fact in its own right, not a sub-line of the stall sensor: a task can be
        // picked up and dropped twice without ever reading as stalled, and that is
        // precisely the case where the model most needs to know it.
        if abandonedStarts > 0 {
            lines.append(
                "PICKED UP AND PUT DOWN: \(abandonedStarts) time\(abandonedStarts == 1 ? "" : "s")")
        }
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
        if !blockerTitles.isEmpty || !externalWaits.isEmpty {
            lines.append("WAITING ON: " + (blockerTitles + externalWaits).joined(separator: "; "))
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
        for preference in advisorPreferences { lines.append("INTERNAL: \(preference)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Fitting the phone's window

    /// How much of the volatile tail to give up so the prompt fits the model's context
    /// window — the phone's is 4096 tokens (the simulator's 8192 hides this). Ordered
    /// cheapest-loss first: the retrieved neighbours go before the person's own words,
    /// and the words are clipped before they are dropped. The first three levels leave
    /// the FINGERPRINT untouched; the notes levels do not (`notes` is in it), which is
    /// why the service fits only the PROMPT and keys the session, the validation and
    /// the evidence on the original facts — the calm invariant never sees a trim.
    enum TrimLevel: Int, CaseIterable, Sendable {
        /// Everything, as `make` built it.
        case full
        /// No related open tasks.
        case noRelated
        /// The capture quote and the reasoning clipped to `quoteClip` characters.
        case shortQuotes
        /// The notes clipped too.
        case shortNotes
        /// Title, sensors and graph only — the facts the reading must never lose.
        case bare
    }

    /// Where a long free-text field is cut at the two clipping levels.
    static let quoteClip = 240

    /// These facts at `level`. Pure; `.full` returns `self`.
    func trimmed(to level: TrimLevel) -> TaskAdvisorFacts {
        var out = self
        if level.rawValue >= TrimLevel.noRelated.rawValue { out.relatedLines = [] }
        if level.rawValue >= TrimLevel.shortQuotes.rawValue {
            out.rawCapture = Self.clip(rawCapture, to: Self.quoteClip)
            out.reasoning = Self.clip(reasoning, to: Self.quoteClip)
        }
        if level.rawValue >= TrimLevel.shortNotes.rawValue {
            out.notes = notes.map { Self.clip($0, to: Self.quoteClip) }
        }
        if level == .bare {
            out.rawCapture = ""
            out.reasoning = ""
            out.notes = nil
            out.advisorPreferences = []
        }
        return out
    }

    /// The first `limit` characters, cut back to the last word boundary, with an
    /// ellipsis so the model reads it as a fragment rather than a sentence that ends.
    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let cut = head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// The evidence behind a reading, in the user's terms — what "Why this?" reveals.
    ///
    /// **Evidence, never reasoning.** Every line is a fact the user can already see
    /// elsewhere in the app, phrased plainly; the model contributes NOTHING here, which
    /// is exactly what keeps this a receipt rather than a narrative about the user.
    /// Deliberately excludes `workIntent` and every INTERNAL prompt line — axis 2 is
    /// system-owned, and internal reasoning signals must not become accidental UI.
    /// The one evidence line that IS the deciding page's spine — named so the
    /// what-matters surfaces can exclude it without matching prose. The obligation
    /// block states the flag with its own controls; evidence repeating it under that
    /// block is the same fact twice, which the floor rule already forbids for
    /// observations.
    static let decisionFlagEvidence = "It's flagged as needing a decision"

    /// What bears on the choice, for the DECIDING page: the evidence minus the flag
    /// line, capped at three. Model-free — the spec's what-matters lines exist
    /// whether or not any reading landed.
    var decisionContextLines: [String] {
        Array(userVisibleEvidence.filter { $0 != Self.decisionFlagEvidence }.prefix(3))
    }

    var userVisibleEvidence: [String] {
        var lines: [String] = []
        if deferralCount > 0 {
            lines.append(
                "You've set this aside \(deferralCount) time\(deferralCount == 1 ? "" : "s") in a row")
        }
        if abandonedStarts > 1 {
            lines.append("You've started it \(abandonedStarts) times and put it back down")
        }
        for blocker in blockerTitles { lines.append("It's waiting on “\(blocker)”") }
        for wait in externalWaits { lines.append("It's waiting on \(wait)") }
        if let overdueDays {
            lines.append("It's \(overdueDays) day\(overdueDays == 1 ? "" : "s") overdue")
        }
        if let stepLabel { lines.append(stepLabel) }
        // "No progress in N days" is false company for "you started it three times":
        // the second says the task has been touched repeatedly. The deferral clause was
        // already guarding against exactly this collision; abandonment joins it.
        if diagnosis != nil, deferralCount == 0, abandonedStarts <= 1, quietDays > 0 {
            lines.append("No progress on it in \(quietDays) days")
        }
        if needsDecision { lines.append(Self.decisionFlagEvidence) }
        if isUrgent { lines.append("You marked it urgent") }
        if !dependentTitles.isEmpty {
            lines.append("Other work waits on it: " + dependentTitles.joined(separator: ", "))
        }
        return lines
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
