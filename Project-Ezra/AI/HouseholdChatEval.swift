//
//  HouseholdChatEval.swift
//  Project-Ezra
//
//  The Ask tab's eval — one labeled household, three questions asked of it:
//
//  1. **Does the floor take the right questions, and answer them exactly?** Every
//     closed case names the shape the floor must take and the titles it must cite;
//     every open case names a question the floor must DECLINE. Pure, so
//     `HouseholdChatTests` runs it in CI — a floor that silently widens (taking "why
//     is it overdue?" as a list) or narrows (missing "what's late?") fails a test, not
//     a person.
//  2. **Does retrieval hand the model the tasks the question is about?** Each open
//     case names the titles that must be in the slice. Also pure, also CI.
//  3. **Does the on-device model answer, and stay inside the facts?** Device-only:
//     served ratio (an arm under 90% served prints DEGRADED — the RambleEval rule),
//     latency p50/p90, and a GROUNDING check per reply — numbers and capitalized
//     words in the answer that appear nowhere in what the model was shown. The check
//     is BRACKETED before it runs (a known-clean reply must score 0 flags, a
//     known-invented one must be caught), because a scorer that cannot fail proves
//     nothing (the 2026-08-22 lesson: five instrument bugs to two pipeline bugs).
//
//  Non-destructive: the fixture is values, never the store. `-HouseholdChatEval`,
//  with `-EvalToFile` teeing to Documents/householdchat-report.txt; the completion
//  marker is `=== END HOUSEHOLD CHAT EVAL ===`.
//

import Foundation

#if DEBUG
enum HouseholdChatEval {

    // MARK: - The fixture household (values only)

    static let you = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let maya = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let sam = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    /// A household on a fixed `now`, so days-until are stable and the report is
    /// comparable run to run.
    static func fixture(now: Date = Date(timeIntervalSince1970: 1_788_000_000)) -> HouseholdChatFacts {
        let day: TimeInterval = 86_400
        func line(
            _ title: String, owner: UUID?, due: Int? = nil, urgent: Bool = false,
            decision: Bool = false, blockers: [String] = [], waits: [String] = [],
            status: TaskStatus = .todo, category: String = "Home", effort: Int? = nil,
            touchedDaysAgo: Double = 1
        ) -> HouseholdChatFacts.Line {
            let ownerName: String? = owner.map { $0 == you ? "You" : $0 == maya ? "Maya" : "Sam" }
            return HouseholdChatFacts.Line(
                id: UUID(), title: title, category: category, status: status, ownerName: ownerName,
                ownerID: owner, dueDate: due.map { now.addingTimeInterval(Double($0) * day) },
                daysUntilDue: due, isUrgent: urgent, needsDecision: decision,
                blockerTitles: blockers, externalWaits: waits, effortMinutes: effort,
                updatedAt: now.addingTimeInterval(-touchedDaysAgo * day))
        }
        let open: [HouseholdChatFacts.Line] = [
            line("Return the Amazon package", owner: you, due: -5, category: "Errands"),
            line("Renew the car insurance", owner: you, due: -2, category: "Car", effort: 30),
            line("Submit the expense report", owner: you, due: 0, urgent: true, category: "Work"),
            line("Call the pharmacy about the refill", owner: maya, due: 0, category: "Health"),
            line(
                "Book the flights for the trip", owner: you, due: 12, blockers: ["Renew the passport"],
                category: "Travel"),
            line(
                "Renew the passport", owner: you, due: 9, blockers: ["Get passport photos"],
                category: "Travel", effort: 60),
            line("Get passport photos", owner: maya, due: 3, category: "Travel", effort: 15),
            line(
                "Decide whether to keep the gym membership", owner: you, decision: true, category: "Finance"),
            line("Sort out the invoice discrepancy", owner: sam, due: 4, category: "Work", effort: 60),
            line(
                "Fix the garden gate", owner: sam, waits: ["the hinge delivery"], category: "Home",
                effort: 120),
            line("Plan Maya's birthday dinner", owner: sam, due: 6, category: "Family", effort: 60),
            line("Pay the water bill", owner: you, due: 2, category: "Finance", effort: 15),
            line("Pick a summer camp", owner: maya, due: 14, decision: true, category: "Family"),
            line("Clear out the garage", owner: nil, category: "Home", effort: 120, touchedDaysAgo: 20),
        ]
        let done: [HouseholdChatFacts.Done] = [
            .init(
                id: UUID(), title: "Book the dentist", ownerName: "You",
                completedAt: now.addingTimeInterval(-1 * day)),
            .init(
                id: UUID(), title: "Order the school shoes", ownerName: "Maya",
                completedAt: now.addingTimeInterval(-2 * day)),
            .init(
                id: UUID(), title: "Renew the parking permit", ownerName: "Sam",
                completedAt: now.addingTimeInterval(-4 * day)),
        ]
        return HouseholdChatFacts(
            now: now,
            members: [
                .init(id: you, name: "You", isYou: true),
                .init(id: maya, name: "Maya", isYou: false),
                .init(id: sam, name: "Sam", isYou: false),
            ],
            open: open, done: done)
    }

