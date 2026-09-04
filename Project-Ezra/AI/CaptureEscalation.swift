//
//  CaptureEscalation.swift
//  Project-Ezra
//
//  The deterministic verifier behind capture's device-first routing (2026-08-29):
//  given the instant local read of an unstructured capture, is there observable
//  EVIDENCE it fell short — evidence worth a cloud escalation to Gemini?
//
//  **This is not the deleted confidence gate, and the difference is load-bearing.**
//  The gate asked a model a META question before any work ("is this safe to handle
//  locally?") — an extra 2.3s call that escalated 95–100% of what it saw, slower than
//  the network it existed to avoid. This asks NO model anything: the deterministic
//  read has already produced its answer in ~2ms, and these checks read FACTS about
//  that answer — counts, resolutions, coverage — in microseconds. Judging an output
//  it can see is deterministic work; predicting the semantics of an input it can't
//  read was the gate's mistake (and `.singleThought`'s before it).
//
//  **The lexical signals point in the DISTRUST direction only, which is why they are
//  legal here.** `.singleThought` died because a lexicon deciding "this is probably
//  one task" KEPT a read on its own authority — a semantic judgment wearing an
//  observation's clothes, whose false positives lost user intent silently. These
//  signals can only ESCALATE: a false positive costs one cloud call; a false negative
//  is caught the way every capture mistake is caught, at the confirm card. The
//  asymmetry is safe by construction, the opposite of the deleted case.
//
//  Cost: pure string work over one capture. The routing check the product was worried
//  about being slow is this file, and it is effectively free.
//

import Foundation

/// Why an unstructured capture's local read wasn't good enough to reveal.
/// The raw value lands in `CaptureRunTelemetry.escalationReason` — the receipt's
/// answer to "why did this capture cost a cloud call?"
enum CaptureEscalationReason: String, Equatable, CaseIterable, Sendable {
    /// The deterministic read produced nothing at all — there is no interpretation
    /// to reveal, so a model must make one.
    case emptyRead
    /// A SPOKEN capture that reads like a conversation the microphone caught — many
    /// short first/second-person items, questions, almost no imperatives — which the
    /// deterministic arm turns into a dozen cards because sentence punctuation reads as
    /// explicit structure. Only the authority can say "there is nothing here", so the
    /// words go to it with permission to return NO tasks (F-02). Voice only: typed
    /// structure never transmits, whatever it looks like.
    case conversation
    /// The capture is past the depth floors (`CaptureRoute.depthCharacterFloor` /
    /// `depthItemFloor`) — the population device evidence says deterministic
    /// segmentation fails on, sent to the authority without paying for a local
    /// attempt first.
    case bigDump
    /// One draft came back from a capture whose surface shows several boundary
    /// signals (connectives, or multiple time expressions). One item out of a
    /// multi-signal dictation is the LEAST certain outcome a splitter can produce —
    /// the founding failure of this pipeline was exactly this case revealed as one
    /// task titled with its own transcript.
    case underSegmented
    /// The user spoke a detail the resolver could not land (today: a time phrase
    /// that failed `resolveDate`). The words carried intent the local read is
    /// provably not representing.
    case unresolvedDetail
    /// Too much of what the user said is absent from the drafts — content was
    /// dropped, not reorganized.
    case lowCoverage
}

enum CaptureEscalation {

    /// The one question, answered from facts: does this local read show evidence of
    /// failure? `nil` means the read is revealed as-is — no model, no transmission,
    /// no quota. Order is diagnostic precedence, not severity: the first reason is
    /// the one the receipt reports.
    static func reason(
        for text: String, drafts: [TaskDraft]
    ) -> CaptureEscalationReason? {
        guard !drafts.isEmpty else { return .emptyRead }
        let items = Segmentation.items(from: text).count
        if text.count >= CaptureRoute.depthCharacterFloor || items >= CaptureRoute.depthItemFloor {
            return .bigDump
        }
        // N drafts account for at most N boundary regions; signals past that are
        // UNACCOUNTED — spoken separators and occasions the read gave no draft to. The
        // first shape of this check fired only on exactly ONE draft, and the corpus
        // immediately produced its counterexample: case 50 (251 chars, nine outcomes,
        // two drafts) sailed through with seven outcomes silently folded away. Two
        // drafts hiding seven is the same failure as one draft hiding three.
        if connectiveSignals(in: text) + timeSignals(in: text) + interiorVerbSignals(in: text)
            >= drafts.count + boundarySignalFloor
        {
            return .underSegmented
        }
        if drafts.contains(where: { !$0.unresolved.isEmpty }) {
            return .unresolvedDetail
        }
        if let covered = coverage(of: text, by: drafts), covered < coverageFloor {
            return .lowCoverage
        }
        return nil
    }

    /// How many UNACCOUNTED boundary signals (signals beyond the draft count) make a
    /// read under-segmented. Two, not one: "buy bread and milk" is one task with one
    /// connective, and escalating every compound noun phrase would spend the quota
    /// the device-first policy exists to save.
    static let boundarySignalFloor = 2

