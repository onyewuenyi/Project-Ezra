//
//  HouseholdChat.swift
//  Project-Ezra
//
//  The household you can ASK — the second `InquiryScope` (P-01). The task chat answers
//  inside one task; this answers across all of them — every open task, every member,
//  the week's finished work — from the Ask tab. Same advisor, wider room; the loop that
//  answers (on-device only, never acts, replies whole, one session per fingerprint, the
//  continuity digest, the serial gate, the ledger) is `Inquiry.swift`'s and runs here
//  unchanged. This file holds what is genuinely the household's: its facts, its FLOOR,
//  its RETRIEVAL, its rules, its starter questions.
//
//  **The two decisions that make it fast and right on a 3B on-device model, stated
//  so nobody undoes them for convenience:**
//
//  1. **A deterministic FLOOR answers the questions a model would get wrong.**
//     "What's overdue?", "what's due today?", "who has the most on their plate?",
//     "what did we finish this week?" are COUNTING and FILTERING questions. A small
//     model asked to count sixty task lines miscounts; the app can answer exactly, in
//     two milliseconds, with the tasks themselves as tappable rows. So
//     `HouseholdChatFloor` takes the closed question shapes and the model takes the
//     open ones ("why is the passport stuck?", "what should Maya do first?"). Rung 0
//     answers before the model may — the Advisor's own promise, applied to a chat.
//     The floor is deliberately NARROW: any question carrying a reasoning word (why,
//     should, how, could, whether …) goes to the model even if it also names a
//     filter, because "why is it overdue?" is not a list.
//
//  2. **RETRIEVAL, not a dump.** Instruction length is the latency (Campaign 2: about
//     1.5 ms per instruction token over a fixed base), so the household's whole task
//     list is never sent. The INSTRUCTIONS hold the stable, small picture — the date,
//     who is in the household, how much each person carries — and warm once; each
//     TURN carries only the tasks relevant to THAT question, chosen deterministically
//     (`HouseholdChatRetrieval`: a named person, a filter word, lexical overlap,
//     recency; cap 12). The model reasons over a dozen lines, never sixty.
//
//  Citations are verified (`InquiryCitations`): a reply may cite only what the turn
//  showed, by title, and the answer's rows open the pager with the cited tasks as peers.
//
//  Grep-pinned on-device in `HouseholdChatTests`, alongside `Inquiry.swift`.
//

import Foundation

// MARK: - Facts (the snapshot everything reads)

/// The household, as values. Built once per ask from the live store; never Core Data
/// downstream — the floor, retrieval, prompt and eval all read this and nothing else.
struct HouseholdChatFacts: Sendable, Equatable {

    struct Member: Sendable, Equatable, Hashable {
        let id: UUID
        let name: String
        let isYou: Bool
    }

    struct Line: Sendable, Equatable {
        let id: UUID
        let title: String
        let category: String
        let status: TaskStatus
        /// The owner's display name ("You" for the current user), nil when unowned.
        let ownerName: String?
        let ownerID: UUID?
        let dueDate: Date?
        /// Days until due: negative = overdue, 0 = today, nil = undated.
        let daysUntilDue: Int?
        let isUrgent: Bool
        let needsDecision: Bool
        let blockerTitles: [String]
        let externalWaits: [String]
        let effortMinutes: Int?
        let updatedAt: Date
        /// When a HUMAN last touched it (`TaskItem.humanTouchedAt`) — the staleness input,
        /// never `updatedAt`, which every sweep bumps. Defaults to `updatedAt` for fixtures.
        var humanTouchedAt: Date? = nil
        /// The outcome this is a step of (`TaskItem.parentTaskID`), so the day answer
        /// can let an umbrella speak for its steps (2026-09-23). Defaults for fixtures.
        var parentID: UUID? = nil
        /// How far this outcome's steps have got — zero total for a plain task.
        var stepsDone: Int = 0
        var stepsTotal: Int = 0
        /// The steps' own display order, so "next" is the first open one by position.
        var sortIndex: Int = 0

        var touchedAt: Date { humanTouchedAt ?? updatedAt }

        var isOverdue: Bool { (daysUntilDue ?? 0) < 0 }
        var isDueToday: Bool { daysUntilDue == 0 }
        var isDueTomorrow: Bool { daysUntilDue == 1 }
        var isBlocked: Bool { !blockerTitles.isEmpty || !externalWaits.isEmpty }
        var isDueThisWeek: Bool {
            guard let days = daysUntilDue else { return false }
            return days >= 0 && days <= 7
        }
        /// The week after this one, as a window: 7 to 13 days out. The answer says so.
        var isDueNextWeek: Bool {
            guard let days = daysUntilDue else { return false }
            return days >= 7 && days <= 13
        }
        var isInProgress: Bool { status == .doing }
    }

    struct Done: Sendable, Equatable {
        let id: UUID
        let title: String
        let ownerName: String?
        let completedAt: Date
    }

    let now: Date
    let members: [Member]
    /// Every OPEN task, owner-resolved.
    let open: [Line]
    /// Finished inside the last `doneWindowDays`, newest first.
    let done: [Done]
    /// The open set in `TaskRanking` order — the system's honest opinion, which the day
    /// answer reads. Empty when the facts were built without tasks (fixtures), in which
    /// case `open`'s own order (overdue first, nearest due) stands in.
    var rankOrder: [UUID] = []

    /// How many rows the day answer names: a hero and three under it (2026-09-23, the
    /// calm home — five rows with five verbs was the loudest thing on the screen).
    static let dayAnswerCap = 4

    /// The day answer's rows: rank with the blocked sunk, then the answer's three
    /// re-readings (`DayAnswer.seat`, 2026-09-23 — outcomes over steps, time pressure
    /// ahead of judgment, decisions collapsed to their oldest), capped — for one person
    /// when named, otherwise for everyone. Rank is still the only ORDER; the answer
    /// re-seats what rank says, it never re-scores it.
    func dayAnswer(for person: Member?) -> [Line] {
        DayAnswer.seat(ranked(for: person), cap: Self.dayAnswerCap)
    }

    static let doneWindowDays = 7
    /// A ceiling on what any single answer lists — a floor answer that runs to forty
    /// rows is a list, not an answer.
    static let listCap = 12

