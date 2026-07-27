//
//  HouseholdEngine.swift
//  Project-Ezra
//
//  The pure layer between Tasks and the Household surface — the coordination
//  counterpart to the Today pipeline:
//
//      Tasks (+ change log + roster) → Household Engine → HouseholdSnapshot → Household UI
//
//  Today answers "what should I do?" (personal execution). Household answers "how
//  are we operating together?" (shared execution). Same architecture: this is a
//  pure function of state against `now`, returning a derived value that is NEVER
//  stored — every count and flag recomputes on read, exactly like Overdue / Stale
//  / Blocked already do. No ModelContext, fully testable.
//
//  It is deliberately NOT another task list: it surfaces operational health,
//  coordination events, ownership balance, and a shared horizon — awareness, not
//  density. The on-device narrative (`AIEngine.householdNarrative`) phrases a warm
//  sentence over the `HouseholdFacts` this engine computes; it never invents data.
//

import Foundation

// MARK: - Derived value types (never stored @Models)

/// The household's operational temperature — one calm status, never a multi-metric
/// dashboard. Maps to a single design-system status color at render (success /
/// warning / neutral), staying inside the rationed palette.
enum HouseholdStatus: Equatable {
    case quiet  // solo, or no active shared work — nothing to coordinate
    case operatingSmoothly  // real work in flight, no red flags
    case needsAttention  // overloaded / overdue / open decisions / unowned work
}

/// One person's share of the household's work — balance and overload, not a
/// productivity scoreboard. Counts are present but quiet; flags only when they mean
/// something. The `shared` bucket is unowned household work ("up for grabs").
struct MemberLoad: Identifiable, Equatable {
    enum Kind: Equatable {
        case you  // the current user (ownerID == the device's linked member id)
        case member(UUID)  // another FamilyMember by uuid
        case shared  // nil owner — handed back to the household, nobody owns it
    }

    var kind: Kind
    var name: String
    var activeCount: Int  // open, confirmed (.active) tasks on this plate
    var dueTodayCount: Int
    var blockedCount: Int
    var overdueCount: Int
    /// Carrying disproportionately more than the rest of the household.
    var isOverloaded: Bool

    var id: String {
        switch kind {
        case .you: return "you"
        case .member(let uuid): return "member-\(uuid.uuidString)"
        case .shared: return "shared"
        }
    }

    /// The calm flag phrases a row shows — empty when there's nothing to flag.
    var flags: [String] {
        var out: [String] = []
        if isOverloaded { out.append("Carrying most") }
        if blockedCount > 0 { out.append("\(blockedCount) blocked") }
        if overdueCount > 0 { out.append("\(overdueCount) overdue") }
        return out
    }
}

/// One shared coordination event — the answer to "what's happening with us?". A
/// value, computed fresh. `reasons` is the "Why am I seeing this?" answer, verbatim.
struct CoordinationEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case completed  // shared/delegated work finished
        case assigned  // work delegated to or from someone
        case waiting  // blocked on the world (external blocker)
        case upForGrabs  // filed for the household, unowned
        case decision  // a values call waiting on a person
        case aiMove  // the assistant handled something (unblock, re-file)
    }

    var id: String
    var sentence: String  // the feed line, shown verbatim
    var reasons: [String]  // long-press explanation — never empty
    var timestamp: Date
    var kind: Kind
    var taskID: UUID?
}

/// One upcoming shared commitment — the household's operational horizon (≤7 days).
/// Unlike Now's Looking Ahead, this spans EVERY owner, not just the user's own.
struct TimelineEntry: Identifiable, Equatable {
    var id: String
    var taskID: UUID?
    var title: String
    var dueDate: Date
    var ownerKind: MemberLoad.Kind
    var dayLabel: String  // "Today", "Tomorrow", "Sat"
}

/// Everything the Household surface renders, in one computed value.
struct HouseholdSnapshot: Equatable {
    var status: HouseholdStatus
    var headline: String  // "Operating smoothly" / "Needs attention" / quiet copy
    var highlights: [String]  // quiet fact chips: "2 overdue", "1 blocked", …
    var members: [MemberLoad]  // you + each active member + shared (only if non-empty)
    var coordination: [CoordinationEvent]
    var timeline: [TimelineEntry]
    var hasHousehold: Bool  // false = solo (no active members) → empty state
}

