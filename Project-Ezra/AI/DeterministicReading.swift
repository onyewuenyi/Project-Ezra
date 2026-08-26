//
//  DeterministicReading.swift
//  Project-Ezra
//
//  Rung 0's Advisor reading: built from facts alone, no model, no network, always
//  available.
//
//  **Why this exists.** The intelligence ladder promises that rung 0 carries "sensors,
//  gates, rankings, fact lines, template fallbacks", and that every rung has a named
//  fallback so "the core loop survives on every device, offline, with zero entitlements."
//  For the Advisor that promise was only half kept. The no-model path rendered
//  `StallDiagnosis.headline` — and `StallDetector.diagnose` answers for exactly ONE of the
//  gate's nine worthy reasons.
//
//  The other eight were not merely thin, they were structurally impossible:
//  `.decisionFlag` is excluded by an explicit guard inside `diagnose` (a flagged decision
//  is never "stalled"), and `.blocked` / `.doing` / `.overdue` are checked AFTER `.stalled`
//  in a first-match-wins gate, so reaching them means the diagnosis is nil by
//  construction. `fallbackContent` has no `else`, while `showsReading` returns true for
//  `.fallback` regardless — so an Apple-Intelligence-off device showed the word ADVISOR
//  with nothing underneath it, on the most common worthy tasks in the product.
//
//  That is worse than either honest outcome. Silence is a first-class judgment and renders
//  as *nothing*; a labelled empty box is a promise the surface then fails to keep.
//
//  **The truth hierarchy is what keeps this honest.** Every sentence below is a
//  restatement of a fact the system already holds — a blocker's title, a due date, a
//  flag the human set. Nothing here infers, predicts, or explains. That is the whole
//  design: rung 0 may only say what it already knows, so a reading produced with no model
//  in the loop still cannot mislead. Where there is nothing factual to say, it returns
//  nil and the surface stays quiet.
//
//  It returns a `ValidatedReading` so the existing renderer is reused wholesale — the
//  evidence disclosure, the understanding/action hairline, the per-move bodies — rather
//  than growing a second, parallel layout that could drift from the model path.
//

import Foundation

enum DeterministicReading {

    /// A reading for a task the gate judged worthy but no model could speak to.
    ///
    /// Returns nil when there is genuinely nothing factual to say — the caller renders
    /// silence, which is a legitimate answer rather than a failure.
    ///
    /// **Deliberately skips the diagnosed-stall case.** When `facts.diagnosis` is present
    /// the view already has a richer template — the diagnosis headline PLUS its
    /// action links ("Do it now" / "Defer it" / "Let it go") — and duplicating it here as
    /// a bare `.advise` would silently drop those buttons. One template per situation.
    static func make(from facts: TaskAdvisorFacts) -> ValidatedReading? {
        guard !facts.status.isResolved else { return nil }
        guard facts.diagnosis == nil else { return nil }

        // **The floor never restates the spine.** The page's shape already renders
        // its defining fact as the spine — the waiting page names its blockers, the
        // deciding page leads with the obligation block, the container leads with its
        // steps — so a reading repeating that fact is the same information twice on
        // one screen. Rung 0 speaks only when it holds a fact the spine does not
        // state; otherwise nil, and the spine IS the reading. Shape ⊆ fingerprint,
        // so this suppression can never disagree with the cached judgment.
        let spine = TaskShape.of(facts)
        guard let (move, observation, cited) = readingBody(for: facts, spine: spine) else { return nil }
        var reading = ValidatedReading(
            move: move,
            observation: observation,
            guidance: nil,
            nextMove: nil,
            options: [],
            recommendation: nil,
            steps: [],
            evidence: facts.userVisibleEvidence
        )
        reading.citedTaskIDs = cited
        return reading
    }

    /// The ladder, most-actionable first — the same precedence the gate uses, so the
    /// reading always speaks to the reason the task was surfaced.
    ///
    /// `.advise` is the move almost everywhere on purpose: rung 0 knows the situation but
    /// cannot author options or steps, and fabricating either to earn a button would be
    /// exactly the invention this file exists to prevent. `.openBlocker` is the one
    /// exception, because its payload is a real edge the graph already holds.
    /// The third element is what the arm CITES: tasks its sentence names, rendered as
    /// tappable references. Only the arm that speaks about a task may cite it — a
    /// citation row under an unrelated observation is a non sequitur with a chevron.
    private static func readingBody(
        for facts: TaskAdvisorFacts, spine: TaskShape
    ) -> (move: AdvisorMove, observation: String, cited: [UUID])? {
        if spine != .waiting, let blocker = facts.blockerTitles.first {
            let others = facts.blockerTitles.count - 1 + facts.externalWaits.count
            let tail = others > 0 ? " and \(others) other thing\(others == 1 ? "" : "s")" : ""
            return (.openBlocker, "This is waiting on “\(blocker)”\(tail).", [])
        }
        // An external wait has no task to open, so the move is `.advise` — offering
        // `.openBlocker` here would promise a row the view cannot render, and the trust
        // boundary would degrade it anyway.
        if spine != .waiting, let wait = facts.externalWaits.first {
            let others = facts.externalWaits.count - 1
            let tail = others > 0 ? " and \(others) other thing\(others == 1 ? "" : "s")" : ""
            return (.advise, "This is waiting on \(wait)\(tail).", [])
        }
        // No needsDecision arm, deliberately. The flag makes the shape `.deciding`
        // by construction, and the obligation block — which renders whenever the
        // flag is set, model or no model — already states it with its own controls.
        // A floor sentence here was the block's content repeated in prose, which is
        // exactly what "the floor never restates the spine" forbids.
        // Breakdown-eligibility speaks only when its evidence is user-visible: a big
        // estimate the user set, or a compound title in their own words.
        // `.planningIntent` is EXCLUDED — it derives from `workIntent`, and voicing it
        // ("this reads as planning") is axis 2 becoming accidental UI, which the task
        // model forbids. The model path may still propose steps from it; rung 0 stays
        // silent rather than narrate an internal classifier.
        if let reason = facts.breakdownReason, reason != .planningIntent {
            return (.advise, "\(reason.rationale).", [])
        }
        if let days = facts.overdueDays {
            return (.advise, "This was due \(days) day\(days == 1 ? "" : "s") ago.", [])
        }
        // Work waiting on THIS one. Not a problem with the task — a reason to finish it,
        // and the one fact rung 0 holds that points outward rather than inward.
        if let dependent = facts.dependentTitles.first {
            let others = facts.dependentTitles.count - 1
            let tail = others > 0 ? " and \(others) other thing\(others == 1 ? "" : "s")" : ""
            // The one arm that cites: "finishing this frees up X" becomes a place the
            // user can GO, not a sentence they must act on by searching.
            return (
                .advise, "Finishing this frees up “\(dependent)”\(tail).",
                Array(facts.dependentIDs.prefix(3))
            )
        }
        if spine != .container, facts.status == .doing {
            guard let label = facts.stepLabel else { return nil }
            return (.advise, "You're partway through this — \(label).", [])
        }
        // Choice-shaped wording under an obligation block is the block restated.
        if spine != .deciding, facts.decisionShaped {
            return (.advise, "This reads like a decision, not a doable step.", [])
        }
        return nil
    }
}
