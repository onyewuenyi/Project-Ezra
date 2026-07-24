//
//  RelationshipSuppression.swift
//  Project-Ezra
//
//  Pair-owned suppression: the durable record of "the user said NO to this
//  suggestion", kept OUT of the edge list so a rejection is never a phantom edge
//  (the old dismissed-tombstone split — no live semantics but real retrieval
//  semantics — is gone; live edges are the only edges).
//
//  Two key forms, because the capture path can never match a pair key — at capture
//  the drafted side has no pre-existing id (every capture mints a new task), so a
//  suppression written for (previousTask, target) would never match
//  (newDraft, target):
//  - **Pair form** (`pairKey`): both tasks exist. Duplicate suppression is symmetric
//    by construction (canonical min:max key), so the same false pair can't come back
//    from the other side. Parent suppression stays directional ("A is not a child of
//    B" doesn't imply the reverse), so its key is the ordered child:parent pair.
//  - **Capture form** (`targetID` + `normalizedTitle`): the user rejected a proposal
//    from a DRAFT against `targetID`. Keyed on the normalized DRAFT TITLE — never the
//    raw capture text (a Ramble is hundreds of freeform words that would never
//    exact-match twice; the draft title is the stable model-produced artifact).
//
//  The set is small and read once per capture, but that's an assumption, not a
//  property — so it's bounded: rows expire past `maxAge`, and rows whose target
//  task no longer exists are pruned lazily at load.
//

import CoreData
import Foundation

/// One suppression, as a value — what crosses into `IntentResolver` per capture.
struct RelationshipSuppression: Hashable, Sendable {
    /// Deliberately NOT `Relationship.Kind`: the suppressed set (merge/parent
    /// *suggestions*) and the edge set are different vocabularies — there is no
    /// live duplicate edge at all.
    enum SuppressionKind: String, Sendable {
        case duplicateMerge
        case parentLink
    }

    var kind: SuppressionKind
    /// Pair form. `duplicateMerge`: canonical `min:max` uuid pair (symmetric).
    /// `parentLink`: ordered `child:parent` pair (directional).
    var pairKey: String?
    /// Capture form: the rejected merge/parent target…
    var targetID: UUID?
    /// …and the normalized draft title that was rejected against it.
    var normalizedTitle: String?
    var createdAt: Date

    /// The canonical symmetric key for an unordered pair.
    static func symmetricKey(_ a: UUID, _ b: UUID) -> String {
        let (lo, hi) = a.uuidString < b.uuidString ? (a, b) : (b, a)
        return "\(lo.uuidString):\(hi.uuidString)"
    }

    /// The ordered key for a directional pair (child:parent).
    static func directionalKey(child: UUID, parent: UUID) -> String {
        "\(child.uuidString):\(parent.uuidString)"
    }

    /// The normalization shared by write (rejection at commit) and read (proposal
    /// check at the next capture): lowercase, significant characters only, single
    /// spaces. Exact-match after normalization; an embedding-similarity threshold
    /// can be layered later if exact match proves too brittle.
    static func normalizeTitle(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whether this suppression kills a capture-time proposal of `kind` from a draft
    /// titled `normalizedTitle` against `targetID`. Pair-form rows can't match here
    /// (the draft has no id yet) — they serve consumers where both tasks pre-exist.
    func suppresses(kind: SuppressionKind, targetID: UUID, normalizedTitle: String) -> Bool {
        self.kind == kind && self.targetID == targetID && self.normalizedTitle == normalizedTitle
    }

    /// Whether this suppression kills a proposal between two EXISTING tasks (a future
    /// dedupe-sweep consumer). Symmetric for duplicates by construction of the key.
    func suppressesPair(kind: SuppressionKind, _ a: UUID, _ b: UUID) -> Bool {
        guard self.kind == kind, let pairKey else { return false }
        switch kind {
        case .duplicateMerge: return pairKey == Self.symmetricKey(a, b)
        case .parentLink: return pairKey == Self.directionalKey(child: a, parent: b)
        }
    }
}

// MARK: - Core Data record

/// The persisted row. Same house conventions as the other models: optional identity,
/// manual `@NSManaged`, convenience init with the `in:` context.
@objc(SuppressionRecord)
final class SuppressionRecord: NSManagedObject {
    @NSManaged var uuid: UUID?
    @NSManaged var kindRaw: String
    @NSManaged var pairKey: String?
    @NSManaged var targetID: UUID?
    @NSManaged var normalizedTitle: String?
    @NSManaged var createdAt: Date?

