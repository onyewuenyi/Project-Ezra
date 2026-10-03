//
//  TaskAdvisorChat.swift
//  Project-Ezra
//
//  The Advisor you can ASK, scoped to ONE task — the first `InquiryScope` (P-01).
//
//  The ambient Advisor volunteers one reading per fingerprint and is silent almost
//  everywhere; this is the same advisor with the door open — a conversation over the
//  same deterministic facts, answering the person's own questions ("what's the first
//  step?", "what's actually in the way?"). Chat is the one surface where the user
//  REQUESTS intelligence rather than receiving it, and every rule that follows from
//  that difference — on-device only, never acts, reply revealed whole, one session per
//  (task, fingerprint), continuity digest when the facts move, in-memory per launch —
//  is enforced ONCE in `Inquiry.swift` and inherited here. This file holds only what
//  is genuinely the task's: its rules, its facts block, its starter questions, and the
//  task-shaped API the detail page calls.
//
//  Before P-01 the loop below existed here in full (`TaskAdvisorChatService`,
//  `TaskAdvisorChatStore`) and again, line for line, in `HouseholdChat.swift`. The two
//  converged independently on the same seven-part structure; that structure is now the
//  primitive, and this scope is one conformance to it.
//
//  Not a cloud surface: the questions never leave the device. Grep-pinned in
//  `TaskAdvisorChatTests` alongside `Inquiry.swift`.
//

import Foundation

// MARK: - Messages

/// The task chat's message — the shared `ChatMessage`, named for its first home.
typealias TaskAdvisorChatMessage = ChatMessage

/// One line of a conversation, as the surface renders it. Shared by every inquiry
/// scope: same roles, same states, same trust rules.
struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case advisor
    }

    enum State: Equatable, Sendable {
        /// On screen and final.
        case sent
        /// An advisor reply in flight — renders the thinking mark.
        case pending
        /// An advisor reply that never arrived. `retryable` is false only for
        /// `.unavailable` (no model), which the surface should never reach because
        /// the entry point hides itself; kept so the vocabulary stays honest.
        case failed(retryable: Bool)
        /// The PERSON stopped this reply (the composer's stop control). Not a failure
        /// — nothing went wrong — so it reads "Stopped." and offers the same way back.
        case stopped
    }

    let id: UUID
    let role: Role
    var text: String
    var state: State
    /// Tasks this line CITES, rendered as tappable rows under it. Deterministic-only,
    /// like `ValidatedReading.citedTaskIDs`: a citation is a task the floor answered
    /// with or a title the reply named that the facts actually hold — never a model's
    /// claim about the graph.
    var citedTaskIDs: [UUID]
    /// One clause per cited task saying why it is here — the day answer's rows carry
    /// them (2026-09-23); a plain citation carries none and the row places itself.
    var reasons: [UUID: String]
    /// When the line was sent (a question) or landed (an answer). Drives the thread's
    /// time dividers and survives the Ask tab's archive.
    var sentAt: Date

    init(
        id: UUID = UUID(), role: Role, text: String, state: State = .sent,
        citedTaskIDs: [UUID] = [], reasons: [UUID: String] = [:], sentAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.state = state
        self.citedTaskIDs = citedTaskIDs
        self.reasons = reasons
        self.sentAt = sentAt
    }
}

// MARK: - Thread rhythm (pure)

enum ChatThreadRhythm {
    /// A divider precedes a line when it starts a new sitting — more than this long
    /// after the line before it, or when it is the first line and older than this.
    static let sittingGap: TimeInterval = 60 * 60

    static func needsDivider(
        before message: ChatMessage, after previous: ChatMessage?, now: Date = Date()
    ) -> Bool {
        guard let previous else { return now.timeIntervalSince(message.sentAt) > sittingGap }
        return message.sentAt.timeIntervalSince(previous.sentAt) > sittingGap
    }

    /// The day answer's kicker: "Friday, 4 September" — the page's date, so the opener
    /// reads as today's page rather than a message from nowhere.
    static func dayLabel(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: date)
    }

    /// "Today 8:00 AM" · "Yesterday 6:12 PM" · "Tue 2 Sep" — the reference design's
    /// quiet timestamp, relative where relative reads naturally.
    static func dividerLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        if calendar.isDate(date, inSameDayAs: now) { return "Today " + time.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday " + time.string(from: date)
        }
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM"
        return day.string(from: date)
    }
}

// MARK: - The scope

