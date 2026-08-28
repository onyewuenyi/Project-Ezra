//
//  Relationship.swift
//  Project-Ezra
//
//  The task graph's one durable edge type. A task carries a list of `Relationship`
//  value structs (JSON-encoded in `TaskItem.relationshipsData`), absorbing what used
//  to be two separate stores — `blockersData` and `parentTaskID` — into a single
//  versioned blob. Every graph consumer already operates on the in-memory
//  `[TaskItem]` set, so an edge is a value on the task, never a second Core Data
//  entity to fetch.
//
//  Kinds:
//  - `.blocks`    — something this task is blocked BY (waits on). A tracked
//                   dependency when `targetID` is set; an untracked external wait
//                   (`note`, `targetID == nil`) otherwise. Backs the `blockers`
//                   derived view, so all the old Blocker semantics survive verbatim.
//  - `.parent`    — this task is a step under `targetID` (Split-Into-Subtasks).
//  - `.related`   — a soft association (reserved).
//
//  Live edges are the ONLY edges: a rejected suggestion is not a dismissed edge on
//  either task — it's a `RelationshipSuppression` in the pair-owned suppression set
//  (see `RelationshipSuppression.swift`). The old `dismissed` tombstones (and the
//  tombstone-only `.duplicate` kind) are gone, so every derived view and guard reads
//  the list unfiltered.
//
//  **Mutation choke point (constitutional):** views and engines NEVER assign
//  `relationships` directly — every write funnels through the `TaskMutations`
//  helpers, the same law as the `status` setter.
//
//  Blob-over-entity expiry condition (deliberate, recorded): revisit this storage
//  when a consumer needs to query edges without the task set already loaded, when
//  `Kind` exceeds ~6 cases, or when household sync needs edge-level granularity.
//

import Foundation
import OSLog

struct Relationship: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case blocks, parent, related }

    /// Who authored the edge. A human edge structurally cannot carry a confidence
    /// and an inferred edge cannot omit one — the illegal states the old
    /// `provenance` + `confidence` pair left to call-site discipline are
    /// unrepresentable here.
    enum Origin: Codable, Hashable {
        case human
        case inferred(confidence: Double)

        var isHuman: Bool { if case .human = self { return true }; return false }

        /// The model's confidence for an inferred edge; nil for a human one.
        var inferredConfidence: Double? {
            if case .inferred(let confidence) = self { return confidence }
            return nil
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    /// The other task's `TaskItem.uuid`. Nil ONLY for an external wait (`kind == .blocks`
    /// with a `note`).
    var targetID: UUID?
    /// The external-wait phrase, in the user's own words. Set iff a `.blocks` edge has
    /// no `targetID`.
    var note: String?
    var origin: Origin
    var createdAt: Date = Date()

    // MARK: - Convenience constructors (mirror the old `Blocker` factory verbs)

    static func blocks(taskID: UUID, origin: Origin = .human) -> Relationship {
        Relationship(kind: .blocks, targetID: taskID, note: nil, origin: origin)
    }

    static func externalWait(_ note: String?, origin: Origin = .human) -> Relationship {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Relationship(
            kind: .blocks, targetID: nil, note: (trimmed?.isEmpty == false) ? trimmed : nil,
            origin: origin)
    }

    static func parent(taskID: UUID, origin: Origin = .human) -> Relationship {
        Relationship(kind: .parent, targetID: taskID, note: nil, origin: origin)
    }

    // MARK: - Invariant validation (DEBUG-asserted on encode, callable from tests)

    /// The set of invariants every persisted relationship list must hold. Asserted on
    /// encode in DEBUG and callable directly from `RelationshipTests`:
    /// - no self-edges,
    /// - no duplicate (kind, targetID) pairs,
    /// - `targetID == nil` only on a `.blocks` edge (an external wait),
    /// - an inferred confidence stays in 0…1.
    /// (The old human⇒confidence-1.0 rule is unrepresentable now — `Origin.human`
    /// carries no confidence at all.)
    /// Returns the first violation message, or nil when the list is valid. `owner` is the
    /// owning task's uuid, so a self-edge can be caught.
    static func firstViolation(in relationships: [Relationship], owner: UUID? = nil) -> String? {
        var keys = Set<String>()
        for rel in relationships {
            if let owner, rel.targetID == owner {
                return "self-edge (\(rel.kind.rawValue)) on \(owner)"
            }
            if rel.targetID == nil && rel.kind != .blocks {
                return "nil targetID on non-blocks edge (\(rel.kind.rawValue))"
            }
            if let confidence = rel.origin.inferredConfidence, !(0...1).contains(confidence) {
                return "inferred edge with confidence \(confidence) outside 0…1"
            }
            if let target = rel.targetID {
                let key = "\(rel.kind.rawValue):\(target.uuidString)"
                if !keys.insert(key).inserted {
                    return "duplicate edge \(key)"
                }
            }
        }
        return nil
    }

    /// One logger for this invariant — same rationale as
    /// `NSManagedObjectContext.saveChanges()`: a violation must leave a trace in
    /// every build, including the Release the device runs. `assertionFailure`
    /// alone left the check DEBUG-only, so a bug that slipped a malformed edge
    /// (a self-blocker, a duplicate) past the mutation choke point in Release
    /// persisted `relationshipsData` silently — no crash, no log, nothing to
    /// find later.
    private static let log = Logger(subsystem: "com.projectezra.app", category: "relationships")

    static func validate(_ relationships: [Relationship], owner: UUID? = nil) {
        guard let violation = firstViolation(in: relationships, owner: owner) else { return }
        log.error("Relationship invariant violated: \(violation, privacy: .public)")
        assertionFailure("Relationship invariant violated: \(violation)")
    }
}

// MARK: - Trust-semantics accessors

/// Named filters so call sites read their trust semantics instead of inlining
/// origin predicates.
extension Sequence where Element == Relationship {
    /// Edges a human authored (or explicitly confirmed at creation).
    func humanConfirmed() -> [Relationship] { filter { $0.origin.isHuman } }
    /// Edges the AI inferred (each carries its confidence).
    func inferred() -> [Relationship] { filter { !$0.origin.isHuman } }
}

// MARK: - Versioned storage envelope

/// The on-disk shape of `TaskItem.relationshipsData`: a version tag plus the edge
/// list. The pre-launch clean-break ignores `v`, but persisting it now means old
/// blobs stay decodable forever — the single migration hook if the shape ever
/// changes post-launch.
enum RelationshipStore {
    /// v2: `origin` (human | inferred(confidence)) replaced `provenance` +
    /// `confidence`, and `dismissed` tombstones left the type entirely (suppression
    /// is pair-owned — see `RelationshipSuppression`).
    static let currentVersion = 2

    private struct Envelope: Codable {
        var v: Int
        var items: [Relationship]
    }

    static func encode(_ relationships: [Relationship]) -> Data? {
        try? JSONEncoder().encode(Envelope(v: currentVersion, items: relationships))
    }

    static func decode(_ data: Data) -> [Relationship] {
        // `encode` has only ever written an `Envelope`, and the clean-break policy destroys
        // the store on any shape change — so a bare-array blob has never been persisted.
        (try? JSONDecoder().decode(Envelope.self, from: data))?.items ?? []
    }
}