    var value: RelationshipSuppression? {
        guard let kind = RelationshipSuppression.SuppressionKind(rawValue: kindRaw) else { return nil }
        return RelationshipSuppression(
            kind: kind, pairKey: pairKey, targetID: targetID,
            normalizedTitle: normalizedTitle, createdAt: createdAt ?? .distantPast)
    }

    convenience init(
        _ suppression: RelationshipSuppression,
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(
            entity: NSEntityDescription.entity(forEntityName: "SuppressionRecord", in: context)!,
            insertInto: context)
        self.uuid = UUID()
        self.kindRaw = suppression.kind.rawValue
        self.pairKey = suppression.pairKey
        self.targetID = suppression.targetID
        self.normalizedTitle = suppression.normalizedTitle
        self.createdAt = suppression.createdAt
    }
}

// MARK: - Store (load + lazy prune + rejection writes)

enum SuppressionStore {
    /// A rejection shouldn't bind forever — an entry this old expires (pruned at load).
    static let maxAge: TimeInterval = 180 * 86_400

    /// Fetch the live suppression set as values, lazily pruning expired rows and rows
    /// whose target task no longer exists. `openIDs` is every task uuid still in the
    /// store (open or resolved — a resolved target keeps its suppression until the
    /// task itself is gone). Callers own `save()`.
    static func load(
        in context: NSManagedObjectContext, existingTaskIDs: Set<UUID>, now: Date = Date()
    ) -> [RelationshipSuppression] {
        let request = NSFetchRequest<SuppressionRecord>(entityName: "SuppressionRecord")
        let rows = (try? context.fetch(request)) ?? []
        var live: [RelationshipSuppression] = []
        for row in rows {
            guard let value = row.value else {
                context.delete(row)
                continue
            }
            let expired = now.timeIntervalSince(value.createdAt) > maxAge
            let orphaned = value.targetID.map { !existingTaskIDs.contains($0) } ?? false
            let pairOrphaned =
                value.pairKey.map { key in
                    !pairMembers(of: key).allSatisfy(existingTaskIDs.contains)
                } ?? false
            if expired || (orphaned && value.pairKey == nil) || (pairOrphaned && value.targetID == nil) {
                context.delete(row)
                continue
            }
            live.append(value)
        }
        return live
    }

    /// Record the user rejecting a duplicate-merge of a draft (titled `draftTitle`,
    /// created as `createdID` when a task was made) against `targetID`: a capture-form
    /// suppression always, plus the symmetric pair form once both tasks exist.
    static func recordRejectedDuplicate(
        draftTitle: String, createdID: UUID?, targetID: UUID,
        in context: NSManagedObjectContext, now: Date = Date()
    ) {
        context.insert(
            SuppressionRecord(
                RelationshipSuppression(
                    kind: .duplicateMerge, pairKey: nil, targetID: targetID,
                    normalizedTitle: RelationshipSuppression.normalizeTitle(draftTitle),
                    createdAt: now),
                in: context))
        if let createdID {
            context.insert(
                SuppressionRecord(
                    RelationshipSuppression(
                        kind: .duplicateMerge,
                        pairKey: RelationshipSuppression.symmetricKey(createdID, targetID),
                        targetID: nil, normalizedTitle: nil, createdAt: now),
                    in: context))
        }
    }

    /// Record the user rejecting a parent link ("keep separate"): directional —
    /// "this draft is not a child of `parentID`" implies nothing about the reverse.
    static func recordRejectedParent(
        draftTitle: String, createdID: UUID?, parentID: UUID,
        in context: NSManagedObjectContext, now: Date = Date()
    ) {
        context.insert(
            SuppressionRecord(
                RelationshipSuppression(
                    kind: .parentLink, pairKey: nil, targetID: parentID,
                    normalizedTitle: RelationshipSuppression.normalizeTitle(draftTitle),
                    createdAt: now),
                in: context))
        if let createdID {
            context.insert(
                SuppressionRecord(
                    RelationshipSuppression(
                        kind: .parentLink,
                        pairKey: RelationshipSuppression.directionalKey(child: createdID, parent: parentID),
                        targetID: nil, normalizedTitle: nil, createdAt: now),
                    in: context))
        }
    }

    private static func pairMembers(of key: String) -> [UUID] {
        key.split(separator: ":").compactMap { UUID(uuidString: String($0)) }
    }
}
