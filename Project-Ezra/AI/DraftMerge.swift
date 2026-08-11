//
//  DraftMerge.swift
//  Project-Ezra
//
//  How a re-parse (or a streaming partial) lands on cards the user may already have
//  touched. The old rule — keep a card only when its whole `aiOriginal` snapshot was
//  byte-identical to the fresh candidate's — failed both halves of its job: any AI
//  re-read discarded every human edit on that card, and streaming partials (which
//  fill fields in progressively) minted a fresh identity per snapshot, tearing the
//  card's view down at token cadence.
//
//  The replacement, in three rules:
//
//  1. **Identity is the AI's reading of the LINE.** A fresh candidate matches a
//     current card by normalized AI title (Pass A) — deliberately the suppression
//     capture-form's vocabulary, and for the same reason: it is the stable name of a
//     line of the capture across re-reads. Leftovers get one gated fallback (Pass B):
//     a growing title (streaming) or a related re-title keeps the card; an unrelated
//     pairing must NOT merge. The matched card's `id` is transplanted onto the fresh
//     candidate, so ForEach identity — and the card's view — survives the stream.
//
//  2. **The user's edits are re-applied field-by-field** from `editedFields`; every
//     untouched field takes the fresh AI value. `aiOriginal` always adopts the
//     LATEST reading, which keeps both downstream contracts honest: the Correction
//     diff at commit compares the user's value against what the AI currently
//     proposes, and the suppression key stays aligned with what the next capture's
//     resolver will normalize.
//
//  3. **A removed card stays removed** for the session (`RemovedDraftSet`) — a
//     deletion the next keystroke resurrects reads as the AI overruling the user.
//

import Foundation

enum DraftMerge {

    /// Below this word-overlap (Jaccard over significant words), a re-titled fresh
    /// candidate is a different thought, not a re-reading — it enters as a new card.
    static let retitleSimilarityFloor = 0.3

    /// The matching key: the AI's normalized title.
    static func key(_ draft: TaskDraft) -> String {
        RelationshipSuppression.normalizeTitle(draft.aiOriginal?.title ?? draft.title)
    }

    /// One-to-one merge of a fresh parse into the current cards, preserving fresh's
    /// order (it reflects the capture text). Matched cards keep their identity and
    /// user edits; unmatched fresh candidates enter as new cards; unmatched current
    /// cards drop (the model no longer reads that line) — unless `keepingUnmatched`.
    ///
    /// `keepingUnmatched` is the STREAMING arm: a partial snapshot grows from the top
    /// of the text, so "this line isn't in the snapshot yet" is a statement about how
    /// far generation has gotten, not about the line. Dropping on that read collapsed
    /// an established card list to one card at the start of every chained re-parse and
    /// regrew it — cards blinking away mid-ramble. Unmatched current cards ride at the
    /// tail (they ARE the tail: snapshots claim cards top-down); only a COMPLETED
    /// parse, which really has re-read every line, may drop one.
    static func merge(
        fresh: [TaskDraft], into current: [TaskDraft], removed: RemovedDraftSet,
        keepingUnmatched: Bool = false
    ) -> [TaskDraft] {
        let candidates = removed.filter(fresh)
        var claimed = [Bool](repeating: false, count: current.count)
        var matches = [Int?](repeating: nil, count: candidates.count)

        // Pass A — exact key match, first unmatched current wins, so two identical
        // lines pair positionally by construction.
        for (f, candidate) in candidates.enumerated() {
            let k = key(candidate)
            guard !k.isEmpty else { continue }
            if let c = current.indices.first(where: { !claimed[$0] && key(current[$0]) == k }) {
                claimed[c] = true
                matches[f] = c
            }
        }

        // Pass B — gated fallback for the leftovers: first related leftover current
        // card wins. "Related" covers the two legitimate ways a line's reading moves
        // between parses; anything else must not merge, or an unrelated card would
        // absorb another line's edits.
        for f in candidates.indices where matches[f] == nil {
            if let c = current.indices.first(where: {
                !claimed[$0] && related(candidates[f], current[$0])
            }) {
                claimed[c] = true
                matches[f] = c
            }
        }

        // Pass C — the PROVISIONAL upgrade. A model candidate claims a provisional
        // card by the clause that card was cut from, because Pass B structurally
        // cannot see this case: the model rewrites the title ("I should probably get
        // around to booking the flights" → "Book flights"), and word-overlap against
        // the heuristic's title falls under the floor. Without this the provisional
        // card is DROPPED and the model's enters with a fresh id — a visible swap
        // that also discards any edit made while the model was still thinking.
        //
        // Both halves of the gate are structural: only a non-provisional (model)
        // candidate may claim, and only a provisional current card may be claimed —
        // so "never fires model-over-model" is unrepresentable rather than merely
        // untested.
        for f in candidates.indices where matches[f] == nil && !candidates[f].isProvisional {
            let title = candidates[f].aiOriginal?.title ?? candidates[f].title
            if let c = current.indices.first(where: {
                !claimed[$0] && current[$0].isProvisional
                    && current[$0].provisionalSource.map {
                        claims(modelTitle: title, source: $0)
                    } == true
            }) {
                claimed[c] = true
                matches[f] = c
            }
        }

        var merged = candidates.enumerated().map { f, candidate in
            matches[f].map { adopt(fresh: candidate, keeping: current[$0]) } ?? candidate
        }
        if keepingUnmatched {
            merged += current.indices.filter { !claimed[$0] }.map { current[$0] }
        }
        return merged
    }

