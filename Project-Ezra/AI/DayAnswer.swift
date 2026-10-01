//
//  DayAnswer.swift
//  Project-Ezra
//
//  The home's first line, composed (2026-09-23). "What deserves me today?" used to be
//  the rank, verbatim, capped at five — and the rank is right for a LIST: Needs Decision
//  on top because the AI may never resolve one, Blocked sunk, attention descending. Read
//  as an ANSWER at 6:43 in the morning it was wrong in three ways the list is not:
//
//  1. **Four stalled decisions outranked a bill a day overdue**, and would again every
//     morning until someone decided them. A judgment call is a permanent carve-out, not
//     a permanent headline. So the answer re-seats TIME PRESSURE ahead of judgment —
//     overdue, due today, urgent lead — and COLLAPSES the decisions to one row, the
//     oldest, whose reason says how many stand behind it. The list still shows all four
//     on top; the rank is unchanged; only the answer reads differently. Precedent: the
//     model-ranks reversal (`docs/decisions.md`).
//  2. **Every row read "You".** A row with no reason is the list again. Each row now
//     carries ONE clause saying why it is here — "3 days overdue", "Maya is waiting on
//     this", "unblocks 2 more", "started 3 days ago, untouched since" — derived from the
//     same facts the rank read, so the reason can never disagree with the position.
//  3. **A step and its outcome could both appear.** The home speaks in outcomes: an
//     umbrella whose steps are among the rows speaks for them, and its reason names
//     the next step.
//
//  Plus the voice of the hour — the same rows, framed for the morning ("first") or the
//  evening ("still", and "nothing more tonight" as a first-class quiet) — the QUICK shape
//  ("I've got 15 minutes", a question the list cannot answer), and the stall line for
//  work the person started and put down.
//
//  Pure over `HouseholdChatFacts`. Nothing here touches the store or a model.
//

import Foundation

enum DayAnswer {

    typealias Line = HouseholdChatFacts.Line

    /// The composed answer: the sentence, the rows in order, and one reason per row.
    struct Composed: Equatable, Sendable {
        var text: String
        var rows: [Line]
        var reasons: [UUID: String]

        var answer: InquiryAnswer {
            InquiryAnswer(text: text, citedTaskIDs: rows.map(\.id), reasons: reasons)
        }
    }

    // MARK: The voice of the hour

    enum Voice: Equatable, Sendable {
        case morning
        case afternoon
        case evening

        /// Evening starts at six: the hour a household stops adding and starts closing.
        static let eveningHour = 18
        static let afternoonHour = 12

        static func of(_ now: Date, calendar: Calendar = .current) -> Voice {
            let hour = calendar.component(.hour, from: now)
            if hour >= eveningHour { return .evening }
            if hour >= afternoonHour { return .afternoon }
            return .morning
        }
    }

    // MARK: Composition

    /// The day answer for one person (or everyone), from rank with the answer's three
    /// re-readings applied. Empty rows → `text` is the honest quiet for the hour.
    static func compose(facts: HouseholdChatFacts, person: HouseholdChatFacts.Member?) -> Composed {
        let voice = Voice.of(facts.now)
        let candidates = facts.ranked(for: person)
        let rows = seat(candidates, cap: HouseholdChatFacts.dayAnswerCap)
        let subject = person.map { $0.isYou ? "you" : $0.name } ?? "you"

        guard !rows.isEmpty else {
            return Composed(
                text: quiet(for: subject, voice: voice, facts: facts, person: person), rows: [], reasons: [:])
        }
        var reasons: [UUID: String] = [:]
        let decisionCount = candidates.filter(\.needsDecision).count
        for row in rows {
            reasons[row.id] = reason(
                for: row, facts: facts, collapsedDecisions: row.needsDecision ? decisionCount : 0,
                candidates: candidates)
        }
        let count = rows.count
        let lead: String
        switch voice {
        case .morning, .afternoon:
            lead =
                count == 1
                ? "One thing deserves \(subject) first" : "\(count) things deserve \(subject) first"
        case .evening:
            lead =
                count == 1
                ? "One thing still deserves \(subject)" : "\(count) things still deserve \(subject)"
        }
        // No "— in order." any more: the home draws the order — a hero, then a kicker
        // that says "then, in order" over the quiet rows — so the sentence stops saying it.
        return Composed(text: lead + ".", rows: rows, reasons: reasons)
    }

