//
//  TaskAdvisorChatTests.swift
//  Project-EzraTests
//
//  The Advisor chat's contract, with the model replaced by an injected responder — the
//  `TaskAdvisorStore` pattern, because `ModelRun` is inert under XCTest and the loop
//  (ask → pending → answered · fail → retry · facts move → continuity) is product
//  behaviour that must not depend on a device to be checked. The prompt is pinned the
//  way the reading's instructions are: the honesty rules are the feature.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

// MARK: - The prompt (pure)

@Suite("Advisor chat — the prompt")
struct TaskAdvisorChatPromptTests {

    private func facts(_ title: String = "Renew the car insurance") -> TaskAdvisorFacts {
        TaskAdvisorFacts.make(
            task: TaskItem(title: title, status: .todo, in: TestStore.makeContext()), among: [])
    }

    @Test("Instructions lead with the rules and end with the FACTS block")
    func instructionsShape() {
        let text = TaskAdvisorChatPrompt.instructions(for: facts())
        #expect(text.hasPrefix(TaskAdvisorChatPrompt.rules))
        #expect(text.contains("FACTS:\nTASK: Renew the car insurance"))
        // The facts come LAST — the stable block is the warm prefix.
        let rulesEnd = text.range(of: "FACTS:")!.lowerBound
        #expect(text[..<rulesEnd].contains("Hard rules:"))
    }

    @Test("The honesty rules are stated: no invention, no acting, general knowledge labelled")
    func honestyRules() {
        let rules = TaskAdvisorChatPrompt.rules
        #expect(rules.contains("Never\n  invent a blocker") || rules.contains("Never invent a blocker"))
        #expect(rules.contains("You cannot act"))
        #expect(rules.contains("never say you did or will"))
        #expect(rules.contains("General knowledge is allowed"))
        #expect(rules.contains("never present a guess about THEIR specifics as a fact"))
        #expect(rules.contains("no exclamation marks, no emoji"))
        #expect(rules.contains("you only know this task"))
        #expect(rules.contains("INTERNAL lines are context for you alone"))
    }

    @Test("A turn on an unbroken thread is the bare question")
    func plainTurn() {
        #expect(
            TaskAdvisorChatPrompt.turnPrompt(question: "  What's first?  ", continuity: nil)
                == "QUESTION: What's first?")
        #expect(
            TaskAdvisorChatPrompt.turnPrompt(question: "What's first?", continuity: "")
                == "QUESTION: What's first?")
    }

    @Test("A turn after the facts moved leads with the continuity digest")
    func continuityTurn() {
        let prompt = TaskAdvisorChatPrompt.turnPrompt(
            question: "And now?", continuity: "They asked: A\nYou said: B")
        #expect(prompt.hasPrefix("EARLIER IN THIS CONVERSATION"))
        #expect(prompt.contains("They asked: A\nYou said: B"))
        #expect(prompt.hasSuffix("QUESTION: And now?"))
    }

    @Test("The continuity digest carries the last two ANSWERED exchanges only")
    func digest() {
        let messages: [TaskAdvisorChatMessage] = [
            .init(role: .user, text: "Q1"), .init(role: .advisor, text: "A1"),
            .init(role: .user, text: "Q2"), .init(role: .advisor, text: "A2"),
            .init(role: .user, text: "Q3"), .init(role: .advisor, text: "", state: .failed(retryable: true)),
            .init(role: .user, text: "Q4"), .init(role: .advisor, text: "A4"),
            .init(role: .user, text: "Q5"), .init(role: .advisor, text: "", state: .pending),
        ]
        let digest = TaskAdvisorChatPrompt.continuityDigest(messages)
        #expect(digest == "They asked: Q2\nYou said: A2\nThey asked: Q4\nYou said: A4")
        // A failed or pending reply said nothing, so its question is not carried either.
        #expect(digest?.contains("Q3") == false)
        #expect(digest?.contains("Q5") == false)
        #expect(TaskAdvisorChatPrompt.continuityDigest([]) == nil)
        #expect(TaskAdvisorChatPrompt.continuityDigest([.init(role: .user, text: "Q")]) == nil)
    }

    @Test("A reply is trimmed, blank-line-collapsed and sentence-clamped; empty is nil")
    func replyValidation() {
        #expect(TaskAdvisorChatPrompt.validatedReply("   \n ") == nil)
        #expect(
            TaskAdvisorChatPrompt.validatedReply("  Start with the policy number.  ")
                == "Start with the policy number.")
        let five =
            "First sentence here. Second sentence here. Third sentence here. Fourth sentence here. Fifth sentence here."
        let clamped = TaskAdvisorChatPrompt.validatedReply(five)!
        #expect(clamped.hasSuffix("Fourth sentence here."))
        #expect(!clamped.contains("Fifth"))
        // A list keeps its line breaks and is clamped by LINE — the sentence clamp
        // would fold the steps into one line.
        let list = "Roughly:\n1. Find the letter.\n\n2. Call them.\n3. Compare.\n4. Switch.\n5. Cancel.\n6. Done.\n7. Extra."
        let clampedList = TaskAdvisorChatPrompt.validatedReply(list)!
        #expect(clampedList.hasPrefix("Roughly:\n1. Find the letter.\n2. Call them."))
        #expect(clampedList.components(separatedBy: "\n").count == TaskAdvisorChatPrompt.maxLines)
        #expect(!clampedList.contains("Extra"))
    }

    @Test("Starter questions follow the task's shape, three at most, never an invitation to invent")
    func starters() {
        let context = TestStore.makeContext()
        let plain = TaskItem(title: "Call the dentist", status: .todo, in: context)
        let plainQuestions = TaskAdvisorChatPrompt.starterQuestions(
            for: TaskAdvisorFacts.make(task: plain, among: [plain]))
        #expect(plainQuestions.count == 3)
        #expect(plainQuestions.first == "What's the first step?")
        #expect(plainQuestions.last == "What am I missing?")

        let blocker = TaskItem(title: "Get the quote", status: .todo, in: context)
        let waiting = TaskItem(
            title: "Book the builder", status: .todo, blockedBy: [blocker.uuid!], in: context)
        let waitingQuestions = TaskAdvisorChatPrompt.starterQuestions(
            for: TaskAdvisorFacts.make(task: waiting, among: [blocker, waiting]))
        #expect(waitingQuestions.first == "What's actually in the way?")

        let deciding = TaskItem(
            title: "Pick a school", status: .todo, needsDecision: true, in: context)
        let decidingQuestions = TaskAdvisorChatPrompt.starterQuestions(
            for: TaskAdvisorFacts.make(task: deciding, among: [deciding]))
        #expect(decidingQuestions.first == "What should I weigh here?")

        for question in plainQuestions + waitingQuestions + decidingQuestions {
            #expect(!question.lowercased().contains("what happens if"))
        }
    }
}