    /// Below this share of the capture's content words appearing in the drafts, the
    /// read dropped content rather than reorganizing it. Tuned against the corpus via
    /// the `-RambleEval` policy report, not argued.
    static let coverageFloor = 0.5

    // MARK: - Signals (each pure, each an observation)

    /// Does this read like a caught conversation rather than a list of things to do?
    /// Deterministic and escalate-only, like every signal here: a false positive costs
    /// one call and the authority still returns the tasks it finds; a false negative is
    /// today's behaviour (a dozen cards). Pinned by `ConversationGuardTests`.
    static func conversationSignal(in text: String) -> Bool {
        let items = Segmentation.items(from: text).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard items.count >= conversationItemFloor else { return false }
        var conversational = 0
        var imperative = 0
        for item in items {
            let lowered = item.lowercased()
            let first = lowered.split { !$0.isLetter && $0 != "'" }.first.map(String.init) ?? ""
            if conversationalOpeners.contains(first) || lowered.hasSuffix("?") { conversational += 1 }
            if Segmentation.actionVerbs.contains(first) { imperative += 1 }
        }
        let total = Double(items.count)
        return Double(conversational) / total >= conversationalShare
            && Double(imperative) / total < imperativeCeiling
    }

    /// Fewer items than this is a short capture, not a conversation — let it reveal.
    static let conversationItemFloor = 4
    /// Share of items that open conversationally (or ask a question) before the whole
    /// reads as talk.
    static let conversationalShare = 0.5
    /// Above this share of imperative openers it is a list, however chatty.
    static let imperativeCeiling = 0.3

    /// How talk starts and to-do items don't: pronouns, fillers, agreement, questions.
    static let conversationalOpeners: Set<String> = [
        "i", "i'm", "i've", "i'd", "i'll", "you", "you're", "you've", "we", "we're", "we've",
        "he", "she", "they", "it's", "that's", "there's", "yeah", "yes", "yep", "no", "nope",
        "okay", "ok", "so", "um", "uh", "well", "like", "hmm", "right", "oh", "and", "but",
        "because", "anyway", "actually", "honestly", "what", "why", "how", "when", "where",
        "who", "did", "do", "does", "is", "are", "was", "were", "can", "could", "would", "should",
    ]

    /// Occurrences of the separators people speak between distinct outcomes —
    /// **one spoken boundary = one signal**, however it is spelled.
    ///
    /// The first shape of this summed six independent substring counts, which
    /// double-counted every compound spelling: ", and " scored on both ", " and
    /// " and ", and " and then " scored on both connectives — so
    /// `boundarySignalFloor` was calibrated against an inflated signal on English's
    /// most common compound connective. Found by the campaign quadrant (2026-08-29):
    /// "schedule the oil change and then call the vet" escalated as underSegmented
    /// with the local count already right — a measured unnecessary escalation whose
    /// whole cause was the inflation. The fix normalizes before counting: a
    /// comma/semicolon immediately followed by a connective word collapses into the
    /// connective, and a RUN of connective words collapses into one. Verified against
    /// the adversarial suite before and after (the A4 protocol): no other verdict
    /// moved, so `boundarySignalFloor = 2` stands on the corrected signal.
    static func connectiveSignals(in text: String) -> Int {
        // A trailing comma is dictation punctuation ("Clean my car tomorrow,"), not a
        // boundary — nothing follows it. Counted, it made the Private Capture
        // detector nag a one-line real capture (2026-09-02).
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        var lowered = " " + trimmed.lowercased() + " "
        // ", and " / "; then " … — punctuation + connective is ONE spoken boundary.
        lowered = lowered.replacingOccurrences(
            of: #"[,;]\s+(and|then|also|plus)\s"#, with: " $1 ",
            options: .regularExpression)
        // " and then " … — a run of connective words is ONE spoken boundary.
        lowered = lowered.replacingOccurrences(
            of: #"\s(and|then|also|plus)(\s+(and|then|also|plus))+\s"#, with: " $1 ",
            options: .regularExpression)
        let separators = [", ", " and ", " then ", " also ", " plus ", "; "]
        return separators.reduce(0) { count, separator in
            count + lowered.components(separatedBy: separator).count - 1
        }
    }

