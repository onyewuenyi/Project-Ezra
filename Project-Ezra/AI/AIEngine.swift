//
//  AIEngine.swift
//  Project-Ezra
//
//  The AI is the mechanism, not the pitch. This protocol is the seam between the
//  product loop and whatever intelligence backs it. Two implementations ship:
//  `FoundationModelsEngine` (on-device LLM, used when the device is capable) and
//  `HeuristicEngine` (deterministic rules, the always-available fallback).
//
//  Fallback strategy (declared here per the skill's guidance): the AI feature is
//  CORE, so we never hide it — we degrade to deterministic rules that keep the
//  full loop working, just with lower confidence and more Needs-Decision routing.
//

import CoreData
import Foundation

/// A proposed graph edge from a new capture to an EXISTING task — the confirm card's
/// duplicate / child chip. Never auto-executed: an accepted proposal rides the confirm
/// tap. Tiered by the model's confidence at resolution (see `IntentResolver`).
struct EdgeProposal: Hashable {
    enum Kind: String, Hashable { case duplicateOf, childOf }
    enum Decision: String, Hashable {
        case accepted  // ≥0.85 — pre-selected, still confirm-gated
        case undecided  // 0.5–0.85 — shown as a question, user chooses
        case rejected  // the user said no → a dismissed tombstone at commit
    }
    var kind: Kind
    var targetID: UUID
    var targetTitle: String
    var confidence: Double
    var decision: Decision
}

