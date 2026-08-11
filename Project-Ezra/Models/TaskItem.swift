//
//  TaskItem.swift
//  Project-Ezra
//
//  The core domain model. A task carries FOUR separate axes, never fused (see
//  `docs/task-model.md`): Lifecycle (`TaskStatus`, single-value, user-owned), Type
//  (`WorkIntent`, AI-classified and human-correctable), Attention flags (stackable —
//  Needs Decision, Blocked, Overdue, Stale), and Signals (`isUrgent`, human-declared,
//  feeding the computed `AttentionEngine` score). Only Needs Decision, Overdue, and
//  Urgent are ever visible; everything else manifests as position.
//

import CoreData
import Foundation

// MARK: - Status (the user-owned lifecycle axis)

/// The one axis a task moves along: `Todo → Doing → Done | Canceled`. It is
/// *lifecycle only* — deliberately free of AI judgment. "Does this need a
/// decision?", "is it blocked?" are flags a task wears, never states here.
///
/// **A `TaskItem` is born `.todo` at Confirm and never exists before it.** The
/// retired `.inbox` case was a ghost: every creation path confirmed in the same
/// breath, so nothing ever rested there. Pre-Confirm state lives on a parked
/// `Capture` (raw text + encoded drafts), which is explicitly *not* a task — that is
/// the single representation of "not yet committed".
///
/// `todo`/`doing` stays split rather than collapsing into one "active": it is what
/// makes `stateTimeline` real cycle-time data ("In progress for 4h") instead of an
/// undifferentiated dwell. `done`/`canceled` stay split so the resolution-honesty
/// signal survives — Recap counts completions, `Metrics.rotRate` counts kills.
enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case todo  // confirmed, in the working set, not started
    case doing  // in flight
    case done  // resolved by completion
    case canceled  // resolved as not-doing (manual kill or the reversible auto-archive)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .todo: return "Todo"
        case .doing: return "In Progress"
        case .done: return "Done"
        case .canceled: return "Canceled"
        }
    }

    /// A resolved task has left the working set — done and canceled alike.
    var isResolved: Bool { self == .done || self == .canceled }

    /// Live work: confirmed and not yet resolved. Replaces the ~40 "is this active"
    /// checks the two-field model needed. Nothing stores this and nothing writes
    /// through it, so it is a read-through of the one lifecycle axis, not a second one.
    var isLive: Bool { self == .todo || self == .doing }
}

// MARK: - Autonomy tiers (gated on confidence AND reversibility)

enum AutonomyTier: String, Codable {
    case silent  // high confidence + reversible → runs without asking
    case suggest  // high confidence but costly → one-tap confirm
    case ask  // low confidence or values-laden → asks first

    var confirmationLabel: String {
        switch self {
        case .silent: return "Automatically updated"
        case .suggest: return "AI suggestion — Accept"
        case .ask: return "Needs your input"
        }
    }
}

// MARK: - Work intent (what KIND of work this is — computed, never permanent)

/// The shape of work a task represents, classified by the model and cached — never
/// a permanent stored fact. Refreshed on material title/notes edits and on
/// structural change (gaining/losing a child or a blocker), so a "planning" task
/// that gets decomposed doesn't stay "planning" forever.
///
/// **`.decision` is retired as a type** (2026-08-08): choosing is not a kind of work
/// the user should have to classify — it is a capability the system brings. The
/// Thinking Partner now triggers on the `needsDecision` flag or on choice-shaped
/// wording (`DecisionShape`), and never on this axis. Neither case here reads or
/// writes `needsDecision`.
enum WorkIntent: String, Codable, CaseIterable, Identifiable {
    case action  // a concrete thing to do
    case planning  // figuring out an approach / breaking something down

    var id: String { rawValue }

    var label: String {
        switch self {
        case .action: return "Action"
        case .planning: return "Planning"
        }
    }

    /// Decode a stored raw value, absorbing retired vocabulary. Additive-in-practice:
    /// rows written before the retirement carry `"decision"`, and a wipe over a
    /// raw-string vocabulary would be spending schema budget on a rename. A decision
    /// to make is nearest to figuring out an approach, so legacy rows read as
    /// `.planning`. Nothing may WRITE `"decision"` after this — the setter goes
    /// through the two live cases only.
    static func decode(_ raw: String) -> WorkIntent? {
        if let intent = WorkIntent(rawValue: raw) { return intent }
        return raw == "decision" ? .planning : nil
    }
}