    /// Compiled once. Constructing `NSRegularExpression` per call is measurably
    /// wasteful even at capture volume, and the pattern is fixed — it is the ONE
    /// shared time vocabulary (`IntentResolver.timeExpressionPattern`), never a copy.
    private static let timeSignalRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: IntentResolver.timeExpressionPattern, options: [.caseInsensitive])

    /// Distinct time expressions in the capture. Several of them beyond the draft
    /// count is the run-on-dictation shape: occasions competing for boundaries no
    /// draft accounts for. The vocabulary deliberately shadows
    /// `IntentResolver.resolveDate`'s — bare weekdays included, because the resolver
    /// resolves them and `expand` fans them out ("walk my dog monday and tuesday" IS
    /// two occasions) — so the signal never claims time-ness the pipeline doesn't
    /// recognize, and never misses one it does.
    ///
    /// **A day word and the clock time beside it are ONE occasion.** "tomorrow at
    /// 3 PM" is a single deadline, not two boundary signals — counted as two it made
    /// the Private Capture detector nag on a single thought and `underSegmented`
    /// spend a cloud call on a one-line capture (both surfaced by the real-utterance
    /// corpus, 2026-09-02). The day alternatives absorb a trailing clock time; a clock
    /// time on its own still counts, because it is an occasion (today's).
    static func timeSignals(in text: String) -> Int {
        guard let regex = timeSignalRegex else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    /// Action verbs standing mid-sentence where nothing marked a boundary — the
    /// "…tomorrow go to the park cook a lunch…" shape: outcomes JUXTAPOSED, the one
    /// join the splitter is not allowed to cut (interior-verb splitting was deleted
    /// from `Segmentation` on 2026-08-22 as a semantic judgment, and stays deleted).
    /// Counting the same verbs HERE is legitimate because a signal can only
    /// escalate: it sends a read to the authority, never keeps one.
    ///
    /// Added 2026-09-02, when the time-expression boundary taught the splitter to cut
    /// case 50 from two drafts to five — still four short — and the connective and
    /// time signals no longer exceeded the draft count: the policy's founding case
    /// would have become its first false-keep, silently, with every floor green.
    ///
    /// Excluded, so a correctly split read scores near zero: the verb at the head of
    /// the text; one right after a time expression (the boundary the splitter already
    /// reads, replaced by a marker before counting); one after a subordinating word —
    /// determiners, modals, "to", connectives — where the "verb" is a noun ("the
    /// plan"), an infinitive ("need to book") or a connective-joined verb (already a
    /// connective signal); and one after a continuation adverb ("probably email",
    /// "never go"). The residual noise is compound nouns ("oil change", "action
    /// plan"), which is why this is one signal among three under a floor of two and
    /// not a boundary of its own.
    static func interiorVerbSignals(in text: String) -> Int {
        var lowered = text.lowercased()
        if let regex = timeSignalRegex {
            lowered = regex.stringByReplacingMatches(
                in: lowered, range: NSRange(lowered.startIndex..., in: lowered),
                withTemplate: " | ")
        }
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "|'"))
        let words = lowered.components(separatedBy: keep.inverted).filter { !$0.isEmpty }
        var count = 0
        for (index, word) in words.enumerated()
        where index > 0 && index + 1 < words.count && Segmentation.actionVerbs.contains(word) {
            let previous = words[index - 1]
            if previous == "|" || Segmentation.subordinatingWords.contains(previous)
                || continuationWords.contains(previous)
            {
                continue
            }
            // A verb that starts an outcome takes an object: "cook A lunch", "walk MY
            // dog", "review THE year". A lexicon "verb" followed by anything else is
            // most often a noun in a compound — "action plan this Sunday", "oil change
            // and…" — and counting those escalated a correctly-read three-item
            // capture on 2026-09-02 (the noun "plan" was the fifth signal).
            guard objectStarters.contains(words[index + 1]) else { continue }
            count += 1
        }
        return count
    }

    /// What the first word after an outcome-starting verb looks like: a determiner,
    /// a possessive, a pronoun, or the particle/preposition the verb takes.
    static let objectStarters: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "some", "any",
        "this", "that", "these", "those", "another", "every", "each", "all",
        "it", "them", "him", "me", "us", "everything", "something",
        "up", "out", "off", "down", "back", "over", "to", "for", "with", "about", "on", "in",
    ]

    /// Words after which an action verb continues the current outcome rather than
    /// starting a new one — adverbs and subjects, mostly ("i should probably email",
    /// "we never go there").
    static let continuationWords: Set<String> = [
        "probably", "maybe", "never", "just", "still", "really", "always", "quickly",
        "definitely", "actually", "finally", "eventually", "already", "please",
        "i", "we", "you", "they", "he", "she", "it", "who", "not", "don't", "dont",
    ]

    /// The share of the capture's content words that survived into the drafts, or nil
    /// when the capture is too short for the ratio to mean anything. Length ≥ 4 is a
    /// cheap stopword filter — the words that matter to coverage ("passport",
    /// "landlord", "registration") clear it; the glue ("the", "to", "my") doesn't.
    static func coverage(of text: String, by drafts: [TaskDraft]) -> Double? {
        let contentWords = words(in: text).filter { $0.count >= 4 }
        guard contentWords.count >= minimumCoverageWords else { return nil }
        let draftText = drafts.map(\.title).joined(separator: " ")
        let draftWords = Set(words(in: draftText))
        let covered = contentWords.filter(draftWords.contains).count
        return Double(covered) / Double(contentWords.count)
    }

    /// Under this many content words, a coverage ratio is noise (one dropped word
    /// swings it by a fifth or more), so the check abstains.
    static let minimumCoverageWords = 6

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
