//
//  HeuristicEngine.swift
//  Project-Ezra
//
//  Deterministic, always-available fallback for when Foundation Models isn't on
//  the device (older hardware, Apple Intelligence disabled, or the simulator).
//  It keeps the whole loop working with keyword categorization and rule-based
//  confidence — lower ceiling than the LLM, so it routes more items to Needs
//  Decision rather than guessing, exactly as the confidence-lever framing intends.
//

import Foundation

struct HeuristicEngine: AIEngine {
    let engineName = "On-device rules"
    let isOnDevice = false

    /// Deterministic and effectively instant, so the streaming callback is
    /// ignored — the "partial" and the final are the same thing. Personalization
    /// is applied uniformly by `IntentResolver`'s learned rules, not here.
    func triage(
        rawText: String,
        context: TriageContext,
        onPartial: (@MainActor ([TaskIntent]) -> Void)?
    ) async throws -> [TaskIntent] {
        let lines = Self.splitIntoItems(rawText)
        return lines.map { Self.intent(from: $0) }
    }

    // MARK: - Household narrative (deterministic template)

    /// Deterministic counterpart to the on-device narrative — a calm one-to-two
    /// sentence summary built straight from the facts, so the simulator / non-AI
    /// path still renders a real sentence. Behaviorally consistent with the LLM:
    /// same facts in, same shape of summary out, nothing invented.
    func householdNarrative(_ facts: HouseholdFacts) async throws -> String {
        Self.narrative(from: facts)
    }

    static func narrative(from facts: HouseholdFacts) -> String {
        guard !facts.memberSummaries.isEmpty else {
            return "Nothing shared is in motion right now."
        }

        // The counts live in the highlights row; the sentence stays calm and names
        // at most the two biggest things, so it reads as a summary, not a tally.
        var flags: [String] = []
        if facts.overdueCount > 0 { flags.append("\(facts.overdueCount) overdue") }
        if facts.blockedCount > 0 { flags.append("\(facts.blockedCount) blocked") }
        if facts.needsDecisionCount > 0 {
            flags.append(facts.needsDecisionCount == 1 ? "a decision to make" : "decisions to make")
        }
        if facts.unownedCount > 0 { flags.append("\(facts.unownedCount) unowned") }
        let top = Array(flags.prefix(2))

        switch facts.status {
        case "operatingSmoothly":
            return "The household is running smoothly right now."
        case "needsAttention" where !top.isEmpty:
            return "A few things need coordinating — \(listPhrase(top))."
        case "needsAttention":
            return "A few things need coordinating."
        default:
            return "It's quiet across the household."
        }
    }

