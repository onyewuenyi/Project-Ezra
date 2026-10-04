//
//  CaptureJudge.swift
//  Project-Ezra
//
//  **The read makes the pieces; the model says what each piece is.** (2026-10-04)
//
//  Capture reads on the device only, and `-DumpEval` measured what that costs on a long
//  dump: the deterministic read holds every intended outcome in SOME card (recall 12/12)
//  and gets the card COUNT right on 4 of 12 — a greeting, a sign-off and "so I was
//  thinking" become cards, and "wash the uniform and refill the prescription" stays one.
//  The same run settled what the on-device model must not do: asked to CUT a dump it
//  over-cut or timed out (`OnDeviceSegmenter`, still off).
//
//  So the model gets the one job it has measured well at — read ONE short piece — and the
//  question is the one the read cannot answer: is this piece one task, several, or
//  nothing to do? For a task it also offers the piece as a short to-do, which the app
//  accepts only in the person's own words. `-CardJudgeEval`, per piece: no real task judged `none` in 165, every
//  fused piece caught, ~0.7 s a call.
//
//  **Every failure lands on the side of keeping the person's words.**
//  - A piece that plainly opens on an action never reaches the model (`screen`).
//  - `none` SETS ASIDE, never deletes: the piece rides to Confirm as a left-out line the
//    person can add back, and a piece that states a need is kept whatever the model said.
//  - `several` only licenses a re-split the app makes and validates itself (`resplit`):
//    every part must stand on its own, or the piece stays one card.
//  - A short REPORT ("The pediatrician called") folds into the next card as context — a
//    deterministic rule, not a verdict: asked as a fourth verdict ("background") the model
//    lost four real tasks out of 108 and folded "Monday Maya has swim at 4" away.
//  - A to-do title is accepted only if it starts with a verb, carries no date, keeps every
//    name, and uses no content word the person did not say (`validatedTodo`).
//  - No answer inside the budget is the same as `task`: the piece stays a card.
//
//  The model produces a verdict; deterministic code decides what the verdict may do. That
//  is rule 2 of the Ramble economics, and the asymmetry `CaptureEscalation` already
//  relies on: a signal that can only ask for a second look may read what an authoritative
//  one may not.
//

import Foundation
import FoundationModels

enum CaptureJudge {

    enum Verdict: String, CaseIterable, Sendable {
        case task, several, none
    }

    /// What the model said about one piece: the verdict, and for a task its offered
    /// to-do title (validated before use, never trusted).
    struct Answer: Equatable, Sendable {
        var verdict: Verdict
        var todo: String? = nil
    }

    // MARK: - The schemas

    @Generable
    struct PieceRead {
        @Guide(description: "Exactly one of: task, several, none.", .anyOf(["task", "several", "none"]))
        let kind: String
        @Guide(
            description:
                "For a task: the line as a short to-do of at most eight words that starts with a verb, in the person's own words, with no date or time. Otherwise empty."
        )
        let todo: String
    }

    @Generable
    struct SplitRead {
        @Guide(
            description:
                "Each separate to-do in the line, in order: at most eight words, starting with a verb, in the person's own words, with no date or time."
        )
        let todos: [String]
    }

    /// ~120 tokens. Changes here re-run `-CardJudgeEval` before they ship: the bracket is
    /// FALSE DROP 0 over the Ramble corpora's task clauses.
    nonisolated static let instructions = """
        You sort lines a person said or pasted into their to-do app. kind: task if the \
        line holds one thing they need to do, get, book, pay, send or remember. several \
        if it holds more than one separate thing to do. none if it is a greeting, a \
        sign-off, small talk or a remark with nothing to do. When unsure between task \
        and none, answer task. todo: for a task, the line as a short to-do that starts \
        with a verb they used, in their words, with no date or time.
        """

    nonisolated static let splitInstructions = """
        A line from someone's to-do app holds several separate things to do. List each \
        one as a short to-do that starts with a verb, in their words, with no date or time.
        """

