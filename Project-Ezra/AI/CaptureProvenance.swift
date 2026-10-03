//
//  CaptureProvenance.swift
//  Project-Ezra
//
//  The receipt for one capture→N-tasks run: which rung answered, which arm won, what it
//  cost, and the full `[TaskDraft]` the commit was built from.
//
//  **Why this exists.** Every fact here was already computed and then thrown away.
//  `AppBrain.TriageRun` carried only drafts/candidates, so route, engine, winning arm
//  (`CaptureTriageRace.HedgedResult.arm` was read NOWHERE), outcome, latency, retrieval,
//  partial cadence, token count and ungrounded drops all died at the `return`. What did
//  survive went into `ModelMetrics.shared.stats[.captureTriage]` — global, last-write-wins
//  counters the next capture overwrites — so the app could tell you the average and never
//  the instance. And `AppBrain.commit` clears `capture.parkedDrafts`, which destroys the
//  richest provenance object in the system (`aiOriginal`, `edgeProposals` with their
//  confidences, `ownerBasis`, `dueReason`, `provisionalSource`, `editedFields`) at the
//  exact moment the tasks are born.
//
//  **Why it is NOT Core Data.** Adding an attribute moves `PersistenceStack.modelDigest`,
//  which trips `Project_EzraApp`'s tripwire unless `schemaGeneration` bumps — and a bump
//  destroys a store that now holds real daily-use work. A diagnostic must never be able to
//  cost the user their data. So this is a file sidecar, the same shape `StoreResetRecord`
//  uses for the same reason, and `.xcdatamodeld` is untouched.
//
//  **It records forward only.** A capture committed before this shipped has no record and
//  gets none: the run facts are unrecoverable, and reconstructing a plausible-looking one
//  from what the store happens to hold would be a fabricated measurement — the exact
//  failure the eval seams exist to prevent. `nil` reads as "not recorded", never as zero.
//

import Foundation

// MARK: - Run telemetry

/// The facts about HOW a parse ran, gathered inside `AppBrain.triage` where they exist and
/// carried out on `TriageRun` — previously the point at which all of this was lost.
///
/// Separate from `CaptureProvenance` because it is known at PARSE time, while the record is
/// assembled at COMMIT time from this plus the drafts, the created tasks and the sampled
/// metrics. A capture can be parsed several times and committed once.
struct CaptureRunTelemetry: Codable, Equatable {
    // Routing — the decision, not merely its outcome.
    var route: String = CaptureRoute.local.metricName
    var rung: String = IntelligenceRung.facts.rawValue
    var segmentation: String = ""
    /// The reasoning level this ramble bought, nil when it ran reasoning-free.
    var reasoningDepth: String?
    var cloudAvailable = false
    /// Why this capture escalated past the deterministic read (2026-08-29 policy), nil
    /// when the local read was revealed as-is. The receipt's answer to "why did this
    /// capture cost a cloud call?" — the number the escalation signals get tuned on.
    var escalationReason: String?

    // Which model actually answered. Nil on the deterministic arm — which is a fact
    // about the run, not a gap in it.
    var engineName: String?
    var modelIdentifier: String?
    var modelVersion: String?
    /// `primary` or `hedge` — which arm of `CaptureTriageRace` produced the answer.
    var armWon: String?
    var hedgeStarted = false
    /// success · salvaged · timedOut · cancelled · failed(label). Salvaged is a SERVED
    /// user, not a failure (see `ModelDeadline.captureSeconds`), and reads that way here.
    var outcome: String = "success"

    // Cost.
    var parseMs: Int?
    var retrievalMs: Int?
    var firstPartialMs: Int?
    var partialCount = 0

    // The performance contract's clock (2026-08-29). All optional and stamped at
    // reveal, so a run that never revealed (cancelled, superseded) carries honest nils.
    /// `submittedAt` → `revealedAt`, orb dwell INCLUDED — the contract's one clock,
    /// perceived latency rather than pipeline latency. Nil = predates the contract or
    /// the reveal never fired.
    var confirmMs: Int?
    /// Measurement bucket (`CapturePerformanceContract.Tier.rawValue`), derived from
    /// the exact text the read came from. Measurement-only — never routing input.
    var tier: String?
    /// Voice only: ms from the last transcript delta to capture-end. ≈5000 by
    /// construction when the silence window fired; shorter when the orb was tapped.
    /// OUTSIDE the contract's clock — this is the UX parameter the silence window is
    /// tuned on, not a pipeline cost.
    var sinceLastWordMs: Int?
    /// Whether this capture came through `finishListening` — the cohort key separating
    /// dwell-floored voice reveals from instant typed ones.
    var fromVoice: Bool?

    // Pipeline effects.
    var ungroundedDrops = 0
    /// The retrieval package the model was actually shown — the only ids it was allowed
    /// to cite for a duplicate/child proposal.
    var candidateTitles: [String] = []

    /// The deterministic route's telemetry: no model ran, and saying so is the point.
    static func local(segmentation: String, cloudAvailable: Bool) -> CaptureRunTelemetry {
        CaptureRunTelemetry(
            route: CaptureRoute.local.metricName, rung: CaptureRoute.local.rung.rawValue,
            segmentation: segmentation, cloudAvailable: cloudAvailable)
    }
}

