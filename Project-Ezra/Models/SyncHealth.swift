//
//  SyncHealth.swift
//  Project-Ezra
//
//  Whether sync is actually working, and when it last did.
//
//  **Why this exists (2026-09-20).** `HouseholdSync.isLive` flipped on 2026-09-12 and
//  from that day the app has had a second copy of the user's data in the cloud — with no
//  meter of any kind. `NSPersistentCloudKitContainer` degrades in total silence by
//  design: it retries, it backs off, and an app whose sync has never once succeeded looks
//  exactly like an app whose sync has nothing to do. The only existing listener
//  (`HouseholdSharing`) watches for ONE successful import and discards every other event,
//  including every failure.
//
//  This codebase has already paid for that shape once. `EmbeddingStore.sentenceEmbedding`
//  returned nil on its first call, froze, and left retrieval lexical-only for a MONTH —
//  and the lesson written down afterwards was that *a graceful degrade with no meter is a
//  feature that can be off for a month*. Sync is a far larger surface than retrieval, and
//  it is about to meet its highest-risk moment.
//
//  **The launch-day failure this was built for.** A development-signed build talks to the
//  CloudKit container's DEVELOPMENT environment. TestFlight and the App Store talk to
//  PRODUCTION, where the schema does not exist until someone presses Deploy Schema
//  Changes in the console (`TODO.md`). So the first build real users ever run is the first
//  build pointed at an environment that has never seen a `CD_TaskItem` — every export
//  fails, nothing syncs, and without this file nothing anywhere says a word. That failure
//  has a recognisable shape, and `Reading.schemaMissing` names it rather than leaving a
//  developer to decode a partial-failure error at midnight.
//
//  Local only, never transmitted, DEBUG-surfaced — the same charter as `ModelMetrics` and
//  `IntelligenceLedger`. **Deliberately not user-facing.** "Sync is broken" on a customer
//  screen is an anxiety and a thing to manage, which is principle 10's whole complaint;
//  the one place a person needs a sentence is when they tap Invite, and
//  `HouseholdSharingError.naming` already owns that. If that changes, it changes there.
//

import CloudKit
import CoreData
import Foundation
import Observation

@Observable final class SyncHealth {

    @MainActor static let shared = SyncHealth()

    /// What the meter can say about a stage. Ordered by how much it should worry the
    /// person reading it, worst first, because `worst(of:)` picks a headline from three.
    enum Reading: Int, Comparable {
        /// The record types this app writes do not exist in the environment it is
        /// talking to. On a TestFlight or App Store build this means exactly one thing:
        /// the schema was never deployed to Production.
        case schemaMissing = 0
        /// A real failure that is not one of the benign ones below.
        case failing = 1
        /// Nobody is signed into iCloud, so there is nothing to sync WITH. Not a fault,
        /// and must never be reported as one — it is the most common state there is.
        case noAccount = 2
        /// The network is away. Sync resumes on its own.
        case offline = 3
        /// Nothing has happened yet this launch.
        case idle = 4
        /// A stage completed without error.
        case working = 5

