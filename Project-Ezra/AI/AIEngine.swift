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
struct EdgeProposal: Hashable, Codable {
    enum Kind: String, Hashable, Codable { case duplicateOf, childOf }
    /// `.undecided` is DUPLICATE-ONLY: a merge destroys user data, so it stays
    /// confidence-tiered (0.85/0.5). A child link is additive and reversible, so
    /// `childOf` is auto-accepted above the suppression floor — the auto-accept
    /// invariant's single destructive-inference exception is the duplicate merge.
    enum Decision: String, Hashable, Codable {
        case accepted  // pre-selected, still confirm-gated
        case undecided  // duplicate 0.5–0.85 — shown as a question, user chooses
        case rejected  // the user said no → a suppression record at commit
    }
    var kind: Kind
    var targetID: UUID
    var targetTitle: String
    var confidence: Double
    var decision: Decision
}

/// A structured task the AI proposes from raw capture, before it is persisted.
struct TaskDraft: Identifiable, Hashable, Codable {
    // `var`, not `let`. Synthesized `Codable` SILENTLY SKIPS an immutable property with
    // an initial value: it compiles, encodes fine, and every decode mints a fresh id.
    // Nothing would have caught it — the suppression capture-form keys on a normalized
    // title by design, so it survives — but any draft identity carried across the
    // park/restore boundary (`ConfirmCreationList`'s ForEach, the remove-by-id path)
    // would break invisibly. See `Capture.parkedDrafts`.
    var id = UUID()
    var title: String
    var category: String
    // NOTE: there is no `proposedStatus`. The AI never proposes a lifecycle position,
    // because a draft is not a task — a `TaskItem` comes into existence at Confirm,
    // born `.todo`. Before that this struct lives on a parked `Capture`.
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
    /// Why this owner, in one short phrase — rendered as a caption under the owner
    /// chip, and the thing the ✦ "assumed" mark keys off. **Nil for `.defaultSelf`**:
    /// defaulting to the capturer is not an inference, and marking it as one would be
    /// worse for trust than the abstention it replaced. Set by `OwnerProposer`.
    var ownerReason: String? = nil
    /// How the owner was chosen. Drives three things: whether the ✦ shows, whether a
    /// corrected owner may teach a name-alias (only `.spoken` may — see
    /// `TaskDraft.corrections`), and whether `resolveOwners` is allowed to match a
    /// name the roster doesn't have.
    var ownerBasis: OwnerProposal.Basis = .defaultSelf
    /// Rough effort in minutes when clearly implied; nil otherwise.
    var effortMinutes: Int? = nil
    /// Open tasks that should WAIT ON this new task once it exists — the reverse
    /// dependency, detected at capture (external-note upgrade or model inference)
    /// and shown on the confirm card as a removable chip. Applied at commit as
    /// real `.task` edges with a reversible change-log entry each.
    var blocks: [OpenTaskSnapshot] = []
    /// Capture-graph proposals for THIS new task — duplicate / child edges to existing
    /// tasks, shown as confirm-card chips. Accepted ones execute at commit (a merge or a
    /// parent link); rejected ones write suppression records; undecided ones do nothing.
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
            // Only a SPOKEN owner may teach a name-alias. `CorrectionProfile` turns a
            // `"owner"` correction into `ownerAlias(spoken:actual:)` — correct when the
            // AI used a name the user actually said, and actively harmful otherwise: if
            // the proposer *inferred* Maya and the user changes it to Alex, learning
            // "Maya means Alex" would rewrite every future capture where they really do
            // say Maya. A proposer-derived correction is recorded under a field the
            // profile ignores, so the signal is kept and nothing is learned from it yet.
            let field = ownerBasis == .spoken ? "owner" : "ownerProposed"
            diffs.append((field, ai.ownerName ?? "you", ownerName ?? "you"))
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

    /// Materialize into a persistable model. **This is the moment the task comes into
    /// existence** — it is only ever called from `AppBrain.commit`, which is the
    /// Confirm boundary, so the task is born `.todo` with `confirmedAt` stamped.
    ///
    /// Neither the blocker nor the owner *reference* is set here — the blocked-on task
    /// may be elsewhere in the same batch, and the owner name needs resolving against
    /// the `FamilyMember` roster, so `commit` resolves both phrases into real
    /// references after every task in the batch is inserted.
    func makeTaskItem(
        rawCapture: String, captureID: UUID? = nil, now: Date = Date(),
        in context: NSManagedObjectContext
    )
        -> TaskItem
    {
        let task = TaskItem(
            title: title,
            category: category,
            status: .todo,
            confidence: confidence,
            isJudgmentCall: isJudgmentCall,
            needsDecision: needsDecision,
            reasoning: reasoning,
            dueDate: dueDate,
            isUrgent: isUrgent,
            ownerOrigin: ownerBasis == .spoken ? .human : .inferred,
            effortMinutes: effortMinutes,
            captureID: captureID,
            rawCapture: rawCapture,
            createdAt: now,
            in: context
        )
        task.workIntent = workIntent  // a pure field write — NEVER touches needsDecision
        task.confirmedAt = now  // creation IS the confirm; there is no later transition
        return task
    }
}

/// The AI-inferred field values at resolution time, frozen. What the Correction
/// diff compares against — never mutated by the review UI.
struct AIFieldSnapshot: Hashable, Codable {
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
struct OpenTaskSnapshot: Sendable, Hashable, Codable {
    var id: UUID
    var title: String
    /// The task's unresolved external blocker notes ("passport") — a note that
    /// matches a newly created task's title upgrades to a real `.task` edge.
    var externalBlockerNotes: [String] = []
    var category: String = "Admin"
    var updatedAt: Date = .distantPast
    var dueDate: Date? = nil
    var isBlocked: Bool = false
    /// The umbrella this task is a step of, when it has a `.parent` edge — surfaced
    /// in the retrieval fact line so the model sees the larger goal a candidate
    /// belongs to (the objective-lite signal).
    var parentTitle: String? = nil
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
    /// Suggestions the user has already rejected (`SuppressionStore`) — the resolver
    /// drops any matching proposal so a "no" sticks across captures.
    var suppressions: [RelationshipSuppression] = []

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

    // NOTE: the tier does not gate creation. A task exists only once the human taps
    // Confirm (`AppBrain.commit`), and it is born `.todo` regardless of how sure the
    // AI was. The tier governs everything that happens *after* it exists: affordances,
    // sweeps, and how much the AI may do silently.
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
