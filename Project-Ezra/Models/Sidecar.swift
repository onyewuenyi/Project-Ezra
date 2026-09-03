//
//  Sidecar.swift
//  Project-Ezra
//
//  **One JSON file beside the store, written once.** (G1 — the second audit)
//
//  Three records had grown the same home by copying: the capture receipts
//  (`CaptureProvenanceStore`), the human's "no"s (`HumanVerdictStore`) and the Advisor's
//  judgments (`AdvisorReadingCache`) — each with a file URL beside the Core Data store, a
//  lazy in-memory cache, newest-first insertion, a record cap, an ISO-8601 encoder pair,
//  atomic writes that swallow failure by design, and an in-memory mode under the test
//  host. Two of the three were written the same day, from the first. This is the shape,
//  named, so the next local record is a one-liner and cannot drift from the rules:
//
//  - **Never Core Data.** A record that exists to make the product calmer or more
//    honest must never be able to cost the user their data. A failed write loses one
//    record; a failed store load loses everything.
//  - **Beside the store**, so an Xcode ▸ Download Container pulls the sidecar off the
//    device with everything it describes.
//  - **Bounded** — a cap, oldest dropped first — because these ship in Release and
//    write on ordinary use.
//  - **A miss is always safe; a stale record served as current is not.** Two version
//    gates: a per-file envelope (drop the whole file on mismatch) or a per-record filter
//    (drop the rows whose shape was re-meaninged, keep the rest).
//  - **In-memory under XCTest**, so a test that writes a record cannot leave it behind
//    for the next test — or the next launch of the app on that simulator — to find.
//

import Foundation

@MainActor
final class Sidecar<Record: Codable> {

    /// How the file is laid out on disk — kept as a choice so the three existing files
    /// stay byte-compatible with what shipped.
    enum Layout {
        /// A bare `[Record]`; an optional per-record gate drops rows, never the file.
        case array(keep: (Record) -> Bool)
        /// `{ "version": N, "records": [...] }`; a mismatched version drops the file unread.
        case envelope(version: Int)
    }

    private struct Envelope: Codable {
        let version: Int
        let records: [Record]
    }

    let fileURL: URL?
    let maxRecords: Int
    let layout: Layout
    private var cache: [Record]?

    /// `fileURL` nil = in-memory (a test double, or the test host). `Sidecar.url(_:)`
    /// gives the beside-the-store default; it is not a parameter default because it
    /// reads `PersistenceStack.storeURL`, which is main-actor isolated.
    init(fileURL: URL?, maxRecords: Int, layout: Layout = .array(keep: { _ in true })) {
        self.fileURL = fileURL
        self.maxRecords = maxRecords
        self.layout = layout
    }

    /// Beside the Core Data store, by file name — or nil under the unit-test host.
    static func url(_ fileName: String) -> URL? {
        guard !AppBrain.isRunningUnderXCTest else { return nil }
        return PersistenceStack.storeURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Every record, newest first.
    var all: [Record] {
        if let cache { return cache }
        let loaded = fileURL.map(load(from:)) ?? []
        cache = loaded
        return loaded
    }

    /// Insert at the head, dropping any record `replacing` matches and trimming to the cap.
    func upsert(_ record: Record, replacing: (Record) -> Bool) {
        var records = all.filter { !replacing($0) }
        records.insert(record, at: 0)
        if records.count > maxRecords { records.removeLast(records.count - maxRecords) }
        write(records)
    }

    /// Drop the records `matching`; a no-op write is skipped.
    func remove(where matching: (Record) -> Bool) {
        let kept = all.filter { !matching($0) }
        guard kept.count != all.count else { return }
        write(kept)
    }

    func reset() {
        cache = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - File

    private func write(_ records: [Record]) {
        cache = records
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data?
        switch layout {
        case .array: data = try? encoder.encode(records)
        case .envelope(let version): data = try? encoder.encode(Envelope(version: version, records: records))
        }
        guard let data else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load(from url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch layout {
        case .array(let keep):
            return ((try? decoder.decode([Record].self, from: data)) ?? []).filter(keep)
        case .envelope(let version):
            guard let envelope = try? decoder.decode(Envelope.self, from: data), envelope.version == version
            else { return [] }
            return envelope.records
        }
    }
}
