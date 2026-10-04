//
//  CardJudgeEval.swift
//  Project-Ezra
//
//  `-CardJudgeEval` — the experiment behind the on-device capture redesign (2026-10-04).
//
//  `-DumpEval` settled what the on-device model must NOT do: cut a dump. Asked for
//  boundaries over a long capture it over-cut or timed out, and the deterministic read
//  already holds every intended outcome in SOME card (recall 12/12). What the read cannot
//  do is tell what each card IS — a greeting, a sign-off and "so I was thinking" become
//  cards, and "wash the uniform and refill the prescription" stays one.
//
//  So this asks the model the question it has measured well at — read ONE short piece —
//  about each clause the deterministic read already made: is it one task, several, or
//  nothing to do? Two shapes are measured side by side: one call per clause, and one call
//  for the whole numbered list.
//
//  **The critical error is a FALSE DROP** — a clause that holds a task, judged `none`.
//  A junk card costs the person one tap at Confirm; a dropped task is their intent lost.
//  The bracket is the Ramble corpora: every clause of a case whose clause count equals its
//  intent count is a task by the corpus's own labels, so any `none` there is a false drop.
//
//  The dump labels are derived, not authored again: a clause holding one of the dump's
//  expected keywords is a task, two or more is several, none is nothing.
//

#if DEBUG

import Foundation
import FoundationModels

enum CardJudgeEval {

    enum Kind: String, CaseIterable, Sendable {
        case task, several, none
    }

    // MARK: - The schemas

    @Generable
    struct OneRead {
        @Guide(description: "Exactly one of: task, several, none.", .anyOf(["task", "several", "none"]))
        let kind: String
    }

    @Generable
    struct ListRead {
        @Guide(
            description:
                "One entry per numbered line, in the same order. Each entry is exactly one of: task, several, none."
        )
        let kinds: [String]
    }

    static let instructions = """
        You sort lines a person said or pasted into their to-do app. For a line, answer \
        with one word. task: it holds one thing they need to do, get, book, pay, send or \
        remember. several: it holds more than one separate thing to do. none: it is a \
        greeting, a sign-off, small talk or a remark with nothing to do. When unsure \
        between task and none, answer task.
        """

    static let capSeconds: Double = 6

    // MARK: - Labels (pure)

    /// The dump's own keywords decide: how many expected outcomes this clause holds.
    static func label(clause: String, expected: [String]) -> Kind {
        let lowered = clause.lowercased()
        switch expected.filter({ lowered.contains($0) }).count {
        case 0: return .none
        case 1: return .task
        default: return .several
        }
    }

    struct Item {
        let source: String
        let clause: String
        let label: Kind
    }

    @MainActor
    static func dumpItems() -> [(name: String, items: [Item])] {
        DumpEval.corpus.map { dump in
            (
                dump.name,
                Segmentation.items(from: dump.text).map {
                    Item(source: dump.name, clause: $0, label: label(clause: $0, expected: dump.expected))
                }
            )
        }
    }

    /// The false-drop bracket: clauses the Ramble corpora's own labels say are tasks.
    @MainActor
    static func bracketItems() -> [Item] {
        (RambleEval.evalSet + RambleEval.realSet).flatMap { evalCase -> [Item] in
            let clauses = Segmentation.items(from: evalCase.utterance)
            let intents = evalCase.expectedIntents ?? evalCase.expected.count
            guard intents > 0, clauses.count == intents else { return [] }
            return clauses.map { Item(source: "ramble", clause: $0, label: .task) }
        }
    }

    // MARK: - The two arms

    static func judgeOne(_ clause: String) async -> (Kind?, Int) {
        let started = Date()
        let instructions = instructions
        let kind: Kind? = try? await ModelDeadline.race(timeout: capSeconds) {
            let session = LanguageModelSession(instructions: instructions)
            let read = try await session.respond(to: "Line: \(clause)", generating: OneRead.self).content
            return Kind(rawValue: read.kind.lowercased())
        }
        return (kind, Int(Date().timeIntervalSince(started) * 1000))
    }

    static func judgeList(_ clauses: [String]) async -> ([Kind]?, Int) {
        let started = Date()
        let numbered = clauses.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let count = clauses.count
        let instructions = instructions
        let kinds: [Kind]? = try? await ModelDeadline.race(timeout: capSeconds + Double(count)) {
            let session = LanguageModelSession(instructions: instructions)
            let read = try await session.respond(
                to: "There are \(count) lines. Answer for each.\n\n\(numbered)", generating: ListRead.self
            ).content
            let parsed = read.kinds.compactMap { Kind(rawValue: $0.lowercased()) }
            return parsed.count == count ? parsed : nil
        }
        return (kinds, Int(Date().timeIntervalSince(started) * 1000))
    }