    static func make(
        tasks: [TaskItem], members: [FamilyMember], currentUserID: UUID?, now: Date = Date()
    ) -> HouseholdChatFacts {
        let roster = members.filter { !$0.isRemoved }
        let names: [UUID: String] = Dictionary(
            uniqueKeysWithValues: roster.map { ($0.uuid, $0.uuid == currentUserID ? "You" : $0.name) })
        let memberValues =
            roster.map {
                Member(id: $0.uuid, name: names[$0.uuid] ?? $0.name, isYou: $0.uuid == currentUserID)
            }
            .sorted { a, b in
                if a.isYou != b.isYou { return a.isYou }
                return a.name < b.name
            }
        // **The two graph lookups are hoisted, because this used to be quadratic.**
        // `activeBlockerTasks(among:)` built a Set of every open uuid AND scanned the
        // whole array, once PER TASK — and `activeBlockers(among:)` right beside it built
        // that same Set again. Over a household of n tasks that is O(n²) with two
        // full-collection allocations per row, and the Ask sheet rebuilds these facts
        // several times per render pass, so it ran again on every keystroke while
        // somebody typed a question. Computed once here, a task's blockers cost only its
        // own edges. The derivation is unchanged: the same `activeBlockers(from:openIDs:)`
        // static the instance accessors delegate to, against the same open set.
        let openIDs = Set(tasks.filter { !$0.status.isResolved }.compactMap(\.uuid))
        let titlesByID: [UUID: String] = Dictionary(
            tasks.compactMap { task in task.uuid.map { ($0, task.title) } },
            uniquingKeysWith: { first, _ in first })
        // The parent edge, decoded ONCE per task: `stepProgress(among:)` per row would
        // decode every task's relationships blob for every row — the O(n²) this function
        // already paid once and fixed.
        let parentByID: [UUID: UUID] = Dictionary(
            tasks.compactMap { task in
                guard let id = task.uuid, let parent = task.parentTaskID else { return nil }
                return (id, parent)
            }, uniquingKeysWith: { first, _ in first })
        var stepsByParent: [UUID: (done: Int, total: Int)] = [:]
        for task in tasks {
            guard let id = task.uuid, let parent = parentByID[id] else { continue }
            var entry = stepsByParent[parent] ?? (0, 0)
            entry.total += 1
            if task.status.isResolved { entry.done += 1 }
            stepsByParent[parent] = entry
        }
        let open = tasks.filter { !$0.status.isResolved }
            .map { task -> Line in
                let active = TaskItem.activeBlockers(from: task.relationships, openIDs: openIDs)
                let blockers = active.compactMap { $0.taskID.flatMap { titlesByID[$0] } }
                let waits = active.filter { $0.taskID == nil }.compactMap(\.note)
                return Line(
                    id: task.uuid ?? UUID(),
                    title: task.title,
                    category: task.category,
                    status: task.status,
                    ownerName: task.ownerID.flatMap { names[$0] },
                    ownerID: task.ownerID,
                    dueDate: task.dueDate,
                    daysUntilDue: task.dueDate.flatMap { TaskItem.daysUntil($0, now: now) },
                    isUrgent: task.isUrgent,
                    needsDecision: task.needsDecision,
                    blockerTitles: blockers,
                    externalWaits: waits,
                    effortMinutes: task.effortMinutes,
                    updatedAt: task.updatedAt,
                    humanTouchedAt: task.humanTouchedAt,
                    parentID: task.uuid.flatMap { parentByID[$0] },
                    stepsDone: task.uuid.flatMap { stepsByParent[$0]?.done } ?? 0,
                    stepsTotal: task.uuid.flatMap { stepsByParent[$0]?.total } ?? 0,
                    sortIndex: Int(task.sortIndex))
            }
            .sorted { a, b in
                // Overdue first, then nearest due, then most recently touched — the
                // order the floor lists in and the order retrieval breaks ties on.
                let ad = a.daysUntilDue ?? Int.max
                let bd = b.daysUntilDue ?? Int.max
                if ad != bd { return ad < bd }
                return a.updatedAt > b.updatedAt
            }
        let cutoff = now.addingTimeInterval(-Double(doneWindowDays) * 86_400)
        let done = tasks.compactMap { task -> Done? in
            guard task.status == .done, let at = task.completedAt, at >= cutoff else { return nil }
            return Done(
                id: task.uuid ?? UUID(), title: task.title,
                ownerName: task.ownerID.flatMap { names[$0] }, completedAt: at)
        }
        .sorted { $0.completedAt > $1.completedAt }
        var facts = HouseholdChatFacts(now: now, members: memberValues, open: open, done: done)
        facts.rankOrder = TaskRanking.sorted(tasks.filter { !$0.status.isResolved }, among: tasks, now: now)
            .compactMap(\.uuid)
        return facts
    }

    // MARK: Derived groups

    var overdue: [Line] { open.filter(\.isOverdue) }
    var dueToday: [Line] { open.filter(\.isDueToday) }
    var dueTomorrow: [Line] { open.filter(\.isDueTomorrow) }
    var dueThisWeek: [Line] { open.filter(\.isDueThisWeek) }
    var dueNextWeek: [Line] { open.filter(\.isDueNextWeek) }
    var inProgress: [Line] { open.filter(\.isInProgress) }
    /// The open set by last human touch, longest-untouched first. Undated and unstarted
    /// work rots invisibly; this is the one view that surfaces it.
    var stalest: [Line] { open.sorted { $0.touchedAt < $1.touchedAt } }
    static let stalestCap = 5

    /// The categories the household's open tasks use, lowercased — a closed vocabulary
    /// the floor may match a question against.
    var categories: Set<String> { Set(open.map { $0.category.lowercased() }).subtracting([""]) }

    /// The category a question names, if exactly one of the household's categories
    /// appears in it as a whole word ("anything for the car?" → Car). Nil when none or
    /// several do — two categories is not a closed question.
    func category(named question: String) -> String? {
        let lowered = question.lowercased()
        let hits = categories.filter { InquiryFloor.mentions(any: [$0], in: lowered) }
        guard hits.count == 1, let hit = hits.first else { return nil }
        return open.first { $0.category.lowercased() == hit }?.category
    }
    var blocked: [Line] { open.filter(\.isBlocked) }
    var urgent: [Line] { open.filter(\.isUrgent) }
    var decisions: [Line] { open.filter(\.needsDecision) }
    var unowned: [Line] { open.filter { $0.ownerID == nil } }

    func openTasks(of member: Member) -> [Line] { open.filter { $0.ownerID == member.id } }

    /// The member a question names, if any — "Maya", "maya's", or "you"/"me"/"my"/"I"
    /// for the current user. Longest name wins so "Jo" cannot claim "Joanna".
    func member(named question: String) -> Member? {
        let lowered = question.lowercased()
        let words = Set(
            lowered.split { !$0.isLetter && $0 != "'" }.map {
                String($0).replacingOccurrences(of: "'s", with: "")
            })
        // A NAMED person wins over a pronoun: "what could Sam hand off to me" is about
        // Sam. The pronouns mean the person asking only when nobody else is named.
        if let named = members.filter({ !$0.isYou })
            .sorted(by: { $0.name.count > $1.name.count })
            .first(where: { words.contains($0.name.lowercased()) })
        {
            return named
        }
        if let you = members.first(where: \.isYou),
            !words.isDisjoint(with: ["you", "me", "my", "i", "mine", "i'm", "i've", "i'd", "i'll", "myself"])
        {
            return you
        }
        return nil
    }

    // MARK: Prompt blocks

    /// The STABLE picture — the instructions' tail, so it warms once and rarely
    /// changes: the date, the roster with each person's load, the totals.
    var stableBlock: String {
        var lines = ["HOUSEHOLD:"]
        lines.append("TODAY: \(Self.dayFormatter.string(from: now))")
        if members.isEmpty {
            lines.append("PEOPLE: just the person asking")
        } else {
            for member in members {
                let mine = openTasks(of: member)
                var parts = ["\(mine.count) open"]
                let over = mine.filter(\.isOverdue).count
                if over > 0 { parts.append("\(over) overdue") }
                let blockedCount = mine.filter(\.isBlocked).count
                if blockedCount > 0 { parts.append("\(blockedCount) waiting") }
                lines.append("PERSON: \(member.name) — " + parts.joined(separator: ", "))
            }
        }
        var totals = ["\(open.count) open"]
        if !overdue.isEmpty { totals.append("\(overdue.count) overdue") }
        if !dueToday.isEmpty { totals.append("\(dueToday.count) due today") }
        if !blocked.isEmpty { totals.append("\(blocked.count) waiting on something") }
        if !decisions.isEmpty { totals.append("\(decisions.count) needing a decision") }
        if !done.isEmpty { totals.append("\(done.count) finished this week") }
        lines.append("TOTALS: " + totals.joined(separator: ", "))
        if !unowned.isEmpty { lines.append("UNOWNED: \(unowned.count)") }
        return lines.joined(separator: "\n")
    }

