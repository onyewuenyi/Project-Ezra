//
//  IntentResolver.swift
//  Project-Ezra
//
//  The deterministic half of triage: turns raw `TaskIntent`s into resolved
//  `TaskDraft` candidates. Date expressions resolve here (in app code, testable),
//  never inside the model; person references stay as names on the draft —
//  `AppBrain.resolveOwners` is the roster half, since it needs the NSManagedObjectContext.
//
//  Every resolved draft proposes `.inbox`: creation always gets the one-tap
//  Confirm-Creation glance, regardless of confidence (always-confirm). Confidence
//  is recorded for quality review — it no longer routes anything at capture time.
//

import Foundation

enum IntentResolver {

    /// Resolve a batch. Only `.create` intents become drafts today.
    static func resolve(
        _ intents: [TaskIntent], rules: [LearnedRule] = [],
        openTasks: [OpenTaskSnapshot] = [], candidates: [RetrievalCandidate] = [], now: Date = Date()
    ) -> [TaskDraft] {
        intents.filter { $0.action == .create }
            .map { resolve($0, rules: rules, openTasks: openTasks, candidates: candidates, now: now) }
    }

    static func resolve(
        _ intent: TaskIntent, rules: [LearnedRule] = [],
        openTasks: [OpenTaskSnapshot] = [], candidates: [RetrievalCandidate] = [], now: Date = Date()
    ) -> TaskDraft {
        let intent = applyRules(rules, to: intent)
        let dueDate = resolveDate(expression: intent.dateExpression, now: now)
        var draft = TaskDraft(
            title: intent.title,
            category: intent.category,
            proposedStatus: .inbox,
            confidence: min(max(intent.confidence, 0), 1),
            autonomy: AutonomyPolicy.tier(
                confidence: intent.confidence, isJudgmentCall: intent.isJudgmentCall),
            isJudgmentCall: intent.isJudgmentCall,
            reasoning: intent.reasoning,
            dueDate: dueDate,
            blockedBy: intent.blockerPhrase,
            isUrgent: intent.isUrgent,
            // Metadata backfill: whatever the engine left empty is inferred here,
            // deterministically and uniformly — no candidate reaches the confirm
            // card with a hole the user has to fill from scratch. Extracted values
            // always win; backfill only fills gaps. Due dates are the deliberate
            // exception: inventing a date with no time signal manufactures a
            // future false Overdue, so an undated task stays honestly undated.
            aiImportance: intent.importance
                ?? inferredImportance(title: intent.title, dueDate: dueDate, now: now),
            ownerName: intent.personReference,
            effortMinutes: intent.effortMinutes ?? estimatedEffort(for: intent.title)
        )
        draft.workIntent = intent.workIntent.flatMap { WorkIntent(rawValue: $0) }
        draft.blocks = detectDependents(for: intent, among: openTasks)
        draft.edgeProposals = edgeProposals(for: intent, candidates: candidates)
        // Freeze the AI's field values so the Confirm-Creation diff can tell what
        // the user corrected — the learning signal starts here. Deliberately taken
        // AFTER rule application: a learned rule is part of the AI's proposal now,
        // so an un-edited confirm must not re-record it as a fresh correction.
        draft.aiOriginal = AIFieldSnapshot(
            title: draft.title,
            category: draft.category,
            dueDate: draft.dueDate,
            isUrgent: draft.isUrgent,
            ownerName: draft.ownerName,
            effortMinutes: draft.effortMinutes,
            blockerPhrase: draft.blockedBy,
            blocksIDs: draft.blocks.map(\.id),
            edgeProposals: draft.edgeProposals
        )
        return draft
    }

    // MARK: - Capture-graph proposals (duplicate / child edges)

    /// Confidence thresholds for tiering a model-proposed edge.
    static let acceptThreshold = 0.85
    static let suggestThreshold = 0.5

