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

    /// **One store's repair must not be the other store's wipe (2026-09-20).**
    ///
    /// There are two stores in one container — the private one, holding every task the
    /// person has ever captured, and the CloudKit shared mirror. `loadPersistentStores`
    /// runs its handler once per store, and the launch self-heal reacted to either
    /// failure by destroying BOTH store files. The mirror is the one that depends on
    /// CloudKit's mood, another person's account and a schema deployed by hand in a web
    /// console; the private store is the one that cannot be recovered. A shared-store
    /// hiccup on someone's commute was a full wipe of their own work.
    @Test("Healing one store leaves the other one standing")
    func aNarrowedResetSparesTheOtherStore() throws {
        cleanUp()
        defer { cleanUp() }
        let dir = location.storeURL.deletingLastPathComponent()
        try writeFakeStore(marker: "everything-i-ever-captured")
        let sharedURL = dir.appendingPathComponent(PersistenceStack.sharedStoreFileName)
        try Data("the-mirror".utf8).write(to: sharedURL)

        let record = PersistenceStack.destroyStore(
            reason: .loadFailure("shared store would not open"), now: now, at: location,
            only: PersistenceStack.sharedStoreFileName)

        #expect(!FileManager.default.fileExists(atPath: sharedURL.path), "the mirror went")
        #expect(
            FileManager.default.fileExists(atPath: location.storeURL.path),
            "the private store — every task the person owns — must still be there")
        #expect(record.destroyedData, "something WAS destroyed, so the receipt says so")

        // The safety copy is still taken over BOTH stores: a wider net is never the
        // wrong call on a path that deletes files.
        let name = try #require(record.backupName)
        let folder = try #require(PersistenceStack.backupURL(named: name, at: location))
        let copied = folder.appendingPathComponent(location.fileName)
        #expect(String(decoding: try Data(contentsOf: copied), as: UTF8.self) == "everything-i-ever-captured")
    }

    /// The narrowed reset must still be honest when there was nothing to remove — a
    /// receipt claiming a wipe that did not happen is the failure `destroyedData` exists
    /// to prevent, and narrowing it is a new way to get that wrong.
    @Test("Healing a store that was never there reports no destruction")
    func aNarrowedResetOnNothingIsSilent() throws {
        cleanUp()
        defer { cleanUp() }
        let dir = location.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeFakeStore(marker: "private-only")

        let record = PersistenceStack.destroyStore(
            reason: .loadFailure("no mirror yet"), now: now, at: location,
            only: PersistenceStack.sharedStoreFileName)

        #expect(!record.destroyedData, "the mirror never existed, so nothing was destroyed")
        #expect(FileManager.default.fileExists(atPath: location.storeURL.path))
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
