//
//  CaptureJudgeTests.swift
//  Project-EzraTests
//
//  The capture judge's deterministic half (`CaptureJudge`): which pieces reach the model,
//  what each verdict is ALLOWED to do, and that every failure keeps the person's words.
//  The model is injected, so these run with none.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Capture judge — the model's verdict, the app's decision")
struct CaptureJudgeTests {

    // MARK: - The screen

    @Test("A piece that opens on an action and shows no second outcome never reaches the model")
    func plainTasksSkipTheModel() {
        #expect(!CaptureJudge.needsJudgment("pay the water bill"))
        #expect(!CaptureJudge.needsJudgment("please renew the car registration"))
        #expect(CaptureJudge.needsJudgment("Dear parents, thank you for a great start to the term"))
        #expect(
            CaptureJudge.needsJudgment("wash the soccer uniform before saturday and refill the prescription"))
    }

    @Test("Three words or fewer is a list item, never judged")
    func shortPiecesAreNeverJudged() {
        #expect(!CaptureJudge.needsJudgment("milk"))
        #expect(!CaptureJudge.needsJudgment("date night"))
        #expect(!CaptureJudge.needsJudgment("dentist on thursday"))
    }

    @Test("A one-piece capture is judged only when it shows a second outcome")
    func singlePieceRule() {
        #expect(CaptureJudge.doubtfulIndices(in: ["the thing with the insurance people"]).isEmpty)
        #expect(
            CaptureJudge.doubtfulIndices(in: ["wash the uniform before saturday and refill the prescription"])
                == [0])
        #expect(
            CaptureJudge.doubtfulIndices(in: ["pay the water bill", "so I was thinking about the weekend"])
                == [1])
    }

    // MARK: - What a verdict may do

    @Test("none sets a piece aside; it never deletes it, and never a piece that states a need")
    func noneSetsAside() {
        let clauses = [
            "Dear parents, thank you for a great start to the term",
            "Please return the signed permission slip by Friday",
            "I have to remember to call the school about pickup",
        ]
        let none = CaptureJudge.Answer(verdict: .none)
        let reading = CaptureJudge.apply([0: none, 1: none, 2: none], to: clauses)
        #expect(reading.leftOut == ["Dear parents, thank you for a great start to the term"])
        #expect(reading.clauses == Array(clauses.dropFirst()))
    }

    @Test("A one-piece capture is never set aside, whatever the model said")
    func singlePieceIsNeverSetAside() {
        let reading = CaptureJudge.apply(
            [0: CaptureJudge.Answer(verdict: .none)], to: ["the thing with the insurance people"])
        #expect(reading.leftOut.isEmpty)
        #expect(reading.clauses == ["the thing with the insurance people"])
    }

    @Test("A missing verdict keeps the piece as a card")
    func noAnswerKeeps() {
        let clauses = ["so I was thinking about the weekend", "book the sitter"]
        let reading = CaptureJudge.apply([:], to: clauses)
        #expect(reading.clauses == clauses)
        #expect(reading.leftOut.isEmpty)
    }

    // MARK: - The re-split

    @Test("several splits only into parts that each stand alone")
    func resplitValidates() {
        #expect(
            CaptureJudge.resplit("wash the soccer uniform before saturday and refill the prescription")
                == ["wash the soccer uniform before saturday", "refill the prescription"])
        #expect(
            CaptureJudge.resplit(
                "send it in, also we're out of milk and eggs and the car needs an oil change at some point")
                == ["send it in", "we're out of milk and eggs", "the car needs an oil change at some point"])
        // One outcome with a compound object: the right side cannot stand alone.
        #expect(CaptureJudge.resplit("Mom's birthday is next week so I need a card and a gift") == nil)
        #expect(CaptureJudge.resplit("email the landlord about the boiler and the leak") == nil)
        // A statement before a request: the first part is not a task, so no split.
        #expect(
            CaptureJudge.resplit("Picture day is Thursday, please return the order form by Tuesday") == nil)
    }

    @Test("several without a valid split leaves the piece one card")
    func severalWithoutSplitKeepsOneCard() {
        let clauses = ["pay the water bill", "email the landlord about the boiler and the leak"]
        let reading = CaptureJudge.apply([1: CaptureJudge.Answer(verdict: .several)], to: clauses)
        #expect(reading.clauses == clauses)
        #expect(reading.resplit == 0)
    }

    @Test("A short imperative whose object is 'it' joins the piece before it")
    func anaphoraFolds() {
        let folded = CaptureJudge.foldingAnaphora([
            "the permission slip is due Friday so sign it", "send it in", "we're out of milk and eggs",
        ])
        #expect(
            folded == [
                "the permission slip is due Friday so sign it and send it in", "we're out of milk and eggs",
            ])
    }

    // MARK: - The pass

    @Test("The pass judges only doubtful pieces, and survives a judge that never answers")
    func passWithInjectedJudge() async {
        let clauses = [
            "Hi families, a few reminders for next week",
            "pay the water bill",
            "wash the uniform before saturday and refill the prescription",
        ]
        let reading = await CaptureJudge.read(clauses: clauses) { clause in
            CaptureJudge.Answer(verdict: clause.hasPrefix("Hi") ? .none : .several)
        }
        #expect(reading.judged == 2)
        #expect(reading.leftOut == ["Hi families, a few reminders for next week"])
        #expect(
            reading.clauses == [
                "pay the water bill", "wash the uniform before saturday", "refill the prescription",
            ])

        let silent = await CaptureJudge.read(clauses: clauses) { _ in nil }
        #expect(silent.clauses == clauses)
        #expect(silent.leftOut.isEmpty)
    }

    // MARK: - The submit decision and the reveal boundary

    @Test("The judge arm is chosen only with a model AND a doubtful piece")
    func planChoosesTheJudge() {
        let dump = "Hi families, a few reminders for next week. Please return the order form by Tuesday."
        let local = AppBrain.provisionalDrafts(dump)
        let withModel = CaptureFlow.plan(text: dump, localRead: local, fromVoice: false, modelAvailable: true)
        #expect(withModel.arm == .judge)
        let noModel = CaptureFlow.plan(text: dump, localRead: local, fromVoice: false, modelAvailable: false)
        #expect(noModel.arm == .revealInstantly)
        let plain = "pay the water bill"
        let plainPlan = CaptureFlow.plan(
            text: plain, localRead: AppBrain.provisionalDrafts(plain), fromVoice: false, modelAvailable: true)
        #expect(plainPlan.arm == .revealInstantly)
    }

    @Test("Left-out lines ride the proposal, obey the reveal boundary, and add back as the person's act")
    func leftOutObeysTheBoundary() throws {
        var interpretation = Interpretation()
        let draft = try #require(CaptureFlow.keepAsOneTask(text: "book the sitter"))
        let taken = interpretation.propose([draft], leftOut: ["so I was thinking"])
        #expect(taken)
        interpretation.reveal()
        let late = interpretation.propose([], leftOut: ["something else"])
        #expect(!late)
        #expect(interpretation.leftOut == ["so I was thinking"])

        let restored = try #require(CaptureFlow.keepAsOneTask(text: "so I was thinking"))
        interpretation.restoreLeftOut("so I was thinking", as: restored)
        #expect(interpretation.leftOut.isEmpty)
        #expect(interpretation.drafts.count == 2)
        #expect(!interpretation.hasUnexplainedMutation)
    }

    // MARK: - Reports, titles, splits (2026-10-04, second pass)

    @Test("A short report folds into the next card as context; with nothing after it, it stays a card")
    func reportsFold() {
        #expect(CaptureJudge.isAReport("The pediatrician called"))
        #expect(CaptureJudge.isAReport("Mom texted"))
        #expect(CaptureJudge.isAReport("Noah's school emailed"))
        #expect(!CaptureJudge.isAReport("Monday Maya has swim at 4"))
        #expect(!CaptureJudge.isAReport("I need to call the pediatrician"))
        let reading = CaptureJudge.apply(
            [0: CaptureJudge.Answer(verdict: .none)],
            to: ["The pediatrician called", "call back about the vaccine form"])
        #expect(reading.clauses == ["call back about the vaccine form"])
        #expect(reading.pieces.first?.context == "The pediatrician called")
        #expect(reading.leftOut.isEmpty)
        let alone = CaptureJudge.apply([:], to: ["pay the water bill", "The pediatrician called"])
        #expect(alone.clauses == ["pay the water bill", "The pediatrician called"])
    }

    @Test("A to-do title is accepted only in the person's own words, with their verb and their names")
    func titlesStayTheirs() {
        #expect(
            CaptureJudge.validatedTodo(
                "Clean the gutters", source: "And the gutters need cleaning before the rain",
                currentTitle: "And the gutters need cleaning before the rain") == "Clean the gutters")
        #expect(
            CaptureJudge.validatedTodo(
                "Email Ms Patel about the field trip form",
                source:
                    "honestly the kids have so much energy, anyway I need to email Ms Patel about the field trip form",
                currentTitle: "Honestly the kids have so much energy, anyway I need to email Ms Patel")
                == "Email Ms Patel about the field trip form")
        // A verb they never said is a guess about what the line means.
        #expect(
            CaptureJudge.validatedTodo(
                "Book dentist for Noah", source: "Tuesday dentist for Noah at 3:30",
                currentTitle: "Dentist for Noah at 3:30") == nil)
        // Their instruction wins over a verb lifted from the school's sentence.
        #expect(
            CaptureJudge.validatedTodo(
                "Collect canned food",
                source: "We are collecting canned food for the drive, bring two cans by Wednesday",
                currentTitle: "We are collecting canned food for the drive, bring two cans") == nil)
        // A word they never said, a date, or a dropped name: refused.
        #expect(
            CaptureJudge.validatedTodo(
                "Buy a nice gift", source: "Mom's birthday is next week so I need a card and a gift",
                currentTitle: "Mom's birthday is next week so I need a card and a gift") == nil)
        #expect(
            CaptureJudge.validatedTodo(
                "Return the slip by Friday", source: "the slip is due Friday, return it",
                currentTitle: "The slip is due Friday, return it") == nil)
        // A title that says nothing is refused even in their words.
        #expect(
            CaptureJudge.validatedTodo(
                "Do something", source: "anyway the weather is nice, we should do something",
                currentTitle: "Anyway the weather is nice, we should do something") == nil)
        // A verb-led title that runs on is replaced; a short one never is.
        #expect(
            CaptureJudge.validatedTodo(
                "Remind Dan to pick up his mother",
                source:
                    "remind Dan to pick up his mother from the airport on Sunday, and yeah that's about it, oh the weather is great",
                currentTitle:
                    "Remind Dan to pick up his mother from the airport on Sunday, and yeah that's about it")
                == "Remind Dan to pick up his mother")
        // A title that already starts with a verb is never replaced.
        #expect(
            CaptureJudge.validatedTodo(
                "Pay water bill", source: "pay the water bill", currentTitle: "Pay the water bill") == nil)
    }

    @Test("A split is accepted only when every part passes and there are at least two")
    func splitsValidate() {
        let source = "Mom's birthday is next week so I need a card and a gift"
        #expect(
            CaptureJudge.validatedSplit(["Get a card", "Get a gift"], source: source) == [
                "Get a card", "Get a gift",
            ])
        // A verb they never said, for something that is not a need, is still refused.
        #expect(
            CaptureJudge.validatedSplit(
                ["Attend parent teacher conference", "Remember report card"],
                source: "Wednesday parent teacher conference at 5, remember the report card") == nil)
        #expect(
            CaptureJudge.validatedSplit(
                ["Wash the soccer uniform", "Refill the prescription"],
                source: "wash the soccer uniform before saturday and refill the prescription")
                == ["Wash the soccer uniform", "Refill the prescription"])
        let laundry = "wash the uniform and fold the towels before saturday"
        #expect(
            CaptureJudge.validatedSplit(["Wash the uniform", "Fold the towels"], source: laundry)
                == ["Wash the uniform", "Fold the towels"])
        #expect(CaptureJudge.validatedSplit(["Wash the uniform"], source: laundry) == nil)
        #expect(CaptureJudge.validatedSplit(["Wash the uniform", "Iron the shirts"], source: laundry) == nil)
    }

    @Test("Split is offered only on a piece that names an action")
    func splitNeedsAnAction() {
        let several = CaptureJudge.Answer(verdict: .several)
        let greeting = CaptureJudge.apply(
            [0: several], to: ["Hi families, a few reminders for next week", "pay it"])
        #expect(greeting.pieces.first?.mightBeSeveral == false)
        let errands = CaptureJudge.apply(
            [0: several], to: ["Mom's birthday is next week so I need a card and a gift", "pay the bill"])
        #expect(errands.pieces.first?.mightBeSeveral == true)
    }

    @Test("A long one-line remark may be set aside; a short line never is")
    func singleLineChatter() {
        let chatter = "ha yeah no that was so funny, she just looked at me like I was crazy"
        #expect(CaptureJudge.doubtfulIndices(in: [chatter]) == [0])
        let reading = CaptureJudge.apply([0: CaptureJudge.Answer(verdict: .none)], to: [chatter])
        #expect(reading.leftOut == [chatter])
        #expect(reading.clauses.isEmpty)
        #expect(CaptureJudge.doubtfulIndices(in: ["the thing with the insurance people"]).isEmpty)
    }
}
