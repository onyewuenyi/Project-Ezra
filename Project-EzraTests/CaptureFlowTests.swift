//
//  CaptureFlowTests.swift
//  Project-EzraTests
//
//  The submit decision as a value (G5, first cut): every rule the composer's submit path
//  enforces, pinned in order of precedence — the judge for a doubtful piece, the
//  single-thought engine for one thought the read could not land, voice earns the beat,
//  typed reveals instantly. No arm transmits: capture reads on the device only.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("CaptureFlow — the submit decision, pure")
struct CaptureFlowTests {

    @Test("A capture that names its own outcome offers it as the group's title; nothing else does")
    func suggestedOutcomeTitle() {
        #expect(
            CaptureFlow.suggestedOutcomeTitle(from: "Lagos trip: renew passport, book flights")
                == "Lagos trip")
        #expect(
            CaptureFlow.suggestedOutcomeTitle(from: "  Kitchen remodel : get quotes ") == "Kitchen remodel")
        // No colon, nothing after it, or a lead too long to be a name → the field starts empty.
        #expect(CaptureFlow.suggestedOutcomeTitle(from: "renew passport, book flights") == nil)
        #expect(CaptureFlow.suggestedOutcomeTitle(from: "Lagos trip:") == nil)
        #expect(
            CaptureFlow.suggestedOutcomeTitle(
                from: "I really need to sort out everything for the trip this year: a, b") == nil)
    }

    private let oneThought = "call the dentist tomorrow about the crown"
    private let typedList = "renew the passport\nbook the flights\npay the water bill"

    private func plan(_ text: String, voice: Bool = false, model: Bool = true) -> CaptureFlow.Arm {
        CaptureFlow.plan(
            text: text, localRead: AppBrain.provisionalDrafts(text), fromVoice: voice, modelAvailable: model
        ).arm
    }

    @Test("Typed text the read handled reveals instantly; the same words spoken earn the beat")
    func typedInstantSpokenDwell() {
        #expect(plan(typedList) == .revealInstantly)
        #expect(plan(typedList, voice: true) == .revealAfterDwell)
        #expect(plan(oneThought) == .revealInstantly)
    }

    @Test("A doubtful piece goes to the judge — only when a model is present")
    func doubtfulPieceGoesToTheJudge() {
        let email = "Hi families, a few reminders for next week. Please return the order form by Tuesday."
        #expect(plan(email) == .judge)
        #expect(plan(email, voice: true) == .judge)
        #expect(plan(email, model: false) == .revealInstantly)
        #expect(plan(email, voice: true, model: false) == .revealAfterDwell)
    }

    @Test("One thought the read could not land runs the single-thought engine; a landed one does not")
    func singleThoughtEngineOnEvidence() {
        let unresolved = "call the dentist at"
        let read = AppBrain.provisionalDrafts(unresolved)
        #expect(CaptureEscalation.reason(for: unresolved, drafts: read) == .unresolvedDetail)
        #expect(plan(unresolved) == .privateEngine)
        #expect(plan(unresolved, model: false) == .revealInstantly)
        #expect(plan(oneThought) != .privateEngine, "a read that landed needs no model")
    }

    @Test("No model, no model arm — whatever the capture looks like")
    func noModelNoModelArm() {
        let dump = "so I need to pay the water bill and renew the car registration and email the landlord"
        for text in [oneThought, typedList, dump] {
            for voice in [true, false] {
                let arm = plan(text, voice: voice, model: false)
                #expect(arm == (voice ? .revealAfterDwell : .revealInstantly))
            }
        }
    }
}
