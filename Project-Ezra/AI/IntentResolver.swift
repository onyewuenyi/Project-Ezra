//
//  IntentResolver.swift
//  Project-Ezra
//
//  The deterministic half of triage: turns raw `TaskIntent`s into resolved
//  `TaskDraft` candidates. Date expressions resolve here (in app code, testable),
//  never inside the model; person references stay as names on the draft —
//  `AppBrain.resolveOwners` is the roster half, since it needs the NSManagedObjectContext.
//
//  Drafts carry no lifecycle status — a draft is not a TaskItem. TaskItem is born
//  `.todo` at AppBrain.commit, which is the single Confirm-Creation boundary.
//  Confidence is recorded for quality review; it routes nothing at capture time.
//

import Foundation

enum IntentResolver {

    /// Resolve a batch. Only `.create` intents become drafts today.
    ///
    /// **One intent can become more than one draft.** Someone who says "walk the dog
    /// Monday and Tuesday" named one kind of work and two occasions of it, and owes
    /// themselves two tasks — so the batch flat-maps through `expand` first. That is the
    /// only fan-out in the pipeline, and it is deliberately HERE: parse the intent in the
    /// model, expand the schedule in app code, exactly as every other piece of date math
    /// already works.
    static func resolve(
        _ intents: [TaskIntent], rules: [LearnedRule] = [],
        openTasks: [OpenTaskSnapshot] = [], candidates: [RetrievalCandidate] = [],
        suppressions: [RelationshipSuppression] = [], now: Date = Date()
    ) -> [TaskDraft] {
        let drafts = intents.filter { $0.action == .create }
            .flatMap { expand($0, now: now) }
            .map {
                resolve(
                    $0, rules: rules, openTasks: openTasks, candidates: candidates,
                    suppressions: suppressions, now: now)
            }
        return resolvingAnaphoricWaits(drafts)
    }

    /// "Book flights after IT comes through": a wait that opens on a pronoun points at
    /// the outcome just spoken, not at a task called "it comes through". Left as
    /// words, the commit's `resolveBlocker` matched nothing and wrote an EXTERNAL wait
    /// in those words — the passport it plainly meant was one draft earlier in the same
    /// breath (2026-09-17, `-CaptureCompare`; the model arm resolved the same reference
    /// to "passport"). The phrase becomes the previous draft's title, which the commit
    /// then matches to the sibling and writes as a real edge. Short phrases only: "that
    /// report from Sarah" names its own thing and is left alone.
    static func resolvingAnaphoricWaits(_ drafts: [TaskDraft]) -> [TaskDraft] {
        guard drafts.count > 1 else { return drafts }
        var out = drafts
        for i in 1..<out.count {
            guard let phrase = out[i].blockedBy, isAnaphoricWait(phrase) else { continue }
            out[i].blockedBy = out[i - 1].title
        }
        return out
    }

    static func isAnaphoricWait(_ phrase: String) -> Bool {
        let words = phrase.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        guard let first = words.first, words.count <= 3 else { return false }
        return anaphoricOpeners.contains(first)
    }

    private static let anaphoricOpeners: Set<String> = [
        "it", "it's", "that", "that's", "this", "those", "these", "they", "them",
    ]

    // MARK: - Instance expansion (one intent → one draft per named occasion)

    /// The ceiling on a fan-out. Seven is a whole week, and past it the user is
    /// describing a RECURRENCE rather than enumerating occasions — a thing this product
    /// has no model for. Over the cap the expansion is declined entirely rather than
    /// truncated: one task the user can see and correct beats eight they have to delete.
    static let maxInstances = 7

    /// Split an intent into one intent per occasion its date phrase names, each carrying
    /// the fragment of the phrase that is its own. Returns `[intent]` unchanged for the
    /// overwhelmingly common single-occasion case.
    ///
    /// Rewriting `dateExpression` down to the fragment — rather than plumbing a resolved
    /// date through — is what keeps this cheap: each copy then runs the ordinary
    /// `resolve` path, so it gets its own `aiOriginal` snapshot with its own due date and
    /// nothing downstream learns a new shape. The fragment is still the user's own words,
    /// and `sourceQuote` (which grounding checks) is untouched.
    static func expand(_ intent: TaskIntent, now: Date = Date()) -> [TaskIntent] {
        let fragments = instanceExpressions(in: intent.dateExpression, now: now)
        guard fragments.count > 1 else { return [intent] }
        return fragments.map { fragment in
            var copy = intent
            copy.dateExpression = fragment
            return copy
        }
    }