/// A structured task the AI proposes from raw capture, before it is persisted.
struct TaskDraft: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var category: String
    /// The status the AI proposes this task enter. The AI proposes this *once*, at
    /// triage — it never sets a status again.
    var proposedStatus: TaskStatus
    var confidence: Double
    /// The confidence/judgment tier, carried on the draft so `AppBrain.commit` can
    /// decide whether to log a silent-filing trail entry and the review UI can render
    /// the right affordance. On the persisted `TaskItem` this is derived, not stored.
    var autonomy: AutonomyTier
    var isJudgmentCall: Bool
    var reasoning: String
    var dueDate: Date?
    /// What this task is waiting on, when the capture names it ("after passport is
    /// done" → "passport"). A free-text hint the engine infers pre-commit (it can't
    /// know a real task reference yet); `AppBrain.commit` resolves it to a
    /// `TaskItem.blockedBy` reference, or drops it (task stays Ready) if nothing matches.
    var blockedBy: String? = nil
    /// The user's Urgent signal, proposed by the AI at capture and editable at confirm.
    var isUrgent: Bool = false
    /// The AI's importance estimate 0…1 — stamped into the attention score at commit.
    /// Nil when the engine has no signal.
    var aiImportance: Double? = nil
    /// The model's `WorkIntent` classification, stamped onto the task at materialization.
    /// Nil on the heuristic path (left to re-classify later, device-only).
    var workIntent: WorkIntent? = nil
    /// The other person's name when the capture delegates the task ("ask Sarah to…");
    /// nil means it's the user's own. The 1→N multiplayer seam starts here.
    var ownerName: String? = nil
    /// Mirrors `TaskItem.ownerPending`. Always `false` out of both engines — the
    /// ownership gate is applied once, centrally, by `AppBrain.applyOwnershipGate`,
    /// which is the only place household roster size is known.
    var ownerPending: Bool = false
    /// Rough effort in minutes when clearly implied; nil otherwise.
    var effortMinutes: Int? = nil
    /// Open tasks that should WAIT ON this new task once it exists — the reverse
    /// dependency, detected at capture (external-note upgrade or model inference)
    /// and shown on the confirm card as a removable chip. Applied at commit as
    /// real `.task` edges with a reversible change-log entry each.
    var blocks: [OpenTaskSnapshot] = []
    /// Capture-graph proposals for THIS new task — duplicate / child edges to existing
    /// tasks, shown as confirm-card chips. Accepted ones execute at commit (a merge or a
    /// parent link); rejected ones leave a dismissed tombstone; undecided ones do nothing.
    var edgeProposals: [EdgeProposal] = []

    /// The accepted duplicate proposal, if any — the one that turns this draft into a
    /// MERGE at commit (no new task; the target absorbs the capture).
    var acceptedDuplicate: EdgeProposal? {
        edgeProposals.first { $0.kind == .duplicateOf && $0.decision == .accepted }
    }

    /// The AI's original field values, frozen by the resolver before any human
    /// edit. The Confirm-Creation diff compares the edited draft against this to
    /// write `Correction` rows — every edit is a free labeled pair.
    var aiOriginal: AIFieldSnapshot? = nil

    /// The Needs Decision flag this draft will carry at birth: the judgment-category
    /// rule (a values-laden call is always the user's) or plain low confidence.
    var needsDecision: Bool {
        isJudgmentCall || confidence < 0.5
    }

    /// The fields the user changed after the AI filled them in — the learning
    /// signal. Empty when there's no snapshot (fixture drafts) or no edits.
    var corrections: [(field: String, aiValue: String, userValue: String)] {
        guard let ai = aiOriginal else { return [] }
        var diffs: [(String, String, String)] = []
        if title != ai.title { diffs.append(("title", ai.title, title)) }
        if category != ai.category { diffs.append(("category", ai.category, category)) }
        if dueDate != ai.dueDate {
            diffs.append(
                (
                    "dueDate", ai.dueDate.map(Self.dateString) ?? "none",
                    dueDate.map(Self.dateString) ?? "none"
                ))
        }
        if isUrgent != ai.isUrgent {
            diffs.append(("urgent", ai.isUrgent ? "true" : "false", isUrgent ? "true" : "false"))
        }
        if ownerName != ai.ownerName {
            diffs.append(("owner", ai.ownerName ?? "you", ownerName ?? "you"))
        }
        if effortMinutes != ai.effortMinutes {
            diffs.append(
                (
                    "effort", ai.effortMinutes.map(String.init) ?? "none",
                    effortMinutes.map(String.init) ?? "none"
                ))
        }
        if blockedBy != ai.blockerPhrase {
            diffs.append(("blocker", ai.blockerPhrase ?? "none", blockedBy ?? "none"))
        }
        // Reverse dependencies (`blocks`) are now diffed too — the prior gap where removing
        // a proposed dependent recorded no learning signal.
        let blockIDs = blocks.map(\.id.uuidString).sorted()
        let aiBlockIDs = ai.blocksIDs.map(\.uuidString).sorted()
        if blockIDs != aiBlockIDs {
            diffs.append(("blocks", aiBlockIDs.joined(separator: ","), blockIDs.joined(separator: ",")))
        }
        // Capture-graph proposal decisions the user changed (accept ↔ reject a duplicate
        // or a parent link) — a first-class learning signal.
        for proposal in edgeProposals {
            guard
                let original = ai.edgeProposals.first(where: {
                    $0.kind == proposal.kind && $0.targetID == proposal.targetID
                }), original.decision != proposal.decision
            else { continue }
            let field = proposal.kind == .duplicateOf ? "duplicate" : "parent"
            diffs.append((field, original.decision.rawValue, proposal.decision.rawValue))
        }
        return diffs
    }

    private static func dateString(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    /// The user accepting/adjusting a draft's proposed status during review.
    /// This satisfies the judgment-category rule (which forbids the *AI* deciding, not
    /// the human): the override moves to the silent tier while keeping
    /// `isJudgmentCall`/`reasoning` intact, so provenance is honest even though a
    /// person made the call. Ownership is a separate axis and is left untouched.
    mutating func userOverride(status newStatus: TaskStatus) {
        proposedStatus = newStatus
        autonomy = .silent
    }

    /// Materialize into a persistable model. Neither the blocker nor the owner
    /// *reference* is set here — the blocked-on task may be elsewhere in the same
    /// batch, and the owner name needs resolving against the `FamilyMember` roster
    /// (or auto-creating one), so `AppBrain.commit` resolves both `blockedBy` and
    /// `ownerName` (the phrases) into real references after all tasks are inserted.
    func makeTaskItem(
        rawCapture: String, captureID: UUID? = nil, in context: NSManagedObjectContext
    )
        -> TaskItem
    {
        let task = TaskItem(
            title: title,
            category: category,
            status: proposedStatus,
            confidence: confidence,
            isJudgmentCall: isJudgmentCall,
            needsDecision: needsDecision,
            reasoning: reasoning,
            dueDate: dueDate,
            isUrgent: isUrgent,
            ownerPending: ownerPending,
            effortMinutes: effortMinutes,
            captureID: captureID,
            rawCapture: rawCapture,
            in: context
        )
        task.workIntent = workIntent  // a pure field write — NEVER touches needsDecision
        return task
    }
}

/// The AI-inferred field values at resolution time, frozen. What the Correction
/// diff compares against — never mutated by the review UI.
struct AIFieldSnapshot: Hashable {
    var title: String
    var category: String
    var dueDate: Date?
    var isUrgent: Bool
    var ownerName: String?
    var effortMinutes: Int?
    var blockerPhrase: String? = nil
    /// The reverse-dependency ids the AI proposed — frozen so the confirm diff can
    /// record a removal (the prior gap).
    var blocksIDs: [UUID] = []
    /// The capture-graph proposals as the AI first tiered them, so a user's accept/reject
    /// is diffable.
    var edgeProposals: [EdgeProposal] = []
}

/// One roster entry, snapshotted as a value so it can cross into a Sendable
/// engine (and back the resolve-person tool) without dragging a NSManagedObjectContext.
struct RosterPerson: Sendable, Hashable {
    var name: String
    var relationship: String
}

