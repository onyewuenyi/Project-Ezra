//
//  GroupingSweepEval.swift
//  Project-Ezra
//
//  The grouping judge, measured: labeled clusters — some ONE outcome, some merely
//  word-sharing — run through the judge the product uses (`GroupingSweep.judge`) and its
//  validator. The critical error is a FALSE ACCEPT: a non-group the person is asked to
//  group (every ask costs attention; a wrong ask costs trust). A missed group is the
//  cheap error — the rows simply stay loose. Device-only for the model arm; the labeled
//  set and the validator are pure. `-GroupingSweepEval`, `-EvalToFile` tees to
//  Documents/groupingsweep-report.txt; the completion marker is
//  `=== END GROUPING SWEEP EVAL ===`.
//

import CoreData
import Foundation

#if DEBUG
enum GroupingSweepEval {

    struct Case {
        let titles: [String]
        /// The outcome, when the titles are one; nil when they merely share words.
        let outcome: String?
        /// An ATTACH case: the existing outcome, its steps, and which candidates belong.
        var umbrella: String? = nil
        var steps: [String] = []
        var belongs: Set<String> = []
    }

    static let cases: [Case] = [
        Case(
            titles: ["Book flights to Lagos", "Pack for Lagos", "Renew passport for the Lagos trip"],
            outcome: "Lagos trip"),
        Case(
            titles: ["Order the birthday cake", "Send the birthday invites", "Book the birthday venue"],
            outcome: "Birthday party"),
        Case(
            titles: ["Get quotes for the kitchen", "Choose kitchen tiles", "Book the kitchen fitter"],
            outcome: "Kitchen renovation"),
        Case(
            titles: ["Pack the moving boxes", "Book the moving van", "Change the address for the move"],
            outcome: "House move"),
        Case(titles: ["Pay the water bill", "Pay the phone bill"], outcome: nil),
        Case(titles: ["Call the school about pickup", "Call the dentist back"], outcome: nil),
        Case(titles: ["Clean the garage", "Clean the gutters"], outcome: nil),
        Case(titles: ["Return the Amazon package", "Cancel the Amazon subscription"], outcome: nil),
        // The first production proposal (2026-09-17, flow fixtures): two DIFFERENT events
        // sharing "caterer" were offered as "Wedding planning". The critical error, labeled.
        Case(titles: ["Choose the wedding caterer", "Confirm caterer for the reunion"], outcome: nil),
        Case(titles: ["Renew the car insurance", "Renew car registration"], outcome: nil),
        // Attach: the outcome exists; which loose candidates are its steps?
        Case(
            titles: ["Pack for Lagos", "Pay the phone bill", "Book the Lagos hotel"], outcome: "Lagos trip",
            umbrella: "Lagos trip", steps: ["Book flights to Lagos", "Renew passport"],
            belongs: ["Pack for Lagos", "Book the Lagos hotel"]),
        Case(
            titles: ["Order the reunion cake", "Book the wedding photographer"], outcome: "Wedding",
            umbrella: "Wedding", steps: ["Choose the wedding caterer", "Send the wedding invites"],
            belongs: ["Book the wedding photographer"]),
        // The dogfooding store's own question after "Trip Preparation" was named: three
        // loose tasks sharing "trip"/"book" with it, none a step of THAT trip.
        Case(
            titles: ["Renew car registration", "Plan the weekend trip", "Book venue for the offsite"],
            outcome: "Trip Preparation", umbrella: "Trip Preparation",
            steps: ["Renew passport", "Book flights for the trip", "Apply for travel visa"], belongs: []),
        // The flow fixtures' own attach candidate: a shared verb, not a step.
        Case(
            titles: ["Schedule the dentist"], outcome: "Schedule the movers",
            umbrella: "Schedule the movers", steps: ["Change our mailing address"], belongs: []),
        Case(
            titles: ["Clean the kitchen floor"], outcome: "Kitchen renovation",
            umbrella: "Kitchen renovation", steps: ["Get quotes for the kitchen", "Choose kitchen tiles"],
            belongs: []),
    ]

    static func cluster(_ c: Case) -> GroupingSweep.Cluster {
        GroupingSweep.Cluster(
            members: c.titles.map { OpenTaskSnapshot(id: UUID(), title: $0, category: "Home") },
            links: c.titles.count,
            umbrella: c.umbrella.map { OpenTaskSnapshot(id: UUID(), title: $0, category: "Home") },
            steps: c.steps.map { OpenTaskSnapshot(id: UUID(), title: $0, category: "Home") })
    }