// MARK: - The store (the loop, with an injected responder)

@MainActor
@Suite("Advisor chat — the store")
struct TaskAdvisorChatStoreTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func store(
        available: Bool = true,
        responder: @escaping TaskAdvisorChatStore.Responder
    ) -> TaskAdvisorChatStore {
        TaskAdvisorChatStore(responder: responder, isModelAvailable: { available })
    }

    @Test("Ask appends the question and a pending reply, then the validated answer lands")
    func askAnswers() async {
        let context = context()
        let task = TaskItem(title: "Renew the car insurance", status: .todo, in: context)
        var seen: [TaskAdvisorChatTurn] = []
        let store = store { turn in
            seen.append(turn)
            return .success("  Start with the policy number. It's on the last renewal letter.  ")
        }

        store.ask("What's first?", task: task, among: [task])
        let pending = store.messages(for: task.uuid)
        #expect(pending.count == 2)
        #expect(pending[0].role == .user && pending[0].text == "What's first?")
        #expect(pending[1].role == .advisor && pending[1].state == .pending)
        #expect(store.isReplying(for: task.uuid))

        await store.awaitPendingReplies(for: task.uuid)
        let answered = store.messages(for: task.uuid)
        #expect(answered[1].state == .sent)
        #expect(answered[1].text == "Start with the policy number. It's on the last renewal letter.")
        #expect(!store.isReplying(for: task.uuid))
        #expect(seen.count == 1)
        #expect(seen[0].question == "What's first?")
        #expect(seen[0].continuity == nil)
        #expect(seen[0].facts.title == "Renew the car insurance")
    }

    @Test("An empty question is ignored, not sent")
    func emptyIgnored() {
        let task = TaskItem(title: "Anything", status: .todo, in: context())
        var calls = 0
        let store = store { _ in
            calls += 1
            return .success("x")
        }
        store.ask("   ", task: task, among: [task])
        #expect(store.messages(for: task.uuid).isEmpty)
        #expect(calls == 0)
    }

    @Test("A failed reply is a retryable slot; retry re-asks the same question in place")
    func failThenRetry() async {
        let task = TaskItem(title: "Anything", status: .todo, in: context())
        var calls = 0
        let store = store { _ in
            calls += 1
            return calls == 1 ? .failed("guardrailViolation") : .success("Now it worked.")
        }
        store.ask("Why?", task: task, among: [task])
        await store.awaitPendingReplies(for: task.uuid)
        let failed = store.messages(for: task.uuid)
        #expect(failed[1].state == .failed(retryable: true))

        store.retry(replyID: failed[1].id, task: task, among: [task])
        #expect(store.messages(for: task.uuid)[1].state == .pending)
        await store.awaitPendingReplies(for: task.uuid)
        let retried = store.messages(for: task.uuid)
        #expect(retried.count == 2)  // in place — no duplicate question
        #expect(retried[1].id == failed[1].id)
        #expect(retried[1].state == .sent && retried[1].text == "Now it worked.")
    }

    @Test("A reply that validates to nothing is a failure, never an empty line")
    func emptyReplyFails() async {
        let task = TaskItem(title: "Anything", status: .todo, in: context())
        let store = store { _ in .success("   ") }
        store.ask("Why?", task: task, among: [task])
        await store.awaitPendingReplies(for: task.uuid)
        #expect(store.messages(for: task.uuid)[1].state == .failed(retryable: true))
    }

    @Test("No model → an honest, non-retryable slot, and the responder is never asked")
    func unavailable() async {
        let task = TaskItem(title: "Anything", status: .todo, in: context())
        var calls = 0
        let store = store(available: false) { _ in
            calls += 1
            return .success("x")
        }
        store.ask("Why?", task: task, among: [task])
        await store.awaitPendingReplies(for: task.uuid)
        #expect(store.messages(for: task.uuid)[1].state == .failed(retryable: false))
        #expect(calls == 0)
    }

    @Test("Two quick asks never overlap on the session, and answer in order")
    func serial() async {
        let task = TaskItem(title: "Anything", status: .todo, in: context())
        var active = 0
        var peak = 0
        let store = store { turn in
            active += 1
            peak = max(peak, active)
            try? await Task.sleep(nanoseconds: 30_000_000)
            active -= 1
            return .success("Answer to \(turn.question)")
        }
        store.ask("One", task: task, among: [task])
        store.ask("Two", task: task, among: [task])
        await store.awaitPendingReplies(for: task.uuid)
        let messages = store.messages(for: task.uuid)
        #expect(peak == 1)
        #expect(messages.map(\.text) == ["One", "Answer to One", "Two", "Answer to Two"])
    }

    @Test("When the facts move between questions, the next turn carries the continuity digest")
    func factsMoveCarryContinuity() async {
        let context = context()
        let task = TaskItem(title: "Renew the car insurance", status: .todo, in: context)
        var seen: [TaskAdvisorChatTurn] = []
        let store = store { turn in
            seen.append(turn)
            return .success("Answer.")
        }
        store.ask("First?", task: task, among: [task])
        await store.awaitPendingReplies(for: task.uuid)
        // Same facts → same thread, no digest.
        store.ask("Then?", task: task, among: [task])
        await store.awaitPendingReplies(for: task.uuid)
        #expect(seen[1].continuity == nil)

        // The person edits the task (title is in the fingerprint).
        task.title = "Renew the car insurance — Aviva"
        store.ask("And now?", task: task, among: [task])
        await store.awaitPendingReplies(for: task.uuid)
        #expect(seen.count == 3)
        #expect(seen[2].facts.title == "Renew the car insurance — Aviva")
        #expect(
            seen[2].continuity
                == "They asked: First?\nYou said: Answer.\nThey asked: Then?\nYou said: Answer.")

        // Settled on the new facts: the next ask is an unbroken thread again.
        store.ask("Sure?", task: task, among: [task])
        await store.awaitPendingReplies(for: task.uuid)
        #expect(seen[3].continuity == nil)
    }

    @Test("Stop turns every pending slot into a STOPPED slot and keeps the question")
    func cancel() async {
        let task = TaskItem(title: "Anything", status: .todo, in: context())
        let store = store { _ in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return .success("Too late.")
        }
        store.ask("Why?", task: task, among: [task])
        store.cancel(taskID: task.uuid)
        let messages = store.messages(for: task.uuid)
        #expect(messages.count == 2)
        #expect(messages[0].text == "Why?")
        #expect(messages[1].state == .stopped)
        #expect(!store.isReplying(for: task.uuid))
    }

    @Test("Clear forgets the conversation")
    func clear() async {
        let task = TaskItem(title: "Anything", status: .todo, in: context())
        let store = store { _ in .success("Answer.") }
        store.ask("Why?", task: task, among: [task])
        await store.awaitPendingReplies(for: task.uuid)
        store.clear(taskID: task.uuid)
        #expect(store.messages(for: task.uuid).isEmpty)
    }

    @Test("Conversations are per task")
    func perTask() async {
        let context = context()
        let a = TaskItem(title: "A", status: .todo, in: context)
        let b = TaskItem(title: "B", status: .todo, in: context)
        let store = store { turn in .success("About \(turn.facts.title).") }
        store.ask("?", task: a, among: [a, b])
        await store.awaitPendingReplies(for: a.uuid)
        #expect(store.messages(for: a.uuid).count == 2)
        #expect(store.messages(for: b.uuid).isEmpty)
    }
}