// MARK: - Owner origin (who established this ownership)

/// How a task's current `ownerID` came to be. Stored, because it cannot be
/// reconstructed later — and because one consumer depends on it structurally.
///
/// **The affinity denominator counts `.human` only.** `OwnerProposer`'s rung 4
/// (`.defaultSelf`) makes the capturer the owner of everything the earlier rungs
/// miss, which is most things. If category-ownership share were computed over all
/// tasks, those defaults would flood every denominator and a genuinely-preferred
/// owner could never cross the threshold — the rung would be unreachable by
/// construction. Counting human intent instead of the proposer's own output is what
/// lets it learn.
///
/// `.human` = the user spoke the name at capture, or a human reassigned it later
/// (`claim`). `.inferred` = the proposer chose it (adjacency, affinity, or default).
enum OwnerOrigin: String, Codable {
    case human
    case inferred
}

// MARK: - Confidence tier (derived, for display)

enum ConfidenceTier {
    case high, medium, low

    init(score: Double) {
        switch score {
        case 0.8...: self = .high
        case 0.5..<0.8: self = .medium
        default: self = .low
        }
    }
}

// MARK: - Staleness policy (the rot thresholds)

/// The two rot thresholds for undated tasks. Stale is always derived from
/// `updatedAt` — never stored, never a background job flipping bits.
enum StalePolicy {
    /// Untouched past this → surfaces in the Weekly Retro queue.
    static let retroThreshold: TimeInterval = 7 * 24 * 3600
    /// Untouched past this → eligible for the silent, reversible auto-archive.
    static let archiveThreshold: TimeInterval = 21 * 24 * 3600
}

// MARK: - AI Assessment (the derived observation axis)

/// Why a task needs a decision — the honest split under the one visible flag.
enum NeedsDecisionReason: Equatable {
    case humanJudgment  // a values/life-priority call the AI must never resolve (isJudgmentCall)
    case lowConfidence  // the AI wasn't sure enough (confidence < 0.5)
}

/// What Ezra observes about a task *right now*. `needsDecision` reads the stored
/// flag (the one visible flag; set at triage or by Escalate-to-Decision, cleared
/// only by a human decision); everything else is derived fresh on read from
/// stored fields, so no column can drift out of sync with the observation.
struct TaskAssessment: Equatable {
    var needsDecision: NeedsDecisionReason?
    var isBlocked: Bool  // has ≥1 active blocker
    var isUnowned: Bool  // a household gap: handed back to the household (ownerID == nil)
    var isStale: Bool  // undated and untouched past the retro threshold
    var tier: AutonomyTier  // the confidence/judgment → silent/suggest/ask mapping

    /// True when the AI has nothing to flag — the card shows no assessment chip.
    var isClean: Bool { needsDecision == nil && !isBlocked && !isUnowned }
}

// MARK: - State timeline (temporal instrumentation)

/// One continuous stay in a single status. The task's timeline is an ordered list
/// of these — the honest record of where a task actually spent its life, including
/// backward moves (reopen). The last visit is "open" (`exitedAt == nil`).
struct StateVisit: Codable, Hashable {
    /// The `TaskStatus.rawValue` that was entered. Stored raw so the persisted
    /// record survives even if the enum's cases change.
    let state: String
    let enteredAt: Date
    /// nil while this is the current state; stamped when the task moves on.
    var exitedAt: Date?

    /// Closed duration. Nil for the open visit — callers decide whether to extend
    /// it to "now" (see `TaskItem.secondsIn(_:now:)`); we never invent an end.
    var duration: TimeInterval? {
        exitedAt.map { $0.timeIntervalSince(enteredAt) }
    }
}

// MARK: - TaskItem

