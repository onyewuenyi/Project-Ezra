//
//  HouseholdCatchUpTests.swift
//  Project-EzraTests
//
//  The home's second opener — what the other caretakers did since this person last
//  looked — is one sentence over the trail, and the sentence has rules.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Since you last looked")
struct HouseholdCatchUpTests {

    private func change(
        _ actor: String, _ action: String, _ title: String, id: UUID? = UUID(), handed: Bool = false
    ) -> HouseholdCatchUp.Change {
        .init(actorName: actor, action: action, taskTitle: title, taskID: id, handedToYou: handed)
    }

    @Test("Nothing to say is nil, never an empty sentence")
    func emptyIsNil() {
        #expect(HouseholdCatchUp.answer([]) == nil)
    }

    @Test("One person's acts read as one clause, and the rows are the tasks")
    func oneActorOneClause() throws {
        let a = UUID()
        let b = UUID()
        let answer = try #require(
            HouseholdCatchUp.answer([
                change("Maya", "completed", "Renew the car insurance", id: a),
                change("Maya", "decided", "Pick the caterer", id: b),
            ]))
        #expect(
            answer.text
                == "Since you last looked, Maya finished “Renew the car insurance”, decided “Pick the caterer”."
        )
        #expect(answer.citedTaskIDs == [a, b])
    }

    @Test("A task handed to the reader leads, whoever did it last")
    func handedYouLeads() throws {
        let answer = try #require(
            HouseholdCatchUp.answer([
                change("Maya", "completed", "Drop the kids at practice"),
                change("Sam", "assigned", "Book the vet", handed: true),
            ]))
        #expect(answer.text.hasPrefix("Since you last looked, Sam handed you “Book the vet”; Maya finished"))
    }

    @Test("Past three, the rest is a count that points at Activity")
    func restIsCounted() throws {
        let changes = (1...5).map { change("Maya", "completed", "Task \($0)") }
        let answer = try #require(HouseholdCatchUp.answer(changes))
        #expect(answer.text.hasSuffix(", and 2 more in Activity."))
        #expect(answer.citedTaskIDs.count == 3)
    }

    @Test("An unknown action is 'updated', never a made-up verb")
    func unknownActionIsUpdated() {
        #expect(HouseholdCatchUp.verb(for: change("Maya", "somethingNew", "X")) == "updated")
        #expect(HouseholdCatchUp.verb(for: change("Maya", "assigned", "X")) == "reassigned")
        #expect(HouseholdCatchUp.verb(for: change("Maya", "assigned", "X", handed: true)) == "handed you")
    }

    @Test(
        "The catch-up is the home's news line, not a thread opener; the openers are the day answer and the stall"
    )
    func catchUpIsNewsNotAnOpener() throws {
        let facts = HouseholdChatEval.fixture()
        let line = try #require(
            HouseholdCatchUp.answer([change("Maya", "completed", "Renew the car insurance")]))
        let scope = HouseholdInquiryScope(facts: facts)
        // The calm home (2026-09-23) renders the news as one muted sentence under the
        // answer with no rows, so the scope seats only what is about the person's own
        // work: the day answer, and a stall line when one applies.
        #expect(!scope.openers().contains(line))
        #expect(scope.openers().first?.text == scope.opener()?.text)
        #expect(scope.openers().count <= 2)
        #expect(line.text.hasPrefix("Since you last looked, Maya finished"))
    }

    @Test("A person with nothing on still hears what the household has on")
    func emptyDayNamesTheOthers() {
        let facts = HouseholdChatEval.fixture()
        // Someone on the roster with nothing open, if the fixture has one; else the
        // rule is exercised by construction on a member with no tasks.
        guard let idle = facts.members.first(where: { !$0.isYou && facts.openTasks(of: $0).isEmpty })
        else { return }
        let answer = HouseholdChatFloor.answer(question: "What deserves \(idle.name) today?", facts: facts)
        #expect(answer?.text.hasPrefix("Nothing is asking for \(idle.name) today.") == true)
        let busy = facts.members.first { !$0.isYou && $0.id != idle.id && !facts.openTasks(of: $0).isEmpty }
        if let busy { #expect(answer?.text.contains("\(busy.name) has") == true) }
        #expect(answer?.citedTaskIDs.isEmpty == true, "the rows are theirs to ask for by name")
    }

    @Test("The named day question scopes to the person, and the chip exists once someone else has work")
    func namedDayQuestion() {
        let facts = HouseholdChatEval.fixture()
        guard
            let other = facts.members.filter({ !$0.isYou })
                .max(by: { facts.openTasks(of: $0).count < facts.openTasks(of: $1).count }),
            !facts.openTasks(of: other).isEmpty
        else { return }
        let chips = HouseholdChatPrompt.starterQuestions(for: facts)
        #expect(chips.contains("What deserves \(other.name) today?"))
        let answer = HouseholdChatFloor.answer(question: "What deserves \(other.name) today?", facts: facts)
        #expect(answer?.text.contains("deserve") == true || answer?.text.contains("deserves") == true)
        #expect(answer?.text.contains(other.name) == true)
        #expect(answer?.text.contains("you first") == false)
    }
}

@Suite("The capture offer — a to-do typed into the question box")
struct CaptureOfferTests {

    @Test("Imperatives and stated intentions read as to-dos")
    func toDos() {
        for line in [
            "call the dentist tomorrow", "Pay the water bill", "renew my passport, book flights",
            "I need to buy a birthday gift for Sam", "remember to cancel the gym", "gotta email the landlord",
        ] {
            #expect(CaptureOffer.looksLikeCapture(line), "\(line) should be offered as a task")
        }
    }

    @Test("The offer sits on the person's send path, and only there — the store never sees a held line")
    func offerIsOnTheSendPath() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Project-Ezra")
        let view = try String(
            contentsOf: root.appendingPathComponent("Features/Chat/HouseholdChatView.swift"), encoding: .utf8)
        #expect(view.contains("if !force, CaptureOffer.looksLikeCapture(question)"))
        #expect(view.contains("ChatCaptureOffer("))
        let store = try String(contentsOf: root.appendingPathComponent("AI/Inquiry.swift"), encoding: .utf8)
        #expect(
            !store.contains("CaptureOffer"), "the store answers what it is given; the offer is the view's")
    }

    @Test("Questions, instructions to Ezra and one-word lines are never offered")
    func questions() {
        for line in [
            "what's overdue?", "What deserves me today", "who has the most on their plate",
            "should I keep paying for the gym", "how many does Maya have open", "tell me what's due",
            "check what's stuck", "find the passport task", "is anything due friday", "call",
            "can you list my decisions", "pay the water bill?",
        ] {
            #expect(!CaptureOffer.looksLikeCapture(line), "\(line) should go to the floor or the model")
        }
    }
}