/// One task, as something Ezra can be asked about — or, in `.reading` mode, the thing
/// the ambient Advisor JUDGES: the unasked turn over the same facts (G2). The two modes
/// share the key and the fingerprint (one session per (task, facts) each) and differ in
/// their prefix: the chat puts the facts in its instructions and takes questions; the
/// reading keeps the Advisor's static instructions and puts the facts in the prompt, so
/// one warm spare can serve any task's first judgment.
struct TaskInquiryScope: InquiryScope {
    enum Mode: String, Sendable {
        /// Asked turns: the conversation.
        case chat
        /// The unasked turn: the ambient reading, generated as a typed judgment.
        case reading
    }

    let taskID: UUID
    let facts: TaskAdvisorFacts
    let mode: Mode

    init(taskID: UUID, facts: TaskAdvisorFacts, mode: Mode = .chat) {
        self.taskID = taskID
        self.facts = facts
        self.mode = mode
    }

    /// Nil when the facts carry no id — a fixture, never a live task.
    init?(facts: TaskAdvisorFacts) {
        guard let id = facts.id else { return nil }
        self.init(taskID: id, facts: facts)
    }

    var key: UUID { taskID }
    var fingerprint: Int { facts.fingerprint }
    var instructions: String {
        switch mode {
        case .chat: return TaskAdvisorChatPrompt.instructions(for: facts)
        case .reading: return TaskAdvisorService.instructions
        }
    }
    var sessionDiscriminator: String { mode.rawValue }

    static let changedNoun = "the task"
    var feature: ModelFeature { mode == .chat ? .advisorChat : .taskAdvisor }
    /// Reply prose runs a little cooler than the reading — a question deserves a direct
    /// answer, not a flourish — and the ceiling is the four-sentence clamp's worth of
    /// tokens with room for a list the person asked for. The reading keeps the Advisor's
    /// own profile.
    var config: CapabilityProfiles.Config { mode == .chat ? Self.chatConfig : CapabilityProfiles.taskAdvisor }
    static let chatConfig = CapabilityProfiles.Config(
        temperature: 0.4, reasoningLevel: nil, maximumResponseTokens: 240)
    /// A step per line, plus a line to introduce them.
    static let maxLines = 6
    static let prewarmPrefix = "QUESTION:"

    /// Rung 0 for a task: the CLOSED questions — when is it due, what is it waiting on,
    /// how long will it take, what is left — answered exactly from the facts, with the
    /// blockers and steps as rows. The reading remains the conversation's opener; this
    /// is what makes condition 2 of the scoped-conversation fence true here too.
    func floor(for question: String) -> InquiryAnswer? {
        TaskInquiryFloor.answer(question: question, facts: facts)
    }

    /// The unasked turn's rung 0: the deterministic reading. The SAME function as the
    /// asked floor with no question — two floors became one (G2).
    func opener() -> InquiryAnswer? {
        TaskInquiryFloor.answer(question: nil, facts: facts)
    }
    // No per-turn context: the facts block in the instructions carries everything.

    func starterQuestions() -> [String] { TaskAdvisorChatPrompt.starterQuestions(for: facts) }
    func followUps(after question: String, asked: [String]) -> [String] {
        TaskAdvisorChatPrompt.followUps(for: facts, asked: asked)
    }
}

/// One turn, as the responder is given it.
typealias TaskAdvisorChatTurn = InquiryTurn<TaskInquiryScope>

extension InquiryTurn where Scope == TaskInquiryScope {
    var taskID: UUID { scope.taskID }
    var facts: TaskAdvisorFacts { scope.facts }
}

// MARK: - The prompt (what is the task's own)

enum TaskAdvisorChatPrompt {

    /// The rules, then the facts. The rules come first so the stable block leads and
    /// the per-task facts are appended — the same prefix discipline as capture.
    static func instructions(for facts: TaskAdvisorFacts) -> String {
        rules + "\n\n" + facts.promptBlock
    }

