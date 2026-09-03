//
//  HumanVerdict.swift
//  Project-Ezra
//
//  **One noun for the human's verdict on something the system proposed.** (P-02)
//
//  Before this, the same act — the person saying "no" (or "not that, this") to an AI
//  proposal — was three unrelated records with three different durabilities:
//
//    - a confirm-card edit → a `Correction` row (persisted; feeds learned rules)
//    - a rejected merge or link → a `SuppressionRecord` (persisted; expires; two key forms)
//    - a dismissed Advisor reading → `state = .dismissed` on an in-memory entry, gone at
//      the next launch — so §10's "an opinion the human declined never resurfaces until
//      the facts change" was true only until the app was relaunched, and the learning
//      loop (S5) never saw the Advisor's most frequent human signal at all.
//
//  `HumanVerdict` is the shared vocabulary: a SUBJECT (what was proposed), a VERDICT
//  (declined, or changed to something else), and WHEN. The store below is the one
//  writer for verdicts that have no other home today — the Advisor's dismissals — and
//  the one reader the learning loop consults for all three (`HumanVerdicts.collect`).
//
//  **Why the three storages are not merged in one move.** The schema froze at
//  generation 10 (additive-only from here; the wipe-on-mismatch hatch closes when sync
//  lands), so `Correction` and `SuppressionRecord` keep their Core Data homes and their
//  existing writers. What is unified NOW is the vocabulary and the read; what is fixed
//  NOW is the durability gap. When the schema next moves, those two writers move behind
//  `HumanVerdictStore.record` and this file becomes the only place a "no" is written.
//
//  **Expiry binds to the FINGERPRINT, not the clock.** A dismissed reading stays
//  dismissed while the facts that produced it hold; the moment they move, the reading
//  is new and the verdict no longer applies (the fingerprint is part of the subject, so
//  a changed fingerprint is a different subject). The only clock here is housekeeping:
//  records older than `maxAge` are pruned so the file stays bounded — the same rule
//  `SuppressionStore.maxAge` already uses.
//
//  **A file sidecar, never Core Data** — `CaptureProvenance`'s rule: a record that
//  exists to make the product calmer must never be able to cost the user their data.
//  Losing this file loses some "no"s, which is strictly better than a failed store load.
//

import Foundation

/// The human's verdict on one proposal.
struct HumanVerdict: Codable, Equatable, Sendable {

    /// What was proposed. Each case is one of the product's proposal channels; the
    /// associated values are what makes the verdict re-findable.
    enum Subject: Codable, Hashable, Sendable {
        /// A field on a confirm-card draft (`Correction.fieldCorrected`).
        case draftField(taskID: UUID?, field: String)
        /// A proposed graph edge — the suppression's pair or capture key.
        case proposedEdge(key: String)
        /// An Advisor reading, identified by the task and the facts fingerprint it was
        /// produced over. A new fingerprint is a new subject.
        case reading(taskID: UUID, fingerprint: Int)
    }

    enum Verdict: String, Codable, Sendable {
        /// The person waved it off: a dismissed reading, a rejected edge.
        case declined
        /// The person replaced it with their own value: a confirm-card edit.
        case changed
    }

    let subject: Subject
    let verdict: Verdict
    let at: Date
    /// What SHAPE the declined proposal had — for a reading, its `AdvisorMove` raw
    /// value. This is what learning reads: "they keep waving off step breakdowns" is a
    /// preference; "they waved off reading #4127" is not.
    var move: String?
    /// For a CHANGED draft field: what the system proposed and what the person wrote
    /// instead — the pair the capture learner reads (`Learned.rules`).
    var from: String?
    var to: String?

    init(
        subject: Subject, verdict: Verdict, at: Date = Date(), move: String? = nil,
        from: String? = nil, to: String? = nil
    ) {
        self.subject = subject
        self.verdict = verdict
        self.at = at
        self.move = move
        self.from = from
        self.to = to
    }
}

