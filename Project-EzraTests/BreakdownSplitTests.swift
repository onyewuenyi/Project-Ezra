//
//  BreakdownSplitTests.swift
//  Project-EzraTests
//
//  What accepting a breakdown actually does. This is the one capability that COMMITS —
//  the Thinking Partner changes nothing, a split creates real tasks — so the guarantees
//  worth pinning are the commit semantics, the single reversible entry, and the ranking
//  consequence of a task becoming a container.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
struct BreakdownSplitTests {

    private func context() -> NSManagedObjectContext { TestStore.makeContext() }

    private func steps(_ titles: [String]) -> [BreakdownStep] {
        titles.map { BreakdownStep(title: $0, effortMinutes: 30) }
    }

    private func entries(in context: NSManagedObjectContext) throws -> [ChangeLogEntry] {
        try context.fetch(NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry"))
    }

    // MARK: - The split

    @Test("Children are born Todo and confirmed — creation IS the accept tap")
    func childrenAreBornConfirmed() {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)

        let created = parent.splitInto(
            steps(["Book flights", "Book the hotel"]), in: context)

        #expect(created.count == 2)
        for child in created {
            #expect(child.status == .todo)
            #expect(child.confirmedAt != nil)  // the accept tap is the confirm
            #expect(child.parentTaskID == parent.uuid)
        }
    }

    @Test("Children inherit the parent's owner and category — your work stays yours")
    func childrenInheritOwnership() {
        let context = context()
        let me = UUID()
        let parent = TaskItem(
            title: "Plan the trip", category: "Travel", status: .todo, ownerID: me, in: context)
        context.insert(parent)

        let created = parent.splitInto(steps(["Book flights"]), in: context)
        #expect(created.first?.ownerID == me)
        #expect(created.first?.category == "Travel")
    }

    @Test("One entry for one action, carrying every created id")
    func oneReversibleEntry() throws {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)

        let created = parent.splitInto(steps(["A", "B", "C"]), in: context)