/// The Sendable fact snapshot handed to the narrative layer. The LLM only ever sees
/// these already-computed strings/numbers, so it can restate but never invent.
struct HouseholdFacts: Sendable, Equatable {
    var status: String
    var memberSummaries: [String]  // "Maya: 5 active, 1 blocked", "You: 8 active"
    var overdueCount: Int
    var blockedCount: Int
    var needsDecisionCount: Int
    var unownedCount: Int
    var upcoming: [String]  // "Sat: Birthday party (Maya)"
}

// MARK: - Engine

enum HouseholdEngine {

    /// Bounded surface — awareness, not density. Enforced here and nowhere else.
    enum Budget {
        static let feed = 5
        static let timeline = 7
    }

    /// The overload thresholds: a person must be carrying a real plate AND clearly
    /// more than the household's middle. Relative by design — a solo carrier can't be
    /// "overloaded relative to the household".
    private enum Overload {
        static let floor = 4  // fewer than this is never overload, however lopsided
        static let ratio = 2  // ≥ this × the median plate
    }

    /// Compute the whole surface. Pure: tasks + change log + roster + now in,
    /// HouseholdSnapshot out.
    static func compute(
        tasks: [TaskItem],
        changes: [ChangeLogEntry],
        members: [FamilyMember],
        currentUserID: UUID?,
        now: Date = Date()
    ) -> HouseholdSnapshot {
        // The current user is a real member now (see `UserProfile.linkedMemberID`); keep
        // them OUT of the delegatable roster so "you" gets exactly one load row (the
        // `.you` bucket), never also a `.member` row. `hasHousehold` = are there OTHER
        // people — so a solo user (only the you-member) still reads as solo.
        let roster = members.filter { !$0.isRemoved && $0.uuid != currentUserID }
        let open = tasks.filter { !$0.status.isResolved }
        let hasHousehold = !roster.isEmpty

        let loads = memberLoads(
            open: open, allTasks: tasks, roster: roster, currentUserID: currentUserID, now: now)
        let coordination = buildFeed(open: open, changes: changes, roster: roster, now: now)
        let timeline = buildTimeline(open: open, roster: roster, currentUserID: currentUserID, now: now)

        let overdueTotal = loads.reduce(0) { $0 + $1.overdueCount }
        let blockedTotal = loads.reduce(0) { $0 + $1.blockedCount }
        let needsDecisionTotal = open.filter { $0.needsDecision }.count
        let unownedTotal = open.filter { $0.ownerID == nil }.count
        let anyOverloaded = loads.contains { $0.isOverloaded }
        let hasActiveWork = loads.contains { $0.activeCount > 0 }

        let status: HouseholdStatus = {
            guard hasHousehold, hasActiveWork else { return .quiet }
            if overdueTotal > 0 || anyOverloaded || needsDecisionTotal > 0 || unownedTotal > 0 {
                return .needsAttention
            }
            return .operatingSmoothly
        }()

        let headline: String = {
            switch status {
            case .quiet: return hasHousehold ? "All quiet" : "Just you for now"
            case .operatingSmoothly: return "Operating smoothly"
            case .needsAttention: return "Needs attention"
            }
        }()

        let highlights = buildHighlights(
            loads: loads, overdue: overdueTotal, blocked: blockedTotal,
            needsDecision: needsDecisionTotal, unowned: unownedTotal, status: status)

        return HouseholdSnapshot(
            status: status,
            headline: headline,
            highlights: highlights,
            members: loads,
            coordination: coordination,
            timeline: timeline,
            hasHousehold: hasHousehold
        )
    }

    // MARK: - Ownership / workload