/// The durable home for verdicts that have no other one — one `Sidecar`, newest first,
/// bounded two ways (age and count).
@MainActor
final class HumanVerdictStore {

    /// In-memory under the unit-test host (`Sidecar.url` returns nil there): a test that
    /// dismisses a reading must not leave a verdict behind for the next test — or the
    /// next launch of the app on that simulator — to find.
    static let shared = HumanVerdictStore(fileURL: Sidecar<HumanVerdict>.url("human-verdicts.json"))

    /// Housekeeping only — see the header. Matches `SuppressionStore.maxAge`.
    static let maxAge: TimeInterval = 180 * 86_400
    /// A ceiling on the file, oldest dropped first. Far more than a person dismisses.
    static let maxRecords = 500

    private let sidecar: Sidecar<HumanVerdict>

    /// `fileURL` nil = in-memory. Injectable so a test can use a temporary file and prove
    /// the reload path without touching the real one.
    init(fileURL: URL?) {
        sidecar = Sidecar(fileURL: fileURL, maxRecords: Self.maxRecords)
    }

    /// Every verdict, newest first.
    var all: [HumanVerdict] { sidecar.all }

    /// Record a verdict. A later verdict on the same subject replaces the earlier one —
    /// a subject has one current verdict, not a history.
    func record(_ verdict: HumanVerdict) {
        sidecar.upsert(verdict) { $0.subject == verdict.subject }
    }

    /// The current verdict on a subject, if any.
    func verdict(on subject: HumanVerdict.Subject) -> HumanVerdict? {
        all.first { $0.subject == subject }
    }

    /// Did the person decline THIS reading — same task, same facts? The Advisor's rung-1
    /// check for a "no": answered from memory, no generation, across launches.
    func isDeclined(reading taskID: UUID, fingerprint: Int) -> Bool {
        verdict(on: .reading(taskID: taskID, fingerprint: fingerprint))?.verdict == .declined
    }

    /// How many readings of each shape the person declined inside a window — the
    /// Advisor's learning input (F-10). Counts only `.reading` subjects.
    func declinedMoveCounts(within days: Int = Learned.preferenceWindowDays, now: Date = Date()) -> [String: Int] {
        Learned.declinedMoveCounts(in: all, within: days, now: now)
    }

    /// Drop records past `maxAge`. Called lazily; safe to call often.
    @discardableResult
    func prune(now: Date = Date()) -> Int {
        let before = all.count
        sidecar.remove { now.timeIntervalSince($0.at) > Self.maxAge }
        return before - all.count
    }

    func reset() { sidecar.reset() }
}

/// The one READ over all three storages — what the learning loop consults. Pure: hand
/// it the rows and it hands back verdicts, so a caller with a context and one with
/// fixtures get the same answer.
enum HumanVerdicts {

    static func collect(
        corrections: [Correction] = [],
        suppressions: [RelationshipSuppression] = [],
        store: HumanVerdictStore? = nil
    ) -> [HumanVerdict] {
        var verdicts: [HumanVerdict] = []
        verdicts.append(
            contentsOf: corrections.map {
                HumanVerdict(
                    subject: .draftField(taskID: $0.taskUUID, field: $0.fieldCorrected),
                    verdict: .changed, at: $0.createdAt, from: $0.aiValue, to: $0.userValue)
            })
        verdicts.append(
            contentsOf: suppressions.map { suppression in
                // Pair form when both tasks existed; capture form (target + normalized
                // draft title) when the rejection happened on the confirm card.
                let key =
                    suppression.pairKey
                    ?? "\(suppression.targetID?.uuidString ?? "?")|\(suppression.normalizedTitle ?? "")"
                return HumanVerdict(
                    subject: .proposedEdge(key: "\(suppression.kind.rawValue):\(key)"),
                    verdict: .declined, at: suppression.createdAt)
            })
        if let store { verdicts.append(contentsOf: store.all) }
        return verdicts.sorted { $0.at > $1.at }
    }
}
