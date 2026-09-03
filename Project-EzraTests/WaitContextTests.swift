//
//  WaitContextTests.swift
//  Project-EzraTests
//
//  One deadline function. Every constant the product measured is reproduced by the
//  derivation from (presence · budget · output · answer in hand) — so a new scope
//  inherits a predictable deadline instead of choosing a number, and none of the
//  existing numbers moved.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("WaitContext — one deadline function")
struct WaitContextTests {

    @Test("The table reproduces every measured constant")
    func table() {
        #expect(ModelDeadline.seconds(for: .card) == ModelDeadline.cardSeconds)
        #expect(ModelDeadline.seconds(for: .reply) == ModelDeadline.cardSeconds)
        #expect(ModelDeadline.seconds(for: .background) == ModelDeadline.backgroundSeconds)
        #expect(
            ModelDeadline.seconds(for: .capture(escalation: nil)) == ModelDeadline.captureSeconds)
        #expect(
            ModelDeadline.seconds(for: .capture(escalation: .bigDump)) == ModelDeadline.captureSeconds)
        #expect(
            ModelDeadline.seconds(for: .capture(escalation: .underSegmented))
                == ModelDeadline.captureStandbySeconds)
        #expect(
            ModelDeadline.seconds(for: .advisor(rung: .cloud, presenceTime: false))
                == ModelDeadline.advisorDeepPrecomputeSeconds)
        #expect(
            ModelDeadline.seconds(for: .advisor(rung: .cloud, presenceTime: true))
                == ModelDeadline.advisorDeepPresenceSeconds)
        #expect(
            ModelDeadline.seconds(for: .advisor(rung: .onDevice, presenceTime: false))
                == ModelDeadline.cardSeconds)
    }

    @Test("The legacy selectors are the table, not a second table")
    func legacySelectorsDerive() {
        for reason in CaptureEscalationReason.allCases {
            #expect(
                ModelDeadline.captureSeconds(for: reason)
                    == ModelDeadline.seconds(for: .capture(escalation: reason)))
        }
        for rung in IntelligenceRung.allCases {
            for presence in [true, false] {
                #expect(
                    ModelDeadline.advisorSeconds(rung: rung, presenceTime: presence)
                        == ModelDeadline.seconds(for: .advisor(rung: rung, presenceTime: presence)))
            }
        }
    }

    @Test(
        "Ordering invariants: an answer in hand waits least; a watched deep read waits less than an unattended one; a dump waits longest of the shallow rows"
    )
    func ordering() {
        var inHand = WaitContext.reply
        inHand.answerInHand = true
        #expect(ModelDeadline.seconds(for: inHand) < ModelDeadline.seconds(for: .reply))
        #expect(
            ModelDeadline.seconds(for: .advisor(rung: .cloud, presenceTime: true))
                < ModelDeadline.seconds(for: .advisor(rung: .cloud, presenceTime: false)))
        #expect(
            ModelDeadline.seconds(for: .background) < ModelDeadline.seconds(for: .card))
        #expect(
            ModelDeadline.seconds(for: .card) < ModelDeadline.seconds(for: .capture(escalation: nil)))
    }

    @Test(
        "Capture speaks the shared budget: a big dump is .deep, a short one .shallow, and the level derives from the budget"
    )
    func captureBudgetVocabulary() {
        let short = "Call the dentist tomorrow"
        let dump = String(
            repeating: "Take the kids to school, then go to the park, then cook lunch. ", count: 8)
        #expect(CaptureRoute.budget(for: short) == .shallow)
        #expect(CaptureRoute.budget(for: dump) == .deep)
        #expect(CaptureRoute.captureDepth(for: short) == nil)
        #expect(CaptureRoute.captureDepth(for: dump) == .moderate)
    }
}