@objc(TaskItem)
final class TaskItem: NSManagedObject {
    /// Stable identity for linking change-log entries back to their task, so an
    /// Undo can revert the actual task (not just strike the log line). Optional for
    /// CloudKit; always set in `init`.
    @NSManaged var uuid: UUID?
    @NSManaged var title: String
    /// The "area" this belongs to (Personal, Car, Travel, …).
    @NSManaged var category: String
    @NSManaged private var statusRaw: String
    /// Who authored this task — a `FamilyMember.uuid` (stamped at commit for a real
    /// capture; the current user's linked member). Distinct from `ownerID` (who it's
    /// *for*): the My Tasks "Created" tab keys off this. Optional for CloudKit.
    @NSManaged var creatorID: UUID?
    /// AI confidence in its categorization/framing, 0…1. Recorded on every task
    /// (instrument now, tune later) — it never gates capture.
    @NSManaged var confidence: Double
    /// True when this is a values/life-priority call the AI must never resolve
    /// on its own, regardless of confidence (the judgment-category rule).
    @NSManaged var isJudgmentCall: Bool
    /// The one visible flag. Set at triage (judgment call OR confidence < 0.5) or
    /// by Escalate-to-Decision; cleared only by a human decision (Confirm). Stored,
    /// not derived, because escalation is an action, not a recomputation.
    @NSManaged var needsDecision: Bool
    /// One-sentence AI explanation, surfaced on the card.
    @NSManaged var reasoning: String
    @NSManaged var dueDate: Date?
    @NSManaged var createdAt: Date
    /// Last meaningful touch — every mutation helper bumps this, and it drives
    /// Stale detection (untouched-since). Defaults to `createdAt` at birth.
    @NSManaged var updatedAt: Date
    /// When the user tapped Confirm at creation (Inbox → Active). Nil while inbox.
    @NSManaged var confirmedAt: Date?
    /// When this task was resolved (done or killed) — nil while open.
    @NSManaged var completedAt: Date?
    /// Set by Kill (manual, retro, or stale auto-archive). Nil otherwise.
    @NSManaged var killedAt: Date?
    /// The Capture record this task was parsed from. Nil for tasks with non-capture
    /// origins (e.g. a future Split-Into-Subtasks).
    @NSManaged var captureID: UUID?
    /// Free-form user notes, editable in the detail sheet.
    @NSManaged var notes: String?
    /// Original raw capture text, kept for re-triage / provenance.
    @NSManaged var rawCapture: String

    // Metadata that drives AI features. All optional/defaulted: metadata is never
    // mandatory (product guardrail) and CloudKit needs optional-or-defaulted.

    /// The user attention Signal, feeding the computed `attention` score. `isUrgent`
    /// is "this matters now" — user-owned, though the AI proposes it at capture
    /// (editable at confirm). Written only through `setUrgent` so the touch clock +
    /// attention recompute stay honest. (Pinned is retired: a manual float-to-top
    /// override competed with the score it was meant to complement.)
    @NSManaged var isUrgent: Bool
    /// The persisted attention score + contributors (`AttentionMetadata`), bridged by
    /// the `attention` accessor. Optional/nil until first scored (reads as `.neutral`).
    @NSManaged private var attentionData: Data?
    /// The task's cached `WorkIntent`, stored raw. Nil until classified (heuristic
    /// path leaves it nil). Bridged by the `workIntent` accessor.
    @NSManaged private var workIntentRaw: String?
    /// Who this task belongs to — a `FamilyMember.uuid`, including the current user's
    /// own linked member (see `UserProfile.linkedMemberID`). `nil` now means
    /// **unassigned / household-shared** work, NOT "you" — every owned task, yours
    /// included, carries an explicit `ownerID` (stamped at commit/claim). The old
    /// `nil == you` sentinel is retired; `isMine(currentUserID:)` compares against the
    /// device's own member id so "mine" is correct on every synced device.
    @NSManaged var ownerID: UUID?
    /// How the current `ownerID` was established (`OwnerOrigin`), stored raw. Nil is
    /// read as `.inferred` — an unstamped owner is never evidence of human intent.
    /// Bridged by the `ownerOrigin` accessor.
    ///
    /// (`ownerPending` is retired. Every task is born owned, so the AI never abstains;
    /// "unowned" now has exactly one spelling, `ownerID == nil`, set only by a human
    /// handing a task back to the household.)
    @NSManaged private var ownerOriginRaw: String?
    /// Backing store for `effortMinutes` — Core Data has no optional scalar Int, so it's
    /// held as an optional NSNumber and bridged by the `effortMinutes` accessor.
    @NSManaged private var effortMinutesValue: NSNumber?
    /// The task's state history, JSON-encoded `[StateVisit]`. Written only through
    /// `transition(to:now:)`, which every status change funnels through.
    @NSManaged private var stateTimelineData: Data?
    /// The task's graph edges, JSON-encoded `[Relationship]` in a versioned envelope
    /// (`RelationshipStore`) — absorbing the old `blockersData` + `parentTaskID` into
    /// one durable blob. A durable list: a `.blocks` edge to a real task stays here
    /// even after its target completes, so reopening that target re-blocks this task.
    /// Bridged by the `relationships` accessor; written ONLY through the `TaskMutations`
    /// helpers (the mutation choke point).
    ///
    /// **The one rule:** a task reads as blocked (`TaskAssessment.isBlocked`) iff
    /// `activeBlockers(among:)` is non-empty. Blocked is never a status and is
    /// never written — mutations add/remove a `.blocks` edge and the assessment
    /// derives it on read, so "blocked with nothing blocking it" is unrepresentable.
    @NSManaged private var relationshipsData: Data?

