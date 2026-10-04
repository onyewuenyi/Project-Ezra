//
//  DumpEval.swift
//  Project-Ezra
//
//  `-DumpEval` — the question the cloud's removal left open (2026-10-04). Capture used to
//  hand its hard tail to a cloud model: a long dump the deterministic read fused or
//  over-split, and speech with no task in it. The corpus held NO long dumps (the only rows
//  over the depth floors were three chatty misses), so what the on-device paths do with
//  that population was a claim, not a number. This is the number.
//
//  For each authored dump: the deterministic read (count, which expected outcomes appear
//  in a card), the route it would have taken, and the on-device boundary pass run
//  REGARDLESS of reason — `OnDeviceSegmenter` is wired only to `.underSegmented`, and the
//  point of this run is to see what it would do on the rest. Zero cloud, prevented rather
//  than observed, same as `-FMPrimitives`.
//
//  **The labels are authored, not gathered** (Claude, 2026-10-04) — a stand-in until the
//  parent-network captures the launch plan asks for exist, and they live HERE, apart from
//  `RambleEval.evalSet`/`realSet`, so no floor moves because of them. Where a label is a
//  judgment (an email's "we look forward to seeing you" is not a task; a date night is
//  one card or two) the report shows the read, so the label can be argued with.
//

#if DEBUG

import Foundation
import FoundationModels

enum DumpEval {

    struct Dump {
        let name: String
        let text: String
        /// One keyword per expected OUTCOME; a keyword found in any card counts as that
        /// outcome present. Empty = there is nothing in this capture to make a task of.
        let expected: [String]
    }

    private static let blob1 =
        "ok so tomorrow I need to drop the kids at school early because of the assembly, then call the dentist to reschedule Maya's cleaning, and I have to order the birthday cake for Saturday, oh and the permission slip for the zoo trip is due Friday so sign it and send it in, also we're out of milk and eggs and the car needs an oil change at some point"
    private static let blob2 =
        "I need to book the soccer registration before it closes on Sunday. Also pick up Noah's cleats from the shop. Mom's birthday is next week so I need a card and a gift. The pediatrician called, I have to call back about the vaccine form. And the gutters need cleaning before the rain."

    static let corpus: [Dump] = [
        Dump(
            name: "dictated-6", text: blob1,
            expected: ["drop", "dentist", "cake", "permission", "milk", "oil"]),
        Dump(
            name: "email-3",
            text:
                "Dear parents, thank you for a great start to the term. Please return the signed permission slip by Friday. Please reply with your preferred conference time. Please bring a labelled water bottle on Monday. We look forward to seeing you all at the fall picnic.",
            expected: ["permission", "conference", "water"]),
        Dump(
            name: "email-4",
            text:
                "Hi families, a few reminders for next week. Picture day is Thursday, please return the order form by Tuesday. We are collecting canned food for the drive, bring two cans by Wednesday. The book fair needs volunteers, sign up using the link. Please confirm your child's pickup person for Friday early dismissal.",
            expected: ["order form", "cans", "sign up", "pickup"]),
        Dump(
            name: "sentences-5", text: blob2,
            expected: ["soccer", "cleats", "card", "pediatrician", "gutters"]),
        Dump(
            name: "runon-8",
            text:
                "so I need to pay the water bill and renew the car registration and email the landlord about the leak and sign up for the carpool and book flights for thanksgiving after my sister confirms and find a babysitter for friday night and wash the soccer uniform before saturday and refill the prescription",
            expected: [
                "water bill", "registration", "landlord", "carpool", "flights", "babysitter",
                "uniform", "prescription",
            ]),
        Dump(
            name: "week-5",
            text:
                "Monday Maya has swim at 4. Tuesday dentist for Noah at 3:30. Wednesday parent teacher conference at 5, remember the report card. Thursday I'm working late so someone else needs to pick up the kids. Friday date night, book the sitter.",
            expected: ["swim", "dentist", "conference", "pick up", "sitter"]),
        Dump(
            name: "thanksgiving-6",
            text:
                "for thanksgiving I need to order the turkey by Monday, ask Aunt Rose to bring the pies, buy extra chairs, clean the guest room, book the flights for my parents once we know the date, and make a seating chart",
            expected: ["turkey", "pies", "chairs", "guest room", "flights", "seating"]),
        Dump(
            name: "big-11", text: blob1 + ". " + blob2,
            expected: [
                "drop", "dentist", "cake", "permission", "milk", "oil", "soccer", "cleats", "card",
                "pediatrician", "gutters",
            ]),
        Dump(
            name: "chatty-1",
            text:
                "okay so um where was I, the kids are being crazy today, anyway, I have to remember to call the school about the pickup change, oh and honestly I think we should just go to the park, whatever",
            expected: ["school"]),
        Dump(
            name: "chatty-2",
            text:
                "so I was thinking about the weekend and honestly the kids have so much energy lately, they are bouncing off the walls, anyway before I forget I need to email Ms Patel about the field trip form and also remind Dan to pick up his mother from the airport on Sunday, and yeah that's about it, oh the weather is supposed to be great",
            expected: ["patel", "dan"]),
        Dump(
            name: "chatty-0",
            text:
                "ha yeah no that was so funny, she just looked at me like I was crazy, anyway anyway the weather is so nice today, I love this time of year, we should do something",
            expected: []),
        Dump(
            name: "compound-1",
            text:
                "I need to schedule a meeting with the school counselor and Noah's teacher about his reading progress before the end of the month",
            expected: ["counselor"]),
    ]

