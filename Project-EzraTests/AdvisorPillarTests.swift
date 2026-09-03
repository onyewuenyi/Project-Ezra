//
//  AdvisorPillarTests.swift
//  Project-EzraTests
//
//  The Advisor pillar's four features, each pinned at the seam that makes it true:
//  F-07 a judgment survives a relaunch (rung 1 across launches), F-08 the task scope
//  has a floor and the scoped-conversation fence holds for every scope, F-09 silence
//  carries the time it was judged, F-10 repeated dismissals of one move reach the prompt.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("F-07 · the judgment cache survives a relaunch")
struct AdvisorReadingCacheTests {

    private func reading(_ observation: String) -> ValidatedReading {
        ValidatedReading(
            move: .advise, observation: observation, guidance: nil, nextMove: nil,
            options: [], recommendation: nil, steps: [])
    }

    @Test("A stored reading round-trips through the file, keyed on task + fingerprint")
    func roundTrip() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("readings-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let task = UUID()
        let cache = AdvisorReadingCache(fileURL: url)
        cache.store(reading("Start with the policy number."), taskID: task, fingerprint: 11)
        let reloaded = AdvisorReadingCache(fileURL: url)
        #expect(
            reloaded.record(for: task, fingerprint: 11)?.reading.observation
                == "Start with the policy number.")
        #expect(reloaded.record(for: task, fingerprint: 12) == nil)
    }

    @Test("A task keeps only its latest fingerprint's judgment")
    func latestOnly() {
        let cache = AdvisorReadingCache(fileURL: nil)
        let task = UUID()
        cache.store(reading("old"), taskID: task, fingerprint: 1)
        cache.store(reading("new"), taskID: task, fingerprint: 2)
        #expect(cache.all.count == 1)
        #expect(cache.record(for: task, fingerprint: 1) == nil)
        #expect(cache.record(for: task, fingerprint: 2)?.reading.observation == "new")
    }

    @Test("A FRESH store over the same facts serves the cached reading with no generation, as rung 1")
    func servedFromMemoryAcrossStores() async throws {
        let context = TestStore.makeContext()
        let task = TaskItem(
            title: "Renew the car insurance",
            dueDate: Calendar.current.date(byAdding: .day, value: -3, to: Date()),
            isUrgent: true, in: context)
        try context.save()
        let cache = AdvisorReadingCache(fileURL: nil)
        func store(judge: @escaping TaskAdvisorStore.Judge, ledger: IntelligenceLedger) -> TaskAdvisorStore {
            TaskAdvisorStore(
                judge: judge, isModelAvailable: { true },
                metrics: AdvisorMetrics(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                ledger: ledger, verdicts: HumanVerdictStore(fileURL: nil), readings: cache)
        }
        let first = store(
            judge: { _, _, _ in .success(self.reading("Find the renewal letter.")) },
            ledger: IntelligenceLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        first.ensure(task: task, among: [task])
        await first.awaitPendingJudgment(for: task.uuid)
        guard case .revealed = first.state(for: task) else {
            Issue.record("expected a reveal; got \(first.state(for: task))")
            return
        }
        #expect(first.judgedAt(for: task) != nil)

        var judged = 0
        let ledger = IntelligenceLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let second = store(
            judge: { _, _, _ in
                judged += 1
                return .failed("must not generate")
            }, ledger: ledger)
        second.ensure(task: task, among: [task])
        await second.awaitPendingJudgment(for: task.uuid)
        guard case .revealed(let served) = second.state(for: task) else {
            Issue.record("expected the cached reveal; got \(second.state(for: task))")
            return
        }
        #expect(served.observation == "Find the renewal letter.")
        #expect(judged == 0)
        #expect(ledger.counts[.advisor]?[.memory] == 1)
    }

    @Test("Silence is cached too, and re-served as model-judged silence")
    func silenceCached() async throws {
        let context = TestStore.makeContext()
        let task = TaskItem(
            title: "Renew the car insurance",
            dueDate: Calendar.current.date(byAdding: .day, value: -3, to: Date()),
            isUrgent: true, in: context)
        try context.save()
        let cache = AdvisorReadingCache(fileURL: nil)
        let first = TaskAdvisorStore(
            judge: { _, _, _ in .success(.silence) }, isModelAvailable: { true },
            metrics: AdvisorMetrics(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            ledger: IntelligenceLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            verdicts: HumanVerdictStore(fileURL: nil), readings: cache)
        first.ensure(task: task, among: [task])
        await first.awaitPendingJudgment(for: task.uuid)
        #expect(first.state(for: task) == .quiet(.model))
        let second = TaskAdvisorStore(
            judge: { _, _, _ in .failed("must not generate") }, isModelAvailable: { true },
            metrics: AdvisorMetrics(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            ledger: IntelligenceLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            verdicts: HumanVerdictStore(fileURL: nil), readings: cache)
        second.ensure(task: task, among: [task])
        await second.awaitPendingJudgment(for: task.uuid)
        #expect(second.state(for: task) == .quiet(.model))
        #expect(second.judgedAt(for: task) != nil)
    }
}

@MainActor
@Suite("F-08 · the task floor, and the scoped-conversation fence")
struct InquiryFenceTests {

    private func facts(
        due: Int? = nil, overdue: Int? = nil, blockers: [String] = [], effort: Int? = nil,
        steps: [String] = []
    ) -> TaskAdvisorFacts {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "Renew the car insurance", in: context)
        var f = TaskAdvisorFacts.make(task: task, among: [task])
        f.daysUntilDue = due
        f.overdueDays = overdue
        f.blockerTitles = blockers
        f.effortMinutes = effort
        f.openStepTitles = steps
        return f
    }

    @Test("The task floor answers the closed questions exactly — and declines reasoning ones")
    func taskFloor() {
        let scope = TaskInquiryScope(
            taskID: UUID(), facts: facts(due: 3, blockers: ["Get the policy number"], effort: 30))
        #expect(scope.floor(for: "When is this due?")?.text == "It's due in 3 days.")
        #expect(scope.floor(for: "What's blocking this?")?.text == "Waiting on Get the policy number.")
        #expect(
            scope.floor(for: "How long will this take?")?.text == "About 30 minutes, going by the estimate.")
        #expect(scope.floor(for: "What's left?")?.text == "It isn't broken into steps.")
        #expect(scope.floor(for: "Why is this due so soon?") == nil)
        #expect(scope.floor(for: "What's the first step?") == nil)
        let overdue = TaskInquiryScope(taskID: UUID(), facts: facts(overdue: 2))
        #expect(overdue.floor(for: "Is this overdue?")?.text == "It was due 2 days ago.")
        let undated = TaskInquiryScope(taskID: UUID(), facts: facts())
        #expect(undated.floor(for: "When is this due?")?.text == "No due date on this.")
    }

    @Test("Condition 2: every shipped scope answers at least one closed question from its floor")
    func everyScopeHasAFloor() {
        let task = TaskInquiryScope(taskID: UUID(), facts: facts(due: 1))
        #expect(task.floor(for: "When is this due?") != nil)
        let household = HouseholdInquiryScope(facts: HouseholdChatEval.fixture())
        #expect(household.floor(for: "What's overdue?") != nil)
        #expect(household.floor(for: "What deserves me today?") != nil)
    }

    @Test("Condition 3: the inquiry files carry no mutation seam — a conversation never acts")
    func neverActs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Project-Ezra")
        for file in ["AI/Inquiry.swift", "AI/TaskAdvisorChat.swift", "AI/HouseholdChat.swift"] {
            let content = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for seam in [".status = ", "complete(", "kill(", "splitInto(", "resolveDecision(", "setStatus("] {
                #expect(!content.contains(seam), "\(file) contains a mutation seam: \(seam)")
            }
        }
    }
}