    /// The fragments of a time phrase that name SEPARATE occasions, ordered earliest
    /// first. Empty means "one occasion, or none" — the cheap path, and the answer for
    /// almost every phrase.
    ///
    /// The guard that makes this safe is that **every** fragment must resolve to a real
    /// date or the whole expansion is declined. A phrase like "before the trip and after
    /// the meeting" splits into two fragments that resolve to nothing, so it falls
    /// through to the normal single-date path untouched; so does "tomorrow if I have
    /// time". Requiring all-or-nothing is what stops a connective in a date phrase from
    /// manufacturing a task.
    ///
    /// Note what this deliberately does NOT do: a quantity or a cadence inside one
    /// occasion ("cook lunch for three days next week") carries no enumeration of dates,
    /// so it never reaches the split at all and stays one task. That is the product rule
    /// — distinct intended outcomes, not distinct verbs — falling out of the mechanism
    /// rather than needing to be restated in it.
    static func instanceExpressions(in expression: String?, now: Date = Date()) -> [String] {
        guard let raw = expression?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !raw.isEmpty,
            raw.contains(" and ") || raw.contains(",") || raw.contains("&")
        else { return [] }

        let fragments =
            raw
            .replacingOccurrences(of: "&", with: ",")
            .replacingOccurrences(of: " and ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard fragments.count > 1, fragments.count <= maxInstances else { return [] }

        var seen: Set<Date> = []
        var dated: [(date: Date, fragment: String)] = []
        for fragment in fragments {
            guard let date = resolveDate(expression: fragment, now: now) else { return [] }
            // "monday and monday" is one occasion said twice.
            if seen.insert(date).inserted { dated.append((date, fragment)) }
        }
        guard dated.count > 1 else { return [] }
        return dated.sorted { $0.date < $1.date }.map(\.fragment)
    }

    /// True when the phrase names MORE distinct occasions than `expand` will ever act
    /// on — the one decline reason where falling through to `resolveDate`'s ordinary
    /// single-date reading would be actively wrong rather than merely conservative.
    /// `instanceExpressions` returning `[]` also covers "not an enumeration at all" and
    /// "one of the fragments isn't a date", and in both of those the single-date
    /// fallback is exactly the right behavior — so this re-parses independently rather
    /// than asking `instanceExpressions` "why" it declined, and only answers true when
    /// every fragment genuinely resolves and there are simply too many of them (e.g.
    /// "clean the litter box every day this week and next Monday": eight real dates,
    /// none of them "the" date). Without this, `resolveDate`'s weekday match silently
    /// picks the FIRST named day and reports it as confident — the whole thing this
    /// exists to stop, not "8+ separate correct dates I chose to only show one of."
    static func exceedsInstanceCap(in expression: String?, now: Date = Date()) -> Bool {
        guard let raw = expression?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !raw.isEmpty,
            raw.contains(" and ") || raw.contains(",") || raw.contains("&")
        else { return false }
        let fragments =
            raw
            .replacingOccurrences(of: "&", with: ",")
            .replacingOccurrences(of: " and ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard fragments.count > maxInstances else { return false }
        return fragments.allSatisfy { resolveDate(expression: $0, now: now) != nil }
    }

    static func resolve(
        _ intent: TaskIntent, rules: [LearnedRule] = [],
        openTasks: [OpenTaskSnapshot] = [], candidates: [RetrievalCandidate] = [],
        suppressions: [RelationshipSuppression] = [], now: Date = Date()
    ) -> TaskDraft {
        let intent = applyRules(rules, to: intent)
        // One tokenization per draft: four backfill helpers below read the same
        // significant-word set, and each used to recompute it — ~5 full tokenizations
        // per draft per applied partial. Computed AFTER rule application (a title
        // rewrite changes the words).
        let titleWords = CorrectionProfile.significantWords(intent.title)
        // The date the user actually EXPRESSED, kept separate from the one inferred
        // from the task's nature below — the two are not interchangeable downstream.
        // Nil when the phrase names more occasions than `expand` will fan out (rather
        // than the ordinary single-date read silently picking the first named day and
        // reporting it as confident) — see `exceedsInstanceCap`.
        let spokenDate =
            exceedsInstanceCap(in: intent.dateExpression, now: now)
            ? nil : resolveDate(expression: intent.dateExpression, now: now)
        let workIntent =
            intent.workIntent.flatMap { WorkIntent.decode($0.lowercased()) }
            ?? inferredWorkIntent(title: intent.title, words: titleWords)
        // A captured wait suppresses the proposal. Two reasons, one of which the eval
        // caught: the blocker's own words are IN the title ("book flights after passport
        // is done" read as a passport renewal and got a two-week deadline), and a task
        // that can't start yet is precisely where a manufactured date becomes a false
        // Overdue. A spoken date still lands on a blocked task — that one the user meant.
        // A JUDGMENT CALL narrows the proposal to the recurring-bill arm (the eval
        // caught both halves of this line): "cancel the streaming subscription" keeps
        // its month-end date — money leaves on a real cadence whether or not the call
        // is made — while "figure out if we should switch insurance" gets nothing; a
        // renewal/deadline arm firing on a decision's TOPIC word is manufactured
        // pressure, not information.
        let proposedDue =
            spokenDate == nil && intent.blockerPhrase == nil
            ? inferredDueDate(
                title: intent.title, now: now, words: titleWords,
                billArmOnly: intent.isJudgmentCall) : nil
        var draft = TaskDraft(
            title: intent.title,
            category: intent.category,
            confidence: min(max(intent.confidence, 0), 1),
            autonomy: AutonomyPolicy.tier(
                confidence: intent.confidence, isJudgmentCall: intent.isJudgmentCall),
            isJudgmentCall: intent.isJudgmentCall,
            reasoning: intent.reasoning,
            dueDate: spokenDate ?? proposedDue?.date,
            blockedBy: intent.blockerPhrase,
            isUrgent: intent.isUrgent,
            // Metadata backfill: whatever the engine left empty is inferred here,
            // deterministically and uniformly — no candidate reaches the confirm
            // card with a hole the user has to fill from scratch. Extracted values
            // always win; backfill only fills gaps.
            //
            // Importance reads the SPOKEN date only. It returns `highImportance` for
            // anything due within two days, so feeding it an inferred date would let
            // a guess inflate the attention score — inference stacked on inference.
            aiImportance: intent.importance
                ?? inferredImportance(
                    title: intent.title, dueDate: spokenDate, now: now, words: titleWords),
            ownerName: intent.personReference,
            effortMinutes: intent.effortMinutes
                ?? estimatedEffort(for: intent.title, words: titleWords)
        )
        draft.workIntent = workIntent
        draft.dueReason = proposedDue?.reason
        // A detail the user SPOKE that we could not land. Both arms below require the
        // capture to have actually said something — an absent date is not unresolved,
        // it is simply undated, and conflating the two would turn a precise "you said a
        // day and I couldn't read it" into a nag on every task without a deadline.
        //
        // These used to vanish in silence: a time phrase that `resolveDate` returned nil
        // for was dropped on the floor, so the user's only clue was noticing an empty
        // chip where they remembered saying "Thursday".
        // An unresolved OWNER is deliberately absent: `ConfirmCreationCard.ownerChip`
        // already names an unrecognised person and offers to add them to the household,
        // which is a better affordance than a generic "Who?" beside it.
        if spokenDate == nil, let phrase = intent.dateExpression,
            !phrase.trimmingCharacters(in: .whitespaces).isEmpty
        {
            draft.unresolved = [.date]
        }
        draft.blocks = detectDependents(for: intent, among: openTasks)
        draft.edgeProposals = edgeProposals(
            for: intent, candidates: candidates, suppressions: suppressions)
        // Freeze the AI's field values so the Confirm-Creation diff can tell what
        // the user corrected — the learning signal starts here. Deliberately taken
        // AFTER rule application: a learned rule is part of the AI's proposal now,
        // so an un-edited confirm must not re-record it as a fresh correction.
        draft.aiOriginal = AIFieldSnapshot(
            title: draft.title,
            category: draft.category,
            dueDate: draft.dueDate,
            isUrgent: draft.isUrgent,
            workIntent: draft.workIntent,
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
    /// unknown ids dropped (must be a candidate), <0.5 suppressed, previously-rejected
    /// pairs dropped (the capture-form suppression check: same normalized draft title
    /// against the same target — a "no" sticks across captures), and a task can't be
    /// both a duplicate of AND a child of the same target (the stronger duplicate wins).
    static func edgeProposals(
        for intent: TaskIntent, candidates: [RetrievalCandidate],
        suppressions: [RelationshipSuppression] = []
    ) -> [EdgeProposal] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let normalizedTitle = RelationshipSuppression.normalizeTitle(intent.title)
        var proposals: [EdgeProposal] = []

        func consider(_ kind: EdgeProposal.Kind, _ ref: EdgeReference?) {
            guard let ref, let candidate = byID[ref.targetID] else { return }  // unknown id dropped
            let suppressionKind: RelationshipSuppression.SuppressionKind =
                kind == .duplicateOf ? .duplicateMerge : .parentLink
            guard
                !suppressions.contains(where: {
                    $0.suppresses(
                        kind: suppressionKind, targetID: ref.targetID, normalizedTitle: normalizedTitle)
                })
            else { return }  // the user already said no to this pairing
            guard let decision = tier(kind, ref.confidence) else { return }  // <0.5 suppressed
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

    /// Tiering splits by DESTRUCTIVENESS, not uniformly by confidence (the auto-accept
    /// invariant): a duplicate merge folds a capture into an existing task, so it keeps
    /// the two-threshold tiering; a child link is additive and reversible, so above the
    /// suppression floor it is simply accepted (pre-selected, editable at confirm — no
    /// `.undecided` limbo that silently does nothing at commit).
    static func tier(_ kind: EdgeProposal.Kind, _ confidence: Double) -> EdgeProposal.Decision? {
        guard confidence >= suggestThreshold else { return nil }
        switch kind {
        case .duplicateOf:
            return confidence >= acceptThreshold ? .accepted : .undecided
        case .childOf:
            return .accepted
        }
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
            guard let regex = rewriteRegex(for: from) else { continue }
            let range = NSRange(intent.title.startIndex..., in: intent.title)
            intent.title = regex.stringByReplacingMatches(
                in: intent.title, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: to))
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
        // F-05: the estimate and the flag the person keeps setting on similar tasks.
        // Effort fills an EMPTY estimate only — a spoken "two hours" beats a learned
        // default; urgency is additive, never cleared by a rule.
        if intent.effortMinutes == nil {
            for case let .effortForKeyword(keyword, minutes) in rules
            where words.contains(keyword.lowercased()) {
                intent.effortMinutes = minutes
                break
            }
        }
        for case let .urgentForKeyword(keyword) in rules where words.contains(keyword.lowercased()) {
            intent.isUrgent = true
            break
        }

        return intent
    }

    /// Compiled rewrite patterns, memoized by source word. The rule set is stable for
    /// a whole composer session, but `applyRules` runs per draft per applied partial —
    /// compiling the same ≤8 patterns hundreds of times per ramble was pure spike.
    /// Main-actor state (the resolver runs on the main actor by default isolation).
    private static var rewriteRegexCache: [String: NSRegularExpression] = [:]

    private static func rewriteRegex(for from: String) -> NSRegularExpression? {
        if let cached = rewriteRegexCache[from] { return cached }
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        rewriteRegexCache[from] = regex
        return regex
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

    static func inferredImportance(
        title: String, dueDate: Date?, now: Date = Date(), words: Set<String>? = nil
    ) -> Double {
        let words = words ?? CorrectionProfile.significantWords(title)
        if !consequenceSignals.isDisjoint(with: words) { return highImportance }
        if let dueDate, (TaskItem.daysUntil(dueDate, now: now) ?? .max) <= 2 {
            return highImportance
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
    static func estimatedEffort(for title: String, words: Set<String>? = nil) -> Int {
        let words = words ?? CorrectionProfile.significantWords(title)
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

    // MARK: - Work-intent backfill (axis 2, when the engine didn't classify)

    /// What KIND of work this is, from the wording alone — the deterministic half of
    /// axis 2, so the heuristic path (the simulator, and any user whose Apple
    /// Intelligence is off or unavailable by region) doesn't reach the confirm card
    /// with the field blank. An engine-supplied classification always wins; this only
    /// fills the gap.
    ///
    /// Two rules this must not break:
    ///
    /// 1. **It never reads `isJudgmentCall` or `needsDecision`.** Axis 2 (what kind of
    ///    work) and axis 3 (what demands attention) answer different questions, and
    ///    deriving one from the other re-fuses them. Lexical signals only.
    /// 2. **Everything unrecognised falls to `.action`**, which is behaviourally
    ///    identical to nil (same CTA verb, same capability set) — so the default arm is
    ///    a naming, not a behaviour change.
    static func inferredWorkIntent(title: String, words: Set<String>? = nil) -> WorkIntent {
        let lower = title.lowercased()
        // Choice-shaped wording is NOT a type any more (axis 2 is action | planning;
        // Decision retired 2026-08-08). A choice is closest to figuring out an
        // approach, so it lands `.planning` — and `DecisionShape` (the hoisted
        // lexicon) is what actually summons the Thinking Partner, independent of
        // this axis.
        if DecisionShape.phrases.contains(where: lower.contains) { return .planning }
        if planningPhrases.contains(where: lower.contains) { return .planning }
        let words = words ?? CorrectionProfile.significantWords(title)
        if !DecisionShape.words.isDisjoint(with: words) { return .planning }
        if !planningWords.isDisjoint(with: words) { return .planning }
        return .action
    }

    /// Deliberately kept separate from `focusedSignals` above (which shares several
    /// words): effort and type answer different questions, and collapsing them into one
    /// vocabulary would make a tweak to either silently move the other. The decision
    /// lexicon lives in `Models/DecisionShape.swift` — one vocabulary for every
    /// consumer that asks "does this read as a choice?".
    private static let planningPhrases = [
        "figure out how", "break down", "map out", "think through", "work out how",
    ]
    /// Deliberately excludes "schedule" and "prepare": both read as concrete actions at
    /// least as often as planning ("schedule a dentist appointment", "prepare dinner"),
    /// and `.action` is the safe default — a wrong `.planning` mislabels the CTA verb.
    private static let planningWords: Set<String> = [
        "plan", "planning", "organize", "organise", "research", "outline",
    ]

    // MARK: - Due-date proposal (from the task's nature, not a spoken phrase)

    /// A due date proposed from what the task IS, for the recurring obligations that
    /// carry a real deadline the user rarely bothers to say out loud ("pay rent",
    /// "renew the passport"). Only ever consulted when `resolveDate` found no spoken
    /// phrase — an expressed date always wins.
    ///
    /// This is a deliberate reversal of the old "an undated task stays honestly
    /// undated" rule, and it is contained four ways: the table below is short and
    /// explicit rather than a general "everything gets a week", `resolve` skips it
    /// entirely for a blocked task, the returned `reason` renders under the chip so the
    /// user can see WHY a date appeared while it is still one tap to clear, and the
    /// result never feeds `inferredImportance` (see `resolve`).
    ///
    /// The residual cost, accepted knowingly: `TaskItem.isStale` only fires on undated
    /// tasks, so anything that gets a proposed date leaves stale detection.
    static func inferredDueDate(
        title: String, now: Date = Date(), words: Set<String>? = nil, billArmOnly: Bool = false
    ) -> (date: Date, reason: String)? {
        let words = words ?? CorrectionProfile.significantWords(title)
        let cal = Calendar.current

        if !recurringBillSignals.isDisjoint(with: words) {
            guard let month = cal.dateInterval(of: .month, for: now),
                let lastDay = cal.date(byAdding: .day, value: -1, to: month.end)
            else { return nil }
            return (cal.startOfDay(for: lastDay), "Bills usually land at month end.")
        }
        // The renewal/deadline arms fire on topic words alone — legitimate on an
        // action, manufactured pressure on a judgment call (see `resolve`).
        guard !billArmOnly else { return nil }
        if !renewalSignals.isDisjoint(with: words) {
            guard let date = cal.date(byAdding: .day, value: 14, to: cal.startOfDay(for: now))
            else { return nil }
            return (date, "Renewals need a couple of weeks' lead time.")
        }
        if !deadlineSignals.isDisjoint(with: words) {
            guard let date = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now))
            else { return nil }
            return (date, "Reads like a deadline — a week's lead time.")
        }
        return nil
    }

    private static let recurringBillSignals: Set<String> = [
        "rent", "bill", "bills", "invoice", "mortgage", "subscription",
    ]
    private static let renewalSignals: Set<String> = [
        "renew", "renewal", "registration", "insurance", "visa", "passport", "prescription",
        "expires", "expiring",
    ]
    private static let deadlineSignals: Set<String> = ["tax", "taxes", "deadline"]

    // MARK: - Date resolution (deterministic, testable)

    /// Resolve a raw time phrase to a concrete date. Handles the common natural
    /// forms plus ISO passthrough; nil for anything it can't honestly resolve —
    /// a wrong guess is worse than an empty field the user can fill at confirm.
    ///
    /// **The arm order is load-bearing**, because several of these phrases contain each
    /// other as substrings. Most specific first: "day after tomorrow" before "tomorrow",
    /// a named weekday before any bare week reference (so "next week friday" is Friday,
    /// not Monday), and "weekend" before "this week" (which "this weekend" contains).
    ///
    /// Everything resolves to a start-of-day. A clock time is read for WHICH DAY it
    /// implies, never as a time: the prompt sends the model no clock, and every
    /// consumer of `dueDate` treats it as a day.
    ///
    /// **A bare clock time means today** (2026-09-02, the first real-utterance corpus:
    /// 8 of 26 captures pulled from the device store were "cook dinner at 3", "make
    /// lunch at noon", "clean up room at 3 PM" — every one meant today, and every one
    /// landed undated with a "When?" chip because this resolver read days only). The
    /// arm sits LAST, so a spoken day always wins over the clock beside it —
    /// "tomorrow at 3 PM" is tomorrow, "Friday at noon" is Friday — and it can only
    /// fire when no day word matched at all. Deterministic over clever: a clock time
    /// already past ("at 3 PM", said at 10 PM) still reads as today, because "due
    /// today" is one tap to move and a guessed "tomorrow" is a task the user did not
    /// describe.
    static func resolveDate(expression: String?, now: Date = Date()) -> Date? {
        guard let raw = expression?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !raw.isEmpty
        else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        // ISO passthrough (the model may echo a date the user literally said).
        if let iso = parseISO(raw) { return iso }

        // Before "tomorrow" — it contains it.
        if raw.contains("day after tomorrow") {
            return cal.date(byAdding: .day, value: 2, to: today)
        }
        if raw.contains("today") || raw.contains("tonight")
            || todayDaypartSignals.contains(where: raw.contains)
        {
            return today
        }
        if raw.contains("tomorrow") {
            return cal.date(byAdding: .day, value: 1, to: today)
        }

        // "in three days", "in 2 weeks", "a week from now".
        if let offset = parseRelativeOffset(raw) {
            return cal.date(byAdding: offset.unit, value: offset.value, to: today)
        }

        // A named month and day ("july 20", "20 july", "jul 20th").
        if let calendarDate = parseMonthDay(raw, now: now, cal: cal) { return calendarDate }
        // A bare month behind a preposition ("in July", "by march", "before the summer
        // holidays in July", 2026-09-18): the first of its next occurrence. The month
        // is the whole precision the person gave, and the first is the day that keeps
        // every "before" and "by" reading honest.
        if let monthStart = parseBareMonth(raw, now: now, cal: cal) { return monthStart }

        // A named weekday beats any bare week reference below.
        if let weekday = weekdayNumber(in: raw) {
            var comps = DateComponents()
            comps.weekday = weekday
            let next = cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
                .map(cal.startOfDay(for:))
            // "next week friday" names the Friday of the FOLLOWING week, not this
            // week's. Bare "next friday" stays the next occurrence — that one is
            // genuinely ambiguous in English and the nearer reading is the safer guess.
            guard raw.contains("next week"), let next else { return next }
            return cal.date(byAdding: .weekOfYear, value: 1, to: next)
        }

        // Before the week arms — "this weekend" contains "this week".
        if raw.contains("weekend") {
            // The coming Saturday (or today, if it already is the weekend).
            if cal.isDateInWeekend(now) { return today }
            var comps = DateComponents()
            comps.weekday = 7  // Saturday
            return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
                .map(cal.startOfDay(for:))
        }

        if raw.contains("end of the month") || raw.contains("end of month") {
            guard let month = cal.dateInterval(of: .month, for: now) else { return nil }
            return cal.date(byAdding: .day, value: -1, to: month.end).map(cal.startOfDay(for:))
        }
        if raw.contains("next month") {
            // The start of the next calendar month, matching how "next week" reads.
            guard let month = cal.dateInterval(of: .month, for: now) else { return nil }
            return month.end
        }
        if raw.contains("end of the week") || raw.contains("end of week")
            || raw.contains("this week")
        {
            guard let thisWeek = cal.dateInterval(of: .weekOfYear, for: now) else { return nil }
            return cal.date(byAdding: .day, value: -1, to: thisWeek.end).map(cal.startOfDay(for:))
        }
        if raw.contains("next week") {
            // The start of the next calendar week — the honest reading of an
            // expression that names a week, not a day.
            if let thisWeek = cal.dateInterval(of: .weekOfYear, for: now) {
                return thisWeek.end
            }
            return cal.date(byAdding: .day, value: 7, to: today)
        }

        // LAST, deliberately: a clock time with no day word anywhere in the phrase
        // reached this far without one matching, and a bare clock time means today.
        if clockTimeRange(in: raw) != nil { return today }
        return nil
    }

    /// "this morning" / "this afternoon" / "this evening" — a part of TODAY, spoken
    /// the way people actually name it. Shadowed by `CaptureEscalation.timeSignals`.
    static let todayDaypartSignals = ["this morning", "this afternoon", "this evening"]

    /// The one clock-time vocabulary, shared by every reader that must agree on what
    /// a clock time IS: this resolver (which day it implies), `HeuristicEngine`'s
    /// extractor (hands the phrase over verbatim) and `CaptureEscalation.timeSignals`
    /// (counts it as one occasion). Three copies of this regex would be three places
    /// for "9 p.m." to be a time in one and noise in another.
    ///
    /// Forms: "at 3 PM" · "3PM" · "at 3:30 pm" · "9 p.m." · "at noon" · "midnight" ·
    /// and "at 5" — a bare hour after "at", 1–12 only, because "at 20" is not how the
    /// hour is spoken in English and a street number should not become a deadline.
    static let clockTimePattern =
        #"\b(?:at\s+)?(?:noon|midnight|(?:1[0-2]|0?[1-9])(?::[0-5][0-9])?\s?(?:am|pm|a\.m\.|p\.m\.))(?![a-z0-9])"#
        + #"|\bat\s+(?:1[0-2]|[1-9])(?::[0-5][0-9])?(?![a-z0-9:])"#

    /// Where a clock time sits in a lowercased phrase, or nil when it holds none.
    static func clockTimeRange(in lowered: String) -> Range<String.Index>? {
        lowered.range(of: clockTimePattern, options: .regularExpression)
    }

    /// One TIME EXPRESSION = one occasion: a day word with the clock time beside it
    /// absorbed ("tomorrow at 3 PM" is a single deadline), or a clock time on its own.
    /// The day vocabulary shadows this resolver's arms — bare weekdays included,
    /// because `expand` fans them out. Shared by `CaptureEscalation.timeSignals`
    /// (counts occasions) and `Segmentation` (a time expression followed by a fresh
    /// verb is where one spoken outcome ends and the next begins). Case-insensitive
    /// callers must say so; the pattern is written lowercase.
    static let timeExpressionPattern: String = {
        let dayWords =
            "today|tonight|tomorrow"
            + "|next (?:week|month|monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
            + "|this (?:weekend|week|month|morning|afternoon|evening"
            + "|monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
            + "|monday|tuesday|wednesday|thursday|friday|saturday|sunday"
        // Day-then-clock ("tomorrow at 3 PM"), clock-then-day ("3PM today"), or either
        // alone — each ONE occasion.
        return #"\b(?:"# + dayWords + #")\b(?:\s*(?:"# + clockTimePattern + "))?"
            + "|(?:" + clockTimePattern + #")(?:\s+(?:"# + dayWords + #")\b)?"#
    }()

    /// Weekday names in a fixed order — an array, not a dictionary, because a
    /// dictionary's iteration order is unspecified and a phrase naming two days would
    /// resolve differently between runs.
    private static let weekdayNames: [(String, Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
        ("thursday", 5), ("friday", 6), ("saturday", 7),
    ]

    private static func weekdayNumber(in raw: String) -> Int? {
        weekdayNames.first { raw.contains($0.0) }?.1
    }

    /// "in N days" / "in N weeks" / "in a week" / "a week from now" — N as digits or
    /// spelled out. Returns the calendar unit and count to add to today.
    private static func parseRelativeOffset(
        _ raw: String
    )
        -> (unit: Calendar.Component, value: Int)?
    {
        let pattern =
            #"(?:in|within)\s+(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten)\s+(day|week|month)s?"#
        if let match = raw.range(of: pattern, options: .regularExpression) {
            let phrase = String(raw[match])
            let unit: Calendar.Component =
                phrase.contains("month") ? .month : (phrase.contains("week") ? .weekOfYear : .day)
            if let count = spelledNumber(in: phrase) { return (unit, count) }
        }
        // "a week from now", "two days from today".
        let fromPattern =
            #"(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten)\s+(day|week|month)s?\s+from\s+(now|today)"#
        if let match = raw.range(of: fromPattern, options: .regularExpression) {
            let phrase = String(raw[match])
            let unit: Calendar.Component =
                phrase.contains("month") ? .month : (phrase.contains("week") ? .weekOfYear : .day)
            if let count = spelledNumber(in: phrase) { return (unit, count) }
        }
        return nil
    }

    private static let spelledNumbers: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    private static func spelledNumber(in phrase: String) -> Int? {
        if let digits = phrase.range(of: #"\d+"#, options: .regularExpression) {
            return Int(phrase[digits])
        }
        for (word, value) in spelledNumbers.sorted(by: { $0.key.count > $1.key.count })
        where phrase.range(of: #"\b"# + word + #"\b"#, options: .regularExpression) != nil {
            return value
        }
        return nil
    }

    private static let monthNames = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december",
    ]

    /// A month/day with no year ("july 20", "20 july", "jul 20th"), resolved to the
    /// NEXT occurrence — a date the user names is always ahead of them, never a
    /// past-dated task that lands already overdue.
    private static func parseMonthDay(_ raw: String, now: Date, cal: Calendar) -> Date? {
        // The full name or its three-letter abbreviation, whole-word — never a prefix
        // match, which would read "market" as March.
        guard
            let month = monthNames.firstIndex(where: {
                raw.range(
                    of: #"\b(?:"# + $0 + "|" + $0.prefix(3) + #")\b"#, options: .regularExpression)
                    != nil
            })
        else { return nil }
        guard let dayRange = raw.range(of: #"\b\d{1,2}(st|nd|rd|th)?\b"#, options: .regularExpression),
            let day = Int(raw[dayRange].prefix(while: \.isNumber)), (1...31).contains(day)
        else { return nil }

        var comps = DateComponents()
        comps.month = month + 1
        comps.day = day
        comps.year = cal.component(.year, from: now)
        guard let candidate = cal.date(from: comps).map(cal.startOfDay(for:)) else { return nil }
        if candidate < cal.startOfDay(for: now) {
            comps.year = (comps.year ?? 0) + 1
            return cal.date(from: comps).map(cal.startOfDay(for:))
        }
        return candidate
    }

    /// "in july" / "by march" → the first of that month's NEXT occurrence (this month
    /// counts only while it has begun and not ended — "in September" said mid-September
    /// is now). Prepositioned only, so a month named as a topic ("the july invoice")
    /// is never a date; `HeuristicEngine.dateExpression` hands over that shape alone.
    private static func parseBareMonth(_ raw: String, now: Date, cal: Calendar) -> Date? {
        guard
            let match = raw.range(
                of: #"\b(?:in|by|before|until|during|for)\s+(?:early\s+|mid\s+|late\s+)?([a-z]+)\b"#,
                options: .regularExpression)
        else { return nil }
        let word = raw[match].split(separator: " ").last.map(String.init) ?? ""
        guard
            let month = monthNames.firstIndex(where: {
                $0 == word || ($0.prefix(3) == word && word.count == 3)
            })
        else { return nil }
        var comps = DateComponents()
        comps.month = month + 1
        comps.day = 1
        comps.year = cal.component(.year, from: now)
        guard let candidate = cal.date(from: comps).map(cal.startOfDay(for:)) else { return nil }
        if cal.component(.month, from: now) == month + 1 { return cal.startOfDay(for: now) }
        if candidate < cal.startOfDay(for: now) {
            comps.year = (comps.year ?? 0) + 1
            return cal.date(from: comps).map(cal.startOfDay(for:))
        }
        return candidate
    }

    /// Fixed-format POSIX formatter, built once — `DateFormatter` construction is the
    /// classic per-call allocation tax, and this runs inside the per-draft date arm.
    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func parseISO(_ raw: String) -> Date? {
        // yyyy-MM-dd anywhere in the phrase.
        guard let range = raw.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
            return nil
        }
        return isoFormatter.date(from: String(raw[range]))
    }
}
