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
        let reading = CaptureJudge.apply([0: .none, 1: .none, 2: .none], to: clauses)
        #expect(reading.leftOut == ["Dear parents, thank you for a great start to the term"])
        #expect(reading.clauses == Array(clauses.dropFirst()))
    }

    @Test("A one-piece capture is never set aside, whatever the model said")
    func singlePieceIsNeverSetAside() {
        let reading = CaptureJudge.apply([0: .none], to: ["the thing with the insurance people"])
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
        let reading = CaptureJudge.apply([1: .several], to: clauses)
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
            clause.hasPrefix("Hi") ? CaptureJudge.Verdict.none : .several
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
}