@Suite("F-09 · silence carries the time it was judged")
struct SilenceLineTests {

    @Test("The line names when Ezra looked; without a time it still says it looked")
    func silenceLine() {
        let now = Date()
        #expect(TaskDetailView.silenceLine(judgedAt: now, now: now) == "Looked just now — nothing to add.")
        #expect(TaskDetailView.silenceLine(judgedAt: nil) == "Looked — nothing to add.")
        let earlier = TaskDetailView.silenceLine(judgedAt: now.addingTimeInterval(-3 * 3600), now: now)
        #expect(
            earlier.hasPrefix("Looked ") && earlier.hasSuffix("— nothing to add.")
                && !earlier.contains("just now"))
    }
}

@MainActor
@Suite("F-10 · repeated dismissals of one move reach the prompt")
struct AdvisorPreferenceTests {

    @Test("Two declines of one move is a preference; one is a mood; nothing is never one")
    func threshold() {
        #expect(Learned.advisorPreferences(declined: ["createSteps": 1]).isEmpty)
        let lines = Learned.advisorPreferences(declined: ["createSteps": 2, "nothing": 9])
        #expect(lines.count == 1)
        #expect(lines[0].contains("declined 2 step breakdowns"))
    }

    @Test("The verdict store counts declined moves inside the window only")
    func counts() {
        let store = HumanVerdictStore(fileURL: nil)
        let now = Date()
        for i in 0..<3 {
            store.record(
                HumanVerdict(
                    subject: .reading(taskID: UUID(), fingerprint: i), verdict: .declined, at: now,
                    move: "createSteps"))
        }
        store.record(
            HumanVerdict(
                subject: .reading(taskID: UUID(), fingerprint: 99), verdict: .declined,
                at: now.addingTimeInterval(-40 * 86_400), move: "decide"))
        let counts = store.declinedMoveCounts(within: 30, now: now)
        #expect(counts["createSteps"] == 3)
        #expect(counts["decide"] == nil)
    }