    /// A wedge guard per call, not a budget: measured p95 was under a second.
    nonisolated static let callCapSeconds: Double = 4
    /// The whole pass. A piece without an answer by then stays a card.
    nonisolated static let passBudgetSeconds: Double = 6
    /// More doubtful pieces than this are not all judged; the rest stay cards.
    nonisolated static let maxCalls = 12

    // MARK: - The screen (pure)

    /// Does this piece need the model at all? A piece that opens on an action and shows
    /// no sign of a second outcome is a task on its face: judging it costs a call and can
    /// only make it worse.
    ///
    /// Nor does a piece of three words or fewer: "milk", "date night" and "dentist
    /// thursday" are how people write list items, a short noun phrase is the likeliest
    /// thing for a classifier to call `none`, and there is nothing in three words to split.
    static func needsJudgment(_ clause: String) -> Bool {
        let core = opening(of: clause)
        guard wordCount(core) > shortPieceWords else { return false }
        guard Segmentation.startsAnItem(core) else { return true }
        return showsASecondOutcome(core)
    }

    static let shortPieceWords = 3
    /// A one-piece capture this long, opening on no action, reads as a sentence someone
    /// said rather than a list item, and may be judged for `none`.
    static let singleSentenceWords = 8

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// The read's own boundary signals, asked of one piece.
    static func showsASecondOutcome(_ clause: String) -> Bool {
        CaptureEscalation.connectiveSignals(in: clause) > 0
            || CaptureEscalation.interiorVerbSignals(in: clause) > 0
    }

    /// A one-piece capture that is a long sentence with no action and no stated need —
    /// the chatter shape ("ha yeah no that was so funny…").
    static func isSingleSentenceChatter(_ clause: String) -> Bool {
        let core = opening(of: clause)
        return wordCount(core) >= singleSentenceWords && !Segmentation.startsAnItem(core)
            && !statesANeed(clause)
    }

    /// Which pieces of this capture go to the model. A one-piece capture is judged only
    /// when it shows a second outcome or reads as a sentence of chatter; a short single
    /// line ("the thing with the insurance") is kept as the person gave it.
    static func doubtfulIndices(in clauses: [String]) -> [Int] {
        if clauses.count == 1 {
            let core = opening(of: clauses[0])
            return showsASecondOutcome(core) || isSingleSentenceChatter(clauses[0]) ? [0] : []
        }
        return Array(clauses.indices.filter { needsJudgment(clauses[$0]) }.prefix(maxCalls))
    }

    /// The piece as its first real word starts it: lead-ins and a polite "please" gone.
    static func opening(of clause: String) -> String {
        var core = Segmentation.strippedLeadIn(clause.trimmingCharacters(in: .whitespacesAndNewlines))
        if core.lowercased().hasPrefix("please ") { core = String(core.dropFirst("please ".count)) }
        return core
    }

    private static let needMarkers = [
        "need to", "needs to", "have to", "has to", "got to", "gotta", "remember to", "don't forget",
        "dont forget", "please ", "must ", "is due", "are due", "remind ",
        // A need for a THING is a need too: "I need a card", "we're out of milk", "the car
        // needs an oil change".
        " i need ", " we need ", " needs ", " out of ",
    ]

    /// A piece that states a need is kept as a card whatever the model answered: the
    /// person said they have something to do, in so many words.
    static func statesANeed(_ clause: String) -> Bool {
        let lowered = " " + clause.lowercased() + " "
        return Segmentation.startsAnItem(opening(of: clause)) || needMarkers.contains { lowered.contains($0) }
    }

    // MARK: - The re-split (pure)

    private static let splitPattern = try? NSRegularExpression(
        pattern:
            #"\s*(?:[,;]\s*(?:and\s+|also\s+|plus\s+|then\s+|oh\s+and\s+)?|\s(?:and|also|plus|then)\s)\s*"#,
        options: [.caseInsensitive])