    /// Cache key for the session: the stable block IS what the instructions hold.
    var stableFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(stableBlock)
        return hasher.finalize()
    }

    /// One task as a prompt line — compact, owner-named, with the facts a question
    /// could turn on. The uuid is NOT sent: the model cites by title and the app
    /// verifies the title (`HouseholdChatCitations`).
    static func promptLine(_ line: Line) -> String {
        var parts = [line.title]
        if let owner = line.ownerName { parts.append("owner: \(owner)") }
        if line.status == .doing { parts.append("in progress") }
        if let days = line.daysUntilDue {
            if days < 0 {
                parts.append("\(-days) day\(days == -1 ? "" : "s") overdue")
            } else if days == 0 {
                parts.append("due today")
            } else {
                parts.append("due in \(days) day\(days == 1 ? "" : "s")")
            }
        }
        if line.isUrgent { parts.append("urgent") }
        if line.needsDecision { parts.append("needs a decision") }
        if !line.blockerTitles.isEmpty {
            parts.append("waiting on: " + line.blockerTitles.joined(separator: "; "))
        }
        if !line.externalWaits.isEmpty {
            parts.append("waiting on " + line.externalWaits.joined(separator: "; "))
        }
        if let effort = line.effortMinutes { parts.append("~\(effort) min") }
        return "- " + parts.joined(separator: " · ")
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f
    }()
}

// MARK: - The floor (rung 0: exact answers to closed questions)

/// What a floor answer carries back: the sentence, and the tasks it is about —
/// rendered as rows, so the answer IS the navigation. The shared `InquiryAnswer`.
typealias HouseholdChatAnswer = InquiryAnswer

enum HouseholdChatFloor {

    /// The shared vocabulary (`InquiryFloor`), kept reachable under this name.
    static var reasoningWords: Set<String> { InquiryFloor.reasoningWords }

    /// The closed question shapes the floor takes. Order is precedence: the first
    /// match answers, and specific shapes (done, who-most) sit before broad ones.
    enum Shape: Equatable, CaseIterable {
        /// "What deserves me today?" — the Brief's job, kept as a question (F-11). Answered
        /// from RANK, never from a model: position is the system's honest opinion, and
        /// the day answer is the top of the stack with the blocked sunk, as rows.
        case today
        case done
        case whoMost
        case overdue
        case dueToday
        /// Added 2026-09-17 on a GA transcript: asked "what's due tomorrow?" over a
        /// household with nothing due tomorrow, the model listed a task due today and one
        /// due in two days, and annotated one "listed for tomorrow context".
        case dueTomorrow
        case dueThisWeek
        /// Same transcript: "next week" got tasks 3, 4, 6 and 9 days out. The floor's
        /// window is stated in its answer.
        case dueNextWeek
        /// Same transcript: "what's in progress?" over a household with NO task started
        /// listed three as in progress. Status is a fact the app holds exactly.
        case inProgress
        case blocked
        case urgent
        case decisions
        case unowned
        case countOpen
        case personOpen
        /// A category the household uses, named as a whole word ("anything for the car?").
        /// The model answered these correctly but from the slice's titles alone, so it
        /// missed the travel task whose title never says "travel"; the app knows the
        /// category. Lowest precedence — every other shape wins over it.
        case category
        /// "What's been sitting untouched the longest?" — the second GA transcript: the
        /// model picked the most overdue task, because the slice never carries when a
        /// task was last touched. The app knows exactly.
        case stalest
        /// "I've got 15 minutes" — the one thing a person says to the home about
        /// themselves rather than the list (2026-09-23): unblocked work at or under the
        /// effort ceiling, in rank order. A question the list genuinely cannot answer.
        case quick
        /// "Why does “X” deserve me first?" — the hero's long-press (2026-09-25). The
        /// answer is the app's own: the reason the day answer gave the row, and what
        /// comes after it. Asked of the model it answered "You do not know why"; the
        /// ranking is the one thing about the household the app knows exactly.
        case whyFirst
    }

    static func mentions(any phrases: [String], in lowered: String) -> Bool {
        InquiryFloor.mentions(any: phrases, in: lowered)
    }

    /// Which shape a question is — nil when the floor should stay silent and let
    /// the model answer.
    static func shape(of question: String, facts: HouseholdChatFacts) -> Shape? {
        let lowered = question.lowercased()
        func has(_ phrases: String...) -> Bool { mentions(any: phrases, in: lowered) }
        // The orientation question is the ONE reasoning-shaped question the floor takes,
        // because its answer is not reasoning — it is the rank, which is already the
        // system's judgment. Checked before the reasoning gate for exactly that reason.
        // "What deserves Maya today?" is the same question scoped to a named person —
        // the home's named chip (2026-09-23); `member(named:)` supplies the subject.
        if has(
            "what deserves me today", "what deserves me", "what deserves", "what matters today",
            "what matters most",
            "what should i focus on", "what should i do first", "where do i start", "where should i start",
            "what's my day", "what is my day", "my day", "priorities", "what's important today",
            "what should i do today", "what do i do today", "what deserves my attention")
        {
            return .today
        }
        // The hero's question carries "why", so it sits before the reasoning gate: the
        // answer is a fact the app holds, not a judgment.
        if has("deserve me first", "deserves me first", "why this first", "why is this first", "why first") {
            return .whyFirst
        }
        // The quick shape carries no reasoning word but reads like a statement, so it
        // sits beside the day question, before the reasoning gate.
        if has(
            "15 minutes", "fifteen minutes", "ten minutes", "10 minutes", "20 minutes", "a few minutes",
            "quick win", "quick wins", "something quick", "something small", "something short",
            "anything quick", "anything small", "knock out", "quick ones", "quick things", "quick tasks",
            "small things", "got 15", "have 15")
        {
            return .quick
        }
        if InquiryFloor.isReasoning(question) { return nil }
        // Time and outcome first — "what did we get done this week" must not fall
        // into "this week" (due this week).
        if has(
            "get done", "got done", "finished", "completed", "did we do", "did i do", "done this week",
            "done today", "wrapped up", "crossed off", "checked off", "ticked off")
        {
            return .done
        }
        // "What did Maya finish?" — the second GA transcript had the model answer that
        // nothing was finished, because finished work never reaches its slice. A past-tense
        // opener with a finishing verb is the done question in any tense.
        if ["what did", "what has", "what have", "has ", "have ", "did "].contains(where: lowered.hasPrefix),
            has("finish", "complete", "done")
        {
            return .done
        }
        if has(
            "untouched", "sitting the longest", "sitting longest", "neglected", "stale", "gathering dust",
            "haven't touched", "not touched", "least recently", "longest without")
        {
            return .stalest
        }
        if has(
            "who has the most", "who's carrying", "who is carrying", "busiest", "most on their plate",
            "most to do", "most tasks", "most open")
        {
            return .whoMost
        }
        if has("overdue", "past due", "late") { return .overdue }
        if has("tomorrow") { return .dueTomorrow }
        if has("today") { return .dueToday }
        if has("next week") { return .dueNextWeek }
        if has("this week", "upcoming", "coming up", "next few days", "next 7 days", "next seven days") {
            return .dueThisWeek
        }
        if has("in progress", "underway", "started", "in flight", "half done", "halfway") {
            return .inProgress
        }
        if has("blocked", "waiting", "stuck") { return .blocked }
        if has("urgent") { return .urgent }
        if has("decision", "decide", "undecided") { return .decisions }
        if has("unowned", "unassigned", "nobody", "no one", "up for grabs") { return .unowned }
        if has("how many") { return facts.member(named: question) == nil ? .countOpen : .personOpen }
        if facts.member(named: question) != nil,
            has(
                "working on", "have", "has", "got", "tasks", "plate", "list", "doing", "to do", "up to",
                "on for")
        {
            return .personOpen
        }
        if facts.category(named: question) != nil { return .category }
        return nil
    }

