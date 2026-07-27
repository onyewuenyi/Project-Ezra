//
//  StoreBackupTests.swift
//  Project-EzraTests
//
//  The clean-break policy destroys the store on a `schemaGeneration` bump or a failed
//  open. Now that the store holds real captured work rather than seed data, the safety
//  copy and the receipt ARE the policy — a wipe with no copy and no notice is the
//  failure this exists to prevent. So they get tested, not trusted.
//
//  These run against a THROWAWAY `StoreLocation` under the temporary directory, never
//  the app's real store: `destroyStore` unlinks files, and doing that to the sqlite the
//  test host has open trips "BUG IN CLIENT OF libsqlite3: vnode unlinked while in use"
//  — a plausible contributor to this suite's crash-on-exit flakiness. Each test cleans
//  up after itself.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@Suite("Store backup & reset receipt", .serialized)
@MainActor
struct StoreBackupTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let location = PersistenceStack.StoreLocation.temporary("StoreBackupTests")

    /// Put a recognisable stand-in store in the throwaway location, sidecars included.
    private func writeFakeStore(marker: String) throws {
        let dir = location.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let url = dir.appendingPathComponent(location.fileName + suffix)
            try Data((marker + suffix).utf8).write(to: url)
        }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(
            at: location.storeURL.deletingLastPathComponent())
    }

    @Test("A destructive reset copies the store — sidecars included — before deleting it")
    func backsUpBeforeDestroying() throws {
        cleanUp()
        defer { cleanUp() }
        try writeFakeStore(marker: "irreplaceable")

        let record = PersistenceStack.destroyStore(
            reason: .schemaGeneration(from: 9, to: 10), now: now, at: location)

        // The live store is gone…
        #expect(!FileManager.default.fileExists(atPath: location.storeURL.path))
        // …and the receipt says so, with a copy attached.
        #expect(record.destroyedData)
        let name = try #require(record.backupName)
        let folder = try #require(PersistenceStack.backupURL(named: name, at: location))

        // The `-wal` matters: a sqlite copied without it is missing its latest writes.
        for suffix in ["", "-wal", "-shm"] {
            let copied = folder.appendingPathComponent(location.fileName + suffix)
            let contents = try Data(contentsOf: copied)
            #expect(String(decoding: contents, as: UTF8.self) == "irreplaceable" + suffix)
        }
    }

    @Test("A first launch — nothing on disk — reports no destruction and stays silent")
    func firstLaunchIsNotAReset() {
        cleanUp()
        defer { cleanUp() }

        let record = PersistenceStack.destroyStore(
            reason: .schemaGeneration(from: 0, to: 10), now: now, at: location)

        // `destroyedData == false` is what keeps a brand-new install from being told its
        // data was cleared.
        #expect(!record.destroyedData)
        #expect(record.backupName == nil)
    }

    @Test("Backups are bounded — the oldest are pruned, the newest kept")
    func prunesOldBackups() throws {
        cleanUp()
        defer { cleanUp() }

        // One more than the cap, each a second apart so the names sort in time order.
        for offset in 0...PersistenceStack.maxBackups {
            try writeFakeStore(marker: "gen\(offset)")
            PersistenceStack.destroyStore(
                reason: .loadFailure("test"), now: now.addingTimeInterval(Double(offset)),
                at: location)
        }

        let remaining = PersistenceStack.backups(at: location)
        #expect(remaining.count == PersistenceStack.maxBackups)
        // Newest first, and the oldest is the one that went.
        #expect(remaining == remaining.sorted(by: >))
    }

    @Test("The receipt survives a round trip through UserDefaults")
    func receiptRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "StoreBackupTests"))
        defer { defaults.removePersistentDomain(forName: "StoreBackupTests") }

        let record = StoreResetRecord(
            reason: .loadFailure("The model used to open the store is incompatible"),
            date: now, backupName: "store-2026-07-26-120000", destroyedData: true)
        StoreResetLog.write(record, to: defaults)

        let read = try #require(StoreResetLog.pending(in: defaults))
        #expect(read == record)
        #expect(read.reason.detail?.contains("incompatible") == true)

        StoreResetLog.clear(in: defaults)
        #expect(StoreResetLog.pending(in: defaults) == nil)
    }

    @Test("The model digest is stable across reads — it is what the tripwire compares")
    func modelDigestIsStable() {
        // `hashValue` would NOT satisfy this across launches (it is per-process seeded),
        // which is the reason the digest is built from version hashes instead.
        #expect(PersistenceStack.modelDigest == PersistenceStack.modelDigest)
        #expect(PersistenceStack.modelDigest.contains("TaskItem:"))
    }
}