// MARK: - The record

/// One committed capture, in full. Versioned per `ParkedDrafts`: an unrecognized version is
/// DISCARDED rather than decoded into something that means the wrong thing.
struct CaptureProvenance: Codable, Equatable {
    /// Bump ONLY when a field's MEANING changes. Additive optional fields (the
    /// 2026-08-29 contract quartet on `CaptureRunTelemetry`) decode as nil from older
    /// records — synthesized `Codable` treats a missing key on an optional as nil — and
    /// MUST NOT bump this: `load` drops every record whose version mismatches, so a
    /// bump for an additive change would throw away the whole pre-upgrade history to
    /// protect it from nothing.
    static let currentVersion = 1

    var version = CaptureProvenance.currentVersion
    var captureID: UUID
    var rawText: String
    var capturedAt: Date
    var committedAt: Date

    var run: CaptureRunTelemetry

    // Sampled from `ModelMetrics`'s last-write-wins fields at commit. Optional, not
    // defaulted: the token count lands from a detached `Task` and may not have arrived
    // yet, and "pending" must not be recorded as zero.
    var provisionalMs: Int?
    var commitMs: Int?
    var promptTokens: Int?
    var contextSize: Int?

    /// The committed drafts, verbatim. `TaskDraft` is already `Codable` and already carries
    /// the whole per-task story, so this reuses it rather than minting a parallel snapshot
    /// type that could drift away from what actually shipped.
    var drafts: [TaskDraft]
    var createdTaskIDs: [UUID]
    var mergedTaskIDs: [UUID]

    /// The one-line DIAGNOSTIC summary — route, model id, seconds, outcome. For reports
    /// and the provenance detail; never the feed (see `bylineLine`).
    var summaryLine: String {
        var parts: [String] = [run.modelIdentifier.map { "cloud(\($0))" } ?? run.route]
        if let ms = run.parseMs { parts.append(String(format: "%.1fs", Double(ms) / 1000)) }
        if run.outcome != "success" { parts.append(run.outcome) }
        return parts.joined(separator: " · ")
    }

    /// The Activity row's byline, in the product's words (2026-09-18). The row used to
    /// carry `summaryLine` — "local · 0.0s", or "cloud(gemini-…) · 1.2s" — a metric name,
    /// a latency and a VENDOR MODEL ID in the customer's feed, against the rule that the
    /// customer never hears "AI" or a vendor name. What the person can use is where
    /// their words were read (`DataBoundary`'s own vocabulary) and whether the read was
    /// cut short; the numbers stay in the provenance detail.
    var bylineLine: String {
        let route = CaptureRoute(rawValue: run.route)
        let place = route?.transmitsRawCapture == true ? "Read in the cloud" : "Read on your device"
        switch run.outcome {
        case "success": return place
        case "salvaged", "timedOut": return "\(place) · cut short"
        default: return "\(place) · fell back"
        }
    }
}

// MARK: - Storage

/// The provenance sidecar — one `Sidecar` of receipts, newest-first, hard-capped.
///
/// The cap is not tidiness: this ships in Release and writes on every commit, so an
/// unbounded log would grow with use forever inside the user's container. 200 records is
/// far more history than a diagnostic needs and still a small file. Rows whose shape was
/// re-meaninged (`version`) are dropped on load, never the file — a future field addition
/// must not erase the history before it.
@MainActor
final class CaptureProvenanceStore {
    static let shared = CaptureProvenanceStore()

    /// How many committed captures to keep. Oldest are dropped first.
    static let maxRecords = 200

    private let sidecar: Sidecar<CaptureProvenance>

    /// Injectable location, like `PersistenceStack.StoreLocation` — a test must never write
    /// to (or trim) the real user's file. `nil` means the default beside the store.
    init(fileURL: URL? = nil) {
        sidecar = Sidecar(
            fileURL: fileURL ?? Self.defaultURL, maxRecords: Self.maxRecords,
            layout: .array(keep: { $0.version == CaptureProvenance.currentVersion }))
    }

    /// Beside the Core Data store, so an Xcode ▸ Download Container pulls the receipts
    /// off the device along with everything else they describe.
    static var defaultURL: URL {
        PersistenceStack.storeURL.deletingLastPathComponent()
            .appendingPathComponent("capture-provenance.json")
    }

    /// Every record, newest first.
    var all: [CaptureProvenance] { sidecar.all }

    func provenance(forCapture id: UUID) -> CaptureProvenance? {
        all.first { $0.captureID == id }
    }

    /// Persist one run. Replaces any existing record for the same capture — a capture is
    /// committed once, but a seam that re-commits must not leave two conflicting receipts.
    func record(_ provenance: CaptureProvenance) {
        sidecar.upsert(provenance) { $0.captureID == provenance.captureID }
    }

    func reset() { sidecar.reset() }
}

// MARK: - Sentinel bridging

extension Int {
    /// `ModelMetrics` uses `-1` for "never measured" on its `last*` fields. A receipt has
    /// to keep that distinction as `nil`: "not measured" and "measured as zero" are
    /// different findings, and collapsing them would print a confident 0ms for a parse
    /// that never ran.
    var nonNegative: Int? { self < 0 ? nil : self }
}
