//
//  TaskAdvisorReading.swift
//  Project-Ezra
//
//  The Advisor's one compositional response — Next Move, not a capability taxonomy.
//  `TaskAdvisorReading` is UNTRUSTED TRANSPORT: the model's freedom lives in the prose
//  (observation · guidance · next move), and the `action` string is the small internal
//  vocabulary the app can execute. `validated(against:)` is the trust boundary — it
//  produces `ValidatedReading`, the canonical domain object the UI renders and the
//  store caches. Nothing downstream ever touches raw model output.
//
//  Grounding rules (drop/degrade, never substitute):
//  - decide: options clamped 2–4; the recommendation must name one of its OWN options
//    verbatim (the `groundedRecommendation` pattern) or it is dropped whole.
//  - createSteps: steps sanitized to 2–5 with clamped efforts; fewer → degrade to advise.
//  - openBlocker: the facts must actually carry an active blocker, else → advise.
//  - An unknown action string degrades to advise — which is exactly how future moves
//    (research, draft, schedule, delegate, clarify) arrive without a schema rewrite.
//  - nothing discards everything else: silence is a complete answer.
//
//  ⚠️ Device-verify: the `@Generable` schema and the action-string decode. The
//  simulator may not exercise it.
//

import Foundation
import FoundationModels

/// The internal move vocabulary — the contract between intelligence and application
/// behavior. `.nothing` is silence (no surface at all); `.advise` is a words-only
/// reading. The user never sees these names.
enum AdvisorMove: String, Sendable, Equatable, CaseIterable {
    case nothing
    case advise
    case decide
    case createSteps
    case openBlocker

    /// Tolerant decode: trims and case-folds; unknown strings return nil and the
    /// validator degrades them to `.advise`, so a model that learns a new move
    /// tomorrow produces advice today, never a crash or a dropped reading.
    init?(lenient raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let match = Self.allCases.first(where: { $0.rawValue.lowercased() == key }) else {
            return nil
        }
        self = match
    }
}

@Generable
struct TaskAdvisorReading: Sendable {
    @Guide(
        description:
            "One or two plain sentences on what you noticed about this task — grounded ONLY in the given facts. Never invent a blocker, a deadline, or a person."
    )
    let observation: String

    @Guide(
        description:
            "One or two sentences of guidance — why this is the situation and what would help. Empty string when the observation says it all."
    )
    let guidance: String

    @Guide(
        description:
            "The single best next move, one short concrete sentence. Empty when the action is nothing."
    )
    let nextMove: String

    /// The move, constrained at the DECODER (`.anyOf`), not merely requested in prose.
    /// A `description` is prompt text the model may violate; a `GenerationGuide` is
    /// enforced by constrained decoding, so an off-vocabulary emission is structurally
    /// impossible rather than silently degrading to `.advise` and losing a real
    /// `decide` reading. The field stays a `String` and `AdvisorMove(lenient:)` stays
    /// the reader: constrain the model where possible, keep an application-level
    /// escape hatch where necessary.
    @Guide(
        description:
            "Use nothing when you have nothing useful to add — that is a good answer. Use advise when the words are the help and no button applies.",
        .anyOf(AdvisorMove.allCases.map(\.rawValue))
    )
    let action: String

    @Guide(
        description:
            "The distinct options in play when action is decide, 2 to 4, drawn only from the task and its context. Empty otherwise."
    )
    let options: [AdvisorOption]

    @Guide(
        description:
            "When action is decide and the facts clearly favor one option, its label copied EXACTLY. Empty otherwise — an honest abstention beats a coin flip dressed as advice."
    )
    let recommendation: String

    @Guide(
        description:
            "One plain sentence on why that option fits, grounded only in the given facts. Empty when recommendation is empty."
    )
    let recommendationWhy: String

    @Guide(
        description:
            "The concrete steps when action is createSteps, 2 to 5, each independently doable with effortMinutes one of 15, 30, 60, or 120. Empty otherwise."
    )
    let steps: [AdvisorStep]
}

@Generable
struct AdvisorOption: Sendable {
    @Guide(description: "A short label for this option, at most 6 words.")
    let label: String

    @Guide(description: "One plain sentence on this option's key tradeoff.")
    let tradeoff: String
}