    /// The floor's answer, or nil when the model should speak. Exact, cited, capped.
    static func answer(question: String, facts: HouseholdChatFacts) -> HouseholdChatAnswer? {
        guard let shape = shape(of: question, facts: facts) else { return nil }
        let person = facts.member(named: question)
        // A name the roster does not hold makes the question NOT closed (2026-09-18):
        // "what did Sam finish this week?" on a household with no Sam answered the
        // unscoped done shape — everyone's finished work, presented as the answer. The
        // floor declines and the model, which is shown the roster, says who it knows.
        if person == nil, namesSomeoneUnknown(question, facts: facts) { return nil }
        // A named person scopes every list: "what's overdue for Maya?".
        func scoped(_ lines: [HouseholdChatFacts.Line]) -> [HouseholdChatFacts.Line] {
            guard let person else { return lines }
            return lines.filter { $0.ownerID == person.id }
        }
        let whose = person.map { $0.isYou ? "you" : $0.name }

        switch shape {
        case .today:
            // Composed, not recited (`DayAnswer`, 2026-09-23): the subject of the sentence
            // IS the scope (never "deserve you first for you"), every row carries its
            // reason, and the hour frames the lead. A person with nothing on still lives
            // in a household with things on, so the quiet names the others' loads.
            return DayAnswer.compose(facts: facts, person: person).answer
        case .quick:
            return DayAnswer.quickAnswer(facts: facts, person: person)
        case .whyFirst:
            return DayAnswer.whyFirstAnswer(question: question, facts: facts, person: person)
        case .done:
            let done = person == nil ? facts.done : facts.done.filter { $0.ownerName == person?.name }
            guard !done.isEmpty else {
                return HouseholdChatAnswer(
                    text: "Nothing finished in the last \(HouseholdChatFacts.doneWindowDays) days.",
                    citedTaskIDs: [])
            }
            let capped = Array(done.prefix(HouseholdChatFacts.listCap))
            return HouseholdChatAnswer(
                text:
                    "\(count(done.count, "thing")) finished in the last \(HouseholdChatFacts.doneWindowDays) days"
                    + (whose.map { " for \($0)" } ?? "") + ".",
                citedTaskIDs: capped.map(\.id))

        case .whoMost:
            let loads = facts.members.map { ($0, facts.openTasks(of: $0).count) }.sorted { $0.1 > $1.1 }
            guard let top = loads.first, top.1 > 0 else {
                return HouseholdChatAnswer(text: "Nobody has anything open.", citedTaskIDs: [])
            }
            let rest = loads.dropFirst().filter { $0.1 > 0 }.map { "\($0.0.name) \($0.1)" }
            let lead = top.0.isYou ? "You have the most" : "\(top.0.name) has the most"
            let text =
                "\(lead) — \(top.1) open"
                + (rest.isEmpty ? "." : " (then " + rest.joined(separator: ", ") + ").")
            return HouseholdChatAnswer(text: text, citedTaskIDs: [])

        case .overdue:
            return list(scoped(facts.overdue), "overdue", whose: whose)
        case .dueToday:
            return list(scoped(facts.dueToday), "due today", whose: whose)
        case .dueTomorrow:
            return list(scoped(facts.dueTomorrow), "due tomorrow", whose: whose)
        case .dueThisWeek:
            return list(scoped(facts.dueThisWeek), "due in the next 7 days", whose: whose)
        case .dueNextWeek:
            return list(scoped(facts.dueNextWeek), "due next week, 7 to 13 days out", whose: whose)
        case .inProgress:
            return list(scoped(facts.inProgress), "in progress", whose: whose)
        case .category:
            guard let category = facts.category(named: question) else { return nil }
            return list(
                scoped(facts.open.filter { $0.category == category }), "in \(category)", whose: whose)
        case .stalest:
            let lines = Array(scoped(facts.stalest).prefix(HouseholdChatFacts.stalestCap))
            guard let first = lines.first else {
                return HouseholdChatAnswer(
                    text: "Nothing is open\(whose.map { " for \($0)" } ?? "").", citedTaskIDs: [])
            }
            let days = max(0, Int(facts.now.timeIntervalSince(first.touchedAt) / 86_400))
            let since = days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
            let lead =
                lines.count == 1
                ? "One thing is untouched" : "The \(lines.count) longest untouched, longest first"
            return HouseholdChatAnswer(
                text: "\(lead)\(whose.map { " for \($0)" } ?? "") — the first last touched \(since).",
                citedTaskIDs: lines.map(\.id))
        case .blocked:
            return list(scoped(facts.blocked), "waiting on something", whose: whose, scopeBeforeVerb: true)
        case .urgent:
            return list(scoped(facts.urgent), "marked urgent", whose: whose)
        case .decisions:
            return list(scoped(facts.decisions), "waiting on a decision", whose: whose)
        case .unowned:
            return list(facts.unowned, "not owned by anyone", whose: nil)
        case .countOpen:
            let per = facts.members.map { "\($0.name) \(facts.openTasks(of: $0).count)" }
            let text =
                "\(count(facts.open.count, "task")) open"
                + (per.count > 1 ? " — " + per.joined(separator: ", ") + "." : ".")
            return HouseholdChatAnswer(text: text, citedTaskIDs: [])
        case .personOpen:
            guard let person else { return nil }
            let mine = facts.openTasks(of: person)
            let lead = person.isYou ? "You have" : "\(person.name) has"
            guard !mine.isEmpty else {
                return HouseholdChatAnswer(text: "\(lead) nothing open.", citedTaskIDs: [])
            }
            return HouseholdChatAnswer(
                text: "\(lead) \(count(mine.count, "task")) open"
                    + (mine.count > HouseholdChatFacts.listCap ? " — the nearest first." : "."),
                citedTaskIDs: Array(mine.prefix(HouseholdChatFacts.listCap)).map(\.id))
        }
    }