    // Deferral + engagement facts. FACTS, not reasoning — they live here with the
    // other facts, never inside the attention metadata blob. Written by the Today
    // plan seam (`TodayPlanStore`) and the graph mutations; read live by
    // `TaskRanking.currentRelevance`.

    /// Times this task appeared in a committed Today plan and was left UNTOUCHED —
    /// the true skip signal (`currentRelevance` pulls it down). Distinct from
    /// `carriedOverCount`: conflating them would penalize actively-worked multi-day
    /// tasks, the inverted signal.
    @NSManaged var deferralCount: Int32
    /// Times this task was planned, worked on (a human touch since it surfaced), but
    /// not finished. Deliberately written-but-unread by ranking for now — the
    /// distinction can't be backfilled later, so it's recorded from day one.
    @NSManaged var carriedOverCount: Int32
    /// The last time this task appeared in a generated Today plan.
    @NSManaged var lastSurfacedAt: Date?
    /// When this task's last ACTIVE blocker cleared (the recently-unblocked boost).
    /// Stamped by the unblock mutations and the resurface seam — nothing else about
    /// an edge removal survives, so this fact must be written at the moment it happens.
    @NSManaged var lastUnblockedAt: Date?
    /// The HUMAN clock: the last human-initiated edit (`touchHuman`). `updatedAt` is
    /// also bumped by system paths (capture-time edge writes on existing tasks), so
    /// staleness and the plan-reconcile deferral discriminator read THIS, falling
    /// back to `createdAt` while nil.
    @NSManaged var lastHumanTouchAt: Date?

    /// The honest untouched-since clock for staleness-style reads: the last human
    /// touch, or birth when no human has touched it yet.
    var humanTouchedAt: Date { lastHumanTouchAt ?? createdAt }

    /// Rough effort estimate in minutes, when the wording implies one. Feeds the
    /// quick-win signal. Bridges the optional-scalar `effortMinutesValue`.
    var effortMinutes: Int? {
        get { effortMinutesValue?.intValue }
        set { effortMinutesValue = newValue.map(NSNumber.init(value:)) }
    }

    convenience init(
        title: String,
        category: String = "Admin",
        status: TaskStatus = .todo,
        creatorID: UUID? = nil,
        confidence: Double = 0.5,
        isJudgmentCall: Bool = false,
        needsDecision: Bool = false,
        reasoning: String = "",
        dueDate: Date? = nil,
        blockedBy: [UUID] = [],
        isUrgent: Bool = false,
        ownerID: UUID? = nil,
        ownerOrigin: OwnerOrigin = .inferred,
        effortMinutes: Int? = nil,
        captureID: UUID? = nil,
        notes: String? = nil,
        rawCapture: String = "",
        createdAt: Date = Date(),
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(
            entity: NSEntityDescription.entity(forEntityName: "TaskItem", in: context)!, insertInto: context)
        self.uuid = UUID()
        self.title = title
        self.category = category
        self.statusRaw = status.rawValue
        self.creatorID = creatorID
        self.confidence = confidence
        self.isJudgmentCall = isJudgmentCall
        self.needsDecision = needsDecision
        self.reasoning = reasoning
        self.dueDate = dueDate
        // The `blockedBy:` parameter stays for callers/fixtures that speak in task
        // references; it lands as human-provenance `.blocks` edges in the graph blob.
        self.relationshipsData =
            blockedBy.isEmpty
            ? nil : RelationshipStore.encode(blockedBy.map { Relationship.blocks(taskID: $0) })
        self.isUrgent = isUrgent
        self.attentionData = nil
        self.workIntentRaw = nil
        self.ownerID = ownerID
        self.ownerOriginRaw = ownerOrigin.rawValue
        self.effortMinutes = effortMinutes
        self.captureID = captureID
        self.notes = notes
        self.rawCapture = rawCapture
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.confirmedAt = nil
        self.completedAt = nil
        self.killedAt = nil
        // Open the first visit at birth, so dwell is measured from creation rather
        // than from the first transition. Note this assigns `stateTimelineData`
        // directly: `init` sets `statusRaw` without going through the `status`
        // setter, so `transition` never runs here (correct — nothing came before
        // creation).
        self.stateTimelineData = try? JSONEncoder().encode(
            [StateVisit(state: status.rawValue, enteredAt: createdAt, exitedAt: nil)]
        )
    }

