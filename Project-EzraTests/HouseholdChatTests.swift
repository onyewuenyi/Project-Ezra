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

    @Test("A name the roster does not hold makes the question not closed — the floor declines")
    func unknownNameDeclines() {
        // Sam is on this fixture's roster; Priya is not. The same closed question is
        // answered for one and handed to the model for the other, which is shown the
        // roster and can say who it knows.
        #expect(HouseholdChatFloor.answer(question: "What did Sam finish this week?", facts: facts) != nil)
        #expect(HouseholdChatFloor.answer(question: "What did Priya finish this week?", facts: facts) == nil)
        #expect(HouseholdChatFloor.answer(question: "What's overdue for Priya?", facts: facts) == nil)
        #expect(HouseholdChatFloor.answer(question: "What's on Priya's list?", facts: facts) == nil)
        // A category, a weekday, the first word and "I" are not unknown people.
        #expect(HouseholdChatFloor.answer(question: "What's overdue for Travel?", facts: facts) != nil)
        #expect(!HouseholdChatFloor.namesSomeoneUnknown("What's due for Friday?", facts: facts))
        #expect(!HouseholdChatFloor.namesSomeoneUnknown("Priya what's overdue?", facts: facts))
        #expect(!HouseholdChatFloor.namesSomeoneUnknown("What should I do first?", facts: facts))
        #expect(HouseholdChatFloor.answer(question: "Overdue for me?", facts: facts) != nil)
    }

    @Test("The blocked shape puts the person before the verb — the trailing scope attached to the wrong noun")
    func blockedScopeReadsRight() {
        let answer = HouseholdChatFloor.answer(
            question: "What's waiting on something for Sam?", facts: facts)!
        // "…waiting on something for Sam" read as a task waiting on a thing that is for
        // Sam; the scope now precedes the verb whatever the count.
        #expect(!answer.text.contains("something for Sam"))
        #expect(answer.text.contains(" for Sam is ") || answer.text.contains(" for Sam are "))
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
        // …and the chain behind her photos arrives right after her own three.
        #expect(mayas.prefix(5).map(\.title).contains("Renew the passport"))
    }

    @Test("The GA-transcript shapes: tomorrow, next week, in progress and a category answer exactly")
    func transcriptEarnedShapes() {
        let tomorrow = HouseholdChatFloor.answer(question: "What's due tomorrow?", facts: facts)!
        #expect(tomorrow.text == "1 task is due tomorrow.")
        #expect(tomorrow.citedTaskIDs.count == 1)
        // "tomorrow" beside "today" is the tomorrow question, never the today list.
        #expect(HouseholdChatFloor.shape(of: "what's due today or tomorrow", facts: facts) == .dueTomorrow)
        let nextWeek = HouseholdChatFloor.answer(question: "What's due next week?", facts: facts)!
        #expect(nextWeek.text.hasPrefix("2 tasks are due next week, 7 to 13 days out"))
        let started = HouseholdChatFloor.answer(question: "What have I started?", facts: facts)!
        #expect(started.text == "1 task is in progress for you.")
        #expect(HouseholdChatFloor.shape(of: "What should I have started by now?", facts: facts) == nil)
        // A category is a whole word from the household's own vocabulary; two is not closed.
        #expect(facts.category(named: "anything for the car?") == "Car")
        #expect(facts.category(named: "the carpet needs cleaning") == nil)
        #expect(facts.category(named: "car or travel?") == nil)
        let travel = HouseholdChatFloor.answer(question: "What's the travel stuff for Maya?", facts: facts)!
        #expect(travel.text == "1 task is in Travel for Maya.")
        // Precedence: every other shape wins over a category word.
        #expect(HouseholdChatFloor.shape(of: "what's overdue for work", facts: facts) == .overdue)
        // Finished work in any tense; the stalest by HUMAN touch, longest first, capped at five.
        #expect(HouseholdChatFloor.shape(of: "What did Maya finish?", facts: facts) == .done)
        #expect(HouseholdChatFloor.shape(of: "Have we completed anything?", facts: facts) == .done)
        let stale = HouseholdChatFloor.answer(
            question: "What's been sitting untouched the longest?", facts: facts)!
        #expect(stale.citedTaskIDs.count == HouseholdChatFacts.stalestCap)
        #expect(facts.open.first { $0.id == stale.citedTaskIDs[0] }?.title == "Clear out the garage")
        #expect(stale.text.hasSuffix("last touched 20 days ago."))
        var touched = facts.open[0]
        touched.humanTouchedAt = facts.now
        #expect(touched.touchedAt == facts.now)
        // The glance strip gains "in progress" only when something is started.
        #expect(HouseholdChatPrompt.summary(for: facts).map(\.label).contains("1 in progress"))
    }

    @Test("A blocked task brings its whole chain into the slice, both directions, within the cap")
    func retrievalCompletesChains() {
        // "flights" names one task; the chain behind it shares no word with the question.
        let slice = HouseholdChatRetrieval.slice(for: "Why are the flights held up?", facts: facts)
        let titles = slice.map(\.title)
        #expect(titles.first == "Book the flights for the trip")
        #expect(titles.prefix(3).contains("Renew the passport"))
        #expect(titles.prefix(3).contains("Get passport photos"))
        // Upstream from the leaf: the photos pull in the passport, and the flights behind it.
        let photos = HouseholdChatRetrieval.slice(for: "Why do the photos matter?", facts: facts)
        #expect(photos.prefix(3).map(\.title).contains("Book the flights for the trip"))
        // The cap holds even when every line is one chain.
        var chained: [HouseholdChatFacts.Line] = []
        for i in 0..<20 {
            chained.append(
                HouseholdChatFacts.Line(
                    id: UUID(), title: i == 19 ? "Ship the final report" : "Step \(i)", category: "Home",
                    status: .todo, ownerName: "You", ownerID: HouseholdChatEval.you, dueDate: nil,
                    daysUntilDue: nil, isUrgent: false, needsDecision: false,
                    blockerTitles: i == 0 ? [] : ["Step \(i - 1)"], externalWaits: [], effortMinutes: nil,
                    updatedAt: facts.now))
        }
        let long = HouseholdChatFacts(now: facts.now, members: facts.members, open: chained, done: [])
        let capped = HouseholdChatRetrieval.slice(for: "Why is the final report stuck?", facts: long)
        #expect(capped.count == HouseholdChatRetrieval.cap)
        #expect(capped.first?.title == "Ship the final report")
        #expect(Set(capped.map(\.id)).count == capped.count)
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

@Suite("Household chat — follow-ups, glance, rhythm")
struct HouseholdChatFollowUpTests {

    private let facts = HouseholdChatEval.fixture()

    @Test("Follow-ups are shaped by the answered question, never repeat, cap at two")
    func followUps() {
        let after = HouseholdChatPrompt.followUps(
            after: "What's overdue?", facts: facts, asked: ["What's overdue?"])
        #expect(after.count <= 2)
        #expect(after.first == "Which one should I do first?")
        #expect(!after.contains("What's overdue?"))
        // A named person's list invites that person's next move and waits.
        let maya = HouseholdChatPrompt.followUps(after: "What is Maya working on?", facts: facts, asked: [])
        #expect(maya == ["What should Maya do first?", "What is Maya waiting on?"])
        // Every model-bound chip carries a reasoning word; every floor chip is a floor question.
        for chip in after + maya {
            let shape = HouseholdChatFloor.shape(of: chip, facts: facts)
            #expect(shape != nil || InquiryFloor.isReasoning(chip), "\(chip) is neither floor nor model")
        }
        // After a model answer the chips are the floor's starters, minus what was asked.
        let model = HouseholdChatPrompt.followUps(
            after: "Why is the passport stuck?", facts: facts, asked: ["What's overdue?"])
        #expect(!model.isEmpty)
        #expect(!model.contains("What's overdue?"))
    }

    @Test("The glance lists only non-zero counts, in triage order, each a floor question")
    func summary() {
        let items = HouseholdChatPrompt.summary(for: facts)
        #expect(
            items.map(\.label) == [
                "2 overdue", "2 due today", "1 in progress", "3 waiting", "2 decisions", "14 open",
                "3 done this week",
            ])
        for item in items {
            #expect(
                HouseholdChatFloor.shape(of: item.question, facts: facts) != nil,
                "\(item.question) is not a floor question")
        }
        let quiet = HouseholdChatFacts(now: facts.now, members: facts.members, open: [], done: [])
        #expect(HouseholdChatPrompt.summary(for: quiet).map(\.label) == ["0 open"])
    }

    @Test("A divider precedes a new sitting, not every line")
    func rhythm() {
        let now = Date()
        let earlier = ChatMessage(role: .user, text: "a", sentAt: now.addingTimeInterval(-3 * 3600))
        let reply = ChatMessage(role: .advisor, text: "b", sentAt: now.addingTimeInterval(-3 * 3600 + 5))
        let later = ChatMessage(role: .user, text: "c", sentAt: now)
        #expect(ChatThreadRhythm.needsDivider(before: earlier, after: nil, now: now))
        #expect(!ChatThreadRhythm.needsDivider(before: reply, after: earlier, now: now))
        #expect(ChatThreadRhythm.needsDivider(before: later, after: reply, now: now))
        #expect(!ChatThreadRhythm.needsDivider(before: later, after: nil, now: now))
        #expect(ChatThreadRhythm.dividerLabel(for: now, now: now).hasPrefix("Today "))
        #expect(
            ChatThreadRhythm.dividerLabel(for: now.addingTimeInterval(-86_400), now: now).hasPrefix(
                "Yesterday "))
    }

    @Test("Stop leaves a STOPPED slot that retries in place")
    @MainActor
    func stopThenRetry() async {
        var calls = 0
        let store = HouseholdChatStore(
            responder: { _ in
                calls += 1
                if calls == 1 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                return .success("Answer.")
            }, isModelAvailable: { true })
        store.ask("Why is the passport stuck?", facts: facts)
        store.cancel(key: HouseholdInquiryScope.singletonKey)
        #expect(store.messages[1].state == .stopped)
        #expect(!store.isReplying)
        store.retry(replyID: store.messages[1].id, facts: facts)
        await store.awaitPendingReplies()
        #expect(store.messages[1].state == .sent)
        #expect(store.messages[1].text == "Answer.")
    }
}
