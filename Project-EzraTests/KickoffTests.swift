//
//  KickoffTests.swift
//  Project-EzraTests
//
//  The kickoff prompt is a pure function of the task's facts — pinned so nothing ever
//  rides into the "first move" generation unnoticed (the instructions forbid invented
//  specifics precisely because the prompt is this small).
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("Kickoff — fact lines")
struct KickoffTests {

    @Test("A full-fact task renders every line, in order")
    func fullPrompt() {
        let facts = KickoffFacts(
            title: "Renew passport", notes: "Kids' expire in March", category: "Admin",
            effortMinutes: 90, dueDescription: "due in 14 days")
        #expect(
            KickoffService.prompt(facts) == """
                TASK: Renew passport
                Category: Admin
                Notes: Kids' expire in March
                Estimated ~90 min
                Due: due in 14 days
                """)
    }

    @Test("Missing facts stay silent — no empty lines for the model to fill")
    func sparsePrompt() {
        let facts = KickoffFacts(title: "Call the vet", category: "Family")
        #expect(
            KickoffService.prompt(facts) == """
                TASK: Call the vet
                Category: Family
                """)
    }
}
