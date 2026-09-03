//
//  HouseholdChatTests.swift
//  Project-EzraTests
//
//  The Ask tab's contract: the facts snapshot, the deterministic floor (and its
//  refusals), retrieval, citations, the prompt, and the store's loop with an injected
//  responder. The labeled eval set is run HERE too — `HouseholdChatEval.failures()` is
//  pure, so a floor that widens or narrows fails CI before it fails a person.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Household chat — the labeled set")
struct HouseholdChatEvalTests {

    @Test("Every labeled floor and retrieval case holds")
    func labeledSetHolds() {
        let misses = HouseholdChatEval.failures()
        #expect(misses.isEmpty, "\(misses.joined(separator: "\n"))")
    }

    @Test("The grounding scorer is bracketed: a clean reply scores 0, an invented one is caught")
    func groundingBracket() {
        #expect(HouseholdChatEval.bracketHolds())
    }
}

@Suite("Household chat — floor, retrieval, citations, prompt")
struct HouseholdChatFloorTests {

    private let facts = HouseholdChatEval.fixture()

    @Test("A reasoning word sends a filter-shaped question to the model")
    func reasoningWordsDecline() {
        #expect(HouseholdChatFloor.shape(of: "What's overdue?", facts: facts) == .overdue)
        #expect(HouseholdChatFloor.shape(of: "Why is the insurance overdue?", facts: facts) == nil)
        #expect(HouseholdChatFloor.shape(of: "Should I do the overdue ones first?", facts: facts) == nil)
        #expect(HouseholdChatFloor.shape(of: "How do I clear what's overdue?", facts: facts) == nil)
    }

    @Test("A named person scopes the list, and 'me'/'my' means the person asking")
    func personScoping() {
        let maya = HouseholdChatFloor.answer(question: "what's due today for maya", facts: facts)!
        #expect(maya.citedTaskIDs.count == 1)
        #expect(maya.text.contains("for Maya"))
        let me = HouseholdChatFloor.answer(question: "what's due today for me", facts: facts)!
        #expect(me.citedTaskIDs.count == 1)
        #expect(me.text.contains("for you"))
        #expect(facts.member(named: "what has sam got")?.name == "Sam")
        #expect(facts.member(named: "what's on the list")?.name == nil)
    }

    @Test("Empty results are honest sentences, never empty lines")
    func emptyResults() {
        let answer = HouseholdChatFloor.answer(question: "What's overdue for Sam?", facts: facts)!
        #expect(answer.text == "Nothing is overdue for Sam.")
        #expect(answer.citedTaskIDs.isEmpty)
    }

    @Test("Lists cap at the list ceiling and say so")
    func listCap() {
        var lines = facts.open
        for i in 0..<20 {
            lines.append(
                HouseholdChatFacts.Line(
                    id: UUID(), title: "Extra \(i)", category: "Home", status: .todo, ownerName: "You",
                    ownerID: HouseholdChatEval.you, dueDate: nil, daysUntilDue: -1, isUrgent: false,
                    needsDecision: false, blockerTitles: [], externalWaits: [], effortMinutes: nil,
                    updatedAt: facts.now))
        }
        let big = HouseholdChatFacts(now: facts.now, members: facts.members, open: lines, done: [])
        let answer = HouseholdChatFloor.answer(question: "What's overdue?", facts: big)!
        #expect(answer.citedTaskIDs.count == HouseholdChatFacts.listCap)
        #expect(answer.text.contains("Showing the nearest \(HouseholdChatFacts.listCap)"))
    }

    @Test("Who-most names the leader and the rest, and never invents a comparison verdict")
    func whoMost() {
        let answer = HouseholdChatFloor.answer(question: "Who has the most on their plate?", facts: facts)!
        #expect(answer.text.hasPrefix("You have the most — 7 open"))
        #expect(answer.text.contains("Maya 3"))
        #expect(answer.text.contains("Sam 3"))
        #expect(answer.citedTaskIDs.isEmpty)
    }

    @Test("Retrieval is capped and puts the named person's and the matched titles first")
    func retrieval() {
        let slice = HouseholdChatRetrieval.slice(for: "Why is the passport stuck?", facts: facts)
        #expect(slice.count <= HouseholdChatRetrieval.cap)
        #expect(slice.prefix(2).map(\.title).contains("Renew the passport"))
        #expect(slice.prefix(3).map(\.title).contains("Get passport photos"))
        let mayas = HouseholdChatRetrieval.slice(for: "What should Maya do first?", facts: facts)
        #expect(Set(mayas.prefix(3).map(\.ownerName)) == ["Maya"])
    }

