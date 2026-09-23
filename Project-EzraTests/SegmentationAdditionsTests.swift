//
//  SegmentationAdditionsTests.swift
//  Project-EzraTests
//
//  Two findings from the 2026-09-18 reveal screenshots: a line made only of filler
//  became a task, and a second clause whose verb the lexicon had never met kept two
//  errands on one card.
//

import Testing

@testable import Project_Ezra

@Suite("Segmentation — filler lines and errand verbs")
struct SegmentationAdditionsTests {

    @Test("A line made only of filler is nothing, however many words")
    func fillerLinesAreNothing() {
        #expect(Segmentation.isBareFiller("hmm"))
        #expect(Segmentation.isBareFiller("hmm ok so"))
        #expect(Segmentation.isBareFiller("um, yeah. okay"))
        // One content word anywhere and the line is a capture.
        #expect(!Segmentation.isBareFiller("ok so passport"))
        #expect(!Segmentation.isBareFiller("call mom"))
        #expect(!Segmentation.isBareFiller(""))
        // A date phrase does not make filler a task: "ok so this week" is a WHEN with
        // nothing to do on it, and it had become a card titled "Ok so" with a due chip.
        #expect(Segmentation.isBareFiller("ok so this week"))
        #expect(Segmentation.isBareFiller("tomorrow"))
        #expect(!Segmentation.isBareFiller("dentist tomorrow"))
    }

    @Test("A dump that opens with filler and a week never yields an 'Ok so' card")
    func dumpLeadInIsNotATask() async throws {
        let dump =
            "ok so this week I need to renew the car insurance before it lapses, call the school about the trip forms, get the boiler serviced"
        let intents = try await HeuristicEngine().triage(rawText: dump)
        let titles = intents.map(\.title)
        #expect(
            !titles.contains { $0.lowercased().hasPrefix("ok so") },
            Comment(rawValue: titles.joined(separator: " | ")))
        #expect(titles.contains { $0.lowercased().hasPrefix("renew the car insurance") })
    }

    @Test("A cut after a time expression strips the lead-in from the piece it keeps")
    func timeCutStripsLeadIn() {
        let items = Segmentation.items(from: "pick up groceries at noon then text Sarah about saturday")
        #expect(items.count == 2, Comment(rawValue: items.joined(separator: " | ")))
        #expect(
            items.last?.lowercased().hasPrefix("text sarah") == true,
            Comment(rawValue: items.joined(separator: " | ")))
    }

    @Test("Errand verbs the lexicon had never met now open an item")
    func errandVerbsSplit() {
        #expect(Segmentation.items(from: "buy stamps and post the parcel").count == 2)
        #expect(Segmentation.items(from: "iron the shirts and hang the washing").count == 2)
        #expect(Segmentation.startsAnItem("collect the dry cleaning"))
        #expect(Segmentation.startsAnItem("empty the dishwasher"))
        #expect(Segmentation.startsAnItem("chase him about the claim"))
        #expect(Segmentation.startsAnItem("transfer the deposit"))
        #expect(
            Segmentation.items(from: "renew the passport and chase the school about the forms").count == 2)
    }

    @Test("The verb lexicon is a set — a duplicate literal would trap at first use")
    func verbLexiconIsUnique() {
        // Constructing the set is the assertion: a duplicate element traps.
        #expect(Segmentation.actionVerbs.count > 100)
    }
}