@Generable
struct AdvisorStep: Sendable {
    @Guide(description: "A short imperative title for this step, at most 8 words.")
    let title: String

    @Guide(description: "Rough minutes for this step — one of 15, 30, 60, or 120.")
    let effortMinutes: Int
}

// MARK: - The canonical domain contract

/// One option, post-validation. A plain value so the state machine stays `Equatable`
/// without leaning on generated conformances.
struct AdvisorChoice: Sendable, Equatable {
    let label: String
    let tradeoff: String
}

struct AdvisorRecommendation: Sendable, Equatable {
    let label: String
    let why: String
}

/// The reading the UI renders and the store caches — every per-move payload proven
/// present, every string trimmed, the move typed. THE product contract; the generated
/// struct above never crosses the service boundary.
struct ValidatedReading: Sendable, Equatable {
    let move: AdvisorMove
    let observation: String
    let guidance: String?
    let nextMove: String?
    /// Non-empty only for `.decide`.
    let options: [AdvisorChoice]
    let recommendation: AdvisorRecommendation?
    /// Non-empty only for `.createSteps` — already `BreakdownStep`s, ready for `splitInto`.
    let steps: [BreakdownStep]
    /// The deterministic facts this reading was made from, in the user's terms — what
    /// "Why this?" reveals. **Bound to the reading, never recomputed later**, so the
    /// evidence can't drift from the reading that used it. The model contributes
    /// nothing to it (see `TaskAdvisorFacts.userVisibleEvidence`).
    var evidence: [String] = []

    /// The silence value — what `.nothing` validates to.
    static let silence = ValidatedReading(
        move: .nothing, observation: "", guidance: nil, nextMove: nil,
        options: [], recommendation: nil, steps: [])
}

extension TaskAdvisorReading {