    private static func memberLoads(
        open: [TaskItem], allTasks: [TaskItem], roster: [FamilyMember], currentUserID: UUID?,
        now: Date
    ) -> [MemberLoad] {
        let cal = Calendar.current

        // Bucket every open task by owner. A nil owner is shared household work — a
        // deliberate human hand-back, never on anyone's plate. An owner matching the
        // device's linked member is "you"; any other owner is that member.
        func bucket(_ task: TaskItem) -> MemberLoad.Kind {
            guard let ownerID = task.ownerID else { return .shared }
            return ownerID == currentUserID ? .you : .member(ownerID)
        }

        func load(for kind: MemberLoad.Kind, name: String) -> MemberLoad {
            let mine = open.filter {
                sameBucket(bucket($0), kind) && $0.status.isLive
            }
            let dueToday = mine.filter {
                $0.dueDate.map { cal.isDate($0, inSameDayAs: now) } ?? false
            }
            let blocked = mine.filter { $0.hasActiveBlockers(among: allTasks) }
            let overdue = mine.filter { $0.isOverdue(now: now) }
            return MemberLoad(
                kind: kind, name: name,
                activeCount: mine.count,
                dueTodayCount: dueToday.count,
                blockedCount: blocked.count,
                overdueCount: overdue.count,
                isOverloaded: false  // filled in below, once every plate is known
            )
        }

        var loads = [load(for: .you, name: "You")]
        for member in roster.sorted(by: {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }) {
            loads.append(load(for: .member(member.uuid), name: member.name))
        }
        // The shared bucket only appears when there's genuinely unowned work.
        let shared = load(for: .shared, name: "Shared")
        if shared.activeCount > 0 {
            loads.append(shared)
        }

        // Overload is relative to the household median plate, computed over the
        // people buckets (you + members), never the shared bucket.
        let plates =
            loads
            .filter { if case .shared = $0.kind { return false } else { return true } }
            .map(\.activeCount)
            .filter { $0 > 0 }
        let mid = median(plates)
        return loads.map { load in
            guard case .shared = load.kind else {
                let overloaded =
                    load.activeCount >= Overload.floor
                    && Double(load.activeCount) >= Double(mid) * Double(Overload.ratio)
                var copy = load
                copy.isOverloaded = overloaded
                return copy
            }
            return load
        }
    }

    private static func sameBucket(_ a: MemberLoad.Kind, _ b: MemberLoad.Kind) -> Bool { a == b }

    /// Median of a value set (average of the two middles for an even count). Zero for
    /// an empty set, so nobody is "overloaded" in an empty household.
    private static func median(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n.isMultiple(of: 2) {
            return Double(sorted[n / 2 - 1] + sorted[n / 2]) / 2
        }
        return Double(sorted[n / 2])
    }

    // MARK: - Coordination feed

    /// Shared events worth knowing — recent coordination from the change log plus
    /// live-derived states (waiting on the world, unowned work, open decisions).
    /// Household-scoped: unlike the attention feed, it is NOT filtered to the user's
    /// own tasks. Deliberately not "every task update".
    private static func buildFeed(
        open: [TaskItem], changes: [ChangeLogEntry], roster: [FamilyMember], now: Date
    ) -> [CoordinationEvent] {
        var items: [CoordinationEvent] = []
        let window = now.addingTimeInterval(-48 * 3600)

        // 1. Recent coordination from the change log: real shared verbs, or anything a
        //    human did. Skip plain AI filings/confirms — those aren't coordination.
        for entry in changes
        where entry.timestamp >= window && !entry.undone
            && isCoordination(action: entry.action, initiatedBy: entry.initiatedBy)
        {
            let kind: CoordinationEvent.Kind =
                switch entry.action {
                case "assigned": .assigned
                case "completed": .completed
                case "unblocked": .aiMove
                default: entry.initiatedBy == .human ? .assigned : .aiMove
                }
            items.append(
                CoordinationEvent(
                    id: "change-\(entry.uuid?.uuidString ?? entry.summary)",
                    sentence: entry.summary,
                    reasons: [entry.detail ?? "A recent change in the household"],
                    timestamp: entry.timestamp,
                    kind: kind,
                    taskID: entry.taskUUID
                ))
        }

        // 2. Live states — waiting on the world.
        for task in open where task.status.isLive {
            let active = task.activeBlockers(among: open)
            guard !active.isEmpty, active.allSatisfy({ $0.kind == .external }) else { continue }
            let note = active.first?.note ?? "something else"
            items.append(
                CoordinationEvent(
                    id: "waiting-\(task.uuid?.uuidString ?? task.title)",
                    sentence: "Waiting on \(note) — \(task.title)",
                    reasons: ["Blocked on the world, not on anyone here"],
                    timestamp: task.updatedAt,
                    kind: .waiting,
                    taskID: task.uuid
                ))
        }

        // 3. Live states — filed for the household, nobody owns it.
        for task in open where task.ownerID == nil {
            items.append(
                CoordinationEvent(
                    id: "grabs-\(task.uuid?.uuidString ?? task.title)",
                    sentence: "Up for grabs: \(task.title)",
                    reasons: ["Filed for the household — nobody owns it yet"],
                    timestamp: task.updatedAt,
                    kind: .upForGrabs,
                    taskID: task.uuid
                ))
        }

        // 4. Live states — a values call waiting on a person.
        for task in open where task.needsDecision {
            items.append(
                CoordinationEvent(
                    id: "decision-\(task.uuid?.uuidString ?? task.title)",
                    sentence: "Needs a decision: \(task.title)",
                    reasons: [
                        task.isJudgmentCall
                            ? "A values call only a person can make"
                            : "Filed with low confidence — worth a look"
                    ],
                    timestamp: task.updatedAt,
                    kind: .decision,
                    taskID: task.uuid
                ))
        }

        // Most recent first, then bound the surface.
        let sorted = items.sorted { $0.timestamp > $1.timestamp }
        return Array(sorted.prefix(Budget.feed))
    }

