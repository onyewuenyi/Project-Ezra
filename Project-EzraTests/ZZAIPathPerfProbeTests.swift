import Foundation
import Testing

@testable import Project_Ezra

/// A probe, not a test: the deterministic AI path at family scale, timed. Prints one
/// line per stage so the slowest one can be found instead of guessed.
@Suite("ai path perf probe")
@MainActor
struct ZZAIPathPerfProbeTests {

    private func ms(_ block: () -> Void, repeats: Int) -> Double {
        block()  // warm
        let start = Date()
        for _ in 0..<repeats { block() }
        return Date().timeIntervalSince(start) / Double(repeats) * 1000
    }

    @Test("stage costs at 240 tasks")
    func stageCosts() {
        let me = UUID()
        var tasks: [TaskItem] = []
        let verbs = ["Renew", "Book", "Call", "Fix", "Pay", "Order", "Cancel", "Email", "Sort", "Plan"]
        let nouns = ["passport", "the dentist", "the plumber", "the tap", "the water bill", "a gift", "the gym", "Sarah", "the loft", "the trip"]
        for i in 0..<240 {
            let t = TaskItem(
                title: "\(verbs[i % 10]) \(nouns[(i / 10) % 10]) \(i)",
                status: i % 7 == 0 ? .done : .todo, ownerID: i % 3 == 0 ? UUID() : me)
            t.category = ["Home", "Admin", "Family", "Work"][i % 4]
            tasks.append(t)
        }
        for i in stride(from: 0, to: 240, by: 10) {
            tasks[i + 1].linkParent(tasks[i].uuid!)
            tasks[i + 2].linkParent(tasks[i].uuid!)
            tasks[i + 3].addTaskBlocker(tasks[i + 4].uuid!, among: tasks)
        }
        let snapshots = tasks.filter { $0.status.isLive }.map {
            OpenTaskSnapshot(id: $0.uuid!, title: $0.title, category: $0.category, updatedAt: $0.updatedAt)
        }
        let ramble = "call the dentist about thursday then pick up the dry cleaning and email sarah the invoice and book the car in for friday and text mum about sunday"
        let dump = String(repeating: "renew the passport and then book the flights and also call the vet tomorrow. ", count: 8)

        let t1 = ms({ _ = AppBrain.provisionalDrafts(ramble) }, repeats: 20)
        let read = AppBrain.provisionalDrafts(ramble)
        let t2 = ms({ _ = CaptureEscalation.reason(for: ramble, drafts: read) }, repeats: 20)
        let t3 = ms({ _ = Segmentation.items(from: dump) }, repeats: 20)
        let t4 = ms({ _ = ContextRetrieval.candidates(matching: ramble, among: snapshots) }, repeats: 5)
        let t5 = ms({ _ = TaskAdvisorFacts.make(task: tasks[3], among: tasks) }, repeats: 20)
        let t6 = ms({ for t in tasks.prefix(30) { _ = StallDetector.diagnose(t, among: tasks) } }, repeats: 5)
        let t7 = ms({ _ = DuplicateSweep.candidatePairs(among: snapshots, suppressions: [], vector: { _ in [1, 0, 0] }) }, repeats: 3)
        let t8 = ms({ _ = AppBrain.provisionalDrafts(dump) }, repeats: 10)
        let t9 = ms({ for t in tasks.prefix(30) { _ = BreakdownEligibility.evaluate(t, among: tasks) } }, repeats: 5)

        print(String(format: "AIPERF provisionalDrafts(ramble)=%.2fms", t1))
        print(String(format: "AIPERF escalation.reason=%.2fms", t2))
        print(String(format: "AIPERF segmentation(600ch dump)=%.2fms", t3))
        print(String(format: "AIPERF retrieval.candidates(206 snaps, lexical)=%.2fms", t4))
        print(String(format: "AIPERF advisorFacts.make(1 of 240)=%.2fms", t5))
        print(String(format: "AIPERF stallDetector x30=%.2fms", t6))
        print(String(format: "AIPERF duplicateSweep.candidatePairs(206)=%.2fms", t7))
        print(String(format: "AIPERF provisionalDrafts(600ch dump)=%.2fms", t8))
        print(String(format: "AIPERF breakdownEligibility x30=%.2fms", t9))
    }
}
