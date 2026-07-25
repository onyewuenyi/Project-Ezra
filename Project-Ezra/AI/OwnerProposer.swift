//
//  OwnerProposer.swift
//  Project-Ezra
//
//  Who should own this task? A pure, deterministic function over value snapshots —
//  no model call, no managed objects. That is what makes it testable at all, and it
//  is why the heuristic path (and therefore the simulator, and every test) exercises
//  the whole feature, unlike the capture-graph proposals.
//
//  This REPLACES `AppBrain.applyOwnershipGate`, which did the opposite: a confident
//  household draft with no person named was flagged `ownerPending` and the confirm
//  card asked "who does this belong to?". That abstention was right when the AI had
//  no basis for choosing. It now has one — the capture graph, category history, the
//  roster, and per-member load — and every other field already reaches the card
//  populated and editable, so owner being the lone exception broke the
//  metadata-completeness promise rather than honoring it.
//
//  The ladder is TOTAL: it always terminates at the capturer, so every task is born
//  owned and `ownerPending` could be retired outright. "Unowned" now has exactly one
//  spelling — `ownerID == nil` — and only a human hand-back produces it.
//
//  Two rules that are easy to get wrong and are enforced structurally here:
//
//  1. **Load never selects an owner, it only adjusts one.** Rungs 2 and 3 pick a
//     person on FIT; load can then demote an overloaded candidate or break a tie. It
//     can never originate a proposal, so "give it to Maya because her number is
//     lower" — on work she has no context for — is unreachable by construction.
//  2. **`.defaultSelf` claims nothing.** It carries no reason, so the confirm card's
//     ✦ never appears on it. Rung 4 catches most captures; dressing that up as an
//     inference would be worse for trust than the abstention it replaced.
//

import Foundation

/// The proposer's answer. Non-optional owner by design — there is no abstention case.
struct OwnerProposal: Sendable, Hashable {

    /// Why this owner was chosen. Ordered by strength; `defaultSelf` is the terminal.
    enum Basis: String, Sendable, Hashable, Codable {
        /// The user said a name. Never overridden, never sync-gated.
        case spoken
        /// A graph neighbour (parent or duplicate target) has a non-self owner.
        case adjacency
        /// This person owns most of the prior human-assigned work in this category.
        case affinity
        /// The capturer. The default, not a fallback — and the only basis that
        /// deliberately explains nothing.
        case defaultSelf
    }

    /// nil == the capturer. Kept as a name rather than an id because that is the
    /// currency the draft and the confirm card speak; `AppBrain.resolveOwners` maps
    /// it to a `FamilyMember.uuid` at commit.
    var memberName: String?
    var basis: Basis
    /// One short phrase, rendered under the owner chip. **Always nil for
    /// `.defaultSelf`** — see the file header.
    var reason: String?

    static let mine = OwnerProposal(memberName: nil, basis: .defaultSelf, reason: nil)
}

/// A roster member as the proposer sees them: identity plus the live load facts.
/// A value snapshot so the proposer never touches Core Data.
struct OwnerCandidate: Sendable, Hashable {
    var memberID: UUID
    var name: String
    /// Open, live, workload-counting tasks on this plate (`MemberLoad.activeCount`).
    var activeCount: Int
    /// Carrying disproportionately more than the rest of the household.
    var isOverloaded: Bool
}

/// One prior ownership fact, for the affinity rung.
struct OwnerHistoryEntry: Sendable, Hashable {
    var category: String
    var ownerName: String
    /// Whether a HUMAN established this ownership. The affinity share counts these
    /// only — see `OwnerProposer.affinity`.
    var isHumanEstablished: Bool
}

/// Everything the proposer needs about the household, snapshotted as values at the
/// call site — the same convention as `RosterPerson` / `OpenTaskSnapshot`, so the
/// proposer never touches a `NSManagedObjectContext` and stays trivially testable.
///
/// Built by `ComposerView` (and the seed paths) from the live store; empty on a solo
/// install, which makes the whole feature a clean no-op.
struct OwnershipContext: Sendable {
    /// Other household members — never the capturer.
    var candidates: [OwnerCandidate] = []
    /// Prior ownership facts backing the affinity rung.
    var history: [OwnerHistoryEntry] = []
    /// Owner *name* by task id, so a capture-graph proposal's target can be resolved
    /// to a person without a fetch inside the proposer.
    var ownersByTaskID: [UUID: String] = [:]

    static let none = OwnershipContext()
}

enum OwnerProposer {