        static func < (a: Reading, b: Reading) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .schemaMissing: return "SCHEMA NOT DEPLOYED"
            case .failing: return "failing"
            case .noAccount: return "no iCloud account"
            case .offline: return "offline"
            case .idle: return "idle"
            case .working: return "ok"
            }
        }
    }

    /// One stage of the container's work. Three exist: setup, import, export.
    struct Stage {
        var reading: Reading = .idle
        var lastSucceededAt: Date?
        /// A STABLE label for the error, never the framework's message. The same
        /// distinction `AppBrain.errorLabel` draws: a key you can compare across runs,
        /// not a sentence that changes with the payload.
        var errorLabel: String?
        var failureCount = 0
    }

    private(set) var setup = Stage()
    private(set) var importing = Stage()
    private(set) var exporting = Stage()

    private var observer: NSObjectProtocol?

    private init() {}

    /// Start watching a loaded container. A plain (non-CloudKit) container leaves the
    /// meter inert and reading `idle`, which is the truth for the unit-test host and for
    /// any build where sync is off.
    func observe(_ container: NSPersistentContainer) {
        guard let cloud = container as? NSPersistentCloudKitContainer, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: cloud, queue: .main
        ) { [weak self] notification in
            guard
                let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event
            else { return }
            MainActor.assumeIsolated { self?.record(event) }
        }
    }

    /// Fold one event in. Events arrive twice — once when a stage starts and once when it
    /// ends — and only the end carries a verdict, so a start is ignored rather than
    /// recorded as a failure-in-progress.
    func record(_ event: NSPersistentCloudKitContainer.Event) {
        guard event.endDate != nil else { return }
        var stage = self[event.type]
        if event.succeeded {
            stage.reading = .working
            stage.lastSucceededAt = event.endDate
            stage.errorLabel = nil
            stage.failureCount = 0
        } else {
            stage.reading = Self.reading(for: event.error)
            stage.errorLabel = Self.label(for: event.error)
            stage.failureCount += 1
        }
        self[event.type] = stage
    }

    /// A store that would not open even after the launch self-heal reset it. Recorded
    /// rather than crashed on, for the shared mirror only — see the handler in
    /// `Project_EzraApp`. It never arrives as a container event, because the container
    /// never got far enough to emit one.
    func recordSetupFailure(_ error: Error) {
        setup.reading = Self.reading(for: error)
        setup.errorLabel = Self.label(for: error)
        setup.failureCount += 1
    }

    private subscript(type: NSPersistentCloudKitContainer.EventType) -> Stage {
        get {
            switch type {
            case .setup: return setup
            case .import: return importing
            case .export: return exporting
            @unknown default: return exporting
            }
        }
        set {
            switch type {
            case .setup: setup = newValue
            case .import: importing = newValue
            case .export: exporting = newValue
            @unknown default: exporting = newValue
            }
        }
    }

    // MARK: - Reading an error

    /// The worst thing any stage is currently saying. `Reading` is ordered worst-first so
    /// this is a `min`, and a headline never hides a schema failure behind a working import.
    var headline: Reading {
        min(min(setup.reading, importing.reading), exporting.reading)
    }

    /// The DEBUG diagnostics line. Names the stage that is worst, and when sync last
    /// actually landed anything — because "failing" without "last worked 3 days ago" does
    /// not tell you whether this is a blip or a month.
    var statusLine: String {
        guard HouseholdSync.isLive else { return "sync: off" }
        var parts = ["sync: \(headline.label)"]
        if let last = [setup, importing, exporting].compactMap(\.lastSucceededAt).max() {
            parts.append("last ok \(Self.elapsed(since: last))")
        } else if headline != .idle {
            parts.append("never succeeded")
        }
        if let label = [setup, importing, exporting].compactMap(\.errorLabel).first {
            parts.append(label)
        }
        return parts.joined(separator: " · ")
    }

    /// A missing record type is the one failure whose cause is a human step rather than a
    /// condition, so it is worth pulling out of the partial-failure soup it arrives in.
    /// CloudKit spells it several ways depending on where the request died, and the
    /// message is the only reliable tell inside a `partialFailure`.
    static func reading(for error: Error?) -> Reading {
        guard let error else { return .failing }
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated, .managedAccountRestricted, .permissionFailure:
                return .noAccount
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
                return .offline
            case .unknownItem, .invalidArguments:
                return .schemaMissing
            case .partialFailure:
                let inner = (ck.partialErrorsByItemID?.values).map(Array.init) ?? []
                if inner.contains(where: { reading(for: $0) == .schemaMissing }) { return .schemaMissing }
                if inner.contains(where: { reading(for: $0) == .noAccount }) { return .noAccount }
                return .failing
            default:
                break
            }
        }
        // The message is the last resort and the most reliable one for an undeployed
        // schema: the server says so in words before it says so in a code.
        let text = error.localizedDescription.lowercased()
        if text.contains("record type") || text.contains("unknown field") { return .schemaMissing }
        return .failing
    }

    /// A stable key for the error, comparable across runs. Never the message.
    static func label(for error: Error?) -> String? {
        guard let error else { return nil }
        if let ck = error as? CKError { return "CKError.\(ck.code.rawValue)" }
        return "\((error as NSError).domain).\((error as NSError).code)"
    }

    private static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}
