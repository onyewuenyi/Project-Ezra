//
//  UnstickNarrationTests.swift
//  Project-EzraTests
//
//  The narration prompt is a pure function of the deterministic facts — pinned here so
//  the facts the model may phrase are exactly the facts the detector used, and nothing
//  else ever rides along unnoticed.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Unstick narration — fact lines")
struct UnstickNarrationTests {

    @Test("A dying task's prompt carries diagnosis, deferrals, and quiet days — nothing else")
    func dyingPrompt() {
        let facts = UnstickFacts(
            title: "Renew passport", diagnosis: .dying, deferralCount: 4, quietDays: 12)
        #expect(
            UnstickNarrationService.prompt(facts) == """
                TASK: Renew passport
                DIAGNOSIS: repeatedly set aside
                Set aside 4 times in a row
                No touch in 12 days
                """)
    }

    @Test("A blocked task's prompt names its blockers verbatim")
    func blockedPrompt() {
        let facts = UnstickFacts(
            title: "Book flights", diagnosis: .blocked, deferralCount: 0, quietDays: 30,
            blockerTitles: ["Renew passport"])
        #expect(
            UnstickNarrationService.prompt(facts) == """
                TASK: Book flights
                DIAGNOSIS: waiting on something else
                No touch in 30 days
                Waiting on: Renew passport
                """)
    }

    @Test("The choice diagnosis and effort line render; zero counts stay silent")
    func decisionPrompt() {
        let facts = UnstickFacts(
            title: "Decide on the school", diagnosis: .reallyADecision, deferralCount: 1,
            quietDays: 0, effortMinutes: 30)
        #expect(
            UnstickNarrationService.prompt(facts) == """
                TASK: Decide on the school
                DIAGNOSIS: worded as a choice, not a doable step
                Set aside 1 time in a row
                Estimated ~30 min
                """)
    }
}