    /// The rows, seated: outcomes over their steps, time pressure ahead of judgment,
    /// decisions collapsed to their oldest, capped.
    static func seat(_ candidates: [Line], cap: Int) -> [Line] {
        // Outcomes speak for their steps: a step whose umbrella is a candidate leaves.
        let candidateIDs = Set(candidates.map(\.id))
        let withoutSteps = candidates.filter { line in
            guard let parent = line.parentID else { return true }
            return !candidateIDs.contains(parent)
        }
        // Decisions collapse to the one that has waited longest.
        let decisions = withoutSteps.filter(\.needsDecision)
        let oldest = decisions.min { $0.touchedAt < $1.touchedAt }
        let others = withoutSteps.filter { !$0.needsDecision }
        // Time pressure leads, in rank order; then the decision; then the rest.
        let pressed = others.filter(\.isTimePressed)
        let rest = others.filter { !$0.isTimePressed }
        var seated = pressed
        if let oldest { seated.append(oldest) }
        seated.append(contentsOf: rest)
        return Array(seated.prefix(cap))
    }

    /// What the answer says when nothing is on for the person. Morning and afternoon
    /// name the others' loads (the arriving caretaker's first home); the evening is a
    /// first-class quiet with nothing appended, because "nothing more tonight" is the
    /// whole point of it.
    static func quiet(
        for subject: String, voice: Voice, facts: HouseholdChatFacts, person: HouseholdChatFacts.Member?
    ) -> String {
        if voice == .evening { return "Nothing more needs \(subject) tonight." }
        let lead = "Nothing is asking for \(subject) today."
        let others = facts.members
            .filter { $0.id != person?.id && !$0.isYou }
            .map { ($0.name, facts.openTasks(of: $0).count) }
            .filter { $0.1 > 0 }
        guard !others.isEmpty else { return lead }
        return lead + " " + others.map { "\($0.0) has \($0.1) open" }.joined(separator: ", ") + "."
    }

    // MARK: Reasons

    /// ONE clause saying why this row is here, from the facts the rank read. A second
    /// clause joins only when it says something the first did not (the number of
    /// decisions behind a collapsed one, what an overdue task unblocks).
    static func reason(
        for line: Line, facts: HouseholdChatFacts, collapsedDecisions: Int = 0, candidates: [Line]
    ) -> String {
        var clauses: [String] = []
        let waitedDays = max(0, Int(facts.now.timeIntervalSince(line.touchedAt) / 86_400))

        if line.needsDecision {
            if collapsedDecisions > 1 {
                clauses.append("Oldest of \(collapsedDecisions) decisions waiting")
            } else {
                clauses.append("Needs a decision")
            }
            clauses.append(waitingClause(days: waitedDays))
        } else if let days = line.daysUntilDue, days < 0 {
            clauses.append(days == -1 ? "1 day overdue" : "\(-days) days overdue")
        } else if line.isDueToday {
            clauses.append("Due today")
        } else if line.isUrgent {
            clauses.append("Marked urgent")
            if let days = line.daysUntilDue, days > 0 { clauses.append(dueClause(days: days)) }
        } else if line.isInProgress {
            clauses.append(
                waitedDays >= 1
                    ? "Started, untouched \(waitedDays) day\(waitedDays == 1 ? "" : "s")" : "In progress")
            // "In progress" alone says nothing the glyph did not; the due date does.
            if let days = line.daysUntilDue, days > 0, days <= 7 { clauses.append(dueClause(days: days)) }
        } else if line.stepsTotal > 0, let next = nextStep(of: line, facts: facts) {
            clauses.append("Next: \(next.title)")
            clauses.append("\(line.stepsDone) of \(line.stepsTotal) done")
        }

        // The graph clause: who or what this frees. Joins as the second clause, or leads
        // when nothing above applied.
        if clauses.count < 2, let graph = graphClause(for: line, facts: facts) {
            clauses.append(graph)
        }
        if clauses.isEmpty {
            if let days = line.daysUntilDue, days > 0, days <= 7 {
                clauses.append(dueClause(days: days))
            } else if waitedDays >= 7 {
                clauses.append("Untouched \(waitedDays) days")
            } else {
                clauses.append("Nothing in the way")
            }
            if let effort = line.effortMinutes { clauses.append("about \(effort) min") }
        }
        return clauses.prefix(2).joined(separator: " · ")
    }

    private static func waitingClause(days: Int) -> String {
        switch days {
        case 0: return "since today"
        case 1: return "since yesterday"
        default: return "\(days) days"
        }
    }