/// One open task, snapshotted as a value for dependency detection AND capture-graph
/// retrieval at capture time — without dragging a NSManagedObjectContext. Enriched
/// (category/updatedAt/dueDate/isBlocked) so `ContextRetrieval` can rank a new capture
/// against the open set to surface near-duplicates and parents.
struct OpenTaskSnapshot: Sendable, Hashable {
    var id: UUID
    var title: String
    /// The task's unresolved external blocker notes ("passport") — a note that
    /// matches a newly created task's title upgrades to a real `.task` edge.
    var externalBlockerNotes: [String] = []
    var category: String = "Admin"
    var updatedAt: Date = .distantPast
    var dueDate: Date? = nil
    var isBlocked: Bool = false
    /// Task ids this one has already been dismissed-as-duplicate against (tombstones),
    /// so retrieval/proposals never re-surface a pair the user already rejected.
    var dismissedDuplicateIDs: [UUID] = []
}

/// Personal context handed to an engine per triage call. The context budget is
/// small, so this is never a history dump: `personalization` is the top-N learned
/// corrections as instruction lines, and `roster` is the household snapshot that
/// backs the person-resolution tool.
struct TriageContext: Sendable {
    /// Learned-correction instruction lines (see `CorrectionProfile`); nil when
    /// the user hasn't taught anything yet.
    var personalization: String? = nil
    /// Household members, for the resolve-person tool and the ownership gate.
    var roster: [RosterPerson] = []
    /// The open working set, for reverse dependency detection ("should anything
    /// already open wait on this new task?").
    var openTasks: [OpenTaskSnapshot] = []
    /// The retrieval-ranked slice of the graph most relevant to THIS capture — the
    /// candidate package the model gets for duplicate/child detection (the ONLY ids it
    /// may reference). Built by `ContextRetrieval`; empty when nothing is close enough.
    var candidates: [RetrievalCandidate] = []

    static let none = TriageContext()
}

/// The intelligence seam. Both implementations are `Sendable` and stateless per call.
protocol AIEngine: Sendable {
    /// Human-readable name of the engine actually in use (for the trust/settings UI).
    var engineName: String { get }
    /// Whether real on-device intelligence is backing this engine right now.
    var isOnDevice: Bool { get }

    /// Transform a raw capture (a single note or a pasted messy blob of many
    /// lines) into raw intents — ambiguity intact. `IntentResolver` turns these
    /// into `TaskDraft`s deterministically; the model never resolves dates or
    /// people itself. This is the core "collapse chaos into an honest,
    /// categorized set" operation used by both onboarding and capture.
    ///
    /// `onPartial` is the streaming fast path: an engine that can produce
    /// partial results mid-generation calls it with each snapshot of intents so
    /// candidates appear live; the full final result is still the return value.
    /// Engines that resolve instantly (the heuristic) simply ignore it.
    func triage(
        rawText: String,
        context: TriageContext,
        onPartial: (@MainActor ([TaskIntent]) -> Void)?
    ) async throws -> [TaskIntent]

    /// Phrase a calm, human summary of how the household is operating, from the
    /// deterministic facts `HouseholdEngine` already computed. Strictly a
    /// rephrasing — the engine restates the given facts and never invents tasks,
    /// people, or numbers. On device this is the LLM; the heuristic returns a
    /// deterministic template so the simulator and non-AI devices still get a
    /// sentence. Kept behaviorally consistent across both, like `triage`.
    func householdNarrative(_ facts: HouseholdFacts) async throws -> String
}

extension AIEngine {
    /// Context-free convenience for tests and one-shot callers.
    func triage(rawText: String) async throws -> [TaskIntent] {
        try await triage(rawText: rawText, context: .none, onPartial: nil)
    }
}

// MARK: - Shared autonomy derivation

enum AutonomyPolicy {
    /// Map a confidence score + judgment flag onto an autonomy tier, applying the
    /// judgment-category rule: a values-laden decision is always `.ask`, no matter
    /// how confident the model is.
    static func tier(confidence: Double, isJudgmentCall: Bool) -> AutonomyTier {
        if isJudgmentCall { return .ask }
        switch confidence {
        case 0.8...: return .silent
        case 0.5..<0.8: return .suggest
        default: return .ask
        }
    }

    // NOTE: there is no proposedStatus any more. Creation ALWAYS lands in `.inbox`
    // awaiting the one-tap Confirm-Creation glance (always-confirm) — the resolver
    // stamps it. The tier still governs everything that happens to a task *after*
    // it exists: affordances, sweeps, and how much the AI may do silently.
}

// MARK: - Category vocabulary (shared by both engines)

enum TaskCategory {
    static let all = [
        "Personal", "Work", "Home", "Car", "Travel",
        "Health", "Finance", "Family", "Errands", "Admin",
    ]

    static func symbol(for category: String) -> String {
        switch category.lowercased() {
        case "personal": return "person"
        case "work": return "briefcase"
        case "home": return "house"
        case "car": return "car"
        case "travel": return "airplane"
        case "health": return "heart"
        case "finance": return "dollarsign.circle"
        case "family": return "figure.2.and.child.holdinghands"
        case "errands": return "bag"
        case "admin": return "tray.full"
        default: return "circle.grid.2x2"
        }
    }
}
