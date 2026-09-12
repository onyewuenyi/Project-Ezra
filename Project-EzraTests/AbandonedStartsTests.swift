import CoreData
import Foundation
import Testing

@testable import Project_Ezra

/// The avoidance signal, restored (2026-09-12).
///
/// `StallDetector.isStalled` has always had two independent signals: repeated avoidance, and
/// silence. The avoidance one read `deferralCount`, whose only writer was the Brief's
/// day-rollover — cut on 2026-09-02 — so for ten days the ONLY route to "stalled" was
/// neglect by silence, and a person actively bouncing off a task was invisible to the sensor
/// built to catch exactly that. Everything behind the sensor went with it: the whole Advisor
/// diagnosis ladder, and the `.dying` headline's honest branch.
///
/// These tests pin the restored signal AND the two properties that keep it from nagging.
@Suite("abandoned starts — the avoidance signal")
@MainActor
struct AbandonedStartsTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    /// Picked up and put back down `times` times.
    private func abandon(_ task: TaskItem, _ times: Int) {
        for _ in 0..<times {
            task.status = .doing
            task.status = .todo
        }
    }

    // MARK: - The count

    @Test("the count is closed `.doing` visits — the open one is not an abandonment yet")
    func onlyClosedVisitsCount() {
        let task = TaskItem(title: "Sort the loft", status: .todo, in: context())
        abandon(task, 2)
        #expect(task.abandonedStartCount == 2)
        task.status = .doing
        #expect(task.abandonedStartCount == 2, "the visit in flight was counted as abandoned")
    }

    @Test("the count is WINDOWED, so it cannot pin a diagnosis to a task forever")
    func theCountDecays() {
        // The property `deferralCount`'s consecutive-and-cleared design existed to
        // guarantee, restored by a different route. A lifetime count would say "you keep
        // bouncing off this" about a task abandoned twice a year ago.
        let task = TaskItem(title: "Sort the loft", status: .todo, in: context())
        abandon(task, 3)
        let window = StallDetector.quietThreshold
        #expect(task.recentAbandonedStarts(within: window) == 3)
        let muchLater = Date().addingTimeInterval(window * 4)
        #expect(task.recentAbandonedStarts(within: window, now: muchLater) == 0)
    }

    // MARK: - The sensor

    @Test("repeated abandonment makes a task stalled again, with no silence needed")
    func abandonmentStalls() {
        let task = TaskItem(title: "Sort the loft", status: .todo, in: context())
        task.touchHuman()
        // Freshly touched, so the silence signal cannot fire. Before this fix, that meant
        // the task was not stalled at all however many times it had been dropped.
        #expect(!StallDetector.isStalled(task))
        abandon(task, StallDetector.abandonmentThreshold)
        task.touchHuman()
        #expect(StallDetector.isStalled(task))
    }

    @Test("one abandonment is an interruption, not a pattern")
    func oneAbandonmentIsNotAStall() {
        let task = TaskItem(title: "Sort the loft", status: .todo, in: context())
        abandon(task, 1)
        task.touchHuman()
        #expect(!StallDetector.isStalled(task))
    }

    @Test("the signal goes quiet while the person is actually doing the task")
    func doingSilencesTheSignal() {
        // Telling someone they keep avoiding the thing they are doing right now is the
        // nagging this product refuses — and it is the other half of the dismissability
        // guarantee, since starting the task is the action the diagnosis would offer.
        let task = TaskItem(title: "Sort the loft", status: .todo, in: context())
        abandon(task, 3)
        task.touchHuman()
        #expect(StallDetector.isStalled(task))
        task.status = .doing
        task.touchHuman()
        #expect(!StallDetector.isStalled(task), "it nagged about a task in flight")
    }

    // MARK: - What it says

    @Test("a repeatedly-abandoned task is not told it has gone quiet")
    func theHeadlineIsHonest() {
        // The dead branch's user-visible cost: a task picked up and dropped three times is
        // the loudest thing on the list, and it was being told the opposite.
        #expect(
            StallDiagnosis.dying.headline(deferralCount: 0, abandonedStarts: 3)
                == "You've started this 3 times and put it back down.")
        #expect(
            StallDiagnosis.dying.headline(deferralCount: 0, abandonedStarts: 0)
                == "This has gone quiet.")
        // The other rungs are unchanged — this only ever spoke for `.dying`.
        #expect(
            StallDiagnosis.blocked.headline(deferralCount: 0, abandonedStarts: 3)
                == "This is waiting on something else.")
    }

    @Test("the evidence never says 'no progress' about a task that was picked up repeatedly")
    func evidenceDoesNotContradictItself() {
        let context = context()
        let task = TaskItem(title: "Sort the loft", status: .todo, in: context)
        abandon(task, 3)
        let facts = TaskAdvisorFacts.make(task: task, among: [task])
        #expect(facts.abandonedStarts == 3)
        #expect(facts.userVisibleEvidence.contains { $0.contains("put it back down") })
        #expect(
            !facts.userVisibleEvidence.contains { $0.contains("No progress") },
            "it said the task had seen no progress and that it was started three times")
    }
}