// MARK: - Structural privacy

@Suite("Advisor chat — stays on the device")
struct TaskAdvisorChatPrivacyTests {

    @Test("The chat never references the cloud seam — structurally")
    func noCloudReference() throws {
        // The same grep-pin Private Capture carries: prose may NAME the cloud, code
        // may not touch it. A question asked inside a task must have exactly one
        // answer to "where did that go?" — nowhere.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        for file in [
            "AI/TaskAdvisorChat.swift", "AI/Inquiry.swift",
            "Features/Advisor/TaskAdvisorChatView.swift",
        ] {
            let content = try String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(
                !content.contains("CloudModel.") && !content.contains("GeminiProvider")
                    && !content.contains("FirebaseAI"),
                "\(file) touches the cloud seam — the chat's on-device guarantee is broken")
        }
    }

    @Test("The chat is its own workload and its own metrics feature")
    func ownCounters() {
        #expect(IntelligenceWorkload.allCases.contains(.chat))
        #expect(ModelFeature.advisorChat.label == "chat")
    }
}

@Suite("Advisor chat — follow-ups")
struct TaskAdvisorChatFollowUpTests {
    @Test("Follow-ups are the unasked starters, at most two")
    func followUps() {
        let context = TestStore.makeContext()
        let task = TaskItem(title: "Call the dentist", status: .todo, in: context)
        let facts = TaskAdvisorFacts.make(task: task, among: [task])
        let starters = TaskAdvisorChatPrompt.starterQuestions(for: facts)
        let chips = TaskAdvisorChatPrompt.followUps(for: facts, asked: [starters[0]])
        #expect(chips == Array(starters.dropFirst().prefix(2)))
        #expect(TaskAdvisorChatPrompt.followUps(for: facts, asked: starters).isEmpty)
    }
}

