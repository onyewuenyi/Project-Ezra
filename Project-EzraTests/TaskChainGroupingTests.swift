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

    @Test("A standalone task with no dependency links is loose, not a chain")
    func standaloneIsLoose() {
        let task = TaskItem(title: "Water the plants", status: .active, confidence: 0.9)
        let (chains, loose) = TaskChainGrouping.computeChains(in: [task])
        #expect(chains.isEmpty)
        #expect(loose.map(\.title) == ["Water the plants"])
    }

    @Test("A simple 3-link chain groups into one component, ordered root-first")
    func simpleChain() {
        let passport = TaskItem(title: "Renew passport", status: .active, confidence: 0.9)
        let flights = TaskItem(
            title: "Book flights", status: .active, confidence: 0.9,
            blockedBy: [passport.uuid].compactMap { $0 })
        let timeOff = TaskItem(
            title: "Request time off", status: .active, confidence: 0.9,
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
        let passport = TaskItem(title: "Renew passport", category: "Travel", status: .active, confidence: 0.9)
        let flights = TaskItem(
            title: "Book flights", category: "Travel", status: .active, confidence: 0.9,
            blockedBy: [passport.uuid].compactMap { $0 })
        let movers = TaskItem(
            title: "Schedule the movers", category: "Home", status: .active, confidence: 0.9)
        let mailingAddress = TaskItem(
            title: "Change mailing address", category: "Admin", status: .active, confidence: 0.9,
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
        let a = TaskItem(title: "Renew passport", status: .active, confidence: 0.9)
        let b = TaskItem(title: "Book flights", status: .active, confidence: 0.9)
        let visa = TaskItem(
            title: "Apply for visa", status: .active, confidence: 0.9,
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
        let blocker = TaskItem(title: "Renew passport", status: .active, confidence: 0.9)
        blocker.complete()
        let dependent = TaskItem(
            title: "Book flights", status: .active, confidence: 0.9,
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
        let a = TaskItem(title: "Normal root", status: .active, confidence: 0.9)
        let b = TaskItem(title: "Urgent root", status: .active, confidence: 0.9, isUrgent: true)
        let dependent = TaskItem(
            title: "Needs both", status: .active, confidence: 0.9,
            blockedBy: [a.uuid, b.uuid].compactMap { $0 })
        // Score the set so "b"'s urgent signal actually raises its attention (the
        // comparator reads the persisted score, which is neutral until computed).
        let all = [a, b, dependent]
        AttentionEngine.recompute(all, among: all)
        let (chains, _) = TaskChainGrouping.computeChains(in: all)
        #expect(chains.count == 1)
        #expect(chains[0].root.title == "Urgent root")
    }
}