    /// A person must own at least this many prior tasks in a category before the
    /// category means anything. Two coincidences are not a pattern.
    static let minAffinitySamples = 3
    /// …and at least this share of them.
    static let minAffinityShare = 0.6

    /// Choose an owner. First rung that matches wins.
    ///
    /// - Parameters:
    ///   - draft: the candidate being filed; supplies the spoken name and the graph edges.
    ///   - roster: other household members (never the capturer).
    ///   - adjacentOwners: owner names reachable through this draft's graph edges, in
    ///     preference order. **Deliberately excludes blockers** — a blocker is
    ///     frequently owned by someone else precisely *because* they are the
    ///     bottleneck, so it points the wrong way as often as not. Only `childOf` and
    ///     `duplicateOf` targets qualify.
    ///   - history: prior ownership facts for the affinity rung.
    ///   - syncIsLive: whether other people's devices actually exist in this graph.
    ///     Defaults to the compile-time gate; a parameter so tests can drive both sides.
    static func propose(
        draft: TaskDraft,
        roster: [OwnerCandidate],
        adjacentOwners: [String] = [],
        history: [OwnerHistoryEntry] = [],
        syncIsLive: Bool = HouseholdSync.isLive
    ) -> OwnerProposal {

        // Rung 1 — they said a name. Not gated: honoring the user's own words can
        // never strand work with someone unreachable in a way they didn't ask for.
        if let spoken = draft.ownerName?.trimmed, !spoken.isEmpty {
            return OwnerProposal(memberName: spoken, basis: .spoken, reason: nil)
        }

        // Solo installs, and every single-device install, stop here. Inferring a
        // hand-off to a person with no device is a black hole: the task would leave
        // the capturer's execution surface and land nowhere anyone can act on it.
        guard syncIsLive, !roster.isEmpty else { return .mine }

        // Rung 2 — a graph neighbour owns it.
        if let picked = pick(from: adjacentOwners, roster: roster) {
            return OwnerProposal(
                memberName: picked.name, basis: .adjacency,
                reason: "\(picked.name) owns the work this connects to")
        }

        // Rung 3 — they own this kind of work.
        if let picked = affinity(category: draft.category, roster: roster, history: history) {
            return OwnerProposal(
                memberName: picked.name, basis: .affinity,
                reason: "\(picked.name) owns most of the \(draft.category) work")
        }

        // Rung 4 — the capturer. Terminal, and explains nothing.
        return .mine
    }

    // MARK: - Rungs

    /// Resolve candidate names against the roster, then let load adjust — an
    /// overloaded first choice yields to the next candidate that shares the basis,
    /// and an all-overloaded field falls back to the lightest plate rather than
    /// abandoning the rung (fit already established these people are right).
    private static func pick(from names: [String], roster: [OwnerCandidate]) -> OwnerCandidate? {
        let matched = names.compactMap { name in
            roster.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard !matched.isEmpty else { return nil }
        if let notOverloaded = matched.first(where: { !$0.isOverloaded }) { return notOverloaded }
        return lightest(matched)
    }

    /// The category-ownership share, counted over HUMAN-established ownership only.
    ///
    /// This restriction is load-bearing rather than fussy. Rung 4 makes the capturer
    /// the owner of everything the earlier rungs miss, which is most things — so a
    /// share computed over *all* tasks would have its denominator flooded by the
    /// proposer's own defaults, and a genuinely preferred owner could never cross the
    /// threshold. The rung would be unreachable by construction. Counting intent
    /// instead of the proposer's own output is what lets it learn.
    private static func affinity(
        category: String, roster: [OwnerCandidate], history: [OwnerHistoryEntry]
    ) -> OwnerCandidate? {
        let inCategory = history.filter {
            $0.isHumanEstablished && $0.category.caseInsensitiveCompare(category) == .orderedSame
        }
        guard inCategory.count >= minAffinitySamples else { return nil }

        let counts = Dictionary(grouping: inCategory, by: \.ownerName).mapValues(\.count)
        let qualifying =
            counts
            .filter {
                $0.value >= minAffinitySamples
                    && Double($0.value) / Double(inCategory.count) >= minAffinityShare
            }
            .keys
        return pick(from: Array(qualifying), roster: roster)
    }

    /// Tie-break: the lighter plate, then a stable ordering so the result never
    /// depends on dictionary iteration order.
    private static func lightest(_ candidates: [OwnerCandidate]) -> OwnerCandidate? {
        candidates.min {
            $0.activeCount != $1.activeCount
                ? $0.activeCount < $1.activeCount
                : $0.memberID.uuidString < $1.memberID.uuidString
        }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
