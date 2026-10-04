//
//  Interpretation.swift
//  Project-Ezra
//
//  THE reveal boundary, as a type.
//
//  > The system can think as much as it wants before showing you the answer. Once it shows
//  > you the answer, it owns that interpretation until you change it.
//
//  Three separate attempts held this as a *rule* — "structure is decided once", "never
//  progressively reinterpret", "the clamp is conditional on provenance" — and all three
//  leaked, because each left an API that could still mutate what was on screen and relied on
//  every call site remembering not to use it. The user saw the same defect three times: a
//  title rewriting itself twenty seconds after "Here's what I understood", and a second card
//  appearing seconds after the first. "Progressively enrich, never progressively reinterpret"
//  turned out not to be a user contract at all — nobody classifies a change as enrichment
//  versus restructuring; they see an answer, and then they see it change.
//
//  So the guard is structural. After `reveal()`, `propose(_:)` refuses. No parameter, no
//  provenance test, no "unless".
//
//  **This type owns the reveal boundary and nothing else** — no routing, no merging, no
//  metrics. It earns its noun by what minting it DELETED: `DraftMerge.enrich` and its
//  `holdStructure`/`restructured` parameters, `ComposerView.enrich(with:)`,
//  `structureIsUserTyped`, and the `revealWhenDone` branch in `runParse`. If it ever starts
//  coordinating those things again, it has stopped being a boundary and become a layer.
//
//  **Immutability constrains the SYSTEM, never the person.** `editableDrafts` is always
//  writable: the user may retitle, remove and change any field on a revealed card, because
//  those are their changes to their own reading.
//

import Foundation

/// The card set for one capture, and whether the user has seen it.
struct Interpretation {

    /// Where this interpretation is in its life. An enum rather than a bool because the
    /// boundary is the thing this type exists to express, and it will accrete meaning.
    enum RevealState: Equatable {
        /// Being produced. AI proposals are accepted.
        case pending
        /// On screen. AI proposals are refused; only the user may change it.
        case revealed
    }

    private(set) var drafts: [TaskDraft] = []
    private(set) var state: RevealState = .pending

    /// Pieces of the capture the judge read as nothing to do (`CaptureJudge`): shown under
    /// the cards as lines the person can add back, never dropped. Part of the same
    /// proposal as the cards, so it obeys the same boundary; adding one back is the
    /// person's act (`restoreLeftOut`).
    private(set) var leftOut: [String] = []

    /// The drafts as they stood the moment they were revealed — the baseline the DEBUG
    /// detector compares against. Nil until revealed.
    private var revealedFingerprint: [TaskDraft]?

    // MARK: - AI-originated

    /// Offer an interpretation the system produced. Accepted only before the reveal.
    /// Returns whether it was taken, so the caller can record the refusal rather than
    /// assume it landed.
    @discardableResult
    mutating func propose(_ new: [TaskDraft], leftOut: [String] = []) -> Bool {
        guard state == .pending else { return false }
        drafts = new
        self.leftOut = leftOut
        return true
    }

    /// Show it. One-way for this interpretation's life.
    mutating func reveal() {
        state = .revealed
        revealedFingerprint = drafts
    }

    /// Back to the canvas: the user is going to say more, so the next parse may speak again.
    /// Deliberately KEEPS `drafts` — their words and edits survive the trip.
    mutating func reopen() {
        state = .pending
        revealedFingerprint = nil
    }

    // MARK: - User-originated (always allowed)

    /// The binding the confirm cards edit through — the ONE sanctioned way a revealed
    /// interpretation changes. Writing here re-baselines the fingerprint, which is what
    /// distinguishes "the user edited this" from "something moved the ground".
    var editableDrafts: [TaskDraft] {
        get { drafts }
        set {
            drafts = newValue
            if state == .revealed { revealedFingerprint = newValue }
        }
    }

    /// The person says a left-out line IS a task: it joins the cards through their own
    /// edit path, and leaves the left-out list.
    mutating func restoreLeftOut(_ line: String, as draft: TaskDraft) {
        leftOut.removeAll { $0 == line }
        editableDrafts = drafts + [draft]
    }

    // MARK: - Zero tolerance

    /// Has anything changed a revealed interpretation without going through the user's own
    /// edit path? The answer must be NO, always — a violation is a launch-blocking bug, not
    /// a metric to keep low.
    ///
    /// `propose` refusing only proves the one path we thought of is closed. This proves the
    /// property itself, so a future mutation added somewhere unexpected is caught by the
    /// invariant rather than by a user noticing their card changed.
    var hasUnexplainedMutation: Bool {
        guard let baseline = revealedFingerprint else { return false }
        return drafts != baseline
    }

    /// Call after any operation that could touch a revealed set. DEBUG-only teeth; in
    /// release it is a no-op, because the structural guard is what actually holds the line.
    func assertNotMutated(_ context: @autoclosure () -> String = "") {
        #if DEBUG
        assert(
            !hasUnexplainedMutation,
            "A revealed interpretation was mutated outside the user's edit path. \(context())"
        )
        #endif
    }
}