    private static func dueClause(days: Int) -> String {
        days == 1 ? "Due tomorrow" : "Due in \(days) days"
    }

    /// "Maya is waiting on this" beats "unblocks 2 more": a person is the better reason.
    static func graphClause(for line: Line, facts: HouseholdChatFacts) -> String? {
        let dependents = facts.dependents(of: line)
        guard !dependents.isEmpty else { return nil }
        if let other = dependents.first(where: { $0.ownerID != nil && $0.ownerID != line.ownerID }),
            let name = other.ownerName, name != "You"
        {
            return "\(name) is waiting on this"
        }
        return "Unblocks \(dependents.count) more"
    }

    /// The first open step of an outcome, in the steps' own order: the one the row
    /// names as "next".
    static func nextStep(of umbrella: Line, facts: HouseholdChatFacts) -> Line? {
        facts.open
            .filter { $0.parentID == umbrella.id && !$0.isBlocked }
            .min { $0.sortIndex < $1.sortIndex }
            ?? facts.open.filter { $0.parentID == umbrella.id }.min { $0.sortIndex < $1.sortIndex }
    }

    // MARK: The way to the rest

    /// "and N more in Tasks" — the count the answer did not show, for the person it is
    /// about. Nil when the rows are the whole list.
    static func moreInTasks(
        facts: HouseholdChatFacts, person: HouseholdChatFacts.Member?, shown: Int
    )
        -> String?
    {
        let total = person.map { facts.openTasks(of: $0).count } ?? facts.open.count
        let rest = total - shown
        guard rest > 0 else { return nil }
        return "and \(rest) more in Tasks"
    }

    // MARK: Quick

    /// The effort ceiling for "I've got 15 minutes".
    static let quickMinutes = 15

    /// Unblocked open work at or under the ceiling, in rank order, for one person or
    /// everyone. Effort is inferred at capture, so most rows carry one.
    static func quick(facts: HouseholdChatFacts, person: HouseholdChatFacts.Member?) -> [Line] {
        Array(
            facts.ranked(for: person)
                .filter { ($0.effortMinutes ?? Int.max) <= quickMinutes }
                .prefix(HouseholdChatFacts.dayAnswerCap))
    }

    static func quickAnswer(facts: HouseholdChatFacts, person: HouseholdChatFacts.Member?) -> InquiryAnswer {
        let rows = quick(facts: facts, person: person)
        let scope = person.map { $0.isYou ? "" : " for \($0.name)" } ?? ""
        guard !rows.isEmpty else {
            return InquiryAnswer(text: "Nothing\(scope) fits in \(quickMinutes) minutes.", citedTaskIDs: [])
        }
        let lead = rows.count == 1 ? "One quick thing" : "\(rows.count) quick things"
        var reasons: [UUID: String] = [:]
        for row in rows {
            reasons[row.id] = "about \(row.effortMinutes ?? quickMinutes) min"
        }
        return InquiryAnswer(
            text: "\(lead)\(scope) — \(quickMinutes) minutes or less each.", citedTaskIDs: rows.map(\.id),
            reasons: reasons)
    }

    /// The chip that asks it. A statement, not a question: it is the one thing a person
    /// says to the home that is about themselves, not the list.
    static let quickChip = "I've got 15 minutes"

    // MARK: Why this first