        let splits = try entries(in: context).filter { $0.action == "split" }
        #expect(splits.count == 1)  // one action the user took → one line in the feed
        let entry = try #require(splits.first)
        #expect(entry.isReversible)
        #expect(entry.initiatedBy == .human)  // the AI proposes; the person accepts
        let ids = (entry.newValue ?? "").split(separator: ",").map(String.init)
        #expect(Set(ids) == Set(created.compactMap { $0.uuid?.uuidString }))
    }

    @Test("An empty accept does nothing at all")
    func emptyAcceptIsANoOp() throws {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        #expect(parent.splitInto([], in: context).isEmpty)
        #expect(try entries(in: context).isEmpty)
    }

    // MARK: - The container reading (derived, never a stored wait)

    @Test("The umbrella can't be finished before its steps — and says so as progress")
    func openStepsAreTheContainerState() {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)

        let created = parent.splitInto(steps(["Book flights", "Book the hotel"]), in: context)
        let all = TaskItem.fetchAll(in: context)

        #expect(Set(parent.openSteps(among: all).compactMap(\.uuid)) == Set(created.compactMap(\.uuid)))
        #expect(parent.stepProgress(among: all) == StepProgress(done: 0, total: 2))
        #expect(parent.stepProgress(among: all)?.label == "0 of 2 steps")

        created[0].complete()
        #expect(parent.stepProgress(among: all) == StepProgress(done: 1, total: 2))
        created[1].complete()
        // Nothing had to remember to update anything: the progress is the children.
        #expect(parent.openSteps(among: all).isEmpty)
        #expect(parent.stepProgress(among: all)?.isComplete == true)
    }

    @Test("A container is NOT blocked — the two graphs stay unfused")
    func containerIsNotBlocked() {
        let context = context()
        let me = UUID()
        let parent = TaskItem(title: "Plan the trip", status: .todo, ownerID: me, in: context)
        context.insert(parent)
        parent.splitInto(steps(["Book flights"]), in: context)
        let all = TaskItem.fetchAll(in: context)

        // Storing the wait as a `.blocks` edge was tried and reversed: it made the CTA
        // read "Unblock" (one tap to dismantle the breakdown) and the stall rung claim the
        // task was waiting on "something else" — when the something else was itself.
        #expect(parent.taskBlockerIDs.isEmpty)
        #expect(!parent.hasActiveBlockers(among: all))
        #expect(parent.recommendedAction(among: all, currentUserID: me) == .start)

        parent.deferralCount = StallDetector.deferralThreshold  // stalled by avoidance
        #expect(StallDetector.diagnose(parent, among: all) != .blocked)

        // A REAL obstacle on the same task still reads as one — the container reading
        // never suppressed anything, so nothing had to be carved back in.
        parent.addExternalBlocker("the visa office", among: all)
        #expect(parent.recommendedAction(among: all, currentUserID: me) == .unblock)
        #expect(StallDetector.diagnose(parent, among: all) == .blocked)
    }

    @Test("A breakdown renders as ONE chain, steps in front of the umbrella")
    func breakdownGroupsIntoOneChain() throws {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        let created = parent.splitInto(steps(["Book flights", "Book the hotel"]), in: context)

        let all = TaskItem.fetchAll(in: context)
        let (chains, loose) = TaskChainGrouping.computeChains(in: all)

        #expect(loose.isEmpty)  // the umbrella no longer scatters away from its own steps
        let chain = try #require(chains.first)
        #expect(chain.members.count == 3)
        // Containment orders the stack the same way sequencing does: what you have to get
        // through first comes first, so the umbrella lands last and a step is the front card.
        #expect(chain.members.last?.uuid == parent.uuid)
        #expect(created.compactMap(\.uuid).contains(chain.root.uuid))
    }

    @Test("Closing the umbrella early is allowed, but never silent")
    func resolutionNoticeNamesWhatIsLeft() {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        let created = parent.splitInto(steps(["Book flights", "Book the hotel"]), in: context)
        let all = TaskItem.fetchAll(in: context)

        let notice = UndoNotice.resolution(
            "Completed", parent.title, steps: parent.stepProgress(among: all))
        #expect(notice.message.contains("2 steps still open"))

        created.forEach { $0.complete() }
        let clean = UndoNotice.resolution(
            "Completed", parent.title, steps: parent.stepProgress(among: all))
        #expect(!clean.message.contains("still open"))  // nothing left ⇒ nothing to say
    }

    // MARK: - Undo

    @Test("Undo removes the children and their edges, leaving the parent untouched")
    func undoRemovesChildren() throws {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        parent.splitInto(steps(["Book flights", "Book the hotel"]), in: context)
        try context.save()

        let entry = try #require(try entries(in: context).first { $0.action == "split" })
        ChangeLogUndo.revert(entry, in: context)
        try context.save()

        let remaining = TaskItem.fetchAll(in: context)
        #expect(remaining.count == 1)  // the children are gone…
        #expect(remaining.first?.uuid == parent.uuid)  // …and the parent survived
        #expect(parent.status == .todo)
        // The split wrote exactly one edge per step, on the step — so deleting the steps
        // is the whole undo. Nothing on the parent to unwind, which is the point of
        // deriving the container reading rather than storing it.
        #expect(parent.children(among: remaining).isEmpty)
        #expect(parent.stepProgress(among: remaining) == nil)
        #expect(parent.taskBlockerIDs.isEmpty)
    }

    @Test("Undo does NOT reclaim a step the user has since worked on")
    func undoSparesTouchedChildren() throws {
        let context = context()
        let parent = TaskItem(title: "Plan the trip", status: .todo, in: context)
        context.insert(parent)
        let created = parent.splitInto(
            steps(["Book flights", "Book the hotel"]), in: context)
        try context.save()

        // Read the ids up front. Once the undo below deletes the untouched child and the
        // context is saved, that object is gone from the store — reading any property of
        // it is a use-after-delete on a managed object, which faults and kills the host.
        let touchedID = try #require(created[0].uuid)
        let reclaimedID = try #require(created[1].uuid)

        // One step is real work now — completed. Undo promised to reverse the split,
        // not to destroy something the user has since acted on.
        //
        // `complete()`, not `completeAndResurface(in:)`: the arm keys off `status.isResolved`,
        // so resurfacing dependents is setup this case never reads.
        created[0].complete()
        try context.save()

        let entry = try #require(try entries(in: context).first { $0.action == "split" })
        ChangeLogUndo.revert(entry, in: context)
        try context.save()

        let remaining = TaskItem.fetchAll(in: context)
        #expect(remaining.contains { $0.uuid == touchedID })  // kept
        #expect(!remaining.contains { $0.uuid == reclaimedID })  // reclaimed
        // The container reading follows the survivors with no bookkeeping: one step left,
        // and it is done.
        //
        // NOTE (2026-08-11): a delete-heavy test in this suite crashes the HOST in
        // full-suite runs. It is NOT this assertion and NOT `stepProgress` — removing this
        // line moved the crash to `undoRemovesChildren`, which nothing had touched. The
        // signature is an over-release inside Core Data's in-memory `NSMappedObjectStore`
        // teardown: the shared-scratch-context harness bug tracked separately. Every test
        // here passes when run alone.
        #expect(parent.stepProgress(among: remaining) == StepProgress(done: 1, total: 1))
    }

    // MARK: - Ranking: the umbrella steps back

    @Test("A parent with open children ranks below the same task without them")
    func containerRecedes() {
        let context = context()
        let now = Date()
        let plain = TaskItem(title: "Renew passport", status: .todo, createdAt: now, in: context)
        let parent = TaskItem(title: "Plan the trip", status: .todo, createdAt: now, in: context)
        context.insert(plain)
        context.insert(parent)
        parent.splitInto(steps(["Book flights"]), in: context)

        let all = TaskItem.fetchAll(in: context)
        let keys = TaskRanking.rankKeys(for: all, now: now)
        let parentKey = try? #require(keys[parent.uuid!])
        let plainKey = try? #require(keys[plain.uuid!])
        // Surfacing the umbrella alongside its own steps double-bills the same work.
        #expect((parentKey?.effectiveAttention ?? 0) < (plainKey?.effectiveAttention ?? 0))
    }

    @Test("The recede lifts once every child resolves — it reads the OPEN set")
    func containerLiftsWhenChildrenResolve() {
        let context = context()
        let now = Date()
        let parent = TaskItem(title: "Plan the trip", status: .todo, createdAt: now, in: context)
        context.insert(parent)
        let created = parent.splitInto(steps(["Book flights"]), in: context)

        let before = TaskRanking.rankKeys(for: TaskItem.fetchAll(in: context), now: now)
        created[0].complete(now: now)
        let after = TaskRanking.rankKeys(for: TaskItem.fetchAll(in: context), now: now)

        let id = parent.uuid!
        #expect((after[id]?.effectiveAttention ?? 0) > (before[id]?.effectiveAttention ?? 0))
    }

    @Test("The model's sequence survives the split — sortIndex, never timestamp inference")
    func splitPersistsTheModelsSequence() {
        let context = context()
        let parent = TaskItem(title: "Plan the launch", status: .todo, in: context)
        // Titles chosen so ALPHABETICAL and uuid order cannot accidentally match the
        // proposed sequence: only the persisted ordinal can reproduce it.
        let proposed = [
            BreakdownStep(title: "Zip up the announcement", effortMinutes: 15),
            BreakdownStep(title: "Ask legal to sign off", effortMinutes: 30),
            BreakdownStep(title: "Mail the customers", effortMinutes: 15),
        ]
        let created = parent.splitInto(proposed, in: context)

        #expect(created.map(\.sortIndex) == [0, 1, 2])
        // The one ordered derivation returns them in breakdown order — every sibling
        // shares one `createdAt`, so without the ordinal this collapses to uuid order.
        let ordered = parent.children(among: [parent] + created.shuffled())
        #expect(ordered.map(\.title) == proposed.map(\.title))
    }

    @Test("Pre-sortIndex stores keep their old order — zero ties fall back, stably")
    func legacyZeroTiesFallBack() {
        let context = context()
        let parent = TaskItem(title: "Old container", status: .todo, in: context)
        let created = parent.splitInto(
            [
                BreakdownStep(title: "First", effortMinutes: 15),
                BreakdownStep(title: "Second", effortMinutes: 15),
                BreakdownStep(title: "Third", effortMinutes: 15),
            ], in: context)
        // Simulate a store written before the attribute existed: every ordinal 0.
        for step in created { step.sortIndex = 0 }

        let once = parent.children(among: [parent] + created).map(\.uuid)
        let again = parent.children(among: [parent] + created.reversed()).map(\.uuid)
        #expect(once == again)  // stable regardless of input order — the old behaviour
    }

    @Test("The additive model version is additive in fact — the old shape still ships")
    func oldModelVersionStillShips() {
        // The tripwire's widened premise: a digest that moved because a NEW version
        // was added must find the OLD version's digest still in the bundle. If this
        // set ever collapses to one member, either a version was deleted or the
        // current one was edited in place — both are the store-eating mistake.
        let digests = PersistenceStack.bundledModelVersionDigests
        #expect(digests.contains(PersistenceStack.modelDigest))
        #expect(digests.count >= 2)
    }

    @Test("nextOpenStep is the one 'what's next' — breakdown order, resolved skipped")
    func nextOpenStepFollowsTheBreakdown() {
        let context = context()
        let parent = TaskItem(title: "Ship the release", status: .todo, in: context)
        let created = parent.splitInto(
            [
                BreakdownStep(title: "Write the notes", effortMinutes: 15),
                BreakdownStep(title: "Cut the build", effortMinutes: 15),
                BreakdownStep(title: "Announce it", effortMinutes: 15),
            ], in: context)
        let all = [parent] + created

        #expect(parent.nextOpenStep(among: all)?.title == "Write the notes")
        created[0].complete()
        #expect(parent.nextOpenStep(among: all)?.title == "Cut the build")
        created[1].complete()
        created[2].complete()
        #expect(parent.nextOpenStep(among: all) == nil)
    }

}