    /// `scopeBeforeVerb` puts the person before the verb — "1 task for Maya is waiting
    /// on something" — for the one predicate where the trailing scope attached to the
    /// wrong noun: "1 task is waiting on something for Maya" read as a task waiting on
    /// a thing that is for Maya (2026-09-18). Every other shape keeps the trailing
    /// scope ("overdue for Maya", "in Travel for Maya"), which reads as intended.
    private static func list(
        _ lines: [HouseholdChatFacts.Line], _ predicate: String, whose: String?,
        scopeBeforeVerb: Bool = false
    ) -> HouseholdChatAnswer {
        let scope = whose.map { " for \($0)" } ?? ""
        let leading = scopeBeforeVerb ? scope : ""
        let trailing = scopeBeforeVerb ? "" : scope
        guard !lines.isEmpty else {
            return HouseholdChatAnswer(
                text: "Nothing\(leading) is \(predicate)\(trailing).", citedTaskIDs: [])
        }
        let capped = Array(lines.prefix(HouseholdChatFacts.listCap))
        let more = lines.count > capped.count ? " Showing the nearest \(capped.count)." : ""
        let verb = lines.count == 1 ? "is" : "are"
        return HouseholdChatAnswer(
            text: "\(count(lines.count, "task"))\(leading) \(verb) \(predicate)\(trailing).\(more)",
            citedTaskIDs: capped.map(\.id))
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// A capitalised word in the person's slot — after "for"/"did"/"has"/"is"/"can"/
    /// "should", or wearing a possessive — that names nobody on the roster and is not a
    /// category, a weekday or a month. Mid-sentence only: the first word is capitalised
    /// by the keyboard, and "I" is the person asking.
    static func namesSomeoneUnknown(_ question: String, facts: HouseholdChatFacts) -> Bool {
        let patterns = [
            #"\b(?:for|did|does|has|have|is|can|could|should|with|about)\s+([A-Z][a-z]+)\b"#,
            #"\b([A-Z][a-z]+)'s\b"#,
        ]
        let known = Set(
            facts.members.map { $0.name.lowercased() } + TaskCategory.all.map { $0.lowercased() }
                + [
                    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                    "january", "february", "march", "april", "may", "june", "july", "august",
                    "september", "october", "november", "december", "ezra", "i",
                ])
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(question.startIndex..., in: question)
            for match in regex.matches(in: question, range: range) {
                guard let wordRange = Range(match.range(at: 1), in: question),
                    wordRange.lowerBound != question.startIndex
                else { continue }
                let word = String(question[wordRange]).lowercased()
                if !known.contains(word) { return true }
            }
        }
        return false
    }
}

// MARK: - Retrieval (the per-turn slice)

enum HouseholdChatRetrieval {

    static let cap = 12

    /// The tasks a question is about, ranked deterministically: a named person's
    /// tasks and filter words first, then lexical overlap with titles and blockers,
    /// recency as the tie-breaker. Pure and cheap — no embeddings, so it never adds to
    /// the turn's latency.
    static func slice(for question: String, facts: HouseholdChatFacts) -> [HouseholdChatFacts.Line] {
        let lowered = question.lowercased()
        let queryWords = Set(CorrectionProfile.significantWords(question))
        let person = facts.member(named: question)
        func has(_ phrases: String...) -> Bool { HouseholdChatFloor.mentions(any: phrases, in: lowered) }

        let scored = facts.open.map { line -> (HouseholdChatFacts.Line, Double) in
            var score = 0.0
            // The named person's tasks outrank any lexical hit — a question about Maya
            // is about Maya's tasks before it is about a task with her name in it.
            if let person, line.ownerID == person.id { score += 5 }
            if has("overdue", "late"), line.isOverdue { score += 3 }
            if has("today"), line.isDueToday { score += 3 }
            if has("tomorrow"), line.daysUntilDue == 1 { score += 3 }
            if has("week", "upcoming", "soon"), line.isDueThisWeek { score += 2 }
            if has("in progress", "started", "working on", "underway"), line.status == .doing { score += 3 }
            if has("blocked", "waiting", "stuck"), line.isBlocked { score += 3 }
            if has("urgent"), line.isUrgent { score += 3 }
            if has("decision", "decide"), line.needsDecision { score += 3 }
            let titleWords = Set(
                CorrectionProfile.significantWords(
                    line.title + " " + line.blockerTitles.joined(separator: " ")))
            // A title the question names outranks a bare filter hit (3 per word vs 3
            // per filter), so "why is the passport stuck?" ranks the passport tasks above
            // every other blocked one.
            let overlap = queryWords.intersection(titleWords).count
            score += Double(overlap) * 3
            if overlap > 0, queryWords.count > 0, Double(overlap) / Double(queryWords.count) >= 0.5 {
                score += 2
            }
            // Recency: a task touched this week edges out one from a month ago.
            let age = facts.now.timeIntervalSince(line.updatedAt) / 86_400
            score += max(0, 1 - age / 30) * 0.5
            // Nearness: a dated task edges out an undated one at equal relevance.
            if let days = line.daysUntilDue { score += max(0, 1 - Double(abs(days)) / 30) * 0.5 }
            return (line, score)
        }
        let ranked =
            scored
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.id.uuidString < b.0.id.uuidString
            }
            .map(\.0)
        // A named person's tasks lead, whole, before any chain is walked — "what should
        // Maya do first?" is about Maya's three before it is about the passport that waits
        // on her photos. The chain still arrives, right after.
        let leading = person.map { who in ranked.filter { $0.ownerID == who.id } } ?? []
        return completingChains(ranked, leading: leading, facts: facts)
    }

    /// **A blocked task brings its chain.** The slice is what the model reasons over,
    /// and "why is the passport stuck?" is a question about the chain — the photos the
    /// passport waits on, the flights that wait on the passport — which the lexical
    /// score reaches only when their titles share a word with the question. Walking the
    /// ranked list, each admitted line pulls in the lines it waits on and the lines
    /// waiting on it (both directions, transitively) ahead of the next lexical hit, so
    /// a chain the question touches is shown whole and the model never has to guess at
    /// a blocker it was told about by title alone. Still capped, still deterministic.
    static func completingChains(
        _ ranked: [HouseholdChatFacts.Line], leading: [HouseholdChatFacts.Line] = [],
        facts: HouseholdChatFacts
    ) -> [HouseholdChatFacts.Line] {
        let byTitle = Dictionary(facts.open.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [HouseholdChatFacts.Line] = []
        var seen = Set<UUID>()
        func admit(_ line: HouseholdChatFacts.Line) {
            guard out.count < cap, seen.insert(line.id).inserted else { return }
            out.append(line)
            expand(line)
        }
        // Upstream: what this waits on. Downstream: what waits on this.
        func expand(_ line: HouseholdChatFacts.Line) {
            for title in line.blockerTitles {
                if let blocker = byTitle[title] { admit(blocker) }
            }
            for dependent in facts.open where dependent.blockerTitles.contains(line.title) {
                admit(dependent)
            }
        }
        for line in leading.prefix(cap) where seen.insert(line.id).inserted { out.append(line) }
        // The leading lines' chains come next, before any lexical hit.
        for line in leading { expand(line) }
        for line in ranked {
            guard out.count < cap else { break }
            admit(line)
        }
        return out
    }
}

// MARK: - Citations (the household's lines, through the shared verifier)

enum HouseholdChatCitations {
    /// The tasks a reply NAMES, verified against the slice it was shown. The algorithm
    /// is `InquiryCitations`'; this maps the household's lines onto it.
    static func cited(in reply: String, among lines: [HouseholdChatFacts.Line]) -> [UUID] {
        InquiryCitations.cited(in: reply, among: lines.map { InquiryCitable(id: $0.id, title: $0.title) })
    }
}

// MARK: - The prompt (pure, pinned by tests)

enum HouseholdChatPrompt {

    static func instructions(for facts: HouseholdChatFacts) -> String {
        rules + "\n\n" + facts.stableBlock
    }

