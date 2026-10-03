//
//  KickoffTests.swift
//  Project-EzraTests
//
//  The kickoff prompt is a pure function of the task's facts — pinned so nothing ever
//  rides into the "first move" generation unnoticed (the instructions forbid invented
//  specifics precisely because the prompt is this small). The validator is the check
//  behind that instruction: a step naming a specific the facts never held is dropped.
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
            effortMinutes: 90, dueDescription: "due in 14 days",
            spoken: "renew the passports, need to find the old ones first", abandonedStarts: 2)
        #expect(
            KickoffService.prompt(facts) == """
                TASK: Renew passport
                Category: Admin
                Notes: Kids' expire in March
                Estimated ~90 min
                Due: due in 14 days
                They said: renew the passports, need to find the old ones first
                Started before and put down: 2 times
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

    @Test("A single abandoned start reads singular")
    func singularAbandon() {
        let facts = KickoffFacts(title: "Sort the loft", category: "Home", abandonedStarts: 1)
        #expect(KickoffService.prompt(facts).hasSuffix("Started before and put down: 1 time"))
    }

    @Test("The instructions name both new facts, so the lines are read, not ignored")
    func instructionsReadTheNewLines() {
        #expect(KickoffService.instructions.contains("\"They said\""))
        #expect(KickoffService.instructions.contains("started before and put down"))
    }
}

@Suite("Kickoff — the validator")
struct KickoffValidatorTests {

    private let facts = KickoffFacts(
        title: "Call the dentist", notes: "Dr Patel, 555-201-3344", category: "Family",
        spoken: "book the kids in at drpatel.example.com")

    @Test("A plain step passes, trimmed")
    func plainStepPasses() {
        #expect(
            KickoffService.validated("  Find the dentist's number in your contacts. ", against: facts)
                == "Find the dentist's number in your contacts.")
    }

    @Test("An empty step is nothing")
    func emptyIsNil() {
        #expect(KickoffService.validated("   ", against: facts) == nil)
    }

    @Test("A specific the facts hold survives — the number and the site were given")
    func givenSpecificsSurvive() {
        #expect(KickoffService.validated("Call 555-201-3344 now", against: facts) != nil)
        #expect(KickoffService.validated("Open drpatel.example.com", against: facts) != nil)
    }

    @Test("An invented phone number, URL or email drops the whole step")
    func inventedSpecificsDrop() {
        #expect(KickoffService.validated("Call 555-867-5309 to book", against: facts) == nil)
        #expect(KickoffService.validated("Go to www.dentist-booking.com", against: facts) == nil)
        #expect(KickoffService.validated("Email front@dentist.com", against: facts) == nil)
    }

    @Test("Short numbers are not specifics — a time, a day count, a small quantity pass")
    func shortNumbersPass() {
        #expect(KickoffService.validated("Set a 10 min timer and start", against: facts) != nil)
        #expect(KickoffService.validated("Call at 10:30 tomorrow", against: facts) != nil)
        #expect(KickoffService.specifics(in: "due in 14 days, 3 forms, 2026").isEmpty)
    }
}
