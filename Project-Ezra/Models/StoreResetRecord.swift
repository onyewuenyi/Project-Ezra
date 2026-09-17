//
//  StoreResetRecord.swift
//  Project-Ezra
//
//  The receipt for a destroyed store. The clean-break schema policy (see
//  `Project_EzraApp.schemaGeneration`) is only honest while the store holds disposable
//  seed data; once it holds real captured work, a wipe that happens SILENTLY is
//  indistinguishable from the app losing your life's admin. So every path that calls
//  `PersistenceStack.destroyStore(reason:)` writes one of these, and `SettingsView`
//  surfaces it — with the safety copy attached — until the user dismisses it.
//
//  Deliberately UserDefaults-backed rather than Core Data: the whole point is to survive
//  the store being deleted.
//

import Foundation

/// Why the local store was destroyed.
enum StoreResetReason: Codable, Equatable {
    /// A deliberate clean-break bump — the stored data's MEANING changed.
    case schemaGeneration(from: Int, to: Int)
    /// The store could not be opened, and the self-heal reset it to keep the app launchable.
    /// In practice this almost always means the model was edited without adding a new
    /// version, leaving lightweight migration no source model to work from.
    case loadFailure(String)
    /// The user asked for it, in Settings ▸ Data (`DataReset`).
    ///
    /// The odd one out, and the reason this enum exists rather than a bool: the other two
    /// are things that HAPPENED TO you, and their card is a warning. This one you chose,
    /// so `isVoluntary` turns the same card into a receipt. What it must keep from the
    /// involuntary arms is the durable part — a record that outlives the store it
    /// describes, carrying the safety copy's name — because "where did my backup go?"
    /// is asked hours later, not while the sheet is still open.
    case userRequested(clearedIdentity: Bool)
    /// The self-heal's own reset (`.loadFailure`) did not fix it — the retry also failed
    /// (a full disk, revoked file protection, a second corruption). Crash-looping here
    /// would brick the app for good, so the launch falls back to an in-memory store for
    /// this session instead: nothing typed tonight is saved, but the app opens, and a
    /// normal on-disk store is tried fresh on the next launch.
    case unrecoverable(String)

    /// Whether the user chose this. Drives the card's tone; never its existence.
    var isVoluntary: Bool { if case .userRequested = self { return true }; return false }

    /// Plain-language explanation, for the Settings card.
    var explanation: String {
        switch self {
        case .schemaGeneration(let from, let to):
            return "the data model moved from generation \(from) to \(to)"
        case .loadFailure:
            return "the saved data couldn't be opened"
        case .userRequested(let clearedIdentity):
            return clearedIdentity ? "you reset everything" : "you cleared all tasks"
        case .unrecoverable:
            return "the saved data couldn't be recovered, even after a reset — tonight's session isn't being saved"
        }
    }

    /// The underlying technical detail, when there is one worth showing.
    var detail: String? {
        switch self {
        case .schemaGeneration, .userRequested: return nil
        case .loadFailure(let message), .unrecoverable(let message): return message
        }
    }
}

/// A single reset, pending acknowledgement.
struct StoreResetRecord: Codable, Equatable {
    let reason: StoreResetReason
    let date: Date
    /// The safety copy's folder name inside `PersistenceStack.backupsDirectory`, or nil if
    /// there was nothing to copy (a first launch) or the copy itself failed.
    let backupName: String?
    /// Whether a store actually existed and was destroyed. False on a first launch, where
    /// the "reset" is a formality and must stay invisible. **A record with
    /// `destroyedData == true` and no `backupName` is the worst case — data lost AND the
    /// copy failed — and must still be shown.**
    let destroyedData: Bool

    /// The safety copy, if it still exists on disk. Main-actor isolated because
    /// `PersistenceStack` is (the target defaults types to `MainActor`), and the only
    /// reader is `SettingsView`.
    @MainActor var backupURL: URL? { backupName.flatMap { PersistenceStack.backupURL(named: $0) } }
}

/// Storage for the pending reset receipt. Injectable defaults, like `MetricsRecorder`.
enum StoreResetLog {
    private static let key = "store.lastReset"

    static func write(_ record: StoreResetRecord, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }

    /// The reset the user has not yet acknowledged, if any.
    static func pending(in defaults: UserDefaults = .standard) -> StoreResetRecord? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoreResetRecord.self, from: data)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
