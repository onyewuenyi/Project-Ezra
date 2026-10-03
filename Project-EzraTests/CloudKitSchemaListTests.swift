//
//  CloudKitSchemaListTests.swift
//  Project-EzraTests
//
//  **What the Production CloudKit schema has to contain, kept in step with the model.**
//
//  Deploying the schema to Production is a human pressing a button in a web console, and
//  it is the launch-day failure with no symptom: a distribution build talks to Production,
//  the schema has only ever existed in Development, and until someone deploys it every
//  export fails for every user while the app looks merely quiet (`SyncHealth`,
//  `.schemaMissing`).
//
//  The check that proves it done is "the Production schema lists these record types", so
//  the list has to be right. On 2026-09-20 `TODO.md` named FOUR — the ones the household
//  share carries — and that check would have passed with ten record types missing. Every
//  entity in the private store mirrors, not just the shared ones, so the answer is the
//  whole model.
//
//  This test exists so the list cannot go stale. The schema is frozen at generation 10,
//  which means future model changes are ADDITIVE — a new entity is expected, and it must
//  arrive with a re-deploy and a line in the docs, not silently.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("CloudKit schema · the deploy checklist matches the model")
struct CloudKitSchemaListTests {

    /// Core Data mirrors an entity `Foo` as the record type `CD_Foo`.
    private var expectedRecordTypes: [String] {
        PersistenceStack.model.entities.compactMap(\.name).map { "CD_\($0)" }.sorted()
    }

    /// The list as the docs state it. A mismatch means one of the two moved.
    @Test("Every entity in the model is on the deploy checklist")
    func theChecklistIsComplete() throws {
        let docs = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("docs/app-store-listing.md"),
            encoding: .utf8)

        let missing = expectedRecordTypes.filter { !docs.contains($0) }
        #expect(
            missing.isEmpty,
            """
            The Production deploy checklist in docs/app-store-listing.md is missing \
            \(missing.joined(separator: ", ")). Every entity mirrors to CloudKit, not \
            just the ones the household share carries — a partial list is a gate that \
            passes while sync is broken. Add them, and re-deploy the schema.
            """)
    }

    /// The count is pinned separately and deliberately loudly: a NEW entity is an
    /// additive model change, which the freeze permits, and it needs a Production
    /// re-deploy that nothing else in the build will ever mention.
    @Test("A new entity is a deliberate act, not a surprise")
    func theEntityCountIsPinned() {
        #expect(
            expectedRecordTypes.count == 14,
            """
            The model's entity count changed. That is allowed under the schema freeze \
            (additive only) — but it means the CloudKit Production schema is now behind \
            the app. Re-deploy it, update the list in docs/app-store-listing.md, and \
            move this number.
            """)
    }
}
