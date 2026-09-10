//
//  AdvisorReadingCache.swift
//  Project-Ezra
//
//  **Rung 1, made durable.** (F-07)
//
//  The Advisor's whole latency answer is that a judgment doesn't have to be computed
//  while the person watches — it has to be right when they look. That held inside a
//  launch and broke at the app boundary: the judgment cache lived on `TaskAdvisorStore`'s
//  in-memory entries, so the first task opened every morning regenerated, and the
//  morning open is the one that matters most. §10 billed rung 1 as "$0 · instant ·
//  already built"; this is what makes that sentence true.
//
//  What is cached is exactly what the fingerprint already guards: one `ValidatedReading`
//  per (task, facts fingerprint) — including SILENCE, because a model-judged "nothing"
//  is a judgment too, and re-asking for it every launch is the same waste. A cache hit
//  is served through the reveal gate like any reading, is written to the ledger as
//  `.memory`, and is NOT counted as a new offer (the original reveal counted it; a
//  re-served reading is the same offer seen again).
//
//  A file sidecar, never Core Data (`CaptureProvenance`'s rule), versioned so a schema
//  change to the reading drops the file rather than decoding nonsense, bounded by count,
//  and in-memory under the unit-test host.
//

import Foundation

@MainActor
final class AdvisorReadingCache {

    static let shared = AdvisorReadingCache(fileURL: Sidecar<Record>.url("advisor-readings.json"))

    /// Bump when `ValidatedReading`'s shape changes meaning; a mismatched file is dropped
    /// unread. A miss is always safe; a stale reading served as current is not.
    static let version = 1

    /// Readings kept, newest first. A person's working set is tens of tasks; this is
    /// months of judgments.
    static let maxRecords = 300

    struct Record: Codable, Equatable, Sendable {
        let taskID: UUID
        let fingerprint: Int
        let reading: ValidatedReading
        let judgedAt: Date
    }

    private let sidecar: Sidecar<Record>

    init(fileURL: URL?) {
        sidecar = Sidecar(fileURL: fileURL, maxRecords: Self.maxRecords, layout: .envelope(version: Self.version))
    }

    var all: [Record] { sidecar.all }

    /// The reading judged over exactly these facts, if one was.
    func record(for taskID: UUID, fingerprint: Int) -> Record? {
        all.first { $0.taskID == taskID && $0.fingerprint == fingerprint }
    }

    /// Keep a judgment. One per (task, fingerprint); a later judgment over the same
    /// facts replaces the earlier one. A task keeps only its LATEST fingerprint — older
    /// fingerprints can never be asked for again, so keeping them is just file growth.
    func store(_ reading: ValidatedReading, taskID: UUID, fingerprint: Int, at: Date = Date()) {
        sidecar.upsert(Record(taskID: taskID, fingerprint: fingerprint, reading: reading, judgedAt: at)) {
            $0.taskID == taskID
        }
    }

    /// Drop the cached judgment for exactly these facts — a retry must generate fresh.
    /// Forgets only the one (task, fingerprint) pair so a valid reading on a prior set
    /// of facts is not evicted when a different fingerprint fails and retries.
    func forget(taskID: UUID, fingerprint: Int) {
        sidecar.remove { $0.taskID == taskID && $0.fingerprint == fingerprint }
    }

    /// Drop ALL cached judgments for a task — use only when the task is deleted.
    func forget(taskID: UUID) {
        sidecar.remove { $0.taskID == taskID }
    }

    func reset() { sidecar.reset() }
}