// MARK: - The two surfaces render the same answer

@Suite("Chat surfaces — an answer's citations reach the screen")
struct ChatCitationParityTests {

    @Test("Both chat surfaces hand their answers' citations to the line — structurally")
    func citationsReachBothSurfaces() throws {
        // The bug this pins shipped INERT: `ChatAdvisorLine.citedTasks` is an unset
        // DEFAULT parameter, so the task chat built every answer without it — the floor
        // cited `blockerIDs`/`childIDs`, `InquiryCitations` resolved the model's, and
        // none of it ever drew a row. The household chat did it correctly, and both read
        // from the one component whose header promises "the answer is the navigation".
        //
        // A capability threaded through a call chain has to be asserted at the POINT OF
        // USE: nothing downstream can tell an empty package from an absent one, which is
        // why every test stayed green while the feature was missing on half its surfaces.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        for file in [
            "Features/Advisor/TaskAdvisorChatView.swift", "Features/Chat/HouseholdChatView.swift",
        ] {
            let content = try String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(
                content.contains("citedTasks: cited"),
                "\(file) builds a ChatAdvisorLine without its answer's citations")
            #expect(
                content.contains("gestures: ChatRowGestures("),
                "\(file) renders cited rows without the list's two swipes")
        }
        // The reading-opener `AdvisorView` in the task chat has its own citation path
        // (`citedTasks: peers`, where `peers` is `readingCitedTasks` captured at render-time).
        // Removing it would not be caught by the message-level check above, because the
        // message-level `ChatAdvisorLine` still passes `citedTasks: cited` independently.
        let taskChatContent = try String(
            contentsOf: root.appendingPathComponent("Features/Advisor/TaskAdvisorChatView.swift"),
            encoding: .utf8)
        #expect(
            taskChatContent.contains("citedTasks: peers"),
            "TaskAdvisorChatView's AdvisorView opener is missing its citedTasks — the 'frees up' navigation rows won't render"
        )
    }
}