    /// Fresh's values + kept's identity + kept's user-touched fields re-applied.
    static func adopt(fresh: TaskDraft, keeping kept: TaskDraft) -> TaskDraft {
        var merged = fresh
        merged.id = kept.id
        merged.editedFields = kept.editedFields
        for field in kept.editedFields ?? [] {
            switch field {
            case .title: merged.title = kept.title
            case .category: merged.category = kept.category
            case .dueDate:
                merged.dueDate = kept.dueDate
                merged.dueReason = kept.dueReason
            case .isUrgent: merged.isUrgent = kept.isUrgent
            case .workIntent: merged.workIntent = kept.workIntent
            case .ownerName:
                // The whole owner trio moves together: the reason line and the ✦
                // describe the AI's proposal, and once the user has picked, the
                // basis that decides "owner" vs "ownerProposed" must not be
                // overwritten by a fresh proposal they never saw.
                merged.ownerName = kept.ownerName
                merged.ownerReason = kept.ownerReason
                merged.ownerBasis = kept.ownerBasis
            case .effortMinutes: merged.effortMinutes = kept.effortMinutes
            case .blockedBy: merged.blockedBy = kept.blockedBy
            case .blocks: merged.blocks = kept.blocks
            }
        }
        // Proposal decisions the user changed carry per-proposal, by value diff —
        // reliable here (unlike the fields above) because `aiOriginal.edgeProposals`
        // is frozen at resolve and only `setDecision` mutates the live copy.
        for (index, proposal) in merged.edgeProposals.enumerated() {
            guard
                let keptProposal = kept.edgeProposals.first(where: {
                    $0.kind == proposal.kind && $0.targetID == proposal.targetID
                }),
                let keptOriginal = kept.aiOriginal?.edgeProposals.first(where: {
                    $0.kind == keptProposal.kind && $0.targetID == keptProposal.targetID
                }),
                keptProposal.decision != keptOriginal.decision
            else { continue }
            merged.edgeProposals[index].decision = keptProposal.decision
        }
        return merged
    }