    @Test("The preference rides the prompt as an INTERNAL line, and is excluded from the fingerprint")
    func promptLine() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "Plan the birthday dinner", in: context)
        var facts = TaskAdvisorFacts.make(task: task, among: [task])
        let before = facts.fingerprint
        facts.advisorPreferences = Learned.advisorPreferences(declined: ["createSteps": 2])
        #expect(facts.promptBlock.contains("INTERNAL: the person has declined 2 step breakdowns"))
        #expect(facts.fingerprint == before)
        #expect(!facts.userVisibleEvidence.joined().contains("declined"))
    }
}

@MainActor
@Suite("F-11 · the day answer")
struct DayAnswerTests {

    @Test("'What deserves me today?' is answered from rank, blocked sunk, capped, as rows")
    func dayAnswer() {
        let facts = HouseholdChatEval.fixture()
        let answer = HouseholdChatFloor.answer(question: "What deserves me today?", facts: facts)
        #expect(answer != nil)
        #expect(answer?.citedTaskIDs.isEmpty == false)
        #expect((answer?.citedTaskIDs.count ?? 99) <= HouseholdChatFacts.dayAnswerCap)
        let blocked = Set(facts.blocked.map(\.id))
        #expect(answer?.citedTaskIDs.allSatisfy { !blocked.contains($0) } == true)
        #expect(HouseholdChatFloor.shape(of: "what should I focus on", facts: facts) == .today)
        #expect(HouseholdChatFloor.shape(of: "Where do I start?", facts: facts) == .today)
        // Other reasoning questions still go to the model.
        #expect(HouseholdChatFloor.shape(of: "Why is the passport stuck?", facts: facts) == nil)
    }

    @Test("The orientation question leads the starter chips whenever anything is open")
    func starterLeads() {
        let facts = HouseholdChatEval.fixture()
        #expect(HouseholdChatPrompt.starterQuestions(for: facts).first == "What deserves me today?")
        let empty = HouseholdChatFacts(now: facts.now, members: facts.members, open: [], done: [])
        #expect(!HouseholdChatPrompt.starterQuestions(for: empty).contains("What deserves me today?"))
    }

    @Test("Rank order, when present, decides the day answer")
    func rankDecides() {
        var facts = HouseholdChatEval.fixture()
        let unblocked = facts.open.filter { !$0.isBlocked }
        guard unblocked.count >= 2 else { return }
        facts.rankOrder = [unblocked.last!.id, unblocked.first!.id]
        let answer = facts.dayAnswer(for: nil)
        #expect(answer.first?.id == unblocked.last!.id)
    }
}
