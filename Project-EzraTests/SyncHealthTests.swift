//
//  SyncHealthTests.swift
//  Project-EzraTests
//
//  The meter's whole job is to tell three things apart that CloudKit reports almost
//  identically: sync is broken, sync has nothing to sync with, and sync is fine.
//  Confusing the second for the first would put a false alarm in front of the majority
//  of users (nobody is signed into iCloud on a fresh simulator or a new phone), and
//  confusing the first for the second is the silence this file was written to end.
//
//  The classification is pure, so it is tested directly; the notification plumbing is not
//  reachable from a suite and is exercised by reading the diagnostics line on a device.
//

import CloudKit
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Sync health · a silent degrade finally has a meter")
struct SyncHealthTests {

    private func ck(_ code: CKError.Code) -> CKError {
        CKError(code)
    }

    /// The launch-day failure. A build signed for distribution talks to the container's
    /// Production environment, where the schema does not exist until a human deploys it,
    /// and CloudKit answers with an unknown record type. If the meter reads that as a
    /// generic failure, the one error whose fix is a documented button looks like every
    /// other one.
    @Test("An undeployed schema is named, not filed under 'failing'")
    func anUndeployedSchemaIsItsOwnReading() {
        #expect(SyncHealth.reading(for: ck(.unknownItem)) == .schemaMissing)
        #expect(SyncHealth.reading(for: ck(.invalidArguments)) == .schemaMissing)
        #expect(SyncHealth.Reading.schemaMissing.label.contains("SCHEMA"))
    }

    /// CloudKit wraps per-record failures in a partial failure, so the interesting error
    /// is never the outer one. The first shape of this read only the outer code and would
    /// have reported the launch-day failure as an unremarkable "failing".
    @Test("A partial failure is judged by what is inside it")
    func aPartialFailureIsOpened() {
        let inner = ck(.unknownItem)
        let outer = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "x"): inner]])
        #expect(SyncHealth.reading(for: outer) == .schemaMissing)

        let account = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "y"): ck(.notAuthenticated)]])
        #expect(SyncHealth.reading(for: account) == .noAccount)
    }

    /// The most common state in the world, and NOT a fault. A meter that cries about it
    /// is a meter nobody reads by the second week.
    @Test("No iCloud account and no network are conditions, not faults")
    func benignStatesAreNotFailures() {
        for code in [CKError.Code.notAuthenticated, .managedAccountRestricted, .permissionFailure] {
            #expect(SyncHealth.reading(for: ck(code)) == .noAccount)
        }
        for code in [CKError.Code.networkUnavailable, .networkFailure, .serviceUnavailable] {
            #expect(SyncHealth.reading(for: ck(code)) == .offline)
        }
        #expect(SyncHealth.Reading.noAccount > SyncHealth.Reading.failing)
        #expect(SyncHealth.Reading.offline > SyncHealth.Reading.failing)
    }

    /// The server says "Did not find record type" in words before it says so in a code,
    /// and inside some partial failures the words are all there is.
    @Test("The server's own words about a missing record type are read")
    func theMessageIsTheLastResort() {
        let worded = NSError(
            domain: "CKErrorDomain", code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Did not find record type: CD_TaskItem"])
        #expect(SyncHealth.reading(for: worded) == .schemaMissing)

        let unrelated = NSError(
            domain: "NSCocoaErrorDomain", code: 134_060,
            userInfo: [NSLocalizedDescriptionKey: "A Core Data error occurred."])
        #expect(SyncHealth.reading(for: unrelated) == .failing)
    }

    /// A stable key, comparable across runs — never the framework's sentence, which
    /// changes with its payload. The same rule `AppBrain.errorLabel` holds.
    @Test("The error label is a key, not a message")
    func theLabelIsStable() {
        let label = try? #require(SyncHealth.label(for: ck(.networkUnavailable)))
        #expect(label == "CKError.\(CKError.Code.networkUnavailable.rawValue)")
        #expect(SyncHealth.label(for: nil) == nil)
    }

    /// Three stages, one headline, and the headline must be the WORST of them. A working
    /// import beside a failing export is a broken sync, and a meter that led with the
    /// good news would be worse than no meter.
    @Test("A working stage never hides a failing one")
    func theHeadlineIsTheWorstStage() {
        #expect(min(SyncHealth.Reading.working, .schemaMissing) == .schemaMissing)
        #expect(min(SyncHealth.Reading.working, .idle) == .idle)
        #expect(min(SyncHealth.Reading.offline, .failing) == .failing)
    }

    /// "failing" alone does not say whether this is a blip or a month, which is the only
    /// question the reader actually has.
    @Test("The line says when sync last actually landed something")
    @MainActor
    func theLineCarriesRecency() {
        let health = SyncHealth.shared
        guard HouseholdSync.isLive else {
            #expect(health.statusLine == "sync: off")
            return
        }
        // Untouched in a suite (the test host builds no CloudKit container), so the
        // honest reading is idle with no history to report.
        #expect(health.statusLine.contains("sync: "))
        #expect(!health.statusLine.contains("last ok"), "nothing has synced in a test host")
    }
}