    /// A provisional pass landing on cards a model parse may already own. **Additive
    /// only**: a matched card is returned BYTE-IDENTICAL, never re-read down to
    /// heuristic values. That is the whole rule — a card that already exists is by
    /// definition at least as good as what the segmenter would now say about it, and
    /// re-adopting would clobber the three things only the model has (the tightened
    /// title, the edge proposals, and `aiOriginal`, whose rewrite would break both the
    /// Correction diff and the suppression key). No epoch is needed to make that safe;
    /// it is safe by construction.
    static func mergeProvisional(
        fresh: [TaskDraft], into current: [TaskDraft], removed: RemovedDraftSet
    ) -> [TaskDraft] {
        let candidates = removed.filter(fresh)
        var claimed = [Bool](repeating: false, count: current.count)
        var result: [TaskDraft] = []
        for candidate in candidates {
            if let c = provisionalMatch(for: candidate, in: current, claimed: claimed) {
                claimed[c] = true
                result.append(current[c])  // untouched — never downgraded
            } else {
                result.append(candidate)
            }
        }
        // A card the segmenter no longer sees (the model split a line differently)
        // must not vanish because the user typed one more character.
        result += current.indices.filter { !claimed[$0] }.map { current[$0] }
        return result
    }

    /// Enrichment onto a set the user is ALREADY READING — the whole of "progressively
    /// enrich; never progressively reinterpret", as a pure function so the rule can be
    /// property-tested instead of trusted.
    ///
    /// The model's richer read (tightened titles, dates, owners, edge proposals) is
    /// merged in, but the structure on screen wins absolutely: the result is rebuilt
    /// from `shown`, in `shown`'s order, one entry per shown draft. A model that split
    /// or joined differently cannot add a card, drop a card, or move one. That is not a
    /// nicety — the reveal is the product's claim to have understood, and a set that
    /// re-counts itself after the user has read it retracts the claim.
    ///
    /// `structureDisagreed` reports (for DEBUG metrics) that the model's structure
    /// differed and was overruled, so the trust predicate can be tuned on evidence. It
    /// merges with `keepingUnmatched: true` for that measurement alone: without it, a
    /// model that simply had nothing new to say about a card would drop it from the
    /// merge and be recorded as having disagreed about the structure — which would make
    /// the one number that tunes the trust predicate mostly false positives.
    static func enrich(
        _ fresh: [TaskDraft], onto shown: [TaskDraft], removed: RemovedDraftSet
    ) -> (drafts: [TaskDraft], structureDisagreed: Bool) {
        guard !fresh.isEmpty else { return (shown, false) }
        let merged = merge(fresh: fresh, into: shown, removed: removed, keepingUnmatched: true)
        let kept = shown.map { existing in
            merged.first(where: { $0.id == existing.id }) ?? existing
        }
        return (kept, merged.count != shown.count)
    }

    /// Pass A / B / C′ for the additive merge. C′ is Pass C with the roles swapped —
    /// a MODEL card claiming this provisional candidate's clause — so a retitle is
    /// recognised from both directions and the provisional pass can't add a duplicate
    /// card for a line the model already holds under a rewritten title.
    private static func provisionalMatch(
        for candidate: TaskDraft, in current: [TaskDraft], claimed: [Bool]
    ) -> Int? {
        let k = key(candidate)
        if !k.isEmpty,
            let c = current.indices.first(where: { !claimed[$0] && key(current[$0]) == k })
        {
            return c
        }
        if let c = current.indices.first(where: { !claimed[$0] && related(candidate, current[$0]) }) {
            return c
        }
        guard let source = candidate.provisionalSource else { return nil }
        return current.indices.first(where: {
            !claimed[$0] && !current[$0].isProvisional
                && claims(
                    modelTitle: current[$0].aiOriginal?.title ?? current[$0].title, source: source)
        })
    }

    /// Does a model title read as a COMPRESSION of the clause a provisional card was
    /// cut from? Deliberately not `related`'s Jaccard: a rewritten title is a short
    /// subset of a transcript clause, and a symmetric metric punishes it for the words
    /// it correctly threw away ("Book flights" vs "i should probably get around to
    /// booking the flights" scores 0.25 — under the floor, so the upgrade misses).
    /// Containment over the smaller side, with a crude local stem so "booking" reaches
    /// "book".
    static let provisionalClaimFloor = 0.5