    private static func isCoordination(action: String?, initiatedBy: ChangeInitiator) -> Bool {
        switch action {
        case "assigned", "completed", "unblocked": return true
        // "suppressed" is human-initiated but solo: rejecting a merge suggestion at your
        // own capture coordinates nothing with anybody, and the default arm below would
        // otherwise sweep it into the household feed on the strength of `.human` alone.
        case "filed", "confirmed", "suppressed": return false
        default: return initiatedBy == .human
        }
    }

    // MARK: - Shared timeline

    private static func buildTimeline(
        open: [TaskItem], roster: [FamilyMember], currentUserID: UUID?, now: Date
    ) -> [TimelineEntry] {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        let horizon = startToday.addingTimeInterval(8 * 24 * 3600)  // through day 7

        let dated =
            open
            .filter { task in
                guard let due = task.dueDate else { return false }
                return due >= startToday && due < horizon
            }
            .sorted { ($0.dueDate ?? now) < ($1.dueDate ?? now) }

        return dated.prefix(Budget.timeline).map { task in
            let due = task.dueDate ?? now
            let kind: MemberLoad.Kind =
                task.ownerID.map { $0 == currentUserID ? .you : MemberLoad.Kind.member($0) } ?? .shared
            return TimelineEntry(
                id: "timeline-\(task.uuid?.uuidString ?? task.title)",
                taskID: task.uuid,
                title: task.title,
                dueDate: due,
                ownerKind: kind,
                dayLabel: dayLabel(for: due, now: now, calendar: cal)
            )
        }
    }

    private static func dayLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        let tomorrow = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)
        if calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    // MARK: - Highlights

    private static func buildHighlights(
        loads: [MemberLoad], overdue: Int, blocked: Int, needsDecision: Int, unowned: Int,
        status: HouseholdStatus
    ) -> [String] {
        switch status {
        case .quiet:
            return []
        case .operatingSmoothly:
            let active = loads.reduce(0) { $0 + $1.activeCount }
            let people = loads.filter { $0.activeCount > 0 && !isShared($0.kind) }.count
            var out = ["\(active) active across \(people) \(people == 1 ? "person" : "people")"]
            if let carrier = loads.first(where: { $0.isOverloaded }) {
                out.append("\(carrier.name) carrying most")
            }
            return out
        case .needsAttention:
            var out: [String] = []
            if let carrier = loads.first(where: { $0.isOverloaded }) {
                out.append("\(carrier.name) carrying most")
            }
            if overdue > 0 { out.append("\(overdue) overdue") }
            if blocked > 0 { out.append("\(blocked) blocked") }
            if needsDecision > 0 {
                out.append("\(needsDecision) needs \(needsDecision == 1 ? "a decision" : "decisions")")
            }
            if unowned > 0 { out.append("\(unowned) up for grabs") }
            return out
        }
    }

    private static func isShared(_ kind: MemberLoad.Kind) -> Bool {
        if case .shared = kind { return true }
        return false
    }

    // MARK: - Facts for the narrative layer

    /// Reduce a snapshot to the Sendable facts the on-device narrative rephrases.
    static func facts(from snapshot: HouseholdSnapshot) -> HouseholdFacts {
        let summaries = snapshot.members
            .filter { $0.activeCount > 0 || isShared($0.kind) }
            .map { load -> String in
                var parts = ["\(load.activeCount) active"]
                if load.blockedCount > 0 { parts.append("\(load.blockedCount) blocked") }
                if load.overdueCount > 0 { parts.append("\(load.overdueCount) overdue") }
                return "\(load.name): \(parts.joined(separator: ", "))"
            }
        let upcoming = snapshot.timeline.map { "\($0.dayLabel): \($0.title)" }
        return HouseholdFacts(
            status: String(describing: snapshot.status),
            memberSummaries: summaries,
            overdueCount: snapshot.members.reduce(0) { $0 + $1.overdueCount },
            blockedCount: snapshot.members.reduce(0) { $0 + $1.blockedCount },
            needsDecisionCount: snapshot.coordination.filter { $0.kind == .decision }.count,
            unownedCount: snapshot.coordination.filter { $0.kind == .upForGrabs }.count,
            upcoming: upcoming
        )
    }
}
