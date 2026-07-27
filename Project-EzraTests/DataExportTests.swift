//
//  DataExportTests.swift
//  Project-EzraTests
//
//  The export is a rescue path: it only earns its place if what comes out is
//  complete enough to reconstruct what you had. These tests pin the fields that carry
//  irreplaceable user intent — the verbatim capture text, the graph edges, and the
//  human/AI provenance — rather than every column.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Data export")
@MainActor
struct DataExportTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A task's user-authored fields survive an encode/decode round trip")
    func roundTripsTask() throws {
        let context = TestStore.makeContext()
        let task = TaskItem(
            title: "Renew my passport", status: .todo, createdAt: now)
        task.notes = "The photo booth on Main St"
        task.isUrgent = true
        task.dueDate = now.addingTimeInterval(86_400)
        context.insert(task)

        let export = DataExport.build(
            tasks: [task], captures: [], changes: [], corrections: [], capacity: [],
            profile: nil, members: [], now: now)
        let decoded = try DataExport.decode(DataExport.encode(export))

        let row = try #require(decoded.tasks.first)
        #expect(row.title == "Renew my passport")
        #expect(row.notes == "The photo booth on Main St")
        #expect(row.isUrgent)
        #expect(row.status == TaskStatus.todo.rawValue)
        #expect(row.id == task.uuid)
        #expect(decoded.exportedAt == export.exportedAt)
    }

    @Test("Graph edges are exported in readable form, with their origin intact")
    func exportsRelationshipsWithOrigin() throws {
        let context = TestStore.makeContext()
        let blocker = TaskItem(title: "Get the photo taken", status: .todo, createdAt: now)
        let blocked = TaskItem(title: "Renew my passport", status: .todo, createdAt: now)
        context.insert(blocker)
        context.insert(blocked)
        let blockerID = try #require(blocker.uuid)
        blocked.relationships = [
            .blocks(taskID: blockerID, origin: .inferred(confidence: 0.7))
        ]

        let export = DataExport.build(
            tasks: [blocked], captures: [], changes: [], corrections: [], capacity: [],
            profile: nil, members: [], now: now)
        let decoded = try DataExport.decode(DataExport.encode(export))

        let edge = try #require(decoded.tasks.first?.relationships.first)
        #expect(edge.kind == "blocks")
        #expect(edge.targetID == blockerID)
        #expect(edge.origin == "inferred")
        #expect(edge.confidence == 0.7)
    }

    @Test("A human edge carries no confidence — the illegal state stays unrepresentable")
    func humanEdgeHasNoConfidence() throws {
        let context = TestStore.makeContext()
        let blocker = TaskItem(title: "Call the bank", status: .todo, createdAt: now)
        let blocked = TaskItem(title: "Pay the deposit", status: .todo, createdAt: now)
        context.insert(blocker)
        context.insert(blocked)
        blocked.relationships = [.blocks(taskID: try #require(blocker.uuid), origin: .human)]

        let export = DataExport.build(
            tasks: [blocked], captures: [], changes: [], corrections: [], capacity: [],
            profile: nil, members: [], now: now)

        let edge = try #require(export.tasks.first?.relationships.first)
        #expect(edge.origin == "human")
        #expect(edge.confidence == nil)
    }

    @Test("The verbatim capture text is exported exactly as it was spoken")
    func preservesRawCaptureText() throws {
        let context = TestStore.makeContext()
        let messy = "ok so umm the car needs an oil change and also call mum back"
        let capture = Capture(rawText: messy, source: .voice, in: context)

        let export = DataExport.build(
            tasks: [], captures: [capture], changes: [], corrections: [], capacity: [],
            profile: nil, members: [], now: now)
        let decoded = try DataExport.decode(DataExport.encode(export))

        #expect(decoded.captures.first?.rawText == messy)
        #expect(decoded.captures.first?.source == CaptureSource.voice.rawValue)
    }

    @Test("An empty store exports a valid, empty document rather than failing")
    func exportsEmptyStore() throws {
        let context = TestStore.makeContext()

        let decoded = try DataExport.decode(
            DataExport.encode(DataExport.everything(in: context, now: now)))

        #expect(decoded.tasks.isEmpty)
        #expect(decoded.captures.isEmpty)
        #expect(decoded.exportedAt == now)
    }

    @Test("Everything() picks the store's rows up through the context")
    func fetchesFromContext() throws {
        let context = TestStore.makeContext()
        context.insert(TaskItem(title: "Book the flights", status: .todo, createdAt: now))
        try context.save()

        let export = DataExport.everything(in: context, now: now)

        #expect(export.tasks.map(\.title) == ["Book the flights"])
    }
}