    static let rules = """
        You are a quiet, competent advisor sitting inside ONE task, answering the
        person's questions about it. Everything you know about their situation is in
        the FACTS below.

        Answer the question that was asked, in plain, steady prose — at most three
        short sentences. No headings, no bullet lists unless they ask for steps, no
        pep talk, no exclamation marks, no emoji.

        Hard rules:
        - The FACTS are authoritative and complete about the person's situation. Never
          invent a blocker, a person, a date, a number, a place, a price, a phone
          number, a URL, or a consequence that is not in them. When the facts don't
          say, say so in one sentence — and, if it helps, say what would settle it.
        - General knowledge is allowed when the question calls for it (how a renewal
          usually works, what a task like this typically involves). Keep it general:
          never present a guess about THEIR specifics as a fact.
        - You cannot act. You never start, edit, complete, schedule or split the task,
          and you never say you did or will — the person does that on the task page.
          If they ask you to change something, tell them where it happens.
        - SENSOR lines are deterministic readings: interpret them, never contradict
          them. INTERNAL lines are context for you alone; never repeat their wording.
        - Reporting, never scoring: no verdicts on the person, no guilt, no streaks.
        - If the question has nothing to do with this task, say in one sentence that
          you only know this task.
        """

    /// What to ask next, under the latest answer: the task's starter questions the
    /// person has not asked yet, at most two. Chips, not prose — the conversation
    /// keeps going without typing, and every chip is a question this task can take.
    static func followUps(for facts: TaskAdvisorFacts, asked: [String]) -> [String] {
        let askedSet = Set(asked.map { $0.lowercased() })
        return Array(starterQuestions(for: facts).filter { !askedSet.contains($0.lowercased()) }.prefix(2))
    }

    /// Three questions worth asking THIS task, from its shape — the empty state's
    /// suggestions. Deterministic, so the chat opens knowing what is askable here
    /// rather than with a blank field. Never a question that invites invention (no
    /// "what happens if this slips?").
    static func starterQuestions(for facts: TaskAdvisorFacts) -> [String] {
        var questions: [String] = []
        switch TaskShape.of(facts) {
        case .waiting:
            questions.append("What's actually in the way?")
            questions.append("What can I do while I wait?")
        case .deciding:
            questions.append("What should I weigh here?")
            questions.append("What would settle this?")
        case .container:
            questions.append("What's left on this?")
            questions.append("Which step first?")
        case .action:
            questions.append("What's the first step?")
            if facts.breakdownReason != nil {
                questions.append("How would you break this down?")
            } else {
                questions.append("What does this usually involve?")
            }
        }
        questions.append("What am I missing?")
        return Array(questions.prefix(3))
    }

    // The shared machinery, reachable under the scope's name so the tests that pinned
    // it here keep reading as one story. The logic lives in `InquiryPrompt`, once.
    static var historyWindow: Int { InquiryPrompt.historyWindow }
    static var maxSentences: Int { InquiryPrompt.maxSentences }
    static var maxLines: Int { TaskInquiryScope.maxLines }
    static var continuityExchanges: Int { InquiryPrompt.continuityExchanges }

    static func turnPrompt(question: String, continuity: String?) -> String {
        InquiryPrompt.turnPrompt(
            question: question, context: .none, continuity: continuity,
            changedNoun: TaskInquiryScope.changedNoun)
    }

    static func continuityDigest(_ messages: [TaskAdvisorChatMessage]) -> String? {
        InquiryPrompt.continuityDigest(messages)
    }

    static func validatedReply(_ raw: String) -> String? {
        InquiryPrompt.validatedReply(raw, maxLines: TaskInquiryScope.maxLines)
    }
}

// MARK: - The store, task-shaped

/// The conversations, per task, for this launch — `InquiryStore` keyed by task id.
typealias TaskAdvisorChatStore = InquiryStore<TaskInquiryScope>

extension TaskInquiryScope {
    /// The app's one task-chat store. A generic type cannot hold a static stored
    /// property, so the singleton lives on the scope.
    static let store = InquiryStore<TaskInquiryScope>()
}

extension InquiryStore where Scope == TaskInquiryScope {

    static var shared: InquiryStore<TaskInquiryScope> { TaskInquiryScope.store }

    func messages(for taskID: UUID?) -> [TaskAdvisorChatMessage] { messages(key: taskID) }

    func isReplying(for taskID: UUID?) -> Bool { isReplying(key: taskID) }

    /// Ask about a task. The facts are computed here, at the moment of asking, so the
    /// fingerprint the turn carries is the current truth.
    func ask(_ question: String, task: TaskItem, among tasks: [TaskItem], now: Date = Date()) {
        guard let id = task.uuid else { return }
        let facts = TaskAdvisorFacts.make(task: task, among: tasks, now: now)
        ask(question, scope: TaskInquiryScope(taskID: id, facts: facts), now: now)
    }