    static func claims(modelTitle: String, source: String) -> Bool {
        let modelWords = Set(CorrectionProfile.significantWords(modelTitle).map(stem))
        let sourceWords = Set(CorrectionProfile.significantWords(source).map(stem))
        guard !modelWords.isEmpty, !sourceWords.isEmpty else { return false }
        let overlap = modelWords.intersection(sourceWords)
        guard !overlap.isEmpty else { return false }
        // A shared imperative verb alone is NOT lineage — "Call mom" and "call the
        // dentist" share exactly "call", and letting that claim would hand one line's
        // edits to another. Require a shared word that carries the subject.
        guard !overlap.subtracting(Segmentation.actionVerbs.map(stem)).isEmpty else {
            return false
        }
        return Double(overlap.count) / Double(min(modelWords.count, sourceWords.count))
            >= provisionalClaimFloor
    }

    /// Crude suffix stripping, local to the claim and used NOWHERE else. The
    /// suppression key, the learned-rule vocabulary, blocker matching and the eval
    /// floors all read `CorrectionProfile.significantWords` unstemmed — those are
    /// stable contracts other code depends on, and this predicate is not a reason to
    /// move them.
    private static func stem(_ word: String) -> String {
        if word.count >= 5, word.hasSuffix("ing") { return String(word.dropLast(3)) }
        if word.count >= 4, word.hasSuffix("ed") { return String(word.dropLast(2)) }
        if word.count >= 4, word.hasSuffix("es") { return String(word.dropLast(2)) }
        if word.count >= 4, word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    /// The two legitimate ways one line's reading moves between parses: guided
    /// generation grows the tail element's title token by token (prefix), and a
    /// full re-parse may re-phrase it (word overlap above the floor).
    private static func related(_ a: TaskDraft, _ b: TaskDraft) -> Bool {
        let ka = key(a)
        let kb = key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return false }
        if ka.hasPrefix(kb) || kb.hasPrefix(ka) { return true }
        let wa = CorrectionProfile.significantWords(ka)
        let wb = CorrectionProfile.significantWords(kb)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let overlap = Double(wa.intersection(wb).count)
        let union = Double(wa.union(wb).count)
        return overlap / union >= retitleSimilarityFloor
    }
}

/// The cards the user explicitly deleted this composer session — keyed the way the
/// merge matches (normalized AI title) and COUNTED, so "two identical lines, remove
/// one" keeps one. Session-scoped by design: a removal is a statement about this
/// capture's parse, not a durable preference (durable "no" is the suppression store).
struct RemovedDraftSet {
    private var counts: [String: Int] = [:]
    /// Source clauses of removed PROVISIONAL cards. Without this the title key alone
    /// lets a deleted card come BACK: the user removes the instant card, the model
    /// finishes a second later and re-proposes the same thought under a rewritten
    /// title the key cannot recognise, and the merge — seeing no removal for that
    /// key — lets it in. A card that un-deletes itself reads as the AI overruling the
    /// user, which is the exact failure rule 3 exists to prevent.
    private var sources: [String: Int] = [:]

    mutating func record(_ draft: TaskDraft) {
        counts[DraftMerge.key(draft), default: 0] += 1
        if let source = draft.provisionalSource { sources[source, default: 0] += 1 }
    }

    /// Drop up to the recorded count of fresh candidates per key, in order — then,
    /// for anything that survived, the same check against removed provisional
    /// clauses (a model re-proposal of a removed instant card).
    func filter(_ fresh: [TaskDraft]) -> [TaskDraft] {
        guard !counts.isEmpty || !sources.isEmpty else { return fresh }
        var remaining = counts
        var remainingSources = sources
        return fresh.filter { draft in
            let k = DraftMerge.key(draft)
            if let n = remaining[k], n > 0 {
                remaining[k] = n - 1
                return false
            }
            // The retitle path: does this candidate read as a compression of a clause
            // whose card the user deleted?
            let title = draft.aiOriginal?.title ?? draft.title
            if let source = remainingSources.first(where: { source, count in
                count > 0 && DraftMerge.claims(modelTitle: title, source: source)
            })?.key {
                remainingSources[source]? -= 1
                return false
            }
            return true
        }
    }

}