    @Test("Citations are verified titles only — a reply that names nothing cites nothing")
    func citations() {
        let slice = HouseholdChatRetrieval.slice(for: "passport", facts: facts)
        let cited = HouseholdChatCitations.cited(
            in: "Renew the passport is waiting on the photos.", among: slice)
        #expect(cited.count == 1)
        #expect(HouseholdChatCitations.cited(in: "Nothing to add.", among: slice).isEmpty)
        // The title's words in order, closely spaced, count as naming it.
        let loose = HouseholdChatCitations.cited(
            in: "Get the passport photos done first.", among: slice)
        #expect(loose.contains { id in slice.first { $0.id == id }?.title == "Get passport photos" })
    }

    @Test("The stable block carries the roster, loads and totals; the slice never enters it")
    func stableBlock() {
        let block = facts.stableBlock
        #expect(block.hasPrefix("HOUSEHOLD:\nTODAY:"))
        #expect(block.contains("PERSON: You — 7 open, 2 overdue, 2 waiting"))
        #expect(block.contains("PERSON: Maya — 3 open"))
        #expect(
            block.contains(
                "TOTALS: 14 open, 2 overdue, 2 due today, 3 waiting on something, 2 needing a decision, 3 finished this week"
            ))
        #expect(block.contains("UNOWNED: 1"))
        #expect(!block.contains("Renew the passport"))
    }

    @Test("Instructions are rules then the stable block; a turn is the slice then the question")
    func promptShape() {
        let instructions = HouseholdChatPrompt.instructions(for: facts)
        #expect(instructions.hasPrefix(HouseholdChatPrompt.rules))
        #expect(instructions.hasSuffix(facts.stableBlock))
        let rules = HouseholdChatPrompt.rules
        #expect(rules.contains("Counts come from the HOUSEHOLD block"))
        #expect(rules.contains("You cannot act"))
        #expect(rules.contains("use its exact title from the list"))
        #expect(rules.contains("comparisons of who is doing better"))
        let slice = HouseholdChatRetrieval.slice(for: "passport", facts: facts)
        let turn = HouseholdChatPrompt.turnPrompt(question: " Why? ", slice: slice, continuity: nil)
        #expect(turn.hasPrefix("RELEVANT TASKS:\n- "))
        #expect(turn.hasSuffix("QUESTION: Why?"))
        #expect(
            turn.contains(
                "Renew the passport · owner: You · due in 9 days · waiting on: Get passport photos · ~60 min")
        )
        let empty = HouseholdChatPrompt.turnPrompt(
            question: "x", slice: [], continuity: "They asked: A\nYou said: B")
        #expect(empty.hasPrefix("EARLIER IN THIS CONVERSATION"))
        #expect(empty.contains("RELEVANT TASKS: none match this question."))
    }

    @Test("Starter questions are floor questions shaped to the household")
    func starters() {
        let questions = HouseholdChatPrompt.starterQuestions(for: facts)
        #expect(questions.count == 3)
        for question in questions {
            #expect(
                HouseholdChatFloor.shape(of: question, facts: facts) != nil,
                "\(question) is not a floor question")
        }
        let solo = HouseholdChatFacts(now: facts.now, members: [facts.members[0]], open: [], done: [])
        #expect(!HouseholdChatPrompt.starterQuestions(for: solo).contains("Who has the most on their plate?"))
    }

    @Test("Facts are built from the live store with owners resolved and 'You' for the asker")
    func factsFromStore() {
        let context = TestStore.makeContext()
        let me = FamilyMember(name: "Charles", in: context)
        let maya = FamilyMember(name: "Maya", in: context)
        _ = TaskItem(
            title: "Mine", status: .todo, dueDate: Date().addingTimeInterval(-2 * 86_400), ownerID: me.uuid,
            in: context)
        _ = TaskItem(title: "Hers", status: .todo, ownerID: maya.uuid, in: context)
        let finished = TaskItem(title: "Finished", status: .todo, ownerID: me.uuid, in: context)
        finished.complete(now: Date())
        let tasks = [TaskItem](try! context.fetch(NSFetchRequest<TaskItem>(entityName: "TaskItem")))
        let facts = HouseholdChatFacts.make(tasks: tasks, members: [me, maya], currentUserID: me.uuid)
        #expect(facts.members.first?.name == "You")
        #expect(facts.open.count == 2)
        #expect(facts.open.first { $0.title == "Mine" }?.ownerName == "You")
        #expect(facts.open.first { $0.title == "Hers" }?.ownerName == "Maya")
        #expect(facts.overdue.map(\.title) == ["Mine"])
        #expect(facts.done.map(\.title) == ["Finished"])
    }
}