    /// Every status write in the app funnels through this setter — the mutation
    /// helpers and the change log's undo revert alike — so no transition can be
    /// silently missed. Time is `Date()` here; callers that already have an
    /// authoritative timestamp (`complete(now:)`, `kill(now:)`) call
    /// `transition(to:now:)` directly instead.
    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .todo }
        set { transition(to: newValue) }
    }

    /// How the current owner was established. Nil reads as `.inferred` — an unstamped
    /// owner is never evidence of human intent, which is the safe direction for the
    /// affinity denominator (see `OwnerOrigin`).
    var ownerOrigin: OwnerOrigin {
        get { ownerOriginRaw.flatMap(OwnerOrigin.init(rawValue:)) ?? .inferred }
        set { ownerOriginRaw = newValue.rawValue }
    }

    /// Record a status change and close out the previous state's visit.
    ///
    /// Writes `statusRaw` directly rather than `status`, which is what keeps the
    /// computed-setter funnel from recursing into itself.
    func transition(to newState: TaskStatus, now: Date = Date()) {
        let current = TaskStatus(rawValue: statusRaw) ?? .todo
        // Landing on the same state isn't a transition: the task never left, so the
        // clock keeps running and no visit is recorded.
        guard newState != current else { return }

        var timeline = stateTimeline
        if let last = timeline.indices.last, timeline[last].exitedAt == nil {
            timeline[last].exitedAt = now
        }
        timeline.append(StateVisit(state: newState.rawValue, enteredAt: now, exitedAt: nil))
        stateTimeline = timeline
        statusRaw = newState.rawValue
        updatedAt = now
    }

    /// The autonomy tier is a *derived assessment*, not stored: it is purely the
    /// confidence/judgment → silent/suggest/ask mapping, so there is no separate
    /// column that could disagree with `confidence`/`isJudgmentCall`.
    var autonomy: AutonomyTier {
        AutonomyPolicy.tier(confidence: confidence, isJudgmentCall: isJudgmentCall)
    }

    var confidenceTier: ConfidenceTier { ConfidenceTier(score: confidence) }

    /// The persisted attention score + explanation. Reads as `.neutral` until first
    /// scored. Written only through `AttentionEngine.recompute` / commit stamping —
    /// never a two-way binding.
    var attention: AttentionMetadata {
        get {
            guard let attentionData,
                let decoded = try? JSONDecoder().decode(AttentionMetadata.self, from: attentionData)
            else { return .neutral }
            return decoded
        }
        set { attentionData = try? JSONEncoder().encode(newValue) }
    }

    /// The task's cached work-intent classification; nil until classified (the
    /// heuristic path leaves it nil).
    ///
    /// **System-owned by construction** (2026-08-11): there is no user-editing path.
    /// The write chain is exactly: engine classification / lexical backfill at resolve
    /// → `reclassify` (the background classifier). The user maintains FACTS (status,
    /// owner, due, urgent, category, effort); the system maintains interpretations —
    /// this one feeds the Today advisor and the breakdown bias, and never renders as
    /// a label anywhere.
    var workIntent: WorkIntent? {
        get { workIntentRaw.flatMap(WorkIntent.decode) }
        set { workIntentRaw = newValue?.rawValue }
    }

    /// True when this task is the current user's own to act on — its owner is the
    /// device's linked member. Device-relative on purpose: the same task is "mine"
    /// on the owner's device and someone else's elsewhere. Pass
    /// `UserProfile.linkedMemberID`. A `nil` owner (shared/unassigned) is never mine.
    func isMine(currentUserID: UUID?) -> Bool {
        ownerID != nil && ownerID == currentUserID
    }

    /// Resolve the owner reference against a roster. Nil when the task is unowned
    /// (shared) or the referenced person isn't in the passed roster. Display sites
    /// pass an *others-only* roster (excluding the current user's linked member) so
    /// your own tasks resolve to nil and render badge-free, exactly as before.
    func ownerDisplayName(among members: [FamilyMember]) -> String? {
        guard let ownerID else { return nil }
        return members.first { $0.uuid == ownerID }?.name
    }

    /// The owner's photo bytes, resolved against a roster. Nil for unowned work, a
    /// person absent from the passed roster, or one without a photo yet. Same
    /// others-only convention as `ownerDisplayName`.
    func ownerPhotoData(among members: [FamilyMember]) -> Data? {
        guard let ownerID else { return nil }
        return members.first { $0.uuid == ownerID }?.photoData
    }

    /// Compact effort display ("15m", "1h", "1h 30m"); nil when unestimated.
    var effortLabel: String? { TaskItem.effortLabel(effortMinutes) }

    /// The shared effort formatter, so the record row (task-bound) and the confirm card
    /// (which holds a `TaskDraft`, not a task) format minutes identically.
    static func effortLabel(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// The Overdue flag: an explicit due date that has passed without resolution.
    /// A hard, mechanical fact (a date check) — visible as a small marker, distinct
    /// in kind from Stale's heuristic judgment.
    func isOverdue(now: Date = Date()) -> Bool {
        guard !status.isResolved, let dueDate else { return false }
        return dueDate < Calendar.current.startOfDay(for: now)
    }

    /// Whole calendar days from start-of-day(`now`) to start-of-day(`due`):
    /// positive = future, 0 = today, negative = overdue. THE one due-delta
    /// derivation — retrieval fact lines, plan snapshots, ranking due-proximity,
    /// and importance backfill all read this instead of re-deriving the calendar
    /// math (four independent copies once drifted here).
    nonisolated static func daysUntil(_ due: Date, now: Date, calendar: Calendar = .current) -> Int? {
        calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)
        ).day
    }

    /// The Stale flag: no due date, un-TOUCHED-BY-A-HUMAN past the rot threshold. The
    /// heuristic rot-detector for the majority of errands that never had a date to blow
    /// past. (Dated tasks blow past their date instead — that's Overdue.) Reads the
    /// human clock, not `updatedAt` — a capture-time edge write on this task (a system
    /// path that bumps `updatedAt`) must not silently reset its staleness.
    func isStale(now: Date = Date(), threshold: TimeInterval = StalePolicy.retroThreshold) -> Bool {
        guard !status.isResolved, dueDate == nil else { return false }
        return now.timeIntervalSince(humanTouchedAt) > threshold
    }

    // MARK: - AI Assessment (derived on read)

    /// What Ezra observes about this task right now. The single source for every
    /// "needs a decision / blocked / unowned" chip and for the recommended-action
    /// inference.
    func assessment(among tasks: [TaskItem], now: Date = Date()) -> TaskAssessment {
        assessment(isBlocked: hasActiveBlockers(among: tasks), now: now)
    }

    /// Assessment when the caller already knows blocked-ness (e.g. a card handed a
    /// resolved blocker summary), avoiding a redundant second walk of the task graph.
    func assessment(isBlocked: Bool, now: Date = Date()) -> TaskAssessment {
        let reason: NeedsDecisionReason? =
            needsDecision && !status.isResolved
            ? (isJudgmentCall ? .humanJudgment : .lowConfidence)
            : nil
        return TaskAssessment(
            needsDecision: reason,
            isBlocked: isBlocked,
            isUnowned: ownerID == nil,
            isStale: isStale(now: now),
            tier: autonomy
        )
    }

    /// The single definition of "can I act on this right now?" — live work with
    /// nothing holding it back.
    func isActionable(among tasks: [TaskItem]) -> Bool {
        status.isLive && !hasActiveBlockers(among: tasks)
    }

    // MARK: - Temporal read-outs
    //
    // All derived from the timeline, so there is one source of truth and no stored
    // field can drift out of sync with the history. Every one of these returns nil /
    // zero-signal rather than a fabricated value when the history isn't there.

    /// The task's state history, oldest first. Empty for rows with no recorded
    /// history — an honest "we don't know", never a back-filled guess.
    var stateTimeline: [StateVisit] {
        get {
            guard let stateTimelineData else { return [] }
            return (try? JSONDecoder().decode([StateVisit].self, from: stateTimelineData)) ?? []
        }
        set { stateTimelineData = try? JSONEncoder().encode(newValue) }
    }

    /// Total time spent in a status across every visit to it. The open (current)
    /// visit is counted up to `now` — except for the resolved states, which are
    /// terminal: a resolved task's dwell must not tick upward forever.
    func secondsIn(_ state: TaskStatus, now: Date = Date()) -> TimeInterval {
        stateTimeline.reduce(0) { total, visit in
            guard visit.state == state.rawValue else { return total }
            let end = visit.exitedAt ?? (state.isResolved ? visit.enteredAt : now)
            return total + max(0, end.timeIntervalSince(visit.enteredAt))
        }
    }

    /// When the task entered the state it is in *right now* — the open visit's
    /// `enteredAt`. Distinct from `secondsIn(_:)`, which sums EVERY visit to a
    /// state: a task started, dropped, and picked back up has a large total dwell
    /// but a fresh current visit, and "how long since this commitment" is the
    /// second question. Nil when there is no recorded history.
    var currentStateEnteredAt: Date? {
        stateTimeline.last { $0.exitedAt == nil }?.enteredAt
    }

    /// Has this task been picked up before and put back down? True when the timeline
    /// holds a CLOSED `.doing` visit — a visit that was entered and later exited.
    ///
    /// Read by the CTA so a task you have already had in flight offers "Resume" rather
    /// than "Start". The distinction is small on screen and honest underneath: never
    /// started and started-then-dropped are different situations, and the timeline is
    /// the only thing that knows which one you are looking at.
    var hasBeenStarted: Bool {
        stateTimeline.contains { $0.state == TaskStatus.doing.rawValue && $0.exitedAt != nil }
    }

    /// Capture → resolution. Nil until the task is resolved.
    var timeToResolution: TimeInterval? {
        completedAt.map { $0.timeIntervalSince(createdAt) }
    }
}