    static let rules = """
        You are a quiet, competent advisor for ONE household, answering the person's
        questions about everything they and the people they live with have on. What you
        know about them is in the HOUSEHOLD block below and the RELEVANT TASKS each
        question brings; nothing else about their lives.

        Answer the question that was asked, in plain, steady prose — at most three
        short sentences, or a short list when they ask for several things. Call people
        by the names given; "You" is the person asking. No headings, no pep talk, no
        exclamation marks, no emoji.

        Hard rules:
        - The HOUSEHOLD block and the RELEVANT TASKS are authoritative and complete
          about their situation. Never invent a task, a person, a date, a number, a
          place, a price, a phone number, a URL, or a consequence that is not in them.
          When the facts don't say, say so in one sentence — and, if it helps, say what
          would settle it.
        - Counts come from the HOUSEHOLD block, never from adding up lines yourself.
        - General knowledge is allowed when the question calls for it (how a renewal
          usually works). Keep it general: never present a guess about THEIR specifics
          as a fact.
        - You cannot act. You never start, edit, complete, assign, schedule or split a
          task, and you never say you did or will — the person does that on the task
          itself. If they ask you to change something, tell them where it happens.
        - When you refer to a task, use its exact title from the list. If you list several,
          one title per line, in your own words after it if needed — never copy the
          "owner: … · due …" fields from the list.
        - Reporting, never scoring: no verdicts on anyone, no guilt, no streaks, no
          comparisons of who is doing better.
        - If the question has nothing to do with their tasks, say in one sentence that
          you only know their household's tasks.
        """

    /// The per-turn prompt: the relevant slice, then the question (with the continuity
    /// digest ahead of both when the stable picture changed). The shared prompt with
    /// this scope's context block.
    static func turnPrompt(
        question: String, slice: [HouseholdChatFacts.Line], continuity: String?
    ) -> String {
        InquiryPrompt.turnPrompt(
            question: question, context: HouseholdInquiryScope.context(showing: slice),
            continuity: continuity, changedNoun: HouseholdInquiryScope.changedNoun)
    }

    static func continuityDigest(_ messages: [ChatMessage]) -> String? {
        InquiryPrompt.continuityDigest(messages)
    }

    /// Same boundary as every scope, with a longer list allowance — a household answer
    /// that lists several people's things is longer by nature.
    static func validatedReply(_ raw: String) -> String? {
        InquiryPrompt.validatedReply(raw, maxLines: HouseholdInquiryScope.maxLines)
    }

    static var maxLines: Int { HouseholdInquiryScope.maxLines }

    /// The household at a glance, as tappable counts — each one opens the LIST with
    /// that subset already filtered (`TasksPreset`, 2026-09-23). A count is inventory
    /// vocabulary and "which ones?" is the list's job; asking a chat to recite the rows
    /// was the same question twice, once as a number and once as a chip. Only what is
    /// non-zero, in the order a person triages: overdue · today · in progress · waiting
    /// · decisions · the others' loads · done. No "N open": a total is not a glance, and
    /// the day answer ends with the way to the rest.
    struct SummaryItem: Equatable, Sendable {
        let label: String
        let preset: TasksPreset
        /// What VoiceOver and the DEBUG seams say the count opens.
        let opens: String
        let kind: TelemetryGlanceKind
    }

    static func summary(for facts: HouseholdChatFacts) -> [SummaryItem] {
        var items: [SummaryItem] = []
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)" }
        if !facts.overdue.isEmpty {
            items.append(
                .init(
                    label: count(facts.overdue.count, "overdue"),
                    preset: TasksPreset(tab: .everyone, attention: .overdue), opens: "Overdue tasks",
                    kind: .overdue))
        }
        if !facts.dueToday.isEmpty {
            items.append(
                .init(
                    label: count(facts.dueToday.count, "due today"),
                    preset: TasksPreset(tab: .everyone, attention: .dueToday), opens: "Tasks due today",
                    kind: .dueToday))
        }
        if !facts.inProgress.isEmpty {
            items.append(
                .init(
                    label: count(facts.inProgress.count, "in progress"),
                    preset: TasksPreset(tab: .everyone, status: .doing), opens: "Tasks in progress",
                    kind: .inProgress))
        }
        if !facts.blocked.isEmpty {
            items.append(
                .init(
                    label: count(facts.blocked.count, "waiting"),
                    preset: TasksPreset(tab: .everyone, attention: .waiting),
                    opens: "Tasks waiting on something", kind: .waiting))
        }
        if !facts.decisions.isEmpty {
            items.append(
                .init(
                    label: count(
                        facts.decisions.count, facts.decisions.count == 1 ? "decision" : "decisions"),
                    preset: TasksPreset(tab: .everyone, attention: .decisions),
                    opens: "Tasks needing a decision", kind: .decisions))
        }
        // The other caretakers' loads, by name — a number you notice is a number you
        // can open (2026-09-23). Two at most; the strip is a glance, not a roster.
        let loads = facts.members.filter { !$0.isYou }
            .map { ($0, facts.openTasks(of: $0).count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(2)
        for (other, load) in loads {
            items.append(
                .init(
                    label: "\(other.name) \(load)",
                    preset: TasksPreset(tab: .everyone, attention: .ownedBy(other.id, name: other.name)),
                    opens: "\(other.name)’s tasks", kind: .member))
        }
        if !facts.done.isEmpty {
            items.append(
                .init(
                    label: count(facts.done.count, "done this week"),
                    preset: TasksPreset(tab: .everyone, status: .done), opens: "Finished tasks",
                    kind: .done))
        }
        return items
    }

    /// What to ask next, under the latest answer. Shaped by what was just answered
    /// (a list invites "which first?"; a person invites their waits), never a
    /// question already asked in this thread, at most two. Every model-bound chip
    /// carries a reasoning word so it stays a model question; every floor chip stays
    /// a floor question — the routing is decided by the words, as always.
    static func followUps(after question: String, facts: HouseholdChatFacts, asked: [String]) -> [String] {
        var out: [String] = []
        let person = facts.member(named: question)
        let name = person.map { $0.isYou ? "I" : $0.name }
        // "Which one first?" only makes sense when the answer listed something: an empty
        // list ("Nothing is overdue.") gets the other views instead.
        let listed =
            (HouseholdChatFloor.answer(question: question, facts: facts)?.citedTaskIDs.count ?? 0) > 0
        switch HouseholdChatFloor.shape(of: question, facts: facts) {
        case .overdue, .dueToday, .dueTomorrow, .dueThisWeek, .dueNextWeek, .urgent, .category:
            if listed {
                out.append(name == nil ? "Which one should I do first?" : "Which should \(name!) do first?")
            }
            if facts.dueToday.isEmpty == false, !question.lowercased().contains("today") {
                out.append("What's due today?")
            } else if !facts.overdue.isEmpty, !question.lowercased().contains("overdue") {
                out.append("What's overdue?")
            }
        case .inProgress:
            // Something started invites finishing it, not starting another.
            if listed {
                out.append(
                    name == nil ? "Which one should I finish first?" : "Which should \(name!) finish first?")
            }
            if !facts.overdue.isEmpty { out.append("What's overdue?") }
        case .blocked:
            if listed { out.append("What could I do while I wait?") }
            if !facts.overdue.isEmpty { out.append("What's overdue?") }
            if !facts.dueToday.isEmpty { out.append("What's due today?") }
        case .decisions:
            if listed { out.append("What should I weigh first?") }
            out.append("What's coming up this week?")
        case .personOpen:
            if let name, name != "I" {
                out.append("What should \(name) do first?")
                out.append("What is \(name) waiting on?")
            } else {
                out.append("Which one should I do first?")
                out.append("What am I waiting on?")
            }
        case .whoMost:
            if let top = facts.members.map({ ($0, facts.openTasks(of: $0).count) }).max(by: { $0.1 < $1.1 })?
                .0, !top.isYou
            {
                out.append("What could \(top.name) hand off?")
            }
            out.append("What's overdue?")
        case .done:
            out.append("What's coming up this week?")
        case .stalest:
            // Rot invites a verdict: keep it or let it go — the model's, by its words.
            if listed { out.append("Which of these is still worth doing?") }
            if !facts.overdue.isEmpty { out.append("What's overdue?") }
        case .today:
            // The day answer already IS "which first" — offer the two views it hides.
            if !facts.overdue.isEmpty { out.append("What's overdue?") }
            if !facts.blocked.isEmpty { out.append("What's waiting on something?") }
            out.append("What did we get done this week?")
        case .countOpen, .unowned:
            out.append("What's overdue?")
            out.append("Who has the most on their plate?")
        case .quick:
            if listed { out.append("Which one should I do first?") }
            if !facts.overdue.isEmpty { out.append("What's overdue?") }
        case .whyFirst:
            out.append(DayAnswer.quickChip)
            if !facts.blocked.isEmpty { out.append("What could I do while I wait?") }
        case nil:
            // A model answer: bring the person back to the closed questions that
            // answer instantly, so the thread never dead-ends on prose.
            out.append(contentsOf: starterQuestions(for: facts))
        }
        let askedSet = Set(asked.map { $0.lowercased() })
        var seen = Set<String>()
        let shaped = out.filter {
            seen.insert($0.lowercased()).inserted && !askedSet.contains($0.lowercased())
        }
        // Never a dead end: when the shaped chips are all spent (an empty list, every
        // view already asked), the floor's starters take over.
        let fallback = starterQuestions(for: facts).filter {
            !askedSet.contains($0.lowercased()) && !shaped.contains($0)
        }
        return Array((shaped + fallback).prefix(2))
    }

    /// The empty state's suggestions — every one a floor question, so the first tap
    /// answers in two milliseconds with rows, which teaches what this surface is for
    /// better than any copy. Shaped to the household: the load question needs two
    /// people, the done question needs finished work.
    ///
    /// `seated` is the home's case (2026-09-23): the day answer is already the first
    /// line, so its own question is not offered under it, and the counts the strip
    /// opens as lists are not offered as questions either — what remains are the
    /// questions only a judgment answers.
    static func starterQuestions(for facts: HouseholdChatFacts, seated: Bool = false) -> [String] {
        var questions: [String] = []
        // The orientation question leads whenever there is anything open — the Brief's
        // job, kept as a question, answered from rank in two milliseconds.
        if !facts.open.isEmpty, !seated { questions.append("What deserves me today?") }
        // The home is personal AND shared (2026-09-23): the same day question for the
        // other caretaker, one chip, answered by rank in two milliseconds.
        // The other caretaker whose plate is fullest, not the first name on the roster.
        if let other = facts.members.filter({ !$0.isYou })
            .max(by: { facts.openTasks(of: $0).count < facts.openTasks(of: $1).count }),
            !facts.openTasks(of: other).isEmpty
        {
            questions.append("What deserves \(other.name) today?")
        }
        if seated {
            // The home's judgment chips: what fits the time you have, what to do while
            // the waits clear, what is still worth doing.
            let you = facts.members.first(where: \.isYou)
            if !DayAnswer.quick(facts: facts, person: you).isEmpty { questions.append(DayAnswer.quickChip) }
            if !facts.blocked.isEmpty { questions.append("What could I do while I wait?") }
            if facts.stalest.count >= 3 { questions.append("Which of these is still worth doing?") }
            if questions.count < 3 { questions.append("What's coming up this week?") }
            if questions.count < 3, facts.members.count > 1 {
                questions.append("Who has the most on their plate?")
            }
            return Array(questions.prefix(3))
        }
        if !facts.overdue.isEmpty { questions.append("What's overdue?") }
        if !facts.dueToday.isEmpty { questions.append("What's due today?") }
        if !facts.blocked.isEmpty { questions.append("What's waiting on something?") }
        if facts.members.count > 1 { questions.append("Who has the most on their plate?") }
        if !facts.done.isEmpty { questions.append("What did we get done this week?") }
        if questions.count < 3 { questions.append("What's coming up this week?") }
        if questions.count < 3 { questions.append("How many tasks are open?") }
        return Array(questions.prefix(3))
    }
}

// MARK: - The scope

/// The household, as something Ezra can be asked about. One conversation, not one per
/// member: the household is the scope, and a person asking "what's Maya got on?" and
/// then "and me?" is one thread.
struct HouseholdInquiryScope: InquiryScope {
    /// The singleton key — there is exactly one household.
    static let singletonKey = "household"

