//
//  Segmentation.swift
//  Project-Ezra
//
//  Deterministic item segmentation for the heuristic path — and therefore for the
//  simulator, for XCTest, and for the on-device TIMEOUT fallback. The old splitter
//  read newlines and short comma lists only, so a dictated 600-char run-on
//  ("…and then I need to…") became ONE mega-task — on exactly the paths where the
//  product's flagship input (the spoken ramble) lands when the model can't serve.
//
//  Three passes, all pure string work over a small curated vocabulary:
//  1. Lines: newline/bullet splitting, headers dropped (unchanged from the old shape).
//  2. Sentences: NLTokenizer(.sentence) per line — deterministic, no model assets.
//  3. Clauses: within a sentence, split at spoken connectives ("and then", ", and",
//     "also"…) — but a boundary is accepted ONLY when what follows starts an item
//     (lead-in phrases stripped, then an action verb or a judgment opener), so
//     "call mom and dad" and "wash and fold the laundry" never split. Comma lists
//     then split per part with the same item test (or short noun-list parts) —
//     the old "< 120 characters" cliff is gone; a 130-char errand list splits
//     exactly like a 119-char one. Digit,digit commas ("1,000") never split.
//
//  Emitted clauses drop their lead-in ("I need to renew the passport" → "renew the
//  passport") — the lead-in is how the boundary was verified, and stripping it is
//  what makes split titles read like tasks instead of transcript fragments. A
//  clause whose stripped form doesn't read as an item keeps its original wording:
//  stripping is a title improvement, never a meaning change.
//

import Foundation
import NaturalLanguage

enum Segmentation {

