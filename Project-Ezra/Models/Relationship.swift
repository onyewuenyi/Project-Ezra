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
//  - `.duplicate` — a rejected/dismissed dedupe suggestion, kept as a tombstone so
//                   the same pair is never re-proposed (Phase 2).
//  - `.related`   — a soft association (reserved).
//
//  **Mutation choke point (constitutional):** views and engines NEVER assign
//  `relationships` directly — every write funnels through the `TaskMutations`
//  helpers, the same law as the `status` setter. `dismissed` edges are tombstones:
//  they carry NO live semantics (never a blocker, never a parent) and exist only so
//  a suggestion is never re-proposed.
//

import Foundation

struct Relationship: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case blocks, parent, duplicate, related }
    enum Provenance: String, Codable { case ai, human }

    var id: UUID = UUID()
    var kind: Kind
    /// The other task's `TaskItem.uuid`. Nil ONLY for an external wait (`kind == .blocks`
    /// with a `note`).
    var targetID: UUID?
    /// The external-wait phrase, in the user's own words. Set iff a `.blocks` edge has
    /// no `targetID`.
    var note: String?
    var provenance: Provenance
    /// The AI's confidence in this edge, 0…1. Always `1.0` for a `.human` edge.
    var confidence: Double
    /// Tombstone marker: a dismissed edge is never re-proposed and has no live
    /// semantics (excluded from `blockers`, `parentTaskID`, and every derived view).
    var dismissed: Bool = false
    var createdAt: Date = Date()

    // MARK: - Convenience constructors (mirror the old `Blocker` factory verbs)

    static func blocks(
        taskID: UUID, provenance: Provenance = .human, confidence: Double = 1.0
    ) -> Relationship {
        Relationship(
            kind: .blocks, targetID: taskID, note: nil, provenance: provenance,
            confidence: provenance == .human ? 1.0 : confidence)
    }

    static func externalWait(_ note: String?, provenance: Provenance = .human) -> Relationship {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Relationship(
            kind: .blocks, targetID: nil, note: (trimmed?.isEmpty == false) ? trimmed : nil,
            provenance: provenance, confidence: 1.0)
    }

    static func parent(
        taskID: UUID, provenance: Provenance = .human, confidence: Double = 1.0
    ) -> Relationship {
        Relationship(
            kind: .parent, targetID: taskID, note: nil, provenance: provenance,
            confidence: provenance == .human ? 1.0 : confidence)
    }

    // MARK: - Invariant validation (DEBUG-asserted on encode, callable from tests)

    /// The set of invariants every persisted relationship list must hold. Asserted on
    /// encode in DEBUG and callable directly from `RelationshipTests`:
    /// - no self-edges,
    /// - no duplicate LIVE (kind, targetID) pairs (tombstones may duplicate a live pair),
    /// - `targetID == nil` only on a `.blocks` edge (an external wait),
    /// - `confidence == 1.0` on every `.human` edge.
    /// Returns the first violation message, or nil when the list is valid. `owner` is the
    /// owning task's uuid, so a self-edge can be caught.
    static func firstViolation(in relationships: [Relationship], owner: UUID? = nil) -> String? {
        var liveKeys = Set<String>()
        for rel in relationships {
            if let owner, rel.targetID == owner {
                return "self-edge (\(rel.kind.rawValue)) on \(owner)"
            }
            if rel.targetID == nil && rel.kind != .blocks {
                return "nil targetID on non-blocks edge (\(rel.kind.rawValue))"
            }
            if rel.provenance == .human && rel.confidence != 1.0 {
                return "human edge with confidence \(rel.confidence) ≠ 1.0"
            }
            guard !rel.dismissed else { continue }
            if let target = rel.targetID {
                let key = "\(rel.kind.rawValue):\(target.uuidString)"
                if !liveKeys.insert(key).inserted {
                    return "duplicate live edge \(key)"
                }
            }
        }
        return nil
    }

    static func validate(_ relationships: [Relationship], owner: UUID? = nil) {
        if let violation = firstViolation(in: relationships, owner: owner) {
            assertionFailure("Relationship invariant violated: \(violation)")
        }
    }
}

// MARK: - Versioned storage envelope

/// The on-disk shape of `TaskItem.relationshipsData`: a version tag plus the edge
/// list. The pre-launch clean-break ignores `v`, but persisting it now means old
/// blobs stay decodable forever — the single migration hook if the shape ever
/// changes post-launch.
enum RelationshipStore {
    static let currentVersion = 1

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