    // MARK: - The labeled questions

    enum Expectation: Equatable {
        /// The floor must take it, with exactly these cited titles (order-free).
        case floor(HouseholdChatFloor.Shape, cites: Set<String>)
        /// The floor must decline; retrieval must hand the model these titles.
        case model(sliceMustContain: Set<String>)
    }

    struct Case {
        let question: String
        let expect: Expectation
    }

    static let cases: [Case] = [
        // Closed — the floor's own population.
        Case(
            question: "What's overdue?",
            expect: .floor(.overdue, cites: ["Return the Amazon package", "Renew the car insurance"])),
        Case(
            question: "what's late",
            expect: .floor(.overdue, cites: ["Return the Amazon package", "Renew the car insurance"])),
        Case(
            question: "What's due today?",
            expect: .floor(
                .dueToday, cites: ["Submit the expense report", "Call the pharmacy about the refill"])),
        Case(
            question: "What is Maya working on?",
            expect: .floor(
                .personOpen,
                cites: ["Call the pharmacy about the refill", "Get passport photos", "Pick a summer camp"])),
        Case(
            question: "what's on my plate",
            expect: .floor(
                .personOpen,
                cites: [
                    "Return the Amazon package", "Renew the car insurance", "Submit the expense report",
                    "Book the flights for the trip", "Renew the passport",
                    "Decide whether to keep the gym membership", "Pay the water bill",
                ])),
        Case(
            question: "What's waiting on something?",
            expect: .floor(
                .blocked,
                cites: ["Book the flights for the trip", "Renew the passport", "Fix the garden gate"])),
        Case(question: "Anything urgent?", expect: .floor(.urgent, cites: ["Submit the expense report"])),
        Case(
            question: "What needs a decision?",
            expect: .floor(
                .decisions, cites: ["Decide whether to keep the gym membership", "Pick a summer camp"])),
        Case(question: "Who has the most on their plate?", expect: .floor(.whoMost, cites: [])),
        Case(question: "How many tasks are open?", expect: .floor(.countOpen, cites: [])),
        Case(
            question: "What did we get done this week?",
            expect: .floor(
                .done, cites: ["Book the dentist", "Order the school shoes", "Renew the parking permit"])),
        Case(
            question: "What's coming up this week?",
            expect: .floor(
                .dueThisWeek,
                cites: [
                    "Submit the expense report", "Call the pharmacy about the refill", "Get passport photos",
                    "Sort out the invoice discrepancy", "Plan Maya's birthday dinner", "Pay the water bill",
                ])),
        Case(question: "What's overdue for Sam?", expect: .floor(.overdue, cites: [])),
        Case(question: "Is anything unowned?", expect: .floor(.unowned, cites: ["Clear out the garage"])),
        // Open — reasoning words send these to the model, with the right slice.
        Case(
            question: "Why is the passport stuck?",
            expect: .model(sliceMustContain: ["Renew the passport", "Get passport photos"])),
        Case(
            question: "What should Maya do first?",
            expect: .model(sliceMustContain: [
                "Call the pharmacy about the refill", "Get passport photos", "Pick a summer camp",
            ])),
        Case(
            question: "Why is the Amazon return overdue and what would settle it?",
            expect: .model(sliceMustContain: ["Return the Amazon package"])),
        Case(
            question: "How do passport renewals usually work?",
            expect: .model(sliceMustContain: ["Renew the passport"])),
        Case(
            question: "Should we cancel the gym membership?",
            expect: .model(sliceMustContain: ["Decide whether to keep the gym membership"])),
        Case(
            question: "What could Sam hand off to me this week?",
            expect: .model(sliceMustContain: [
                "Sort out the invoice discrepancy", "Plan Maya's birthday dinner",
            ])),
    ]