    /// A raw capture → individual task lines. Deterministic; empties and obvious
    /// headers dropped.
    static func items(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: "\n\r")
        var items: [String] = []
        for line in text.components(separatedBy: separators) {
            let trimmed =
                line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-•*·—▪◦> \t"))
            guard trimmed.count > 1 else { continue }
            for sentence in sentences(in: trimmed) {
                for clause in splitClauses(sentence) {
                    for run in splitAfterTimeExpressions(clause) {
                        items.append(contentsOf: splitCommaList(run))
                    }
                }
            }
        }
        return fold(items)
    }

    /// Items from ONLY the structure the user actually typed — lines, bullets, sentence
    /// marks, list commas — with no connective-clause inference. Splitting "renew my
    /// passport and call mom" is a judgement about prose; splitting "buy milk, call mom"
    /// is reading punctuation the user put there.
    static func explicitItems(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: "\n\r")
        var items: [String] = []
        for line in text.components(separatedBy: separators) {
            let trimmed =
                line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-•*·—▪◦> \t"))
            guard trimmed.count > 1 else { continue }
            for sentence in sentences(in: trimmed) {
                items.append(contentsOf: splitCommaList(strippedPreamble(sentence)))
            }
        }
        return fold(items)
    }

    /// How much the deterministic read can be trusted to SHOW as final structure.
    ///
    /// Did the USER draw the boundaries, or are we being asked to infer them?
    ///
    /// **Two states, and the collapse from three is the point** (2026-08-22). This used
    /// to be `typed / singleThought / ambiguous`, and the middle case was the problem:
    ///
    ///   * `.explicit` is an OBSERVATION about the input — the person pressed return, or
    ///     typed a bullet, or punctuated a list. It is a fact, and reading a fact is
    ///     something deterministic code may do.
    ///   * `.singleThought` was an INTERPRETATION — an 18-word ceiling and a verb lexicon
    ///     deciding that an unpunctuated sentence probably described one piece of work.
    ///     That is a semantic judgment about task boundaries, and it is exactly the
    ///     judgment the semantic authority exists to make.
    ///
    /// Keeping the middle case meant saying, in effect: *we don't trust deterministic
    /// segmentation to decompose a ramble, but we do trust it to decide when the model
    /// isn't needed.* That is an incoherent authority boundary, and it is the one this
    /// whole redesign set out to remove — so the vocabulary stops describing it. Once
    /// Gemini owns decomposition, whether unstructured input was *probably* one thought
    /// is not a question anyone needs answered; the only question is whether the user
    /// handed us boundaries.
    ///
    /// The on-device confidence gate was the other way to certify a single thought, and
    /// it was measured and deleted: warm p50 2303ms against a 400ms budget, escalating
    /// 95-100% of what it saw, on a device where the cloud answers in about a second.
    enum Structure: Equatable {
        /// The user drew the boundaries. `items` are those boundaries, unaltered.
        case explicit([String])
        /// No boundaries given. One task or eight is a semantic question.
        case unstructured

        /// One stable word for the capture receipt (`CaptureProvenance`), so the two
        /// producers cannot spell the same state differently in the same log.
        var label: String {
            switch self {
            case .explicit: return "explicit"
            case .unstructured: return "unstructured"
            }
        }

        var isExplicit: Bool { if case .explicit = self { return true }; return false }
    }

    /// Structure the user actually provided — never structure we inferred.
    ///
    /// The test is agreement between the two splitters: `items` infers boundaries at
    /// spoken connectives, `explicitItems` reads only punctuation and layout. When they
    /// agree on the count, every boundary in the result is one the user themselves
    /// marked, and nothing was guessed. When they disagree, or when there is a single
    /// unpunctuated run, the boundaries are ours rather than theirs — and that goes to
    /// the authority.
    ///
    /// Note the deliberate consequence: a lone sentence with no punctuation is
    /// `.unstructured` even when it obviously describes one errand. "Obviously" is doing
    /// semantic work there, and this function is not allowed to do semantic work.
    static func structure(of text: String) -> Structure {
        let explicit = explicitItems(from: text)
        guard explicit.count > 1 else { return .unstructured }
        return items(from: text).count == explicit.count ? .explicit(explicit) : .unstructured
    }

    /// Words that, immediately before an action verb, mean it isn't starting a new item.
    static let subordinatingWords: Set<String> = [
        // determiners → the "verb" is a noun
        "a", "an", "the", "my", "your", "his", "her", "its", "our", "their",
        "this", "that", "these", "those", "some", "any", "no", "one", "another",
        // modals + infinitive marker → subordinate clause
        "to", "should", "shall", "could", "would", "can", "will", "must", "might", "may",
        "need", "want", "have", "has", "had", "let", "help", "gonna", "going",
        // conjunctions → shares the previous verb's subject/object
        "and", "or", "then", "also", "but", "nor",
    ]

    // MARK: - Sentences

    private static func sentences(in line: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = line
        var result: [String] = []
        tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
            for sentence in splitAtSpokenPeriods(String(line[range])) {
                let trimmed = trimItem(sentence)
                if !trimmed.isEmpty { result.append(trimmed) }
            }
            return true
        }
        return result.isEmpty ? [trimItem(line)] : result
    }

    /// Dictation writes "…for this Wednesday. take Micah to daycare…" — a period the
    /// speech engine placed, followed by a lowercase verb, which `NLTokenizer` reads
    /// as one sentence because it leans on capitalization. The period is the user's
    /// own boundary and is honoured under the usual gate: ONLY when what follows
    /// starts an item. "Tell Mr. Charles, what did…" and "9 p.m. No." stay whole.
    static func splitAtSpokenPeriods(_ sentence: String) -> [String] {
        var pieces: [String] = []
        var start = sentence.startIndex
        var searchFrom = sentence.startIndex
        while let range = sentence.range(of: ". ", range: searchFrom..<sentence.endIndex) {
            let right = sentence[range.upperBound...].drop(while: { $0 == " " })
            let rightItem = strippedLeadIn(trimItem(String(right)))
            if startsAnItem(rightItem), rightItem.split(separator: " ").count >= 2 {
                pieces.append(String(sentence[start..<range.lowerBound]))
                start = right.startIndex
            }
            searchFrom = range.upperBound
        }
        pieces.append(String(sentence[start...]))
        return pieces
    }

    // MARK: - Clauses (spoken connectives, item-gated)

    /// The spoken joints of a ramble. Matching is case-insensitive directly over the
    /// clause (no lowered shadow string — index math must survive any input); at a
    /// shared position the LONGEST match wins, the same arm-order discipline as
    /// `IntentResolver.resolveDate` (", and then" before ", and" before " and ").
    private static let connectives: [String] = [
        ", and after that ", " and after that ", ", after that ", " after that ",
        ", then i need to ", " then i need to ", ", and then ", " and then ",
        ", and also ", " and also ", ", then ", ", also ",
        " also ", " oh and ", ", and ", ", plus ", " plus ", " and ", "; ",
    ]

    /// Split one sentence at accepted connective boundaries, scanning left to right.
    /// A rejected boundary ("call mom and dad") is stepped past and the scan
    /// continues — later boundaries in the same sentence still split.
    static func splitClauses(_ sentence: String) -> [String] {
        var clauses: [String] = []
        var remaining = Substring(strippedPreamble(sentence))
        var searchFrom: Substring.Index?

        while let (range, connective) = earliestConnective(in: remaining, from: searchFrom) {
            if acceptBoundary(
                connective: connective, left: remaining[..<range.lowerBound],
                right: remaining[range.upperBound...])
            {
                let leftItem = trimItem(String(remaining[..<range.lowerBound]))
                if !leftItem.isEmpty { clauses.append(leftItem) }
                remaining = remaining[range.upperBound...]
                searchFrom = nil
            } else {
                guard range.lowerBound < remaining.endIndex else { break }
                let next = remaining.index(after: range.lowerBound)
                guard next < remaining.endIndex else { break }
                searchFrom = next
            }
        }
        let tail = trimItem(String(remaining))
        if !tail.isEmpty { clauses.append(tail) }
        return clauses.map(strippedLeadIn)
    }

    private static func earliestConnective(
        in text: Substring, from start: Substring.Index? = nil
    ) -> (Range<Substring.Index>, String)? {
        let searchStart = start ?? text.startIndex
        guard searchStart < text.endIndex else { return nil }
        var best: (range: Range<Substring.Index>, connective: String)?
        for connective in connectives {
            guard
                let found = text.range(
                    of: connective, options: [.caseInsensitive],
                    range: searchStart..<text.endIndex)
            else { continue }
            if let current = best {
                if found.lowerBound < current.range.lowerBound
                    || (found.lowerBound == current.range.lowerBound
                        && found.upperBound > current.range.upperBound)
                {
                    best = (found, connective)
                }
            } else {
                best = (found, connective)
            }
        }
        return best.map { ($0.range, $0.connective) }
    }

    /// A boundary is real when the RIGHT side starts an item. The bare " and " is
    /// the weak connective — compound objects ("mom and dad") and compound verbs
    /// sharing one object ("wash and fold the laundry", "pick up and drop off the
    /// kids") ride it — so it additionally requires the LEFT side to be a complete
    /// item of its own: at least verb + object ("pay rent" splits; a bare "wash"
    /// or a verb + particle "pick up" does not), or a ≥3-word non-imperative
    /// clause; and the right side must still carry an object after its opener.
    private static func acceptBoundary(
        connective: String, left: Substring, right: Substring
    ) -> Bool {
        let stripped = strippedLeadIn(trimItem(String(right)))
        if connective == " and ", datedOnBothSides(left: trimItem(String(left)), right: stripped) {
            return true
        }
        guard startsAnItem(stripped) else { return false }
        if connective == " and " {
            let leftClause = trimItem(String(left))
            let leftWords = leftClause.split(separator: " ")
            guard leftWords.count >= 2,
                startsAnItem(strippedLeadIn(leftClause)) || leftWords.count >= 3,
                let lastLeft = leftWords.last.map({ $0.lowercased() }),
                !verbParticles.contains(lastLeft),
                stripped.split(separator: " ").count >= 2
            else { return false }
        }
        return true
    }

    /// Two clauses that each carry their OWN time phrase are two outcomes even when the
    /// second has no verb of its own: "dentist on thursday and the vet on friday", "text
    /// mom about sunday and the dentist about thursday". Measured on 2026-09-17 (iOS 27
    /// GA): these were 2 of the 3 utterances that still escalated as under-segmented,
    /// and the on-device boundary pass answered "one part" for both — the deterministic
    /// read is the only arm that can resolve them, at 2 ms, with no transmission. The
    /// guard against a day-list ("walk my dog monday and tuesday plan the year") is that
    /// the right side must not OPEN with a weekday: a clause that starts on a day is
    /// continuing an enumeration the resolver fans out, never a second outcome. The right
    /// side must also say more than its day, or "…and friday" would become a card.
    static func datedOnBothSides(left: String, right: String) -> Bool {
        let leftLower = left.lowercased()
        let rightLower = right.lowercased()
        guard HeuristicEngine.dateExpression(from: leftLower) != nil,
            HeuristicEngine.dateExpression(from: rightLower) != nil
        else { return false }
        let rightWords = rightLower.split(separator: " ").map(String.init)
        guard rightWords.count >= 2, let first = rightWords.first,
            !HeuristicEngine.isWeekday(first)
        else { return false }
        return left.split(separator: " ").count >= 2
    }

    /// A left clause ENDING in one of these is a verb still waiting for its object
    /// ("pick up and drop off the kids") — never a complete item to split after.
    private static let verbParticles: Set<String> = [
        "up", "off", "out", "in", "on", "away", "back", "over", "down",
    ]

    /// Does this clause read as a standalone item? An imperative start ("renew…"),
    /// or a judgment opener ("should I keep paying…") — judgment calls are items
    /// too, and a ramble mixes them into the same breath as its errands.
    static func startsAnItem(_ clause: String) -> Bool {
        let lowered = clause.lowercased()
        if judgmentOpeners.contains(where: lowered.hasPrefix) { return true }
        guard let first = lowered.split(separator: " ").first else { return false }
        return actionVerbs.contains(String(first))
    }

    private static let judgmentOpeners: [String] = [
        "should i ", "should we ", "do i ", "do we ", "is it worth ",
    ]

    // MARK: - Preambles ("ok brain dump time — renew…" → "renew…")

    /// Strip a spoken warm-up from the head of a sentence — but ONLY when what
    /// remains is a verified item, so a real task can never lose its words. Two
    /// contained forms: a dash/colon preamble ("ok brain dump time — renew the
    /// passport") whose lead-up is short and verb-free, and a run of filler openers
    /// ("okay so um renew the passport"). A sentence that is ALL filler ("okay so
    /// this week is a lot") is returned untouched — it becomes a card the user can
    /// delete, dimmed by the heuristic's low-confidence read, never silently
    /// dropped (always-confirm: visible and fixable beats invisible and gone).
    static func strippedPreamble(_ sentence: String) -> String {
        // Dash/colon form: everything before the first separator is a short,
        // verb-free warm-up and everything after starts an item.
        for separator in [" — ", " – ", ": "] {
            if let range = sentence.range(of: separator) {
                let head = sentence[..<range.lowerBound]
                let tail = trimItem(String(sentence[range.upperBound...]))
                let headWords = head.split(separator: " ")
                if headWords.count <= 4,
                    !headWords.contains(where: { actionVerbs.contains($0.lowercased()) }),
                    startsAnItem(strippedLeadIn(tail))
                {
                    return tail
                }
            }
        }
        // Filler-opener run: strip while the remainder verifies as an item.
        var remaining = Substring(sentence)
        var stripped = false
        while let first = remaining.split(separator: " ").first,
            fillerOpeners.contains(first.lowercased())
        {
            remaining = remaining.dropFirst(first.count).drop(while: { $0 == " " })
            stripped = true
        }
        if stripped {
            let candidate = trimItem(String(remaining))
            if startsAnItem(strippedLeadIn(candidate)) { return candidate }
        }
        return sentence
    }

    private static let fillerOpeners: Set<String> = [
        "ok", "okay", "alright", "so", "anyway", "um", "uh", "well", "right",
        "honestly", "basically", "and", "yeah",
    ]

    // MARK: - Lead-ins ("i need to …" → the action itself)

    /// Spoken preambles stripped from the head of a clause, iteratively — "and i
    /// also need to" is several of these in a row. Ordered longest-first so
    /// "i need to" wins before "to".
    private static let leadIns: [String] = [
        // Meta-narration — the act of capturing, spoken (P4, the real-utterance corpus
        // 2026-09-02: "I want to add that I need to be ready to go to brunch",
        // "Adding pickup shirt at 3 PM"). Longest first, ahead of the "i want to"
        // they contain.
        "i want to add that ", "i wanted to add that ", "i just want to add that ",
        "adding that ", "adding ", "add that ", "note to self ", "note that ",
        "remind me to ", "reminder to ", "reminder ", "don't let me forget to ",
        "i keep forgetting to ",
        "i really need to ", "i also need to ", "i still need to ", "don't forget to ",
        "i've got to ", "i have to ", "i need to ", "i should probably ",
        "i want to ", "we need to ", "we have to ", "make sure to ",
        "make sure i ", "remember to ", "need to ", "i gotta ", "gotta ", "have to ",
        "try to ", "so basically ", "so i ", "oh and ", "also ", "then ", "to ",
        // Spoken enumeration openers ("first call mom…") — like every lead-in they
        // strip only when the remainder verifies as an item, so "first aid kit"
        // keeps its words.
        "first ", "second ", "third ", "lastly ", "finally ",
    ]

    /// Strip lead-in phrases while the remainder still reads as an item — a clause
    /// whose stripped form doesn't is returned in its original wording.
    static func strippedLeadIn(_ clause: String) -> String {
        var remaining = Substring(clause)
        var changed = true
        while changed {
            changed = false
            let lowered = remaining.lowercased()
            for leadIn in leadIns where lowered.hasPrefix(leadIn) {
                remaining = remaining.dropFirst(leadIn.count)
                changed = true
                break
            }
        }
        let trimmed = trimItem(String(remaining))
        return startsAnItem(trimmed) ? trimmed : trimItem(clause)
    }

    // MARK: - Time expressions ("…groceries at noon make a plan…")

    /// A time expression followed directly by a fresh verb is where one spoken
    /// outcome ends and the next begins: "pick up groceries at noon make an action
    /// plan this Sunday" has no punctuation and no connective — the first real
    /// unpunctuated run-on the corpus produced (2026-09-02), kept local as ONE task
    /// by every other pass. Item-gated like every boundary here: the right side must
    /// start an item of at least two words after its lead-in, so "walk the dog
    /// monday and tuesday" ("and…" starts nothing) and "at 3 PM so this is where…"
    /// stay whole. The vocabulary is the resolver's own
    /// (`IntentResolver.timeExpressionPattern`) — a day word with its clock absorbed,
    /// or a clock time alone.
    static func splitAfterTimeExpressions(_ clause: String) -> [String] {
        guard
            let regex = try? NSRegularExpression(
                pattern: IntentResolver.timeExpressionPattern, options: [.caseInsensitive])
        else { return [clause] }
        var pieces: [String] = []
        var start = clause.startIndex
        for match in regex.matches(in: clause, range: NSRange(clause.startIndex..., in: clause)) {
            guard let range = Range(match.range, in: clause), range.lowerBound >= start
            else { continue }
            let right = clause[range.upperBound...].drop(while: { $0 == " " })
            guard !right.isEmpty else { continue }
            let rightItem = strippedLeadIn(trimItem(String(right)))
            guard startsAnItem(rightItem), rightItem.split(separator: " ").count >= 2
            else { continue }
            let leftItem = trimItem(String(clause[start..<range.upperBound]))
            if !leftItem.isEmpty { pieces.append(leftItem) }
            start = right.startIndex
        }
        let tail = trimItem(String(clause[start...]))
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.isEmpty ? [clause] : pieces
    }

    // MARK: - Comma lists

    /// Split a clause at list commas — per PART, not per line length (the old
    /// "< 120 characters" gate made a 130-char errand list behave differently from
    /// a 119-char one). A split is accepted only when every part is an item or a
    /// short noun-list entry; digit,digit commas ("1,000") never split.
    static func splitCommaList(_ clause: String) -> [String] {
        guard clause.contains(",") else { return [clause] }
        var parts: [String] = []
        var current = ""
        let characters = Array(clause)
        for (index, character) in characters.enumerated() {
            let previousIsDigit = index > 0 && characters[index - 1].isNumber
            let nextIsDigit = index + 1 < characters.count && characters[index + 1].isNumber
            if character == ",", !(previousIsDigit && nextIsDigit) {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)

        let trimmedParts = parts.map { strippedLeadIn(trimItem($0)) }.filter { $0.count > 1 }
        guard trimmedParts.count > 1 else { return [clause] }
        let allItemLike = trimmedParts.allSatisfy { part in
            startsAnItem(part) || part.split(separator: " ").count <= 4
        }
        return allItemLike ? trimmedParts : [clause]
    }

    // MARK: - Folding

    /// A fragment too thin to stand alone ("and dad too") folds into its left
    /// neighbour rather than becoming a junk card.
    private static func fold(_ items: [String]) -> [String] {
        var folded: [String] = []
        for item in items {
            if CorrectionProfile.significantWords(item).count < 2, !folded.isEmpty {
                folded[folded.count - 1] += ", \(item)"
            } else {
                folded.append(item)
            }
        }
        return folded
    }

    private static func trimItem(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix(".") || trimmed.hasSuffix("…") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    // MARK: - Action-verb lexicon

    /// Curated imperative starts — the gate that keeps compound objects together.
    /// Whole words, lowercased.
    static let actionVerbs: Set<String> = [
        "call", "text", "email", "reply", "message", "ping", "ask", "remind", "confirm",
        "rsvp", "buy", "get", "grab", "pick", "order", "return", "drop", "take", "bring",
        "send", "mail", "ship", "book", "schedule", "plan", "organize", "organise",
        "clean", "wash", "fold", "fix", "repair", "renew", "register", "pay", "file",
        "submit", "sign", "cancel", "finish", "start", "write", "draft", "prepare",
        "research", "review", "check", "look", "find", "figure", "decide", "choose",
        "make", "set", "put", "sort", "update", "install", "print", "scan", "upload",
        "download", "water", "walk", "feed", "pack", "unpack", "move", "go", "do",
        "read", "sell", "donate", "vacuum", "mow", "shovel", "change", "replace",
        // The real-utterance corpus (2026-09-02): "cook dinner at 3 PM, make a…" and
        // "…clean my clothes and then eat breakfast" both failed to split for want
        // of a verb the lexicon had never met. Everyday outcomes, all imperative.
        "cook", "eat", "bake", "meet", "visit", "drive", "attend", "practice",
        "study", "shop", "apply", "tidy", "wrap", "charge", "exercise",
        // "be ready to go to brunch", "pickup shirt" — spoken imperatives the corpus
        // produced that the list had no word for.
        "be", "pickup", "stop", "reach",
    ]
}