    // MARK: - Scoring (pure)

    /// How many of `expected`'s outcomes appear in some card's title.
    static func recall(_ expected: [String], in titles: [String]) -> Int {
        let lowered = titles.map { $0.lowercased() }
        return expected.filter { keyword in lowered.contains { $0.contains(keyword) } }.count
    }

    // MARK: - The run

    @MainActor
    static func runIfRequested(brain: AppBrain) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-DumpEval") else { return }
        if args.contains("-RambleEval") || args.contains("-FMPrimitives") || args.contains("-FMDiagnostics") {
            print("=== DUMP EVAL REFUSED — run alone (other seams warm what this measures) ===")
            return
        }
        if args.contains("-EvalToFile") { Instrument.teeStdoutToDocuments("dumpeval-report.txt") }
        let markers = Instrument.Markers(name: "DUMP EVAL")
        print(markers.begin)
        print("The cloud's removed tail — long dumps and chatty speech, read on the device only")
        print(
            Instrument.runStamp(
                model: brain.status.description,
                configuration: OnDeviceSegmenter.instructions
                    + "|cap=\(OnDeviceSegmenter.generationCapSeconds)"))

        // Zero-cloud, PREVENTED rather than observed (the `-FMPrimitives` pattern).
        let originalProvider = CloudModel.provider
        CloudModel.provider = LaunchSeams.EvalQuotaGuard.self
        defer { CloudModel.provider = originalProvider }
        let onDevice = brain.status.isOnDevice
        if !onDevice {
            print("(no on-device model on this host — the boundary-pass columns are not measured)")
        }

        var localExact = 0
        var bestExact = 0
        var passAccepted = 0
        var passMadeWorse = 0
        var latencies: [Int] = []
        print("\nname            len  exp  local  recall  route                 boundary pass")
        for dump in corpus {
            let local = AppBrain.provisionalDrafts(dump.text)
            let localTitles = local.map(\.title)
            let route = CaptureRoute.route(for: dump.text, localRead: local)
            let routeText = "\(route.route)/\(route.escalation.map { "\($0)" } ?? "-")"
            let localRight = local.count == dump.expected.count

            var passText = "—"
            var bestCount = local.count
            var bestTitles = localTitles
            if onDevice {
                let started = Date()
                let outcome = await OnDeviceSegmenter.segment(text: dump.text)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                latencies.append(ms)
                switch outcome {
                case .accepted(let drafts, let fragments, _):
                    passAccepted += 1
                    passText = "ACCEPT \(fragments) cards · \(ms)ms"
                    bestCount = drafts.count
                    bestTitles = drafts.map(\.title)
                    if localRight && drafts.count != dump.expected.count { passMadeWorse += 1 }
                case .refused(let reason):
                    passText = "refused \(reason) · \(ms)ms"
                }
            }
            if localRight { localExact += 1 }
            if bestCount == dump.expected.count { bestExact += 1 }
            let found = recall(dump.expected, in: bestTitles)
            print(
                "\(dump.name.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                    + "\(String(dump.text.count).padding(toLength: 4, withPad: " ", startingAt: 0)) "
                    + "\(String(dump.expected.count).padding(toLength: 4, withPad: " ", startingAt: 0)) "
                    + "\(String(local.count).padding(toLength: 6, withPad: " ", startingAt: 0)) "
                    + "\(found)/\(dump.expected.count)".padding(toLength: 7, withPad: " ", startingAt: 0)
                    + " \(routeText.padding(toLength: 21, withPad: " ", startingAt: 0)) \(passText)")
            if local.count != dump.expected.count {
                print("    local cards: \(localTitles.map { String($0.prefix(70)) })")
            }
        }

        let n = corpus.count
        print("\n── summary ──")
        print("exact card count · deterministic read: \(localExact)/\(n)")
        if onDevice {
            print("exact card count · best of read + boundary pass: \(bestExact)/\(n)")
            print("boundary pass accepted \(passAccepted)/\(n) · made a right read WRONG: \(passMadeWorse)")
            if !latencies.isEmpty {
                let sorted = latencies.sorted()
                print("boundary pass latency p50 \(sorted[sorted.count / 2])ms · max \(sorted.last ?? 0)ms")
            }
        }
        print("providerCalls: 0 (the provider slot held EvalQuotaGuard)")
        print(markers.end)
    }
}

#endif