    // MARK: - Scoring

    struct Score {
        var total = 0
        var answered = 0
        var right = 0
        /// label task/several → judged none. The critical error.
        var falseDrops: [String] = []
        /// label none → judged none. The junk the arm would remove.
        var junkCaught = 0
        var junkTotal = 0
        var severalCaught = 0
        var severalTotal = 0
        /// label task → judged several. Costs a second look, loses nothing.
        var falseSeveral = 0

        mutating func add(_ item: Item, judged: Kind?) {
            total += 1
            if item.label == .none { junkTotal += 1 }
            if item.label == .several { severalTotal += 1 }
            guard let judged else { return }
            answered += 1
            if judged == item.label { right += 1 }
            if judged == .none && item.label != .none { falseDrops.append(item.clause) }
            if judged == .none && item.label == .none { junkCaught += 1 }
            if judged == .several && item.label == .several { severalCaught += 1 }
            if judged == .several && item.label == .task { falseSeveral += 1 }
        }

        var line: String {
            "answered \(answered)/\(total) · right \(right) · FALSE DROP \(falseDrops.count) · "
                + "junk caught \(junkCaught)/\(junkTotal) · several caught \(severalCaught)/\(severalTotal) · "
                + "false several \(falseSeveral)"
        }
    }

    // MARK: - The run

    @MainActor
    static func runIfRequested(brain: AppBrain) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-CardJudgeEval") else { return }
        if args.contains("-EvalToFile") { Instrument.teeStdoutToDocuments("cardjudge-report.txt") }
        let markers = Instrument.Markers(name: "CARD JUDGE EVAL")
        print(markers.begin)
        print(Instrument.runStamp(model: brain.status.description, configuration: instructions))
        guard brain.status.isOnDevice else {
            print("(no on-device model on this host — nothing measured)")
            print(markers.end)
            return
        }

        var perClause = Score()
        var batched = Score()
        var oneLatencies: [Int] = []
        var listLatencies: [Int] = []
        var serialTotals: [Int] = []

        print("\n── dumps ──")
        for (name, items) in dumpItems() {
            var serial = 0
            var oneKinds: [Kind?] = []
            for item in items {
                let (kind, ms) = await judgeOne(item.clause)
                perClause.add(item, judged: kind)
                oneKinds.append(kind)
                oneLatencies.append(ms)
                serial += ms
            }
            serialTotals.append(serial)
            let (kinds, listMs) = await judgeList(items.map(\.clause))
            listLatencies.append(listMs)
            for (index, item) in items.enumerated() { batched.add(item, judged: kinds?[index]) }
            print(
                "\(name) · \(items.count) clauses · per-clause \(serial)ms · list \(listMs)ms\(kinds == nil ? " (NO ANSWER)" : "")"
            )
            for (index, item) in items.enumerated() {
                let one = oneKinds[index]?.rawValue ?? "-"
                let list = kinds?[index].rawValue ?? "-"
                let flag = (one != item.label.rawValue || list != item.label.rawValue) ? "  <<" : ""
                print(
                    "    [\(item.label.rawValue) | one:\(one) list:\(list)] \(item.clause.prefix(80))\(flag)")
            }
        }

        print("\n── bracket: Ramble corpus clauses, every one a task ──")
        var bracketOne = Score()
        let bracket = bracketItems()
        for item in bracket {
            let (kind, ms) = await judgeOne(item.clause)
            bracketOne.add(item, judged: kind)
            oneLatencies.append(ms)
        }
        for drop in bracketOne.falseDrops { print("    FALSE DROP: \(drop.prefix(90))") }

        let sortedOne = oneLatencies.sorted()
        let sortedList = listLatencies.sorted()
        print("\n── summary ──")
        print("dumps · per clause: \(perClause.line)")
        print("dumps · one list call: \(batched.line)")
        print("bracket · per clause (\(bracket.count) task clauses): \(bracketOne.line)")
        for drop in perClause.falseDrops { print("    dump FALSE DROP (per clause): \(drop.prefix(90))") }
        for drop in batched.falseDrops { print("    dump FALSE DROP (list): \(drop.prefix(90))") }
        if !sortedOne.isEmpty {
            print(
                "latency · per clause p50 \(sortedOne[sortedOne.count / 2])ms · p95 \(sortedOne[min(sortedOne.count - 1, sortedOne.count * 95 / 100)])ms"
            )
        }
        if !sortedList.isEmpty, !serialTotals.isEmpty {
            print(
                "latency · whole dump: per-clause serial p50 \(serialTotals.sorted()[serialTotals.count / 2])ms · list call p50 \(sortedList[sortedList.count / 2])ms · max \(sortedList.last ?? 0)ms"
            )
        }
        print(markers.end)
    }
}

#endif