    let facts: HouseholdChatFacts

    var key: String { Self.singletonKey }
    /// The stable block IS what the instructions hold, so it is the session key.
    var fingerprint: Int { facts.stableFingerprint }
    var openerFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(fingerprint)
        hasher.combine(openers())
        return hasher.finalize()
    }
    /// The unasked lines, in reading order (2026-09-23): the day answer, then the
    /// person's own stall for started work the answer did not seat. The household's
    /// NEWS — what the others did since this person last looked, what the day closed —
    /// is not a line in the thread any more: the calm home renders it as one muted
    /// sentence under the answer (`HouseholdChatView.newsLine`), with no rows.
    func openers() -> [InquiryAnswer] {
        let day = opener()
        let shown = Set(day?.citedTaskIDs ?? [])
        return [day, DayAnswer.stallOpener(facts: facts, excluding: shown)].compactMap { $0 }
    }
    var instructions: String { HouseholdChatPrompt.instructions(for: facts) }

    static let changedNoun = "the household"
    var feature: ModelFeature { .householdChat }
    var config: CapabilityProfiles.Config { Self.replyConfig }
    static let replyConfig = CapabilityProfiles.Config(
        temperature: 0.4, reasoningLevel: nil, maximumResponseTokens: 320)
    static let maxLines = 8
    static let prewarmPrefix = "RELEVANT TASKS:"

    /// Rung 0: the closed questions, exactly and instantly.
    func floor(for question: String) -> InquiryAnswer? {
        HouseholdChatFloor.answer(question: question, facts: facts)
    }

    /// The unasked turn: the day answer. The Brief's job, kept as the thing Ask opens
    /// with — rank, blocked sunk, as rows — so orientation is the first thing on screen
    /// without anyone typing. Nil when nothing is open.
    func opener() -> InquiryAnswer? {
        guard !facts.open.isEmpty else { return nil }
        return HouseholdChatFloor.answer(question: "what deserves me today", facts: facts)
    }

    /// The per-turn slice — the dozen tasks this question is about — as the block the
    /// model reads and the citables it may name.
    func context(for question: String) -> InquiryContext {
        Self.context(showing: HouseholdChatRetrieval.slice(for: question, facts: facts))
    }

    static func context(showing slice: [HouseholdChatFacts.Line]) -> InquiryContext {
        let block =
            slice.isEmpty
            ? "RELEVANT TASKS: none match this question."
            : "RELEVANT TASKS:\n" + slice.map(HouseholdChatFacts.promptLine).joined(separator: "\n")
        return InquiryContext(block: block, shown: slice.map { InquiryCitable(id: $0.id, title: $0.title) })
    }

    func starterQuestions() -> [String] { HouseholdChatPrompt.starterQuestions(for: facts) }
    func followUps(after question: String, asked: [String]) -> [String] {
        HouseholdChatPrompt.followUps(after: question, facts: facts, asked: asked)
    }
}

/// One turn, as the responder is given it.
typealias HouseholdChatTurn = InquiryTurn<HouseholdInquiryScope>