    // MARK: - The pure checks (CI)

    /// Every floor and retrieval miss, as one line each. Empty = the labeled set holds.
    static func failures(facts: HouseholdChatFacts = fixture()) -> [String] {
        var out: [String] = []
        let titles: (Set<UUID>) -> Set<String> = { ids in
            Set(
                facts.open.filter { ids.contains($0.id) }.map(\.title)
                    + facts.done.filter { ids.contains($0.id) }.map(\.title))
        }
        for c in cases {
            let shape = HouseholdChatFloor.shape(of: c.question, facts: facts)
            switch c.expect {
            case .floor(let expected, let cites):
                guard shape == expected else {
                    out.append("“\(c.question)”: floor shape \(String(describing: shape)) ≠ \(expected)")
                    continue
                }
                let answer = HouseholdChatFloor.answer(question: c.question, facts: facts)
                let got = titles(Set(answer?.citedTaskIDs ?? []))
                if got != cites {
                    out.append("“\(c.question)”: cited \(got.sorted()) ≠ \(cites.sorted())")
                }
            case .model(let mustContain):
                if let shape {
                    out.append(
                        "“\(c.question)”: the floor took it as \(shape) — a reasoning question is the model's"
                    )
                    continue
                }
                let slice = Set(HouseholdChatRetrieval.slice(for: c.question, facts: facts).map(\.title))
                let missing = mustContain.subtracting(slice)
                if !missing.isEmpty {
                    out.append("“\(c.question)”: slice missing \(missing.sorted())")
                }
            }
        }
        return out
    }

    // MARK: - Grounding (bracketed)

    /// Tokens in `reply` the model was never shown: digits, and capitalized words that
    /// are not sentence-initial and appear in neither the shown text nor the question.
    /// A crude detector, deliberately — it over-flags ("Tuesday"), and the bracket
    /// keeps it honest about what it can and cannot see.
    static func groundingFlags(reply: String, shown: String) -> [String] {
        let shownLower = shown.lowercased()
        var flags: [String] = []
        let sentences = reply.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for sentence in sentences {
            let words = sentence.split(separator: " ").map {
                String($0).trimmingCharacters(in: .punctuationCharacters)
            }
            for (index, word) in words.enumerated() where !word.isEmpty {
                if word.contains(where: \.isNumber) {
                    if !shownLower.contains(word.lowercased()) { flags.append(word) }
                    continue
                }
                guard index > 0, let first = word.first, first.isUppercase, word.count > 1 else { continue }
                if word == "I" { continue }
                if !shownLower.contains(word.lowercased()) { flags.append(word) }
            }
        }
        return flags
    }

    /// The bracket: a clean reply must score 0, an invented one must be caught.
    static func bracketHolds() -> Bool {
        let shown =
            "RELEVANT TASKS:\n- Renew the passport · owner: You · due in 9 days\nQUESTION: why is the passport stuck"
        let clean = groundingFlags(
            reply: "Renew the passport waits on the photos. It is due in 9 days.", shown: shown)
        let invented = groundingFlags(
            reply: "Call 555-0199 and ask Dr. Patel to expedite it by Friday.", shown: shown)
        return clean.isEmpty && invented.count >= 2
    }