    /// The trust boundary. Returns nil only when nothing usable survives (an empty
    /// observation on a non-nothing move) — which the service reports as
    /// `noUsableOutput`, never renders.
    /// The first `limit` sentences, trimmed.
    ///
    /// Uses `enumerateSubstrings(.bySentences)` rather than splitting on ".", which would
    /// cut "This is ~15 min. of work." in half — measured: the tokenizer keeps that one
    /// whole, where a naive split does not.
    ///
    /// It is NOT abbreviation-proof, which was worth measuring rather than assuming. A
    /// leading title splits off as its own fragment — "Dr. Patel's referral is the
    /// blocker." enumerates as ["Dr.", "Patel's referral is the blocker."] — so a plain
    /// count-based clamp would return the word "Dr." as the whole observation. Hence
    /// `minimumMeaningful`: the clamp counts sentences but never returns a fragment too
    /// short to BE one, and keeps taking until it has something substantive. That handles
    /// the general case without a brittle list of abbreviations to maintain.
    ///
    /// A single pathologically long sentence passes through UNCHANGED and on purpose:
    /// that is a prompt problem, and it should surface in the eval's word count where it
    /// can be fixed, not be hidden here behind a silent ellipsis.
    static func clamped(_ text: String, sentences limit: Int) -> String {
        guard limit > 0 else { return "" }
        var kept: [String] = []
        let ns = text as NSString
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length),
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, stop in
            let piece = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { return }
            kept.append(piece)
            let soFar = kept.joined(separator: " ")
            if kept.count >= limit, soFar.count >= Self.minimumMeaningful {
                stop.pointee = true
            }
        }
        return kept.isEmpty ? text : kept.joined(separator: " ")
    }

    /// Below this many characters, a "sentence" is a tokenizer artefact (a title, an
    /// initial) rather than a thought, and the clamp keeps reading.
    static let minimumMeaningful = 16

    func validated(against facts: TaskAdvisorFacts) -> ValidatedReading? {
        let move = AdvisorMove(lenient: action) ?? .advise
        if move == .nothing { return .silence }

        // Brevity is enforced HERE, not requested in the prompt. "One sentence" is a hope
        // when it is only an instruction; a small model at temperature 0.5 will sometimes
        // add the helpful second sentence, and by then the card has already grown. The
        // clamp is the same shape as `sanitizedOptions` — a COLLECTION CLAMP over
        // sentences, never a rewrite, never a mid-word cut, never an ellipsis.
        //
        // **This is also the depth guardrail, and it takes no rung parameter on purpose.**
        // As models get stronger the temptation is to let a better one say more, and that
        // is exactly backwards: sophistication must show up as a better diagnosis and
        // sharper silence, never as more text. A deep reading that turns "you haven't
        // picked a restaurant, and everything else depends on it" into seven hundred words
        // has not become more intelligent — it has become a pile of work disguised as
        // help. The visible contract (one judgment, at most one move) is therefore
        // constant across every rung, which is also what lets providers be swapped without
        // the product changing shape.
        let observation = Self.clamped(trimmed(observation), sentences: 1)
        guard !observation.isEmpty else { return nil }
        // Guidance gets TWO. It sits behind the disclosure, so the person reading it has
        // asked for more — clamping a request for depth to one sentence answers a
        // different question than the one they asked.
        let guidance = nonEmpty(guidance).map { Self.clamped($0, sentences: 2) }
        let nextMove = nonEmpty(nextMove).map { Self.clamped($0, sentences: 1) }
        // The evidence is attached HERE, where the facts are still in hand, so a
        // reading always carries the receipt it was made from.
        let evidence = facts.userVisibleEvidence

        switch move {
        case .nothing:
            return .silence

        case .decide:
            let choices = Self.sanitizedOptions(options)
            guard choices.count >= 2 else {
                return advise(observation, guidance, nextMove, evidence)
            }
            return ValidatedReading(
                move: .decide, observation: observation, guidance: guidance, nextMove: nextMove,
                options: choices, recommendation: grounded(in: choices), steps: [],
                evidence: evidence)

        case .createSteps:
            let cleaned = BreakdownStep.sanitized(
                steps.map { BreakdownStep(title: $0.title, effortMinutes: $0.effortMinutes) })
            guard cleaned.count >= 2 else {
                return advise(observation, guidance, nextMove, evidence)
            }
            return ValidatedReading(
                move: .createSteps, observation: observation, guidance: guidance,
                nextMove: nextMove, options: [], recommendation: nil, steps: cleaned,
                evidence: evidence)

        case .openBlocker:
            guard !facts.blockerTitles.isEmpty else {
                return advise(observation, guidance, nextMove, evidence)
            }
            return ValidatedReading(
                move: .openBlocker, observation: observation, guidance: guidance,
                nextMove: nextMove, options: [], recommendation: nil, steps: [],
                evidence: evidence)

        case .advise:
            return advise(observation, guidance, nextMove, evidence)
        }
    }

    private func advise(
        _ observation: String, _ guidance: String?, _ nextMove: String?, _ evidence: [String]
    )
        -> ValidatedReading
    {
        ValidatedReading(
            move: .advise, observation: observation, guidance: guidance, nextMove: nextMove,
            options: [], recommendation: nil, steps: [], evidence: evidence)
    }

    /// Trim, drop empties, de-duplicate case-insensitively, clamp to 4. Order kept —
    /// sequence is the model's contribution.
    static func sanitizedOptions(_ raw: [AdvisorOption]) -> [AdvisorChoice] {
        var seen = Set<String>()
        var out: [AdvisorChoice] = []
        for option in raw {
            let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(label.lowercased()).inserted else { continue }
            out.append(
                AdvisorChoice(
                    label: label,
                    tradeoff: option.tradeoff.trimmingCharacters(in: .whitespacesAndNewlines)))
            if out.count == 4 { break }
        }
        return out
    }

    /// The recommendation, only when it names one of the reading's OWN surviving
    /// options (case-insensitive). Anti-hallucination at the read: a recommendation
    /// pointing at an option that doesn't exist is dropped whole, never rendered.
    private func grounded(in choices: [AdvisorChoice]) -> AdvisorRecommendation? {
        let pick = trimmed(recommendation)
        guard !pick.isEmpty,
            let match = choices.first(where: { $0.label.caseInsensitiveCompare(pick) == .orderedSame })
        else { return nil }
        return AdvisorRecommendation(label: match.label, why: trimmed(recommendationWhy))
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nonEmpty(_ s: String) -> String? {
        let t = trimmed(s)
        return t.isEmpty ? nil : t
    }
}
