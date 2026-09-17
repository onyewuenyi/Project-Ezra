//
//  DatedClauseSplitTests.swift
//  Project-EzraTests
//
//  Two clauses that each carry their own day are two outcomes, even when the second
//  has no verb — the shape that still escalated on 2026-09-17 after every other arm
//  had been measured, and the one the deterministic read is best placed to resolve.
//  The guards matter as much as the rule: a day-list is one outcome, a compound
//  object is one outcome, and a bare trailing day is not a card.
//

import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct DatedClauseSplitTests {

    private func clauses(_ text: String) -> [String] {
        Segmentation.splitClauses(text)
    }

    @Test("Each side carries its own day → two outcomes, verb or not")
    func datedSidesSplit() {
        #expect(clauses("dentist on thursday and the vet on friday").count == 2)
        #expect(clauses("text mom about sunday and the dentist about thursday").count == 2)
        #expect(
            AppBrain.provisionalDrafts("dentist on thursday and the vet on friday").count == 2)
    }

    @Test("A day-list is one outcome — the right side opening on a day never splits")
    func dayListStaysWhole() {
        #expect(clauses("walk my dog monday and tuesday").count == 1)
        let drafts = AppBrain.provisionalDrafts(
            "walk my dog monday and tuesday plan the year of 2027")
        // The resolver fans the day-list; the CLAUSE count is what this rule governs.
        #expect(clauses("walk my dog monday and tuesday plan the year of 2027").count <= 2)
        #expect(!drafts.contains { $0.title.lowercased().hasPrefix("tuesday") })
    }

    @Test("Compound objects and bare trailing days are still one thing")
    func guardsHold() {
        #expect(clauses("email the landlord about the boiler and the leak").count == 1)
        #expect(clauses("call the school about the trip and the uniform").count == 1)
        #expect(clauses("call mom on friday and saturday").count == 1)
        #expect(clauses("pay rent tomorrow and friday").count == 1)
    }
}