    /// Turn the model's duplicate/child claims into tiered, validated `EdgeProposal`s:
    /// unknown ids dropped (must be a candidate), <0.5 suppressed, and a task can't be
    /// both a duplicate of AND a child of the same target (the stronger duplicate wins).
    static func edgeProposals(
        for intent: TaskIntent, candidates: [RetrievalCandidate]
    ) -> [EdgeProposal] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var proposals: [EdgeProposal] = []

        func consider(_ kind: EdgeProposal.Kind, _ ref: EdgeReference?) {
            guard let ref, let candidate = byID[ref.targetID] else { return }  // unknown id dropped
            guard let decision = tier(ref.confidence) else { return }  // <0.5 suppressed
            proposals.append(
                EdgeProposal(
                    kind: kind, targetID: ref.targetID, targetTitle: candidate.title,
                    confidence: ref.confidence, decision: decision))
        }
        consider(.duplicateOf, intent.duplicateOf)
        consider(.childOf, intent.childOf)

        // Self-dedupe: never propose the same target as BOTH a duplicate and a parent.
        if let dup = proposals.first(where: { $0.kind == .duplicateOf }) {
            proposals.removeAll { $0.kind == .childOf && $0.targetID == dup.targetID }
        }
        return proposals
    }

    /// ≥0.85 → pre-selected (still confirm-gated); 0.5–0.85 → the user chooses; below →
    /// suppressed entirely.
    static func tier(_ confidence: Double) -> EdgeProposal.Decision? {
        if confidence >= acceptThreshold { return .accepted }
        if confidence >= suggestThreshold { return .undecided }
        return nil
    }

    // MARK: - Learned rules (the correction loop's deterministic half)

    /// Apply the user's learned corrections to a raw intent — uniformly, whichever
    /// engine produced it, so the heuristic path (and thus the simulator) learns
    /// too. Order matters: title rewrites first (they change the words), then
    /// owner aliases, then the first matching category override (rules arrive
    /// frequency-sorted). A rule never touches a field the intent didn't produce.
    static func applyRules(_ rules: [LearnedRule], to intent: TaskIntent) -> TaskIntent {
        guard !rules.isEmpty else { return intent }
        var intent = intent

        for case let .titleRewrite(from, to) in rules {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b"
            intent.title = intent.title.replacingOccurrences(
                of: pattern, with: to, options: [.regularExpression, .caseInsensitive])
        }

        for case let .ownerAlias(spoken, actual) in rules {
            if intent.personReference?.lowercased() == spoken.lowercased() {
                intent.personReference = actual
            }
        }

        let words = CorrectionProfile.significantWords(intent.title)
        for case let .categoryOverride(keyword, category) in rules {
            if words.contains(keyword.lowercased()) {
                intent.category = category
                break  // highest-frequency matching override wins
            }
        }

        return intent
    }

    // MARK: - Reverse dependencies ("should anything open wait on this?")

    /// Which open tasks should be blocked BY the task being created. Two sources,
    /// deduplicated:
    /// 1. Deterministic upgrade — an open task carrying an unresolved EXTERNAL
    ///    blocker whose note matches the new title ("book flights" waiting on
    ///    "passport" when "Renew passport" is captured). This closes the loop the
    ///    external-blocker fallback opens, on every engine including the sim's.
    /// 2. Model inference — the engine's `blocksExisting` titles (device), matched
    ///    back against the open set; unmatched titles drop rather than guess.
    static func detectDependents(
        for intent: TaskIntent, among openTasks: [OpenTaskSnapshot]
    ) -> [OpenTaskSnapshot] {
        guard !openTasks.isEmpty else { return [] }
        var matched: [OpenTaskSnapshot] = []
        var seen: Set<UUID> = []

        for open in openTasks
        where open.externalBlockerNotes.contains(where: {
            TaskItem.blockerMatches($0, resolvedTitle: intent.title)
        }) {
            if seen.insert(open.id).inserted { matched.append(open) }
        }

        for title in intent.blocksExisting {
            let hit =
                openTasks.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
                ?? openTasks.first { TaskItem.blockerMatches(title, resolvedTitle: $0.title) }
            if let hit, seen.insert(hit.id).inserted { matched.append(hit) }
        }
        return matched
    }

    // MARK: - Metadata backfill (nothing reaches the confirm card empty)

    /// Importance (0…1) when the engine didn't estimate: consequence signals (a bill
    /// about to bite, a hard deadline) or an imminent date read high; everything
    /// ordinary reads middling — the slow-moving input to the attention score, kept
    /// consistent across both engines.
    static let highImportance = 0.75
    static let ordinaryImportance = 0.4

    static func inferredImportance(title: String, dueDate: Date?, now: Date = Date()) -> Double {
        let words = CorrectionProfile.significantWords(title)
        if !consequenceSignals.isDisjoint(with: words) { return highImportance }
        if let dueDate {
            let days =
                Calendar.current.dateComponents(
                    [.day], from: Calendar.current.startOfDay(for: now),
                    to: Calendar.current.startOfDay(for: dueDate)
                ).day ?? .max
            if days <= 2 { return highImportance }
        }
        return ordinaryImportance
    }

    /// Words that imply real fallout when missed — the "urgency AND consequence"
    /// half of the ranking guidance, keyed to whole words.
    private static let consequenceSignals: Set<String> = [
        "pay", "bill", "bills", "taxes", "tax", "renew", "renewal", "registration",
        "insurance", "deadline", "overdue", "expires", "expiring", "rent", "invoice",
        "passport", "visa", "prescription",
    ]

    /// Effort when the engine didn't estimate: a quick touch (call/text/reply)
    /// ≈ 15, an errand ≈ 30, a chunk of focused work ≈ 60 — the same bands the
    /// on-device model is instructed to use, so the sim's estimates match.
    static func estimatedEffort(for title: String) -> Int {
        let words = CorrectionProfile.significantWords(title)
        if !quickVerbs.isDisjoint(with: words) { return 15 }
        if !focusedSignals.isDisjoint(with: words) { return 60 }
        return 30
    }

    private static let quickVerbs: Set<String> = [
        "call", "text", "email", "reply", "ping", "message", "rsvp", "remind", "ask", "confirm",
    ]
    private static let focusedSignals: Set<String> = [
        "plan", "organize", "write", "finish", "prepare", "research", "build", "draft",
        "clean", "reorganize", "review", "figure", "decide",
    ]

    // MARK: - Date resolution (deterministic, testable)

    /// Resolve a raw time phrase to a concrete date. Handles the common natural
    /// forms plus ISO passthrough; nil for anything it can't honestly resolve —
    /// a wrong guess is worse than an empty field the user can fill at confirm.
    static func resolveDate(expression: String?, now: Date = Date()) -> Date? {
        guard let raw = expression?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !raw.isEmpty
        else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        // ISO passthrough (the model may echo a date the user literally said).
        if let iso = parseISO(raw) { return iso }

        if raw.contains("today") || raw == "tonight" { return today }
        if raw.contains("tomorrow") {
            return cal.date(byAdding: .day, value: 1, to: today)
        }
        if raw.contains("next week") {
            // The start of the next calendar week — the honest reading of an
            // expression that names a week, not a day.
            if let thisWeek = cal.dateInterval(of: .weekOfYear, for: now) {
                return thisWeek.end
            }
            return cal.date(byAdding: .day, value: 7, to: today)
        }
        if raw.contains("weekend") {
            // The coming Saturday (or today, if it already is the weekend).
            if cal.isDateInWeekend(now) { return today }
            var comps = DateComponents()
            comps.weekday = 7  // Saturday
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
                .map(cal.startOfDay(for:))
        }

        let weekdays = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7,
        ]
        for (name, weekday) in weekdays where raw.contains(name) {
            var comps = DateComponents()
            comps.weekday = weekday
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
                .map(cal.startOfDay(for:))
        }
        return nil
    }

    private static func parseISO(_ raw: String) -> Date? {
        // yyyy-MM-dd anywhere in the phrase.
        guard let range = raw.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(raw[range]))
    }
}