// MARK: - Dependency graph (references, N blockers, cycle-safe)

extension TaskItem {
    /// The full graph-edge list. Reads decode the versioned blob; writes re-encode it
    /// (DEBUG-validating the invariants). **Forbidden to assign outside `Models/`** —
    /// every write must funnel through a `TaskMutations` helper (the mutation choke
    /// point, the same law as the `status` setter).
    var relationships: [Relationship] {
        get {
            guard let relationshipsData else { return [] }
            return RelationshipStore.decode(relationshipsData)
        }
        set {
            #if DEBUG
            Relationship.validate(newValue, owner: uuid)
            #endif
            relationshipsData = RelationshipStore.encode(newValue)
        }
    }

    /// Derive the Blocker views from an ALREADY-DECODED edge list. The statics exist
    /// so a bulk pass (the composer's open-set snapshot) can decode each task's blob
    /// once and derive every view from it, instead of paying one decode per accessor
    /// per task; the instance accessors delegate here, so there is one derivation.
    static func blockers(from relationships: [Relationship]) -> [Blocker] {
        relationships
            .filter { $0.kind == .blocks }
            .map { rel in
                Blocker(
                    id: rel.id, kind: rel.targetID != nil ? .task : .external,
                    taskID: rel.targetID, note: rel.note)
            }
    }

