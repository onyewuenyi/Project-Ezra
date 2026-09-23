//
//  CaptureProvenanceTests.swift
//  Project-EzraTests
//
//  The per-capture receipt: its storage contract, and the two invariants that make it safe
//  to add a row to a shipping feed.
//
//  The interesting test here is `capturedEntriesNeverCountTowardAcceptance`. Every other
//  case checks something the feature does; that one checks something the feature must not
//  BREAK. `captured` is AI-initiated and permanently irreversible, so it can only ever score
//  as kept — left inside `Metrics.acceptanceRate` it would raise the product's primary trust
//  number every time the user captured anything, which is a metric improving for a reason
//  unrelated to trust.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Capture provenance")
struct CaptureProvenanceTests {

    private func store() -> CaptureProvenanceStore {
        // A throwaway file per suite run, for the reason `PersistenceStack.StoreLocation`
        // is injectable: these functions write and TRIM, and pointed at the default
        // location a test would delete the developer's own receipts.
        CaptureProvenanceStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("provenance-\(UUID().uuidString).json"))
    }

    private func provenance(
        capture: UUID = UUID(), drafts: [TaskDraft] = [], run: CaptureRunTelemetry = .init()
    ) -> CaptureProvenance {
        CaptureProvenance(
            captureID: capture, rawText: "raw", capturedAt: Date(), committedAt: Date(),
            run: run, drafts: drafts, createdTaskIDs: [], mergedTaskIDs: [])
    }

    // MARK: - Storage

    @Test("A recorded run round-trips and is found by its capture id")
    func roundTrip() {
        let sut = store()
        let id = UUID()
        var run = CaptureRunTelemetry()
        run.route = "cloud"
        run.modelIdentifier = "gemini-flash"
        run.modelVersion = "gemini-3.7-flash"
        run.armWon = "hedge"
        run.parseMs = 6200
        run.outcome = "salvaged"
        sut.record(provenance(capture: id, run: run))

        let found = try? #require(sut.provenance(forCapture: id))
        #expect(found?.run.modelVersion == "gemini-3.7-flash")
        #expect(found?.run.armWon == "hedge")
        #expect(found?.run.outcome == "salvaged")
    }

    // MARK: - The feed's byline

    @Test("The Activity byline speaks the product's words — never a route name, a latency or a vendor id")
    func bylineIsPlain() {
        var cloud = CaptureRunTelemetry()
        cloud.route = "cloud"
        cloud.modelIdentifier = "gemini-flash"
        cloud.modelVersion = "gemini-3.7-flash"
        cloud.parseMs = 1200
        #expect(provenance(run: cloud).bylineLine == "Read in the cloud")
        // The diagnostic line keeps every fact for the detail page and the reports.
        #expect(provenance(run: cloud).summaryLine == "cloud(gemini-flash) · 1.2s")

        var local = CaptureRunTelemetry()
        local.parseMs = 2
        #expect(provenance(run: local).bylineLine == "Read on your device")

        var salvaged = CaptureRunTelemetry()
        salvaged.route = "cloud"
        salvaged.outcome = "salvaged"
        #expect(provenance(run: salvaged).bylineLine == "Read in the cloud · cut short")

        for line in [provenance(run: cloud).bylineLine, provenance(run: salvaged).bylineLine] {
            #expect(!line.lowercased().contains("gemini"))
            #expect(!line.contains("local") && !line.contains("s ·") && !line.contains("ms"))
        }
    }

    @Test("An unknown capture has no receipt — never a synthesized empty one")
    func unknownCaptureIsNil() {
        #expect(store().provenance(forCapture: UUID()) == nil)
    }

    @Test("Re-recording the same capture replaces rather than duplicates its receipt")
    func replacesSameCapture() {
        let sut = store()
        let id = UUID()
        var first = CaptureRunTelemetry()
        first.outcome = "timedOut"
        sut.record(provenance(capture: id, run: first))
        var second = CaptureRunTelemetry()
        second.outcome = "success"
        sut.record(provenance(capture: id, run: second))

        #expect(sut.all.filter { $0.captureID == id }.count == 1)
        #expect(sut.provenance(forCapture: id)?.run.outcome == "success")
    }

    @Test("The record cap is enforced, dropping the OLDEST first")
    func capDropsOldest() {
        let sut = store()
        let newest = UUID()
        // One past the cap: the very first write must be gone and the last must survive.
        let oldest = UUID()
        sut.record(provenance(capture: oldest))
        for _ in 0..<(CaptureProvenanceStore.maxRecords - 1) { sut.record(provenance()) }
        sut.record(provenance(capture: newest))

        #expect(sut.all.count == CaptureProvenanceStore.maxRecords)
        #expect(sut.provenance(forCapture: newest) != nil)
        #expect(sut.provenance(forCapture: oldest) == nil)
    }

    @Test("Sentinel timings decode as nil — 'not measured' is not 'measured as zero'")
    func sentinelsBecomeNil() {
        #expect((-1).nonNegative == nil)
        #expect(0.nonNegative == 0)
        #expect(42.nonNegative == 42)
    }

    @Test("A pre-contract v1 record decodes with nil contract fields — history survives")
    func preContractRecordsDecode() throws {
        // Hand-written v1 JSON WITHOUT the 2026-08-29 contract quartet (confirmMs /
        // tier / sinceLastWordMs / fromVoice). Additive optionals must decode as nil
        // and the record must pass the version gate — the alternative (bumping the
        // version for an additive change) would have `load` silently discard every
        // receipt written before the upgrade, destroying the very history the live
        // report exists to fold.
        let json = """
            {"version": 1, "captureID": "\(UUID().uuidString)", "rawText": "old",
             "capturedAt": 0, "committedAt": 0,
             "run": {"route": "local", "rung": "facts", "segmentation": "explicit",
                     "cloudAvailable": false, "hedgeStarted": false,
                     "outcome": "success", "partialCount": 0,
                     "ungroundedDrops": 0, "candidateTitles": []},
             "drafts": [], "createdTaskIDs": [], "mergedTaskIDs": []}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CaptureProvenance.self, from: json)
        #expect(decoded.version == CaptureProvenance.currentVersion)
        #expect(decoded.run.confirmMs == nil)
        #expect(decoded.run.tier == nil)
        #expect(decoded.run.sinceLastWordMs == nil)
        #expect(decoded.run.fromVoice == nil)
    }

    @Test("The contract fields round-trip through the store")
    func contractFieldsRoundTrip() {
        let sut = store()
        let id = UUID()
        var run = CaptureRunTelemetry()
        run.confirmMs = 742
        run.tier = "simple"
        run.sinceLastWordMs = 5003
        run.fromVoice = true
        sut.record(provenance(capture: id, run: run))
        let found = sut.provenance(forCapture: id)
        #expect(found?.run.confirmMs == 742)
        #expect(found?.run.tier == "simple")
        #expect(found?.run.sinceLastWordMs == 5003)
        #expect(found?.run.fromVoice == true)
    }

    // MARK: - The Activity row

    @Test("Commit writes exactly one non-reversible `captured` entry carrying the capture id")
    func commitWritesCapturedEntry() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        brain.provenanceStore = store()  // never the developer's real receipts file
        var d = TaskDraft(
            title: "Book the dentist", category: "Health", confidence: 0.9,
            autonomy: .silent, isJudgmentCall: false, reasoning: "")
        d.category = "Health"

        brain.commit([d], rawCapture: "book the dentist", into: context)

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        let captured = entries.filter { $0.action == ChangeLogEntry.capturedAction }
        #expect(captured.count == 1)
        let entry = try #require(captured.first)
        // Irreversible on purpose: commit IS the confirm, so there is no prior state an
        // undo could restore — and a button that appears to work while doing nothing was
        // the exact `"filed"` mistake this avoids repeating.
        #expect(entry.isReversible == false)
        #expect(entry.taskUUID == nil)
        // The capture id rides `oldValue`, so the detail screen can resolve the run.
        let captureID = try #require(entry.oldValue.flatMap(UUID.init(uuidString:)))
        let captures = try context.fetch(NSFetchRequest<Capture>(entityName: "Capture"))
        #expect(captures.contains { $0.uuid == captureID })
    }

    @Test("A capture whose drafts are all `.ask` still gets a row — the coverage gap it closes")
    func askOnlyCaptureStillGetsARow() throws {
        let context = TestStore.makeContext()
        let brain = AppBrain()
        brain.provenanceStore = store()
        // `.ask` writes no "filed" entry, so before this verb such a capture left NO trace
        // in the Activity feed at all.
        let d = TaskDraft(
            title: "Decide whether to move", category: "Home", confidence: 0.4,
            autonomy: .ask, isJudgmentCall: true, reasoning: "")

        brain.commit([d], rawCapture: "should we move", into: context)

        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        #expect(entries.contains { $0.action == "filed" } == false)
        #expect(entries.filter { $0.action == ChangeLogEntry.capturedAction }.count == 1)
    }

    @Test("`captured` entries never count toward acceptance — the metric they could silently inflate")
    func capturedEntriesNeverCountTowardAcceptance() {
        let filing = ChangeLogEntry(summary: "Filed A", action: "filed", initiatedBy: .ai)
        let undone = ChangeLogEntry(summary: "Filed B", action: "filed", initiatedBy: .ai)
        undone.undone = true
        let captured = ChangeLogEntry(
            summary: "Captured 3 tasks", action: ChangeLogEntry.capturedAction,
            isReversible: false)

        // Without the exclusion this would be 2/3 — the capture receipt voting "kept".
        #expect(Metrics.acceptanceRate(entries: [filing, undone, captured]) == 0.5)
        // Captures alone are not an acceptance signal at all.
        #expect(Metrics.acceptanceRate(entries: [captured]) == nil)
    }

    @Test("`captured` stays VISIBLE in the feed — being seen is the whole point")
    func capturedIsActivityVisible() {
        let captured = ChangeLogEntry(
            summary: "Captured 3 tasks", action: ChangeLogEntry.capturedAction)
        #expect(captured.isActivityVisible)
        #expect(ChangeLogEntry.activityHiddenActions.contains(ChangeLogEntry.capturedAction) == false)
    }
}