    static func runIfRequested(brain: AppBrain, in context: NSManagedObjectContext) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-GroupingSweepEval") else { return }
        if args.contains("-EvalToFile") { Instrument.teeStdoutToDocuments("groupingsweep-report.txt") }
        print("=== GROUPING SWEEP EVAL ===")
        print(Instrument.runStamp(model: brain.status.description, configuration: "GroupingSweep"))
        guard brain.status.isOnDevice else {
            print("(model arm skipped — no on-device model on this host)")
            print("=== END GROUPING SWEEP EVAL ===")
            return
        }
        // What the sweep would ASK about on THIS store — the prefilter's clusters over the
        // live open set, titles only, no judgment spent. The owner's view of the question
        // before the model answers it.
        let snapshots = OpenTaskSnapshotCache.shared.snapshots(in: context)
        let suppressions = SuppressionStore.load(
            in: context, existingTaskIDs: Set(TaskItem.fetchAll(in: context).compactMap(\.uuid)))
        let storeClusters = GroupingSweep.candidates(
            in: TaskItem.fetchAll(in: context), snapshots: snapshots, suppressions: suppressions,
            includingAttach: true)
        print(
            "store: \(snapshots.count) open · \(storeClusters.count) cluster(s) the sweep would judge"
                + (GroupingSweep.attachIsEnabled ? "" : " (attach questions listed but OFF in the product)"))
        for cluster in storeClusters {
            let head = cluster.umbrella.map { "under “\($0.title)”: " } ?? ""
            print("  · " + head + cluster.members.map(\.title).joined(separator: " | "))
        }
        let before = ModelMetrics.shared.stats[.groupingSweep] ?? .init()
        var latencies: [Double] = []
        var falseAccepts = 0
        var trueAccepts = 0
        var groups = 0
        for c in cases {
            let cluster = cluster(c)
            if c.umbrella != nil ? !c.belongs.isEmpty : c.outcome != nil { groups += 1 }
            let started = Date()
            let outcome = await GroupingSweep.judge(cluster)
            let ms = Date().timeIntervalSince(started) * 1000
            switch outcome {
            case .success(let judgment):
                latencies.append(ms)
                let proposal = GroupingSweep.validated(judgment, shown: cluster.members, umbrella: cluster.umbrella)
                let accepted = proposal != nil
                let verdict: String
                if c.umbrella != nil {
                    // Attach: every accepted member must belong; every belonging one accepted.
                    let got = Set(proposal?.memberTitles ?? [])
                    if !got.subtracting(c.belongs).isEmpty {
                        falseAccepts += 1
                        verdict = "FALSE ACCEPT"
                    } else if got == c.belongs {
                        if !c.belongs.isEmpty { trueAccepts += 1 }
                        verdict = c.belongs.isEmpty ? "decline" : "accept"
                    } else {
                        verdict = "MISS"
                    }
                } else if accepted, c.outcome == nil {
                    falseAccepts += 1
                    verdict = "FALSE ACCEPT"
                } else if accepted {
                    trueAccepts += 1
                    verdict = "accept"
                } else if c.outcome == nil {
                    verdict = "decline"
                } else {
                    verdict = "MISS"
                }
                print(
                    String(
                        format: "  %5.0fms · %@ · conf %.2f · together %@ · title “%@” · members %d/%d  [%@]",
                        ms,
                        verdict, judgment.confidence, judgment.belongsTogether ? "yes" : "no",
                        proposal?.title ?? judgment.outcomeTitle, proposal?.memberIDs.count ?? 0,
                        c.titles.count, c.titles.joined(separator: " | ")))
                if verdict == "MISS" || verdict == "FALSE ACCEPT" {
                    print("      named: " + judgment.memberTitles.joined(separator: " | "))
                }
            case .timedOut:
                print(String(format: "  %5.0fms · TIMED OUT  [%@]", ms, c.titles.joined(separator: " | ")))
            case .failed(let label):
                print(
                    String(
                        format: "  %5.0fms · FAILED %@  [%@]", ms, label, c.titles.joined(separator: " | ")))
            case .unavailable: print("  unavailable")
            case .cancelled: print("  cancelled")
            }
        }
        let after = ModelMetrics.shared.stats[.groupingSweep] ?? .init()
        let delta = Instrument.ArmDelta.between(before, after)
        print(
            Instrument.armLine(
                "judge", delta: delta, latenciesMs: latencies,
                suffix:
                    "FALSE ACCEPT \(falseAccepts)/\(cases.count - groups) · recall \(trueAccepts)/\(groups)"))
        if let banner = Instrument.degradedBanner(delta, arm: "judge") { print(banner) }
        print("=== END GROUPING SWEEP EVAL ===")
    }
}
#endif