@MainActor
@Suite("Household chat — the store")
struct HouseholdChatStoreTests {

    private let facts = HouseholdChatEval.fixture()

    private func store(
        available: Bool = true, responder: @escaping HouseholdChatStore.Responder
    ) -> HouseholdChatStore {
        HouseholdChatStore(responder: responder, isModelAvailable: { available })
    }

    @Test("A closed question is answered by the floor synchronously, cited, with no model call")
    func floorAnswersInstantly() {
        var calls = 0
        let store = store { _ in
            calls += 1
            return .success("x")
        }
        store.ask("What's overdue?", facts: facts)
        #expect(store.messages.count == 2)
        #expect(store.messages[1].state == .sent)
        #expect(store.messages[1].citedTaskIDs.count == 2)
        #expect(store.lastRoute == .floor)
        #expect(!store.isReplying)
        #expect(calls == 0)
    }

    @Test("An open question goes to the model with the slice, and the reply lands cited")
    func modelAnswers() async {
        var seen: HouseholdChatTurn?
        let store = store { turn in
            seen = turn
            return .success("Renew the passport is waiting on Get passport photos.")
        }
        store.ask("Why is the passport stuck?", facts: facts)
        #expect(store.messages[1].state == .pending)
        #expect(store.lastRoute == .model)
        await store.awaitPendingReplies()
        #expect(store.messages[1].state == .sent)
        #expect(store.messages[1].citedTaskIDs.count == 2)
        #expect(seen?.slice.count ?? 0 <= HouseholdChatRetrieval.cap)
        #expect(seen?.slice.map(\.title).contains("Renew the passport") == true)
        #expect(seen?.continuity == nil)
    }

    @Test("A failed reply retries in place; no model → an honest non-retryable slot")
    func failRetryUnavailable() async {
        var calls = 0
        let flaky = store { _ in
            calls += 1
            return calls == 1 ? .failed("x") : .success("Fine.")
        }
        flaky.ask("Why is the passport stuck?", facts: facts)
        await flaky.awaitPendingReplies()
        #expect(flaky.messages[1].state == .failed(retryable: true))
        flaky.retry(replyID: flaky.messages[1].id, facts: facts)
        await flaky.awaitPendingReplies()
        #expect(flaky.messages.count == 2)
        #expect(flaky.messages[1].text == "Fine.")

        let off = store(available: false) { _ in .success("x") }
        off.ask("Why is the passport stuck?", facts: facts)
        await off.awaitPendingReplies()
        #expect(off.messages[1].state == .failed(retryable: false))
    }

    @Test("A changed household carries the continuity digest into the next model turn")
    func continuity() async {
        var seen: [HouseholdChatTurn] = []
        let store = store { turn in
            seen.append(turn)
            return .success("Answer.")
        }
        store.ask("Why is the passport stuck?", facts: facts)
        await store.awaitPendingReplies()
        var open = facts.open
        open.removeLast()  // the household changed: the garage task is gone
        let changed = HouseholdChatFacts(now: facts.now, members: facts.members, open: open, done: facts.done)
        store.ask("And the flights?", facts: changed)
        await store.awaitPendingReplies()
        #expect(seen.count == 2)
        #expect(seen[1].continuity == "They asked: Why is the passport stuck?\nYou said: Answer.")
    }

    @Test("Clear forgets everything")
    func clear() {
        let store = store { _ in .success("x") }
        store.ask("What's overdue?", facts: facts)
        store.clear()
        #expect(store.messages.isEmpty)
        #expect(store.lastRoute == nil)
    }
}

@Suite("Household chat — stays on the device")
struct HouseholdChatPrivacyTests {

    @Test("The household chat never references the cloud seam — structurally")
    func noCloudReference() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        for file in [
            "AI/HouseholdChat.swift", "AI/Inquiry.swift",
            "Features/Chat/HouseholdChatView.swift", "Features/Chat/ChatComponents.swift",
        ] {
            let content = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(
                !content.contains("CloudModel.") && !content.contains("GeminiProvider")
                    && !content.contains("FirebaseAI"),
                "\(file) touches the cloud seam — the Ask tab's on-device guarantee is broken")
        }
    }
}