    /// The hero's question, answered from the answer's own facts: the named task's
    /// reason and its seat, then what follows it. A task the question names that is not
    /// among the rows is placed honestly — waiting on something, or below the first
    /// four. Names nothing the facts do not hold.
    static func whyFirstAnswer(
        question: String, facts: HouseholdChatFacts, person: HouseholdChatFacts.Member?
    )
        -> InquiryAnswer
    {
        let composed = compose(facts: facts, person: person)
        let candidates = facts.ranked(for: person)
        let named = quotedTitle(in: question).flatMap { title in
            facts.open.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
        }
        func reason(_ line: Line) -> String {
            prose(
                self.reason(
                    for: line, facts: facts,
                    collapsedDecisions: line.needsDecision ? candidates.filter(\.needsDecision).count : 0,
                    candidates: candidates))
        }
        guard let subject = named ?? composed.rows.first else {
            return InquiryAnswer(
                text: "Nothing is on for \(person?.isYou == false ? person!.name : "you") today.",
                citedTaskIDs: [])
        }
        var text: String
        var cited = [subject.id]
        if let index = composed.rows.firstIndex(where: { $0.id == subject.id }) {
            if index == 0 {
                text = "“\(subject.title)” is first because \(reason(subject))."
                if composed.rows.count > 1 {
                    let next = composed.rows[1]
                    text += " After it, “\(next.title)” — \(reason(next))."
                    cited.append(next.id)
                }
            } else {
                let ahead = composed.rows[0]
                text =
                    "“\(subject.title)” is number \(index + 1) today — \(reason(subject)). Ahead of it, “\(ahead.title)”: \(reason(ahead))."
                cited.append(ahead.id)
            }
        } else if subject.isBlocked {
            let waits = (subject.blockerTitles + subject.externalWaits).joined(separator: ", ")
            text = "“\(subject.title)” is not up yet — it's waiting on \(waits)."
            if let first = composed.rows.first {
                text += " First today is “\(first.title)”: \(reason(first))."
                cited.append(first.id)
            }
        } else {
            text = "“\(subject.title)” sits below today's first \(composed.rows.count) — \(reason(subject))."
            if let first = composed.rows.first {
                text += " First is “\(first.title)”: \(reason(first))."
                cited.append(first.id)
            }
        }
        return InquiryAnswer(text: text, citedTaskIDs: cited)
    }