    private static let notAVerb: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "some", "any", "this", "that",
        "these", "those", "it", "they", "we", "he", "she", "you", "i", "there", "and", "but", "so", "or",
        "because", "if", "when", "after", "before", "for", "with", "about", "on", "in", "at", "to", "of",
    ]

    private static let determiners: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "some", "up", "out", "off", "back",
    ]

    private static let stateOpeners = ["we're out of", "we are out of", "i'm out of", "out of "]

    /// Could this part be a card by itself? An imperative the lexicon knows, an
    /// imperative it does not ("refill the prescription": an unknown word straight into
    /// an object), or a stated need ("the car needs an oil change", "we're out of milk").
    static func standsAlone(_ part: String) -> Bool {
        let core = opening(of: part)
        let words = core.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard words.count >= 2 else { return false }
        if Segmentation.startsAnItem(core) { return true }
        if !notAVerb.contains(words[0]), determiners.contains(words[1]),
            !CaptureEscalation.conversationalOpeners.contains(words[0])
        {
            return true
        }
        let lowered = " " + core.lowercased() + " "
        if stateOpeners.contains(where: { lowered.contains($0) }) { return true }
        return [" needs ", " need ", " is due", " are due"].contains { lowered.contains($0) }
    }

    /// Split a piece the model called `several`, or refuse. A part that cannot stand
    /// alone glues back onto the part before it ("milk" + "eggs"); if what is left is not
    /// at least two parts that EACH stand alone, the answer is nil and the piece stays
    /// one card. The model's word is the licence; this is the judgment.
    static func resplit(_ clause: String) -> [String]? {
        guard let regex = splitPattern else { return nil }
        let text = clause as NSString
        var raw: [(text: String, joiner: String)] = []
        var cursor = 0
        for match in regex.matches(in: clause, range: NSRange(location: 0, length: text.length)) {
            raw.append(
                (text.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), ""))
            raw[raw.count - 1].joiner = text.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        raw.append((text.substring(from: cursor), ""))

        var parts: [String] = []
        var pendingJoiner = ""
        for piece in raw {
            let trimmed = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                pendingJoiner = piece.joiner
                continue
            }
            if parts.isEmpty || standsAlone(trimmed) {
                parts.append(trimmed)
            } else {
                parts[parts.count - 1] += pendingJoiner + trimmed
            }
            pendingJoiner = piece.joiner
        }
        guard parts.count >= 2, parts.allSatisfy({ standsAlone($0) }) else { return nil }
        return parts
    }

    /// A short imperative whose only object is "it" belongs to the piece before it:
    /// "…so sign it" + "send it in" is one errand. Mirrors
    /// `IntentResolver.resolvingAnaphoricWaits`: a pronoun points back.
    static func foldingAnaphora(_ clauses: [String]) -> [String] {
        var folded: [String] = []
        for clause in clauses {
            let words = clause.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            let pointsBack =
                words.count <= 4 && (words.contains("it") || words.contains("them"))
                && !words.contains(where: { $0.count > 2 && !notAVerb.contains($0) && $0 != words.first })
            if pointsBack, !folded.isEmpty {
                folded[folded.count - 1] += " and " + clause
            } else {
                folded.append(clause)
            }
        }
        return folded
    }

    /// Does any word of this piece name an action the lexicon knows, or a need?
    static func mentionsAnAction(_ clause: String) -> Bool {
        statesANeed(clause) || words(clause).contains { Segmentation.actionVerbs.contains($0.lowercased()) }
    }

    // MARK: - Reports (pure)

    private static let reportPattern = try? NSRegularExpression(
        pattern:
            #"^(?:the |my |our |your |his |her |their |[a-z]+'s )?[a-z]+(?: [a-z]+)? (?:called|rang|phoned|texted|emailed|messaged|wrote|replied|mentioned|left a message)(?: back)?(?: me| us)?[.!]?$"#,
        options: [.caseInsensitive])

    /// A short report of something that happened to the person — "The pediatrician
    /// called", "Mom texted", "Noah's school emailed" — is the reason for the line after
    /// it, not a task. Five words at most, no stated need, a reporting verb at the end.
    static func isAReport(_ clause: String) -> Bool {
        let core = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(core) <= 5, !statesANeed(core), let reportPattern else { return false }
        return reportPattern.firstMatch(in: core, range: NSRange(core.startIndex..., in: core)) != nil
    }

    // MARK: - The to-do title (pure)

    private static let acquisitionVerbs: Set<String> = ["get", "buy"]

    private static let needForAThing = try? NSRegularExpression(
        pattern: #"\b(?:need|needs)\s+(?:a|an|some|new|more|another)\b|\bout of\b|\brunning low on\b"#,
        options: [.caseInsensitive])

    /// "I need a card and a gift", "we're out of milk", "the car needs an oil change".
    static func statesANeedForAThing(_ text: String) -> Bool {
        guard let needForAThing else { return false }
        return needForAThing.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let vagueWords: Set<String> = [
        "something", "anything", "everything", "stuff", "things", "thing", "it", "that", "this", "more",
    ]

    private static let titleGlue: Set<String> = [
        "the", "a", "an", "for", "to", "of", "and", "on", "in", "at", "with", "about", "my", "our",
        "your", "his", "her", "their", "from", "up", "back", "out", "off", "by", "it", "them", "this",
        "that", "some", "any", "all", "new", "or",
    ]

    private static func normalized(_ word: String) -> String {
        var w = word.lowercased()
        for suffix in ["'s", "’s", "s"] where w.count > 3 && w.hasSuffix(suffix) {
            w = String(w.dropLast(suffix.count))
            break
        }
        return w
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }).map(
            String.init)
    }

    /// The model's to-do title, or nil. Accepted only when it is a short verb-led line in
    /// the person's own words: every content word appears in what they said (so nothing
    /// is invented), it carries no date (the chip holds it), and every name in the
    /// current title survives. A title already verb-led is never replaced.
    static func validatedTodo(_ todo: String, source: String, currentTitle: String) -> String? {
        // A title that already starts with a verb is the person's to-do; it is replaced only
        // when it runs on past ten words with the talk that followed it.
        guard !Segmentation.startsAnItem(currentTitle) || currentTitle.isEmpty || wordCount(currentTitle) > 10
        else { return nil }
        var title = todo.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!,;:"))
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let titleWords = words(title)
        guard (2...9).contains(titleWords.count) else { return nil }
        guard CaptureEscalation.timeSignals(in: title) == 0 else { return nil }
        let spoken = Set(words(source).map { normalized($0) })
        let first = titleWords[0].lowercased()
        // The verb is theirs — said as is, or as its -ing / -ed form ("cleaning" → Clean).
        // A verb they never used is a guess about what the line means: "Book dentist for
        // Noah" for an appointment already made.
        let said = Set(words(source).map { $0.lowercased() })
        let verbIsTheirs =
            said.contains(first)
            || spoken.contains { $0.count >= first.count + 2 && $0.hasPrefix(first) }
            // A need for a THING has an honest to-do they did not say in so many words:
            // "I need a card" is "Get a card", "we're out of milk" is "Buy milk".
            || (acquisitionVerbs.contains(first) && statesANeedForAThing(source))
        guard first.count >= 2, verbIsTheirs else { return nil }
        // When they gave an instruction, that is the to-do: "We are collecting canned food,
        // bring two cans" is "Bring two cans", never "Collect canned food". A verb they
        // said word for word is always theirs.
        let instructions = imperativeVerbs(in: source)
        guard
            instructions.isEmpty || instructions.contains(first) || said.contains(first)
                || acquisitionVerbs.contains(first)
        else { return nil }
        let content = titleWords.dropFirst().filter { !titleGlue.contains($0.lowercased()) }
        for word in content {
            guard spoken.contains(normalized(word)) else { return nil }
        }
        // "Do something" is in their words and says nothing.
        guard content.contains(where: { !vagueWords.contains($0.lowercased()) }) else { return nil }
        let titleSet = Set(titleWords.map { normalized($0) })
        for name in words(currentTitle).dropFirst() where name.first?.isUppercase == true {
            guard name.count > 1, CaptureEscalation.timeSignals(in: name) == 0 else { continue }
            guard titleSet.contains(normalized(name)) else { return nil }
        }
        guard title.lowercased() != currentTitle.lowercased() else { return nil }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    private static let instructionLeads: Set<String> = [
        "please", "so", "and", "then", "also", "plus", "just",
    ]

    /// The verbs the person used as instructions: an action verb opening a sentence or a
    /// comma-part, or right after "and" / "then" / "also" / "please" — "wash the uniform
    /// and fold the towels" gives both.
    static func imperativeVerbs(in source: String) -> Set<String> {
        var verbs: Set<String> = []
        for part in source.lowercased().split(whereSeparator: { ",.;!?".contains($0) }) {
            let partWords = words(String(part)).map { $0.lowercased() }
            for (index, word) in partWords.enumerated() where index + 1 < partWords.count {
                guard Segmentation.actionVerbs.contains(word) else { continue }
                let opens = partWords[..<index].allSatisfy { instructionLeads.contains($0) }
                if opens || instructionLeads.contains(partWords[index - 1]) { verbs.insert(word) }
            }
        }
        return verbs
    }

    // MARK: - The reading

    /// One card-to-be: the clause the read made, plus what the judge added to it.
    struct Piece: Equatable, Sendable {
        var clause: String
        /// Background lines that came before it, joined.
        var context: String? = nil
        /// The model's to-do title for it, not yet validated against the draft.
        var todo: String? = nil
        /// Judged several, and the app could not split it safely.
        var mightBeSeveral = false
    }

    struct Reading: Equatable, Sendable {
        var pieces: [Piece]
        /// Pieces judged `none`: carried to Confirm, never dropped.
        var leftOut: [String]
        var judged = 0
        var answered = 0
        var resplit = 0
        var folded = 0

        /// The pieces that become cards, in the order they were said.
        var clauses: [String] { pieces.map(\.clause) }
    }

    /// Apply answers to pieces. Pure: the model's answers come in as a dictionary, so
    /// every rule above is a test rather than a claim. A missing answer keeps the piece.
    static func apply(_ answers: [Int: Answer], to clauses: [String]) -> Reading {
        var kept: [Piece] = []
        var leftOut: [String] = []
        var splits = 0
        var folded = 0
        var pendingContext: [String] = []
        let single = clauses.count == 1
        func keep(_ piece: Piece) {
            var piece = piece
            if !pendingContext.isEmpty {
                piece.context = pendingContext.joined(separator: " · ")
                pendingContext = []
            }
            kept.append(piece)
        }
        for (index, clause) in clauses.enumerated() {
            let answer = answers[index]
            switch answer?.verdict {
            case _ where index < clauses.count - 1 && isAReport(clause):
                pendingContext.append(clause.trimmingCharacters(in: .whitespacesAndNewlines))
                folded += 1
            case .some(.none) where !statesANeed(clause) && (!single || isSingleSentenceChatter(clause)):
                leftOut.append(clause)
            case .some(.several):
                if let parts = resplit(clause) {
                    parts.forEach { keep(Piece(clause: $0)) }
                    splits += 1
                } else {
                    // A Split is offered only where there is something to split: a piece
                    // with no action in it ("Hi families, a few reminders") holds no to-dos.
                    // And only where the read sees a second outcome too: on the phone (24A437)
                    // the model called one task in five "several" ("drop the kids at school
                    // early because of the assembly"), and a Split on a single errand is noise.
                    keep(
                        Piece(
                            clause: clause,
                            mightBeSeveral: mentionsAnAction(clause)
                                && showsASecondOutcome(opening(of: clause))))
                }
            default:
                let todo = answer?.todo.flatMap { $0.isEmpty ? nil : $0 }
                keep(Piece(clause: clause, todo: todo))
            }
        }
        // A report with nothing after it to explain stays the person's card.
        for orphan in pendingContext { kept.append(Piece(clause: orphan)) }
        folded -= pendingContext.count
        return Reading(
            pieces: foldingAnaphora(kept), leftOut: leftOut, judged: 0, answered: answers.count,
            resplit: splits, folded: folded)
    }

    /// `foldingAnaphora` over pieces: a merged piece keeps the first one's context and
    /// loses its to-do, which no longer describes the merged words.
    static func foldingAnaphora(_ pieces: [Piece]) -> [Piece] {
        let merged = foldingAnaphora(pieces.map(\.clause))
        guard merged.count != pieces.count else { return pieces }
        var out: [Piece] = []
        var cursor = 0
        for clause in merged {
            var piece = pieces[cursor]
            piece.clause = clause
            var consumed = pieces[cursor].clause
            cursor += 1
            while consumed != clause, cursor < pieces.count {
                consumed += " and " + pieces[cursor].clause
                cursor += 1
                piece.todo = nil
            }
            out.append(piece)
        }
        return out
    }

    /// Answers arriving from concurrent calls, kept as they land so a pass that runs out of
    /// budget still applies every answer it got.
    private actor AnswerBox {
        var answers: [Int: Answer] = [:]
        func set(_ index: Int, _ answer: Answer) { answers[index] = answer }
    }

    /// Screen → judge the doubtful pieces together → apply. `judge` is injected so the
    /// whole pass runs under test with no model.
    static func read(
        clauses: [String], budget: Double = passBudgetSeconds,
        judge: @escaping @Sendable (String) async -> Answer?
    ) async -> Reading {
        let doubtful = doubtfulIndices(in: clauses).map { ($0, clauses[$0]) }
        guard !doubtful.isEmpty else { return apply([:], to: clauses) }
        let box = AnswerBox()
        _ = try? await ModelDeadline.race(timeout: budget) {
            await withTaskGroup(of: (Int, Answer?).self) { group in
                for (index, clause) in doubtful {
                    group.addTask { (index, await judge(clause)) }
                }
                for await (index, answer) in group {
                    if let answer { await box.set(index, answer) }
                }
            }
        }
        var reading = apply(await box.answers, to: clauses)
        reading.judged = doubtful.count
        return reading
    }

    /// The reading as cards: the same resolver every capture uses, then the judge's
    /// additions mapped onto each draft by the clause it came from. The to-do title is
    /// validated against THAT clause and the draft's own title; a refused one changes
    /// nothing.
    static func drafts(
        from reading: Reading, learned: [LearnedRule] = [], ownership: OwnershipContext = .none,
        now: Date = Date()
    ) -> (drafts: [TaskDraft], retitled: Int) {
        var drafts = AppBrain.drafts(
            fromClauses: reading.clauses, learned: learned, ownership: ownership, now: now)
        var retitled = 0
        for index in drafts.indices {
            guard let piece = reading.pieces.first(where: { $0.clause == drafts[index].provisionalSource })
            else { continue }
            if let context = piece.context { drafts[index].context = context }
            if piece.mightBeSeveral { drafts[index].mightBeSeveral = true }
            if let todo = piece.todo,
                let title = validatedTodo(todo, source: piece.clause, currentTitle: drafts[index].title)
            {
                drafts[index].title = title
                drafts[index].aiOriginal?.title = title
                retitled += 1
            }
        }
        return (drafts, retitled)
    }

    // MARK: - One capture, end to end

    struct CaptureReading {
        var drafts: [TaskDraft]
        var leftOut: [String]
        /// For the receipt: which arm read it, and what the judge did.
        var engineName: String
    }

    /// The whole on-device read of one capture, for a caller with no composer around it
    /// (onboarding). The read makes the pieces; with a model present and a doubtful
    /// piece, the judge runs and its additions are mapped onto the cards; otherwise the
    /// deterministic read stands. Nothing here transmits.
    static func readCapture(
        _ text: String, learned: [LearnedRule] = [], ownership given: OwnershipContext? = nil,
        modelAvailable: Bool
    ) async -> CaptureReading {
        let ownership = given ?? .none
        let clauses = Segmentation.items(from: text)
        guard modelAvailable, !doubtfulIndices(in: clauses).isEmpty else {
            return CaptureReading(
                drafts: AppBrain.drafts(fromClauses: clauses, learned: learned, ownership: ownership),
                leftOut: [], engineName: "deterministic")
        }
        let reading = await read(clauses: clauses) { await modelAnswer($0) }
        let (drafts, retitled) = drafts(from: reading, learned: learned, ownership: ownership)
        return CaptureReading(
            drafts: drafts, leftOut: reading.leftOut,
            engineName:
                "on-device(judge \(reading.answered)/\(reading.judged) · split \(reading.resplit) · out \(reading.leftOut.count) · bg \(reading.folded) · titled \(retitled))"
        )
    }

    // MARK: - The model calls

    /// Sessions built and prewarmed before they are needed (2026-10-04). Each judge call
    /// is a fresh session — a judgment must not see the last one — so each paid for
    /// loading the model and its instructions on the critical path. The composer fills
    /// this when the sheet opens; a call takes a warm session, or builds a cold one.
    @MainActor
    final class SessionPool {
        static let shared = SessionPool()
        static let size = 4
        private var spare: [LanguageModelSession] = []
        private(set) var hits = 0
        private(set) var misses = 0

        func prewarm() {
            guard AppBrain.onDeviceModelAvailable() else { return }
            while spare.count < Self.size {
                let session = LanguageModelSession(instructions: CaptureJudge.instructions)
                session.prewarm(promptPrefix: Prompt("Line: "))
                spare.append(session)
            }
        }

        func take() -> LanguageModelSession {
            guard !spare.isEmpty else {
                misses += 1
                return LanguageModelSession(instructions: CaptureJudge.instructions)
            }
            hits += 1
            return spare.removeFirst()
        }

        func drain() { spare.removeAll() }
    }

    /// One call to the on-device model. Nil on a refusal, a timeout or an answer outside
    /// the four words: all of them keep the piece.
    nonisolated static func modelAnswer(_ clause: String) async -> Answer? {
        let started = Date()
        do {
            let session = await SessionPool.shared.take()
            let answer = try await ModelDeadline.race(timeout: callCapSeconds) { () -> Answer? in
                let read = try await session.respond(to: "Line: \(clause)", generating: PieceRead.self)
                    .content
                return Verdict(rawValue: read.kind.lowercased()).map { Answer(verdict: $0, todo: read.todo) }
            }
            await ModelMetrics.shared.record(
                .captureJudge, answer == nil ? .failed("off-vocabulary") : .success,
                latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return answer
        } catch is ModelDeadline.Exceeded {
            await ModelMetrics.shared.record(
                .captureJudge, .timedOut, latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return nil
        } catch {
            await ModelMetrics.shared.record(
                .captureJudge, .failed(AppBrain.errorLabel(error)),
                latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            return nil
        }
    }

    /// The person tapped Split on a card the app could not split safely. The model names
    /// the parts; each must pass `validatedTodo` against the card's own words and there
    /// must be at least two, or the answer is nil and the card stays as it is.
    nonisolated static func modelSplit(_ text: String) async -> [String]? {
        guard let todos = await modelSplitRaw(text) else { return nil }
        return await validatedSplit(todos, source: text)
    }

    /// The model's parts before validation — for the eval's printout.
    nonisolated static func modelSplitRaw(_ text: String) async -> [String]? {
        try? await ModelDeadline.race(timeout: callCapSeconds + 2) {
            let session = LanguageModelSession(instructions: splitInstructions)
            return try await session.respond(to: "Line: \(text)", generating: SplitRead.self).content.todos
        }
    }

    static func validatedSplit(_ todos: [String], source: String) -> [String]? {
        let parts = todos.compactMap { validatedTodo($0, source: source, currentTitle: "") }
        guard parts.count >= 2, parts.count == todos.count, parts.count <= 6 else { return nil }
        return parts
    }
}