extension InquiryTurn where Scope == HouseholdInquiryScope {
    var facts: HouseholdChatFacts { scope.facts }
    /// The lines this turn showed the model — recomputed deterministically from the
    /// question, so the value is exactly what `context` sent.
    var slice: [HouseholdChatFacts.Line] { HouseholdChatRetrieval.slice(for: question, facts: scope.facts) }

    /// A turn on an unbroken thread — the eval's shape.
    static func make(facts: HouseholdChatFacts, question: String, continuity: String? = nil) -> Self {
        let scope = HouseholdInquiryScope(facts: facts)
        return Self(
            scope: scope, question: question, continuity: continuity, context: scope.context(for: question))
    }
}

// MARK: - The capture offer

/// The chat home's mode trap, answered with an OFFER (2026-09-23): on any chat home
/// people type to-dos into the question box, and this product never guesses which door a
/// sentence was for. So a line that reads like something to do — imperative, no
/// question in it — is not sent to the model; the person is asked whether to add it,
/// with "ask it anyway" one tap away. Conservative on purpose: a question mistaken for a
/// task costs one tap; a task answered as conversation costs the task.
enum CaptureOffer {
    /// Openers that mean "I am telling you a to-do", stripped before the verb test.
    static let intentPrefixes = [
        "i need to ", "i have to ", "i've got to ", "i got to ", "need to ", "gotta ", "got to ",
        "i should ", "i must ", "remember to ", "don't forget to ", "dont forget to ", "remind me to ",
        "have to ", "must ",
    ]
    /// Words that open a QUESTION or an instruction to Ezra, never a to-do.
    static let questionOpeners: Set<String> = [
        "what", "what's", "whats", "who", "who's", "whos", "when", "when's", "where", "where's",
        "why", "which", "how", "is", "are", "am", "can", "could", "should", "would", "will", "do",
        "does", "did", "has", "have", "had", "was", "were", "any", "anything", "tell", "show",
        "list", "give", "explain", "summarize", "summarise", "help",
    ]
    /// Action verbs that, at the head of a line, usually address Ezra rather than name
    /// a task ("check what's overdue", "find the stuck ones").
    static let askingVerbs: Set<String> = ["ask", "check", "look", "find", "figure", "see", "remind"]

    static func looksLikeCapture(_ text: String) -> Bool {
        var lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty, !lowered.contains("?") else { return false }
        for prefix in intentPrefixes where lowered.hasPrefix(prefix) {
            lowered.removeFirst(prefix.count)
            break
        }
        let words = lowered.split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard words.count >= 2, let first = words.first else { return false }
        if questionOpeners.contains(first) { return false }
        if askingVerbs.contains(first) { return false }
        return Segmentation.actionVerbs.contains(first)
    }
}

// MARK: - Since you last looked

/// The home's second opener: what the OTHER caretakers did since this person last
/// looked, as one sentence with the tasks as rows (2026-09-23). It is the Activity
/// feed's information, said once where the person already is — never a badge, never a
/// count asking to be visited (guardrail 1); the sentence only exists while there is
/// something to say, and it is about people, not the system. Pure over `Change`s the
/// view builds from `ChangeLogEntry`, so it is testable without a store.
enum HouseholdCatchUp {
    struct Change: Equatable, Hashable, Sendable {
        let actorName: String
        let action: String
        let taskTitle: String
        let taskID: UUID?
        /// An assignment whose new owner is the person reading — "handed you".
        var handedToYou: Bool = false
    }

    /// How many changes the sentence names before it counts the rest.
    static let named = 3
    /// The window on a first-ever look, so an install's first home does not recite a
    /// month of someone else's trail.
    static let firstLookWindowDays = 7

    static func verb(for change: Change) -> String {
        switch change.action {
        case "completed": return "finished"
        case "killed": return "cancelled"
        case "decided": return "decided"
        case "assigned": return change.handedToYou ? "handed you" : "reassigned"
        case "split": return "split"
        case "grouped": return "grouped"
        case "archived": return "archived"
        case "unblocked": return "unblocked"
        case "merged", "mergedPair": return "merged"
        case "linked": return "linked"
        default: return "updated"
        }
    }

    static func answer(_ changes: [Change]) -> InquiryAnswer? {
        guard !changes.isEmpty else { return nil }
        // "Handed you" leads: the one change that is about the reader.
        let ordered = changes.sorted { $0.handedToYou && !$1.handedToYou }
        let shown = Array(ordered.prefix(named))
        // Grouped by actor, in first-appearance order, so one person's three acts read
        // as one clause: "Maya finished A, took on B".
        var byActor: [(String, [Change])] = []
        for change in shown {
            if let index = byActor.firstIndex(where: { $0.0 == change.actorName }) {
                byActor[index].1.append(change)
            } else {
                byActor.append((change.actorName, [change]))
            }
        }
        let clauses = byActor.map { actor, acts in
            actor + " " + acts.map { "\(verb(for: $0)) “\($0.taskTitle)”" }.joined(separator: ", ")
        }
        var text = "Since you last looked, " + clauses.joined(separator: "; ")
        let rest = changes.count - shown.count
        if rest > 0 { text += ", and \(rest) more in Activity" }
        text += "."
        var seen = Set<UUID>()
        let cited = shown.compactMap(\.taskID).filter { seen.insert($0).inserted }
        return InquiryAnswer(text: text, citedTaskIDs: cited)
    }
}

// MARK: - The store, household-shaped

/// The household conversation for this launch — `InquiryStore` with one key.
typealias HouseholdChatStore = InquiryStore<HouseholdInquiryScope>

extension HouseholdInquiryScope {
    static let store = InquiryStore<HouseholdInquiryScope>()
}

extension InquiryStore where Scope == HouseholdInquiryScope {

    static var shared: InquiryStore<HouseholdInquiryScope> { HouseholdInquiryScope.store }

    private var key: String { HouseholdInquiryScope.singletonKey }

    var messages: [ChatMessage] { messages(key: key) }
    var isReplying: Bool { isReplying(key: key) }
    /// Which rung answered the LAST question — the DEBUG footer's receipt.
    var lastRoute: InquiryRoute? { lastRoute(key: key) }

    func ask(_ question: String, facts: HouseholdChatFacts, now: Date = Date()) {
        ask(question, scope: HouseholdInquiryScope(facts: facts), now: now)
    }

    func retry(replyID: UUID, facts: HouseholdChatFacts, now: Date = Date()) {
        retry(replyID: replyID, scope: HouseholdInquiryScope(facts: facts), now: now)
    }

    func cancelAll() { cancel(key: key) }

    func clear() { clear(key: key) }

    func awaitPendingReplies() async { await awaitPendingReplies(key: key) }

    #if DEBUG
    /// Verification fixture (`-HouseholdChatFixture`): a floor answer with rows, a
    /// model answer, and a reply in flight — every state on screen at once.
    func seedFixture(citing ids: [UUID]) {
        seed(
            key: key,
            messages: [
                .init(role: .user, text: "What's overdue?"),
                .init(
                    role: .advisor, text: "\(ids.count) task\(ids.count == 1 ? " is" : "s are") overdue.",
                    citedTaskIDs: ids),
                .init(role: .user, text: "Why is the passport stuck?"),
                .init(
                    role: .advisor,
                    text:
                        "Renew the passport is waiting on Get passport photos, and the flights wait on both — "
                        + "the photos are the one thing that unblocks the rest."),
                .init(role: .user, text: "What should we do first this weekend?"),
                .init(role: .advisor, text: "", state: .pending),
            ])
    }
    #endif
}