    /// A row's reason clauses as a sentence fragment that follows "because" — the same
    /// facts, said rather than captioned: "Oldest of 3 decisions waiting · 10 days"
    /// becomes "it's the oldest of 3 decisions waiting, 10 days now".
    static func prose(_ caption: String) -> String {
        let clauses = caption.components(separatedBy: " · ")
        var parts: [String] = []
        for (index, raw) in clauses.enumerated() {
            let clause = raw.trimmingCharacters(in: .whitespaces)
            let lowered = clause.prefix(1).lowercased() + clause.dropFirst()
            let said: String
            if lowered.hasPrefix("oldest of") {
                said = "it's the \(lowered)"
            } else if lowered == "needs a decision" {
                said = "it needs a decision"
            } else if lowered.hasPrefix("since ") && index > 0 {
                said = "waiting \(lowered)"
            } else if lowered.hasSuffix(" days") && index > 0 && lowered.first?.isNumber == true {
                said = "\(lowered) now"
            } else if lowered.hasSuffix("overdue") || lowered.hasPrefix("due ") || lowered == "marked urgent"
            {
                said = "it's \(lowered)"
            } else if lowered.hasPrefix("started, untouched") {
                said =
                    "you started it and haven't touched it for \(lowered.dropFirst("started, untouched ".count))"
            } else if lowered == "in progress" {
                said = "it's in progress"
            } else if lowered.hasPrefix("next: ") {
                said = "its next step is \(lowered.dropFirst("next: ".count))"
            } else if lowered.hasSuffix(" done") && lowered.contains(" of ") {
                said = "\(lowered)"
            } else if lowered.hasPrefix("unblocks ") {
                said = "it \(lowered)"
            } else if lowered.hasSuffix(" is waiting on this") {
                said = clause.replacingOccurrences(of: " is waiting on this", with: " is waiting on it")
            } else if lowered.hasPrefix("untouched ") {
                said = "it's been \(lowered.dropFirst("untouched ".count).description) untouched"
            } else if lowered == "nothing in the way" {
                said = "nothing is in the way"
            } else if lowered.hasPrefix("about ") {
                said = "it's \(lowered)"
            } else {
                said = lowered
            }
            parts.append(said)
        }
        switch parts.count {
        case 0: return caption
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    /// The title a question quotes, in curly or straight quotes; nil when none.
    static func quotedTitle(in question: String) -> String? {
        for (open, close) in [("“", "”"), ("\"", "\"")] {
            guard let start = question.range(of: open),
                let end = question.range(of: close, range: start.upperBound..<question.endIndex)
            else { continue }
            let title = question[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    // MARK: The stall line

    /// A started task counts as put down after this many days untouched.
    static let stallDays = 2

    /// "You started “X” 3 days ago and haven't touched it since." — the person's OWN
    /// stall, one sentence, only for work the day answer did not already seat (its row
    /// carries the same clause). Two at most; never a badge, never a count.
    static func stallOpener(facts: HouseholdChatFacts, excluding shown: Set<UUID>) -> InquiryAnswer? {
        guard let you = facts.members.first(where: \.isYou) else { return nil }
        let stalled = facts.open
            .filter { $0.ownerID == you.id && $0.isInProgress && !shown.contains($0.id) }
            .map { ($0, Int(facts.now.timeIntervalSince($0.touchedAt) / 86_400)) }
            .filter { $0.1 >= stallDays }
            .sorted { $0.1 > $1.1 }
            .prefix(2)
        guard !stalled.isEmpty else { return nil }
        let parts = stalled.map { "“\($0.0.title)” \($0.1) days ago" }
        let text =
            "You started " + parts.joined(separator: " and ")
            + " and haven't touched \(stalled.count == 1 ? "it" : "them") since."
        return InquiryAnswer(text: text, citedTaskIDs: stalled.map(\.0.id))
    }

    // MARK: The evening's other line

    /// What moved today, in the evening only: "Today, you finished “X” and Maya finished
    /// “Y”." The catch-up says what others did since you last looked; this says what the
    /// day closed, yours included — minus anything the catch-up already names, so one act
    /// is never said twice on one screen (found on the first evening screenshot). Nil
    /// outside the evening or when nothing is left to say.
    static func eveningRecap(
        facts: HouseholdChatFacts, excluding named: Set<UUID> = [], calendar: Calendar = .current
    ) -> InquiryAnswer? {
        guard Voice.of(facts.now, calendar: calendar) == .evening else { return nil }
        let today = facts.done.filter {
            calendar.isDate($0.completedAt, inSameDayAs: facts.now) && !named.contains($0.id)
        }
        guard !today.isEmpty else { return nil }
        var byActor: [(String, [HouseholdChatFacts.Done])] = []
        for done in today.prefix(HouseholdCatchUp.named) {
            let actor = done.ownerName == "You" ? "you" : (done.ownerName ?? "someone")
            if let index = byActor.firstIndex(where: { $0.0 == actor }) {
                byActor[index].1.append(done)
            } else {
                byActor.append((actor, [done]))
            }
        }
        let clauses = byActor.map { actor, acts in
            "\(actor) finished " + acts.map { "“\($0.title)”" }.joined(separator: ", ")
        }
        var text = "Today, " + clauses.joined(separator: "; ")
        let rest = today.count - min(today.count, HouseholdCatchUp.named)
        if rest > 0 { text += ", and \(rest) more" }
        text += "."
        return InquiryAnswer(text: text, citedTaskIDs: today.prefix(HouseholdCatchUp.named).map(\.id))
    }
}

extension DayAnswer {
    /// What landed during this LOOK and the answer did not seat (2026-09-25): live
    /// tasks confirmed at or after `since`, not among `shown`, newest first, capped like
    /// the answer. The home lists them under "Just added" with the answer's own
    /// reasons — the loop is say it, SEE where it landed, done, and a count going from
    /// 19 to 20 is not seeing. Over `TaskItem` because `confirmedAt` is not a fact line.
    static func landed(
        among tasks: [TaskItem], since: Date, shown: Set<UUID>, cap: Int = HouseholdChatFacts.dayAnswerCap
    ) -> [TaskItem] {
        Array(
            tasks
                .filter { task in
                    guard task.isLiveRow, !task.status.isResolved, let id = task.uuid, !shown.contains(id),
                        let confirmed = task.confirmedAt
                    else { return false }
                    return confirmed >= since
                }
                .sorted { ($0.confirmedAt ?? .distantPast) > ($1.confirmedAt ?? .distantPast) }
                .prefix(cap))
    }
}

extension HouseholdChatFacts.Line {
    /// Overdue, due today or urgent: the rows the answer seats ahead of judgment.
    var isTimePressed: Bool { isOverdue || isDueToday || isUrgent }
}

extension HouseholdChatFacts {
    /// The open set in rank order with the blocked sunk (excluded), scoped to a person
    /// when named — the candidates every answer shape starts from.
    func ranked(for person: Member?) -> [Line] {
        let byID = Dictionary(uniqueKeysWithValues: open.map { ($0.id, $0) })
        let ordered: [Line] = rankOrder.isEmpty ? open : rankOrder.compactMap { byID[$0] }
        return
            ordered
            .filter { !$0.isBlocked }
            .filter { line in person.map { line.ownerID == $0.id } ?? true }
    }

    /// The open tasks waiting on this one — by title, the way the facts hold blockers.
    func dependents(of line: Line) -> [Line] {
        open.filter { $0.id != line.id && $0.blockerTitles.contains(line.title) }
    }
}
