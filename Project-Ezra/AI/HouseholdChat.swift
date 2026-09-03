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

        var isOverdue: Bool { (daysUntilDue ?? 0) < 0 }
        var isDueToday: Bool { daysUntilDue == 0 }
        var isBlocked: Bool { !blockerTitles.isEmpty || !externalWaits.isEmpty }
        var isDueThisWeek: Bool {
            guard let days = daysUntilDue else { return false }
            return days >= 0 && days <= 7
        }
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

    /// How many rows the day answer names. The Brief's "3–5 that matter", kept.
    static let dayAnswerCap = 5

    /// The day answer: the top of the stack with the blocked sunk, capped — for one
    /// person when named, otherwise for everyone. Rank is the ONLY input; nothing here
    /// re-decides what matters.
    func dayAnswer(for person: Member?) -> [Line] {
        let byID = Dictionary(uniqueKeysWithValues: open.map { ($0.id, $0) })
        let ordered: [Line] = rankOrder.isEmpty ? open : rankOrder.compactMap { byID[$0] }
        return Array(
            ordered
                .filter { !$0.isBlocked }
                .filter { line in person.map { line.ownerID == $0.id } ?? true }
                .prefix(Self.dayAnswerCap))
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
        let open = tasks.filter { !$0.status.isResolved }
            .map { task -> Line in
                let blockers = task.activeBlockerTasks(among: tasks).map(\.title)
                let waits = task.activeBlockers(among: tasks).filter { $0.taskID == nil }.compactMap(\.note)
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
                    updatedAt: task.updatedAt)
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
    var dueThisWeek: [Line] { open.filter(\.isDueThisWeek) }
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
            !words.isDisjoint(with: ["you", "me", "my", "i", "mine", "i'm", "myself"])
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
        case dueThisWeek
        case blocked
        case urgent
        case decisions
        case unowned
        case countOpen
        case personOpen
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
        if has(
            "what deserves me today", "what deserves me", "what matters today", "what matters most",
            "what should i focus on", "what should i do first", "where do i start", "where should i start",
            "what's my day", "what is my day", "my day", "priorities", "what's important today",
            "what should i do today", "what do i do today", "what deserves my attention")
        {
            return .today
        }
        if InquiryFloor.isReasoning(question) { return nil }
        // Time and outcome first — "what did we get done this week" must not fall
        // into "this week" (due this week).
        if has(
            "get done", "got done", "finished", "completed", "did we do", "did i do", "done this week",
            "done today")
        {
            return .done
        }
        if has(
            "who has the most", "who's carrying", "who is carrying", "busiest", "most on their plate",
            "most to do", "most tasks", "most open")
        {
            return .whoMost
        }
        if has("overdue", "past due", "late") { return .overdue }
        if has("today") && !has("tomorrow") { return .dueToday }
        if has("this week", "upcoming", "coming up", "next few days", "next 7 days", "next seven days") {
            return .dueThisWeek
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
        return nil
    }

    /// The floor's answer, or nil when the model should speak. Exact, cited, capped.
    static func answer(question: String, facts: HouseholdChatFacts) -> HouseholdChatAnswer? {
        guard let shape = shape(of: question, facts: facts) else { return nil }
        let person = facts.member(named: question)
        // A named person scopes every list: "what's overdue for Maya?".
        func scoped(_ lines: [HouseholdChatFacts.Line]) -> [HouseholdChatFacts.Line] {
            guard let person else { return lines }
            return lines.filter { $0.ownerID == person.id }
        }
        let whose = person.map { $0.isYou ? "you" : $0.name }

        switch shape {
        case .today:
            let ranked = facts.dayAnswer(for: person)
            guard !ranked.isEmpty else {
                return HouseholdChatAnswer(
                    text: whose.map { "Nothing is asking for \($0) today." } ?? "Nothing is asking for you today.",
                    citedTaskIDs: [])
            }
            let lead = ranked.count == 1 ? "One thing deserves you first" : "\(ranked.count) things deserve you first"
            return HouseholdChatAnswer(
                text: lead + (whose.map { " for \($0)" } ?? "") + " — in order.",
                citedTaskIDs: ranked.map(\.id))
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
        case .dueThisWeek:
            return list(scoped(facts.dueThisWeek), "due in the next 7 days", whose: whose)
        case .blocked:
            return list(scoped(facts.blocked), "waiting on something", whose: whose)
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

    private static func list(
        _ lines: [HouseholdChatFacts.Line], _ predicate: String, whose: String?
    ) -> HouseholdChatAnswer {
        let scope = whose.map { " for \($0)" } ?? ""
        guard !lines.isEmpty else {
            return HouseholdChatAnswer(text: "Nothing is \(predicate)\(scope).", citedTaskIDs: [])
        }
        let capped = Array(lines.prefix(HouseholdChatFacts.listCap))
        let more = lines.count > capped.count ? " Showing the nearest \(capped.count)." : ""
        let verb = lines.count == 1 ? "is" : "are"
        return HouseholdChatAnswer(
            text: "\(count(lines.count, "task")) \(verb) \(predicate)\(scope).\(more)",
            citedTaskIDs: capped.map(\.id))
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
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
            if has("week", "upcoming", "soon"), line.isDueThisWeek { score += 2 }
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
        return
            scored
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return a.0.id.uuidString < b.0.id.uuidString
            }
            .prefix(cap)
            .map(\.0)
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
        - When you refer to a task, use its exact title from the list.
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

    /// The empty state's suggestions — every one a floor question, so the first tap
    /// answers in two milliseconds with rows, which teaches what this surface is for
    /// better than any copy. Shaped to the household: the load question needs two
    /// people, the done question needs finished work.
    static func starterQuestions(for facts: HouseholdChatFacts) -> [String] {
        var questions: [String] = []
        // The orientation question leads whenever there is anything open — the Brief's
        // job, kept as a question, answered from rank in two milliseconds.
        if !facts.open.isEmpty { questions.append("What deserves me today?") }
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
        return Self(scope: scope, question: question, continuity: continuity, context: scope.context(for: question))
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
                    text: "Renew the passport is waiting on Get passport photos, and the flights wait on both — "
                        + "the photos are the one thing that unblocks the rest."),
                .init(role: .user, text: "What should we do first this weekend?"),
                .init(role: .advisor, text: "", state: .pending),
            ])
    }
    #endif
}
