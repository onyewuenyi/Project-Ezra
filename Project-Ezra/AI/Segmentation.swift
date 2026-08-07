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
                    items.append(contentsOf: splitCommaList(clause))
                }
            }
        }
        return fold(items)
    }

    // MARK: - Sentences

    private static func sentences(in line: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = line
        var result: [String] = []
        tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
            let sentence = trimItem(String(line[range]))
            if !sentence.isEmpty { result.append(sentence) }
            return true
        }
        return result.isEmpty ? [trimItem(line)] : result
    }

    // MARK: - Clauses (spoken connectives, item-gated)

    /// The spoken joints of a ramble. Matching is case-insensitive directly over the
    /// clause (no lowered shadow string — index math must survive any input); at a
    /// shared position the LONGEST match wins, the same arm-order discipline as
    /// `IntentResolver.resolveDate` (", and then" before ", and" before " and ").
    private static let connectives: [String] = [
        ", and then ", " and then ", ", and also ", " and also ", ", then ", ", also ",
        " also ", " oh and ", ", and ", ", plus ", " plus ", " and ", "; ",
    ]

    /// Split one sentence at accepted connective boundaries, scanning left to right.
    /// A rejected boundary ("call mom and dad") is stepped past and the scan
    /// continues — later boundaries in the same sentence still split.
    static func splitClauses(_ sentence: String) -> [String] {
        var clauses: [String] = []
        var remaining = Substring(sentence)
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

    // MARK: - Lead-ins ("i need to …" → the action itself)

    /// Spoken preambles stripped from the head of a clause, iteratively — "and i
    /// also need to" is several of these in a row. Ordered longest-first so
    /// "i need to" wins before "to".
    private static let leadIns: [String] = [
        "i really need to ", "i also need to ", "i still need to ", "don't forget to ",
        "i've got to ", "i have to ", "i need to ", "i should probably ",
        "i want to ", "we need to ", "we have to ", "make sure to ",
        "make sure i ", "remember to ", "need to ", "i gotta ", "gotta ", "have to ",
        "try to ", "so basically ", "so i ", "oh and ", "also ", "then ", "to ",
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
    ]
}
