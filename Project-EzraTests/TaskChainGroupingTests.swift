//
//  TaskChainGroupingTests.swift
//  Project-EzraTests
//
//  Chain grouping is pure (no NSManagedObjectContext needed) and built entirely on the real
//  `blockedBy` reference graph — these tests exercise connectivity, branching/
//  multi-blocker components, root selection, and topological ordering directly.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("TaskChainGrouping")
struct TaskChainGroupingTests {

    @Test(
        "PrerequisiteIndex answers exactly what activeBlockerTasks + openSteps answer, on a random graph"
    )
    func prerequisiteIndexParity() {
        // The index is `prerequisites(of:within:)`'s implementation — built once per set
        // rather than once per question — so it must be indistinguishable from the two
        // accessors it replaced on every member, in the same order. Randomised so a
        // case nobody authored (a resolved blocker, a step under a resolved parent, a
        // task blocked by its own step) is exercised as well as the obvious ones.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            var tasks: [TaskItem] = []
            for i in 0..<24 {
                let status: TaskStatus = Int.random(in: 0..<5, using: &generator) == 0 ? .done : .todo
                tasks.append(TaskItem(title: "t\(i)", status: status, confidence: 0.9))
            }
            for task in tasks {
                if Int.random(in: 0..<3, using: &generator) == 0 {
                    task.addTaskBlocker(tasks.randomElement(using: &generator)!.uuid!, among: tasks)
                }
                if Int.random(in: 0..<3, using: &generator) == 0 {
                    task.linkParent(tasks.randomElement(using: &generator)!.uuid!)
                }
            }
            let index = TaskChainGrouping.PrerequisiteIndex(tasks)
            for task in tasks {
                let expected = task.activeBlockerTasks(among: tasks) + task.openSteps(among: tasks)
                #expect(index.prerequisites(of: task).map(\.objectID) == expected.map(\.objectID))
            }
        }
    }

    @Test("A container names its group: the umbrella is the caption, its steps are the cards")
    func umbrellaNamesTheGroup() {
        let trip = TaskItem(title: "Trip to Lagos", status: .todo, confidence: 0.9)
        let passport = TaskItem(title: "Renew passport", status: .todo, confidence: 0.9)
        let flights = TaskItem(
            title: "Book flights", status: .todo, confidence: 0.9,
            blockedBy: [passport.uuid!])
        let hotel = TaskItem(title: "Book hotel", status: .todo, confidence: 0.9)
        for step in [passport, flights, hotel] { step.linkParent(trip.uuid!) }
        let all = [hotel, trip, flights, passport]

        let (chains, loose) = TaskChainGrouping.computeChains(in: all)
        #expect(loose.isEmpty)
        #expect(chains.count == 1)
        let chain = chains[0]
        #expect(chain.umbrella?.title == "Trip to Lagos")
        #expect(chain.groupTitle == "Trip to Lagos")
        // The umbrella is never a card, and the front card is actionable: a step that
        // waits on another never leads while one that can move exists.
        #expect(!chain.deckMembers.contains { $0.objectID == trip.objectID })
        #expect(chain.deckMembers.count == 3)
        #expect(chain.root.title != "Book flights")
        #expect(chain.root.objectID == chain.deckMembers.first?.objectID)
    }

    @Test("Siblings under one umbrella page in breakdown order, whatever their attention")
    func siblingsKeepBreakdownOrder() {
        let trip = TaskItem(title: "Trip", status: .todo, confidence: 0.9)
        let first = TaskItem(title: "first", status: .todo, confidence: 0.9)
        let second = TaskItem(title: "second", status: .todo, confidence: 0.9)
        let third = TaskItem(title: "third", status: .todo, confidence: 0.9)
        for (index, step) in [first, second, third].enumerated() {
            step.linkParent(trip.uuid!)
            step.sortIndex = Int32(index)
        }
        // Make the LAST step by breakdown order the most urgent — attention would lead
        // with it; the model's sequence must win among siblings.
        third.isUrgent = true
        let all = [third, second, first, trip]
        let (chains, _) = TaskChainGrouping.computeChains(in: all)
        #expect(chains.count == 1)
        #expect(chains[0].deckMembers.map(\.title) == ["first", "second", "third"])
        #expect(chains[0].root.title == "first")
        // …which is exactly the container's own pointer.
        #expect(trip.nextOpenStep(among: all)?.title == "first")
    }

    @Test("A chain of bare blockers has no umbrella, and every member is a card")
    func bareChainHasNoUmbrella() {
        let a = TaskItem(title: "a", status: .todo, confidence: 0.9)
        let b = TaskItem(title: "b", status: .todo, confidence: 0.9, blockedBy: [a.uuid!])
        let (chains, _) = TaskChainGrouping.computeChains(in: [b, a])
        #expect(chains[0].umbrella == nil)
        #expect(chains[0].deckMembers.count == 2)
        // No name of its own, so the caption tells the chain's story in execution order.
        #expect(chains[0].groupTitle == "a → b")
    }

    @Test("Nested containers: the top-most one names the group")
    func nestedContainersTopMostNames() {
        let outer = TaskItem(title: "outer", status: .todo, confidence: 0.9)
        let inner = TaskItem(title: "inner", status: .todo, confidence: 0.9)
        let leaf = TaskItem(title: "leaf", status: .todo, confidence: 0.9)
        inner.linkParent(outer.uuid!)
        leaf.linkParent(inner.uuid!)
        let (chains, _) = TaskChainGrouping.computeChains(in: [leaf, inner, outer])
        #expect(chains.count == 1)
        #expect(chains[0].umbrella?.title == "outer")
        #expect(chains[0].deckMembers.map(\.title) == ["leaf", "inner"])
    }

    @Test("Done steps leave the deck: the group is the remaining work")
    func doneStepsLeaveTheDeck() {
        let trip = TaskItem(title: "Trip", status: .todo, confidence: 0.9)
        let done = TaskItem(title: "done", status: .todo, confidence: 0.9)
        let open = TaskItem(title: "open", status: .todo, confidence: 0.9)
        for step in [done, open] { step.linkParent(trip.uuid!) }
        done.complete()
        let (chains, loose) = TaskChainGrouping.computeChains(in: [trip, done, open])
        #expect(chains.count == 1)
        #expect(chains[0].deckMembers.map(\.title) == ["open"])
        #expect(loose.map(\.title) == ["done"])
    }

    @Test("A standalone task with no dependency links is loose, not a chain")
    func standaloneIsLoose() {
        let task = TaskItem(title: "Water the plants", status: .todo, confidence: 0.9)
        let (chains, loose) = TaskChainGrouping.computeChains(in: [task])
        #expect(chains.isEmpty)
        #expect(loose.map(\.title) == ["Water the plants"])
    }

    @Test("A simple 3-link chain groups into one component, ordered root-first")
    func simpleChain() {
        let passport = TaskItem(title: "Renew passport", status: .todo, confidence: 0.9)
        let flights = TaskItem(
            title: "Book flights", status: .todo, confidence: 0.9,
            blockedBy: [passport.uuid].compactMap { $0 })
        let timeOff = TaskItem(
            title: "Request time off", status: .todo, confidence: 0.9,
            blockedBy: [flights.uuid].compactMap { $0 })
        let (chains, loose) = TaskChainGrouping.computeChains(in: [timeOff, passport, flights])

        #expect(loose.isEmpty)
        #expect(chains.count == 1)
        let chain = chains[0]
        #expect(chain.members.map(\.title) == ["Renew passport", "Book flights", "Request time off"])
        #expect(chain.root.title == "Renew passport")
    }

    @Test("Two independent chains, in unrelated categories, never merge")
    func independentChainsStaySeparate() {
        let passport = TaskItem(title: "Renew passport", category: "Travel", status: .todo, confidence: 0.9)
        let flights = TaskItem(
            title: "Book flights", category: "Travel", status: .todo, confidence: 0.9,
            blockedBy: [passport.uuid].compactMap { $0 })
        let movers = TaskItem(
            title: "Schedule the movers", category: "Home", status: .todo, confidence: 0.9)
        let mailingAddress = TaskItem(
            title: "Change mailing address", category: "Admin", status: .todo, confidence: 0.9,
            blockedBy: [movers.uuid].compactMap { $0 })

        let (chains, loose) = TaskChainGrouping.computeChains(
            in: [passport, flights, movers, mailingAddress])

        #expect(loose.isEmpty)
        #expect(chains.count == 2)
        let roots = Set(chains.map(\.root.title))
        #expect(roots == ["Renew passport", "Schedule the movers"])
    }

    @Test("A task blocked by two others in the same set forms one 3-member chain")
    func multiBlockerFormsOneComponent() {
        let a = TaskItem(title: "Renew passport", status: .todo, confidence: 0.9)
        let b = TaskItem(title: "Book flights", status: .todo, confidence: 0.9)
        let visa = TaskItem(
            title: "Apply for visa", status: .todo, confidence: 0.9,
            blockedBy: [a.uuid, b.uuid].compactMap { $0 })
        let (chains, loose) = TaskChainGrouping.computeChains(in: [a, b, visa])

        #expect(loose.isEmpty)
        #expect(chains.count == 1)
        #expect(chains[0].members.count == 3)
        // Visa depends on both, so it must be placed after both roots.
        let order = chains[0].members.map(\.title)
        #expect(order.last == "Apply for visa")
    }

    @Test("A done blocker contributes no edge — its dependent is loose, not chained")
    func doneBlockerBreaksTheEdge() {
        let blocker = TaskItem(title: "Renew passport", status: .todo, confidence: 0.9)
        blocker.complete()
        let dependent = TaskItem(
            title: "Book flights", status: .todo, confidence: 0.9,
            blockedBy: [blocker.uuid].compactMap { $0 })
        // Only the still-active set would normally reach this function (Tasks screen
        // scope excludes .done), but even if a done task were present, activeBlockers
        // already excludes it — so there's no edge to form.
        let (chains, loose) = TaskChainGrouping.computeChains(in: [dependent])
        #expect(chains.isEmpty)
        #expect(loose.map(\.title) == ["Book flights"])
    }

    @Test("Root selection picks whichever root sorts first under focusOrder")
    func rootPicksMostUrgentAmongMultipleRoots() {
        // Two independent roots (a fan-in): urgent "b" should out-anchor normal "a".
        let a = TaskItem(title: "Normal root", status: .todo, confidence: 0.9)
        let b = TaskItem(title: "Urgent root", status: .todo, confidence: 0.9, isUrgent: true)
        let dependent = TaskItem(
            title: "Needs both", status: .todo, confidence: 0.9,
            blockedBy: [a.uuid, b.uuid].compactMap { $0 })
        // Score the set so "b"'s urgent signal actually raises its attention (the
        // comparator reads the persisted score, which is neutral until computed).
        let all = [a, b, dependent]
        AttentionEngine.recompute(all, among: all)
        let (chains, _) = TaskChainGrouping.computeChains(in: all)
        #expect(chains.count == 1)
        #expect(chains[0].root.title == "Urgent root")
    }

    @Test("Chain root follows the caller's rank keys, not a member-only re-rank")
    func rootFollowsCallerKeys() {
        // A fan-in: two independent roots feed one dependent.
        let a = TaskItem(title: "Root A", status: .todo, confidence: 0.9)
        let b = TaskItem(title: "Root B", status: .todo, confidence: 0.9)
        let dependent = TaskItem(
            title: "Needs both", status: .todo, confidence: 0.9,
            blockedBy: [a.uuid, b.uuid].compactMap { $0 })
        let members = [a, b, dependent]

        func key(_ t: TaskItem, attention: Double) -> RankKey {
            RankKey(
                needsDecision: false, isBlocked: t.hasActiveBlockers(among: members),
                effectiveAttention: attention, isBlocking: false, isOverdue: false,
                dueDate: nil, createdAt: t.createdAt, id: t.uuid!)
        }

        // Keys the LANE positions the chain under decide the front card — so root
        // selection and lane placement can never disagree (the population-dependence bug,
        // where a member-only re-rank saw different relevance/blocking terms).
        let bWins: [UUID: RankKey] = [
            a.uuid!: key(a, attention: 10), b.uuid!: key(b, attention: 90),
            dependent.uuid!: key(dependent, attention: 50),
        ]
        #expect(
            TaskChainGrouping.computeChains(in: members, rankKeys: bWins).chains.first?.root.title
                == "Root B")

        // Flip the keys → the OTHER root wins, proving the passed keys drive selection.
        let aWins: [UUID: RankKey] = [
            a.uuid!: key(a, attention: 90), b.uuid!: key(b, attention: 10),
            dependent.uuid!: key(dependent, attention: 50),
        ]
        #expect(
            TaskChainGrouping.computeChains(in: members, rankKeys: aWins).chains.first?.root.title
                == "Root A")
    }
}