    /// An error label fit for a table row: the innermost domain+code when the label is
    /// a nested NSError dump, else its first line, capped.
    static func oneLine(_ label: String) -> String {
        if let range = label.range(of: "ModelManagerError Code=[0-9]+", options: .regularExpression) {
            return String(label[range])
        }
        let first = label.split(separator: "\n").first.map(String.init) ?? label
        return first.count > 90 ? String(first.prefix(90)) + "…" : first
    }

    // MARK: - The run (device)

    static func runIfRequested(brain: AppBrain) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-HouseholdChatEval") else { return }
        if args.contains("-EvalToFile") {
            Instrument.teeStdoutToDocuments("householdchat-report.txt")
        }
        print("=== HOUSEHOLD CHAT EVAL ===")
        print("host engine: \(brain.status.description)")

        let facts = fixture()
        let misses = failures(facts: facts)
        let floorCases = cases.filter { if case .floor = $0.expect { return true } else { return false } }
        print(
            "floor + retrieval: \(cases.count - misses.count)/\(cases.count) labeled cases hold (\(floorCases.count) floor, \(cases.count - floorCases.count) model)"
        )
        for miss in misses { print("  MISS \(miss)") }

        print(
            bracketHolds()
                ? "grounding bracket: OK"
                : "grounding bracket: FAIL — the scorer is blind; ignore the grounding column")

        guard brain.status.isOnDevice else {
            print("(model arm skipped — no on-device model on this host; these numbers are device-only)")
            print("=== END HOUSEHOLD CHAT EVAL ===")
            return
        }

        let before = ModelMetrics.shared.stats[.householdChat] ?? .init()
        let service = InquiryService()
        var latencies: [Double] = []
        var totalFlags = 0
        var answered = 0
        for c in cases {
            guard case .model = c.expect else { continue }
            let turn = HouseholdChatTurn.make(facts: facts, question: c.question)
            let slice = turn.slice
            let started = Date()
            let outcome = await service.reply(turn)
            let ms = Date().timeIntervalSince(started) * 1000
            switch outcome {
            case .success(let raw):
                answered += 1
                latencies.append(ms)
                let reply = HouseholdChatPrompt.validatedReply(raw) ?? raw
                let shown =
                    HouseholdChatPrompt.instructions(for: facts) + "\n"
                    + HouseholdChatPrompt.turnPrompt(question: c.question, slice: slice, continuity: nil)
                let flags = groundingFlags(reply: reply, shown: shown)
                totalFlags += flags.count
                let cited = HouseholdChatCitations.cited(in: reply, among: slice).count
                print(
                    String(
                        format: "  %5.0fms · cites %d · flags %d  “%@”", ms, cited, flags.count, c.question))
                print("      → " + reply.replacingOccurrences(of: "\n", with: " / "))
                if !flags.isEmpty { print("      unverified: " + flags.joined(separator: ", ")) }
            case .timedOut: print(String(format: "  %5.0fms · TIMED OUT  “%@”", ms, c.question))
            case .failed(let label):
                print(String(format: "  %5.0fms · FAILED %@  “%@”", ms, oneLine(label), c.question))
            case .unavailable: print("  unavailable  “\(c.question)”")
            case .cancelled: print("  cancelled  “\(c.question)”")
            }
        }
        let after = ModelMetrics.shared.stats[.householdChat] ?? .init()
        let delta = Instrument.ArmDelta.between(before, after)
        print(
            Instrument.armLine(
                "model", delta: delta, latenciesMs: latencies,
                suffix: "grounding flags \(totalFlags) over \(answered) answers"))
        if let banner = Instrument.degradedBanner(delta, arm: "model") { print(banner) }
        print("=== END HOUSEHOLD CHAT EVAL ===")
    }
}
#endif