    static func parentTaskID(from relationships: [Relationship]) -> UUID? {
        relationships.first { $0.kind == .parent }?.targetID
    }

    static func activeBlockers(from relationships: [Relationship], openIDs: Set<UUID>) -> [Blocker] {
        blockers(from: relationships).filter { blocker in
            switch blocker.kind {
            case .external: return true
            case .task: return blocker.taskID.map(openIDs.contains) ?? false
            }
        }
    }

    /// Everything this task is waiting on — a READ-ONLY derived view over the
    /// `.blocks` edges. `Blocker` survives as the UI value type; each derived
    /// blocker reuses its edge's `id`, so `removeBlocker(_ id:)` still lands.
    var blockers: [Blocker] { Self.blockers(from: relationships) }

    /// The task this one is a step under, if any — the first `.parent` edge's
    /// target. Read-only (Split-Into-Subtasks plumbing; capture child-linking is
    /// the only writer, via a mutation helper).
    var parentTaskID: UUID? { Self.parentTaskID(from: relationships) }

    /// The graph edges only. Chains and the cycle guard are built from tracked
    /// dependencies; an `.external` blocker is real but has no edge to walk.
    var taskBlockerIDs: [UUID] {
        blockers.compactMap { $0.kind == .task ? $0.taskID : nil }
    }

    /// The blockers that still stand: `.task` blockers whose target isn't resolved
    /// yet, plus **every** `.external` one (nothing resolves those but a human).
    /// Resolved `.task` blockers stay in the list — so a reopen can re-block — but
    /// don't count here.
    func activeBlockers(among tasks: [TaskItem]) -> [Blocker] {
        let openIDs = Set(tasks.filter { !$0.status.isResolved }.compactMap(\.uuid))
        return Self.activeBlockers(from: relationships, openIDs: openIDs)
    }

