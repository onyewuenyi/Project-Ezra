//
//  TaskIntent.swift
//  Project-Ezra
//
//  The intermediate shape both engines emit — deliberately NOT a finished task.
//  Ambiguous references stay raw: `dateExpression` is the user's time phrase
//  verbatim ("next week", "friday"), `personReference` the name as spoken. A
//  deterministic resolver (`IntentResolver`) turns intents into `TaskDraft`s in
//  app code, so the model never silently picks which Friday "next week" means —
//  date/person resolution stays testable and deterministic rather than a
//  generation artifact.
//

import Foundation

/// What the model wants to do. Only `.create` is produced today; `.update` and
/// `.delete` are reserved for the live mid-utterance loop.
enum IntentAction: String, Codable, Sendable {
    case create, update, delete
}

/// One extracted intent, raw ambiguity intact.
struct TaskIntent: Sendable, Hashable {
    var action: IntentAction = .create
    /// Short verb-led action title.
    var title: String
    /// One of the canonical `TaskCategory` names.
    var category: String
    /// The user's time phrase, verbatim and unresolved ("tomorrow", "next week",
    /// "friday", or an ISO date the user actually said). Nil when no time
    /// dimension was expressed or inferred.
    var dateExpression: String?
    /// The other person's name as spoken, unresolved against any roster.
    var personReference: String?
    /// What this task waits on, as a raw phrase ("passport", "the Q3 deck").
    var blockerPhrase: String?
    /// The model's own score for this intent, 0…1. Recorded, never a gate.
    var confidence: Double
    /// The judgment-category rule's input: a values/life-priority call.
    var isJudgmentCall: Bool
    /// One-sentence explanation of the categorization.
    var reasoning: String
    /// The user's own Urgent signal, when the wording carries it ("asap", "urgent").
    /// A capture-time signal the confirm card can toggle; false when unstated.
    var isUrgent: Bool = false
    /// The model's importance estimate, 0…1 — the slow-moving input to the attention
    /// score. Nil when the engine has no signal (the heuristic infers a default).
    var importance: Double? = nil
    /// Rough effort in minutes when clearly implied.
    var effortMinutes: Int?
    /// Titles of EXISTING open tasks (from the provided open set) that logically
    /// cannot proceed until this new task is done — the model's half of reverse
    /// dependency detection. The resolver matches them back to real snapshots.
    var blocksExisting: [String] = []
    /// Capture-graph awareness: an existing candidate this new task is the SAME as
    /// (a duplicate), or a STEP OF (a child). Raw model output — the resolver validates
    /// the id against the candidate set and tiers by confidence. Nil when none.
    var duplicateOf: EdgeReference? = nil
    var childOf: EdgeReference? = nil
    /// The model's raw `WorkIntent` classification ("action"/"decision"/…). The heuristic
    /// path leaves it nil. Parsed to `WorkIntent` in the resolver.
    var workIntent: String? = nil
}

/// A reference to an existing task the model matched THIS capture against, with its
/// confidence. The id is validated against the candidate set downstream (unknown ids
/// dropped), so this is only ever a claim, never a committed edge.
struct EdgeReference: Sendable, Hashable {
    var targetID: UUID
    var confidence: Double
}