    func retry(replyID: UUID, task: TaskItem, among tasks: [TaskItem], now: Date = Date()) {
        guard let id = task.uuid else { return }
        let facts = TaskAdvisorFacts.make(task: task, among: tasks, now: now)
        retry(replyID: replyID, scope: TaskInquiryScope(taskID: id, facts: facts), now: now)
    }

    func cancel(taskID: UUID?) { cancel(key: taskID) }

    func clear(taskID: UUID?) { clear(key: taskID) }

    func awaitPendingReplies(for taskID: UUID?) async { await awaitPendingReplies(key: taskID) }

    #if DEBUG
    /// Verification fixture (`-ChatFixture`): a canned thread so every message state —
    /// a question, a whole answer, a reply in flight — is on screen at once on a host
    /// with no model.
    func seedFixture(taskID: UUID?) {
        guard let taskID else { return }
        seed(
            key: taskID,
            messages: [
                .init(role: .user, text: "What's the first step?"),
                .init(
                    role: .advisor,
                    text: "Find the last renewal letter — the policy number is on it. "
                        + "Then it's a ten-minute call to get a quote."),
                .init(role: .user, text: "What if I switch providers?"),
                .init(role: .advisor, text: "", state: .pending),
            ])
    }
    #endif
}

// MARK: - The task's floor (rung 0)

enum TaskInquiryFloor {

    enum Shape: Equatable, CaseIterable {
        case due
        case blockers
        case effort
        case steps
    }

    static func shape(of question: String) -> Shape? {
        // "How long" / "how much time" are closed questions about the estimate — the
        // task's own "how many" exception to the reasoning gate.
        let gated = question.lowercased()
            .replacingOccurrences(of: "how long", with: "duration")
            .replacingOccurrences(of: "how much time", with: "duration")
        guard !InquiryFloor.isReasoning(gated) else { return nil }
        let lowered = question.lowercased()
        func has(_ phrases: String...) -> Bool { InquiryFloor.mentions(any: phrases, in: lowered) }
        if has(
            "when is this due", "when's this due", "due date", "deadline", "when is it due", "due when",
            "overdue")
        {
            return .due
        }
        if has("blocking", "blocked", "waiting on", "in the way", "waiting for", "blockers") {
            return .blockers
        }
        if has("how long", "how much time", "effort", "estimate", "time will") { return .effort }
        if has("what's left", "what is left", "steps", "remaining", "what remains") { return .steps }
        return nil
    }

    /// The task's floor. `nil` question = the UNASKED turn, answered by
    /// `DeterministicReading` — the Advisor's rung 0 and the chat's opener are one
    /// function, so they cannot disagree.
    static func answer(question: String?, facts: TaskAdvisorFacts) -> InquiryAnswer? {
        guard let question else {
            guard let reading = DeterministicReading.make(from: facts), !reading.observation.isEmpty else {
                return nil
            }
            return InquiryAnswer(text: reading.observation, citedTaskIDs: reading.citedTaskIDs)
        }
        guard let shape = shape(of: question) else { return nil }
        switch shape {
        case .due:
            if let over = facts.overdueDays {
                return InquiryAnswer(
                    text: "It was due \(over) day\(over == 1 ? "" : "s") ago.", citedTaskIDs: [])
            }
            if let days = facts.daysUntilDue {
                let when = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
                return InquiryAnswer(text: "It's due \(when).", citedTaskIDs: [])
            }
            return InquiryAnswer(text: "No due date on this.", citedTaskIDs: [])
        case .blockers:
            let waits = facts.blockerTitles + facts.externalWaits
            guard !waits.isEmpty else {
                return InquiryAnswer(text: "Nothing is blocking it.", citedTaskIDs: [])
            }
            return InquiryAnswer(
                text: "Waiting on " + waits.joined(separator: "; ") + ".", citedTaskIDs: facts.blockerIDs)
        case .effort:
            if let minutes = facts.effortMinutes {
                return InquiryAnswer(
                    text: "About \(minutes) minutes, going by the estimate.", citedTaskIDs: [])
            }
            return InquiryAnswer(text: "No estimate on this one.", citedTaskIDs: [])
        case .steps:
            guard !facts.openStepTitles.isEmpty else {
                return InquiryAnswer(text: "It isn't broken into steps.", citedTaskIDs: [])
            }
            let count = facts.openStepTitles.count
            return InquiryAnswer(
                text: "\(count) step\(count == 1 ? "" : "s") left: "
                    + facts.openStepTitles.joined(separator: "; ") + ".",
                citedTaskIDs: facts.childIDs)
        }
    }
}
