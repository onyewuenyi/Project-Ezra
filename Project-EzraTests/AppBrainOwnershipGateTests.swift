//
//  AppBrainOwnershipGateTests.swift
//  Project-EzraTests
//
//  The ownership gate (`AppBrain.applyOwnershipGate`) is what makes "unowned"
//  zero-friction for solo installs: it only ever triggers when a household actually
//  exists. It sets only the `ownerPending` flag — the status stays Active, and
//  "unowned" derives from the flag. These tests lock that down, plus the commit
//  behavior that must treat a pending owner like a pending judgment call: never
//  silently logged as handled.
//

import Foundation
import CoreData
import Testing

@testable import Project_Ezra

@Suite("Ownership gate")
struct AppBrainOwnershipGateTests {

    private func draft(
        _ title: String, confidence: Double = 0.9,
        isJudgmentCall: Bool = false, blockedBy: String? = nil, ownerName: String? = nil
    ) -> TaskDraft {
        IntentResolver.resolve(
            TaskIntent(
                title: title, category: "Home", personReference: ownerName,
                blockerPhrase: blockedBy, confidence: confidence,
                isJudgmentCall: isJudgmentCall, reasoning: ""))
    }

    @Test("Solo mode (no household) is a complete no-op")
    func soloModeNoOp() {
        var drafts = [draft("Water the plants")]
        AppBrain.applyOwnershipGate(to: &drafts, hasHousehold: false)
        #expect(!drafts[0].ownerPending)
    }

    @Test("A household flags an undelegated confident draft as unowned — a flag, not a status move")
    func householdFlagsUndelegatedConfident() {
        var drafts = [draft("Water the plants")]
        AppBrain.applyOwnershipGate(to: &drafts, hasHousehold: true)
        #expect(drafts[0].ownerPending)
        #expect(drafts[0].proposedStatus == .inbox)  // always-confirm: everything lands in Inbox
    }

    @Test("A draft with a detected owner is left untouched even in a household")
    func detectedOwnerUntouched() {
        var drafts = [draft("Book venue", ownerName: "Sarah")]
        AppBrain.applyOwnershipGate(to: &drafts, hasHousehold: true)
        #expect(!drafts[0].ownerPending)
    }

    @Test("A judgment/low-confidence draft is left untouched — only silent-tier filings gate")
    func judgmentDraftUntouched() {
        var drafts = [draft("should I quit", isJudgmentCall: true)]
        AppBrain.applyOwnershipGate(to: &drafts, hasHousehold: true)
        #expect(!drafts[0].ownerPending)
    }

    @Test("A confident, undelegated draft with a dependency is still flagged unowned (independent axes)")
    func blockedDraftStillGated() {
        // Blocked and unowned are orthogonal: a filing that also names a dependency is
        // still unowned, and reads as Blocked until cleared, then Up for Grabs. The
        // gate doesn't special-case a detected blocker.
        var drafts = [draft("Book flights", blockedBy: "passport")]
        AppBrain.applyOwnershipGate(to: &drafts, hasHousehold: true)
        #expect(drafts[0].ownerPending)
    }

    // MARK: - Commit integration (needs a NSManagedObjectContext)

    @MainActor private func makeContext() throws -> NSManagedObjectContext {
        return TestStore.makeContext()
    }

    @Test("commit() never logs a change-log entry for an unowned landing")
    @MainActor func commitSkipsTrailForUnowned() throws {
        let context = try makeContext()
        let brain = AppBrain()
        var unowned = draft("Water the plants")
        unowned.ownerPending = true
        let created = brain.commit([unowned], rawCapture: "", into: context)

        #expect(created[0].ownerPending)
        let entries = try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
        #expect(!entries.contains { $0.taskUUID == created[0].uuid })
    }
}