    /// True when at least one blocker still stands — the single definition of Blocked.
    func hasActiveBlockers(among tasks: [TaskItem]) -> Bool {
        !activeBlockers(among: tasks).isEmpty
    }

    /// The still-open tasks this one waits on, for the detail sheet's chip rows.
    func activeBlockerTasks(among tasks: [TaskItem]) -> [TaskItem] {
        let ids = Set(activeBlockers(among: tasks).compactMap(\.taskID))
        return tasks.filter { $0.uuid.map(ids.contains) ?? false }
    }

    /// The still-open tasks that WAIT ON this one — the reverse `.blocks` edge,
    /// walked in ONE place. The Blocking flag and the plan snapshot's
    /// "blocks '…'" facts both read this (they used to re-implement the walk).
    func dependents(among tasks: [TaskItem]) -> [TaskItem] {
        guard let selfID = uuid else { return [] }
        return tasks.filter { other in
            other.uuid != selfID && !other.status.isResolved
                && other.taskBlockerIDs.contains(selfID)
        }
    }

    /// The tasks that name this one as their parent — its steps.
    ///
    /// Distinct from `dependents(among:)`, which is the BLOCKING reverse edge (tasks
    /// waiting on this one). Two different graphs: `.parent` is containment, `.blocks`
    /// is sequencing, and conflating them is an easy and silent mistake.
    func children(among tasks: [TaskItem]) -> [TaskItem] {
        guard let selfID = uuid else { return [] }
        return tasks.filter { $0.parentTaskID == selfID }
    }

    /// The Blocking flag, derived: true when any other unresolved task's blocker
    /// list points at this one. Never stored — storing both directions would let
    /// them drift; compute it at read time instead. Internal: manifests only as a
    /// modest position boost, never a label.
    func isBlocking(among tasks: [TaskItem]) -> Bool {
        guard !status.isResolved else { return false }
        return !dependents(among: tasks).isEmpty
    }

    /// Card display: the first active blocker as a whole phrase ("after Renew passport",
    /// "waiting on the contractor"), plus "+N" for the rest. Nil only when nothing
    /// blocks it — so a Blocked card can never be mute about why.
    func blockerSummary(among tasks: [TaskItem]) -> String? {
        let active = activeBlockers(among: tasks)
        guard let first = active.first else { return nil }
        let titles = Dictionary(
            uniqueKeysWithValues: tasks.compactMap { task in task.uuid.map { ($0, task.title) } })
        let phrase = first.phrase(taskTitle: first.taskID.flatMap { titles[$0] })
        return active.count == 1 ? phrase : "\(phrase) +\(active.count - 1)"
    }

    /// Adjacency map (uuid → its blocker uuids) over a task list, for cycle checks.
    /// Tracked dependencies only — an `.external` blocker has no edge, so it can never
    /// participate in (or be broken by) a cycle.
    static func blockersByUUID(_ tasks: [TaskItem]) -> [UUID: [UUID]] {
        var map: [UUID: [UUID]] = [:]
        for task in tasks { if let id = task.uuid { map[id] = task.taskBlockerIDs } }
        return map
    }

    /// Tasks `task` may start waiting on: not resolved, not itself, not already a
    /// tracked blocker, and — crucially — not anything that transitively depends on
    /// `task`, so a dependency can never close a cycle. Sorted by title. Shared by
    /// every "Waiting on" surface so the eligibility rule lives in one place.
    static func eligibleBlockerCandidates(for task: TaskItem, among tasks: [TaskItem]) -> [TaskItem] {
        guard let selfID = task.uuid else { return [] }
        let map = blockersByUUID(tasks)
        let existing = Set(task.taskBlockerIDs)
        return
            tasks
            .filter { candidate in
                guard let cid = candidate.uuid, cid != selfID else { return false }
                return !candidate.status.isResolved
                    && !existing.contains(cid)
                    && !wouldCreateCycle(from: selfID, adding: cid, blockersByUUID: map)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func wouldCreateCycle(
        from: UUID, adding candidate: UUID, blockersByUUID: [UUID: [UUID]]
    ) -> Bool {
        if candidate == from { return true }
        var stack = [candidate]
        var seen: Set<UUID> = []
        while let node = stack.popLast() {
            if node == from { return true }
            guard seen.insert(node).inserted else { continue }
            stack.append(contentsOf: blockersByUUID[node] ?? [])
        }
        return false
    }
}