    /// Join phrases the way a person would: "a", "a and b", "a, b, and c".
    private static func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }

    // MARK: - Item splitting

    /// A pasted blob may be newline-, comma-, or bullet-separated. Normalize to
    /// individual task lines and drop empties / obvious headers.
    static func splitIntoItems(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: "\n\r")
        let rawLines = text.components(separatedBy: separators)
        var items: [String] = []
        for line in rawLines {
            let trimmed =
                line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-•*·—▪◦> \t"))
            guard trimmed.count > 1 else { continue }
            // A single line may itself list several comma-separated errands.
            if trimmed.contains(",") && trimmed.count < 120 {
                let parts = trimmed.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.count > 1 }
                items.append(contentsOf: parts)
            } else {
                items.append(trimmed)
            }
        }
        return items
    }

    // MARK: - Per-item classification

    static func intent(from line: String) -> TaskIntent {
        let lower = line.lowercased()
        let category = category(for: lower)
        let judgment = isJudgmentCall(lower)
        let blocked = isBlocked(lower)
        // Confidence: strong keyword hit → higher; generic line → medium; ambiguous → low.
        let confidence: Double = {
            if judgment { return 0.4 }
            if category == "Admin" || category == "Errands" { return 0.6 }
            return categoryIsStrong(lower) ? 0.85 : 0.65
        }()
        let owner = ownerName(from: lower)
        let reasoning: String = {
            if judgment { return "This is a personal judgment call, so it's yours to make." }
            if blocked { return "Looks like it depends on something else finishing first." }
            if let owner { return "Sounds like \(owner)'s to handle — kept off your list." }
            return "Filed under \(category) from the wording."
        }()
        return TaskIntent(
            title: cleanTitle(line),
            category: category,
            dateExpression: dateExpression(from: lower),
            personReference: owner,
            blockerPhrase: blocked ? blockerPhrase(from: lower) : nil,
            confidence: confidence,
            isJudgmentCall: judgment,
            reasoning: reasoning,
            isUrgent: urgencySignal(for: lower),
            importance: importanceSignal(for: lower),
            effortMinutes: effortMinutes(from: lower),
            workIntent: isReference(lower) ? WorkIntent.reference.rawValue : nil
        )
    }

    /// Phrases that read as something to KEEP rather than something to do — "the wifi
    /// password is hunter2", "gate code 4417", "remember that the vet closes at six".
    ///
    /// This is the one `WorkIntent` the heuristic path classifies, and it is **not a
    /// test seam**. `workIntent` is otherwise on-device only, and Apple Intelligence
    /// can be off by user setting or unavailable by region — so without this, every
    /// non-AI user has nil intent, `countsAsWorkload` is universally true, and the
    /// whole reference exclusion never fires for them. It is also what makes the five
    /// gated sites verifiable in the simulator at all.
    ///
    /// Deliberately narrow: a false positive silently removes a real task from the
    /// plan, the load counts, and the sweeps, so it only fires on wording that is
    /// clearly a stored fact, never on a bare noun phrase.
    static func isReference(_ lower: String) -> Bool {
        // A record-keeping noun followed by a value: "password is …", "code: 4417".
        let subjects = ["password", "passcode", "pin", "code", "wifi", "wi-fi", "login", "username"]
        if subjects.contains(where: { lower.contains($0) }),
            lower.contains(" is ") || lower.contains(":") || lower.contains("=")
        {
            return true
        }
        // An explicit "keep this" framing, but NOT "remember to …", which is a to-do.
        if lower.hasPrefix("remember that ") || lower.hasPrefix("note that ")
            || lower.hasPrefix("fyi ") || lower.hasPrefix("for reference")
        {
            return true
        }
        return false
    }

    private static func cleanTitle(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        if let first = t.first {
            t.replaceSubrange(t.startIndex...t.startIndex, with: String(first).uppercased())
        }
        return t
    }

    private static let categoryKeywords: [(String, [String])] = [
        (
            "Car",
            ["car", "oil change", "tire", "repair", "mechanic", "dmv", "registration", "insurance card"]
        ),
        (
            "Travel",
            [
                "flight", "hotel", "trip", "passport", "visa", "book flights", "airbnb", "itinerary",
                "vacation",
            ]
        ),
        (
            "Health",
            ["dentist", "doctor", "appointment", "prescription", "gym", "therapy", "vaccine", "checkup"]
        ),
        (
            "Finance",
            [
                "pay", "bill", "invoice", "taxes", "budget", "bank", "refund", "subscription",
                "renew insurance",
            ]
        ),
        ("Family", ["mom", "dad", "kids", "daycare", "school", "birthday", "call grandma", "family"]),
        (
            "Home",
            ["clean", "laundry", "grocery", "groceries", "fix", "plumber", "furniture", "trash", "yard"]
        ),
        (
            "Work",
            ["email", "meeting", "presentation", "deck", "report", "deadline", "client", "standup", "slack"]
        ),
        ("Errands", ["pick up", "drop off", "return", "buy", "post office", "package", "mail"]),
        ("Personal", ["haircut", "read", "journal", "gift", "friend", "plan"]),
    ]

    /// Word-boundary match: a single-word keyword must match a whole word, so
    /// "car" no longer hits inside "day-car-e". Multi-word keywords (phrases) still
    /// use substring matching since they can't accidentally hide inside one word.
    private static func matches(_ keyword: String, in lower: String, words: Set<String>) -> Bool {
        if keyword.contains(" ") { return lower.contains(keyword) }
        return words.contains(keyword)
    }

    private static func words(in lower: String) -> Set<String> {
        Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    private static func category(for lower: String) -> String {
        let words = words(in: lower)
        for (cat, keys) in categoryKeywords
        where keys.contains(where: { matches($0, in: lower, words: words) }) {
            return cat
        }
        return "Admin"
    }

    private static func categoryIsStrong(_ lower: String) -> Bool {
        let words = words(in: lower)
        for (_, keys) in categoryKeywords where keys.contains(where: { matches($0, in: lower, words: words) })
        {
            return true
        }
        return false
    }

    private static let judgmentSignals = [
        "should i", "quit", "cancel", "give up", "still want", "worth it",
        "decide whether", "figure out if", "commit to", "break up", "move to",
        "change careers", "is this still", "do i really",
    ]

    private static func isJudgmentCall(_ lower: String) -> Bool {
        judgmentSignals.contains { lower.contains($0) }
    }

    /// Dependency signals, longest-phrase first so extraction prefers the specific
    /// form. Matched on word boundaries so "after" never hits inside "rafters".
    private static let blockSignals = [
        "when i hear back from", "waiting on", "blocked by", "depends on", "after", "once",
    ]

    private static func isBlocked(_ lower: String) -> Bool {
        lower.contains("when i hear back")
            || blockSignals.contains { signalRange($0, in: lower) != nil }
    }

    private static func signalRange(_ signal: String, in lower: String) -> Range<String.Index>? {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: signal) + "\\b"
        return lower.range(of: pattern, options: .regularExpression)
    }

    /// Extract what the task is waiting on: the phrase following the dependency
    /// signal, with trailing resolution words ("is done", "finishes") stripped so
    /// it can be matched against a completed task's title later.
    static func blockerPhrase(from lower: String) -> String? {
        for signal in blockSignals {
            guard let range = signalRange(signal, in: lower) else { continue }
            var phrase = String(lower[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
            for suffix in [
                " is done", " is finished", " is complete", " gets done", " finishes",
                " comes back", " arrives", " clears", " is sorted",
            ] where phrase.hasSuffix(suffix) {
                phrase = String(phrase.dropLast(suffix.count))
                break
            }
            let trimmed = phrase.trimmingCharacters(in: .whitespaces)
            return trimmed.count > 1 ? trimmed : nil
        }
        return nil
    }

    // MARK: - Metadata extraction (priority / owner / effort)

    private static let urgentSignals = [
        "urgent", "asap", "immediately", "right away", "critical", "overdue", "can't wait",
    ]
    private static let lowSignals = [
        "someday", "eventually", "at some point", "no rush", "when i get a chance", "low priority",
        "maybe ",
    ]
    private static let highSignals = ["important", "don't forget", "make sure", "priority"]

    /// The Urgent signal from the user's own wording only — false when unstated.
    static func urgencySignal(for lower: String) -> Bool {
        urgentSignals.contains { lower.contains($0) }
    }

    /// Importance 0…1 from the user's own wording, or nil when nothing signals it (the
    /// resolver then backfills a default). Explicit deferral ("no rush") wins over
    /// emphasis words so "important but no rush" reads the way the user meant it.
    static func importanceSignal(for lower: String) -> Double? {
        if urgentSignals.contains(where: { lower.contains($0) }) { return 0.85 }
        if lowSignals.contains(where: { lower.contains($0) }) { return 0.15 }
        if highSignals.contains(where: { lower.contains($0) }) { return 0.7 }
        return nil
    }

    private static let notNames: Set<String> = [
        "me", "myself", "him", "her", "them", "someone", "somebody", "everyone",
        "the", "a", "my", "your", "our", "his", "their", "you", "us", "it",
    ]

    /// Delegation: "ask sarah to…", "remind mom about…", "delegate … to ravi",
    /// "mike will handle…". Returns a capitalized name, or nil when the task reads
    /// as the user's own.
    static func ownerName(from lower: String) -> String? {
        let patterns = [
            #/\b(?:ask|tell|get|remind)\s+(?<name>[a-z]+)\s+(?:to|about)\b/#,
            #/\bdelegate\b[\w\s]*?\bto\s+(?<name>[a-z]+)\b/#,
            #/\b(?<name>[a-z]+)\s+will\s+(?:handle|do|take|own)\b/#,
        ]
        for pattern in patterns {
            if let match = try? pattern.firstMatch(in: lower) {
                let name = String(match.name)
                guard !notNames.contains(name), name.count > 1 else { continue }
                return name.prefix(1).uppercased() + name.dropFirst()
            }
        }
        return nil
    }

    /// Rough effort in minutes when the wording implies one; nil otherwise.
    static func effortMinutes(from lower: String) -> Int? {
        if let match = try? #/(?<num>\d+)\s*(?:minutes|minute|mins|min)\b/#.firstMatch(in: lower),
            let minutes = Int(match.num)
        {
            return minutes
        }
        if let match = try? #/(?<num>\d+)\s*(?:hours|hour|hrs|hr)\b/#.firstMatch(in: lower),
            let hours = Int(match.num)
        {
            return hours * 60
        }
        // A call/text/reply is a small, bounded item — a useful quick-win signal.
        let quickVerbs: Set<String> = ["call", "text", "email", "reply", "ping"]
        if !quickVerbs.isDisjoint(with: words(in: lower)) || lower.contains("quick") {
            return 15
        }
        return nil
    }

    /// Extract the raw time phrase — the intent carries it verbatim and
    /// `IntentResolver.resolveDate` turns it into an actual date. Longest/most
    /// specific token first so "day after tomorrow" never truncates to "today".
    static func dateExpression(from lower: String) -> String? {
        let tokens = [
            "tomorrow", "today", "tonight", "next week", "this weekend", "weekend",
            "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        ]
        for token in tokens where lower.contains(token) {
            return token
        }
        return nil
    }
}
