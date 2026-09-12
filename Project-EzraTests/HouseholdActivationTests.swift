//
//  HouseholdActivationTests.swift
//  Project-EzraTests
//
//  The launch plan's household metrics as pure derivations (`HouseholdActivation`):
//  activated = both caretakers acted inside seven days of the household becoming shared;
//  retained = any caretaker acted in the trailing week; a single caretaker is tracked, not
//  counted. The anchor is the accepted invitation, never the household's creation.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Household activation and retention")
struct HouseholdActivationTests {

    private let context = PersistenceStack.scratch
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func captured(by creator: UUID, at: Date) -> TaskItem {
        let task = TaskItem(title: "Something \(UUID().uuidString.prefix(4))", in: context)
        task.creatorID = creator
        task.confirmedAt = at
        return task
    }

    private func completion(by actor: UUID, at: Date) -> ChangeLogEntry {
        ChangeLogEntry(
            summary: "Completed", action: "completed", initiatedBy: .human, actorID: actor, timestamp: at,
            in: context)
    }

    @Test("One caretaker is tracked, never counted, however much they do")
    func singleCaretaker() {
        let me = UUID()
        let reading = HouseholdActivation.measure(
            caretakers: [me], anchor: now.addingTimeInterval(-3600),
            tasks: [captured(by: me, at: now)], entries: [completion(by: me, at: now)], now: now)
        #expect(reading.standing == .singleCaretaker)
        #expect(reading.retainedThisWeek)
    }

    @Test("Activated needs BOTH caretakers to act inside the window; one is pending, then lapsed")
    func bothMustAct() {
        let me = UUID(), partner = UUID()
        let anchor = now.addingTimeInterval(-2 * 24 * 3600)
        let onlyMe = HouseholdActivation.measure(
            caretakers: [me, partner], anchor: anchor,
            tasks: [captured(by: me, at: now.addingTimeInterval(-3600))], entries: [], now: now)
        #expect(onlyMe.standing == .pending)
        #expect(onlyMe.activeInWindow == [me])

        let both = HouseholdActivation.measure(
            caretakers: [me, partner], anchor: anchor,
            tasks: [captured(by: me, at: now.addingTimeInterval(-3600))],
            entries: [completion(by: partner, at: now.addingTimeInterval(-60))], now: now)
        #expect(both.standing == .activated)

        let late = HouseholdActivation.measure(
            caretakers: [me, partner], anchor: now.addingTimeInterval(-9 * 24 * 3600),
            tasks: [captured(by: me, at: now.addingTimeInterval(-3600))], entries: [], now: now)
        #expect(late.standing == .lapsed, "the window closed with one actor")
    }

    @Test("An act BEFORE the anchor does not count — the owner's months of solo use are not activation")
    func actsBeforeAnchorDoNotCount() {
        let me = UUID(), partner = UUID()
        let anchor = now.addingTimeInterval(-24 * 3600)
        let reading = HouseholdActivation.measure(
            caretakers: [me, partner], anchor: anchor,
            tasks: [captured(by: me, at: anchor.addingTimeInterval(-30 * 24 * 3600))],
            entries: [completion(by: partner, at: now)], now: now)
        #expect(reading.standing == .pending)
        #expect(reading.activeInWindow == [partner])
    }

    @Test("Retained reads the trailing week only; an undone completion is not an act")
    func retention() {
        let me = UUID(), partner = UUID()
        let stale = HouseholdActivation.measure(
            caretakers: [me, partner], anchor: now.addingTimeInterval(-60 * 24 * 3600),
            tasks: [captured(by: me, at: now.addingTimeInterval(-10 * 24 * 3600))], entries: [], now: now)
        #expect(!stale.retainedThisWeek)

        let undone = completion(by: partner, at: now.addingTimeInterval(-3600))
        undone.undone = true
        let reverted = HouseholdActivation.measure(
            caretakers: [me, partner], anchor: now.addingTimeInterval(-60 * 24 * 3600),
            tasks: [], entries: [undone], now: now)
        #expect(!reverted.retainedThisWeek)
    }

    @Test("The anchor is the earliest ACCEPTED invitation, else the household's creation")
    func anchorIsAcceptance() {
        let household = Household(in: context)
        #expect(HouseholdActivation.anchor(for: household) == household.createdAt)
        let pending = Invitation(in: context)
        pending.household = household
        #expect(HouseholdActivation.anchor(for: household) == household.createdAt, "pending does not anchor")
        let accepted = Invitation(in: context)
        accepted.household = household
        accepted.accept(now: now)
        #expect(HouseholdActivation.anchor(for: household) == now)
    }

    @Test("Caretakers are live adults — children and pets are planned for, not counted")
    func caretakersAreAdults() {
        let household = Household(in: context)
        let owner = FamilyMember(name: "Me", role: .owner, in: context)
        let partner = FamilyMember(name: "Maya", relationship: .partner, in: context)
        let child = FamilyMember(name: "Kid", relationship: .child, in: context)
        let gone = FamilyMember(name: "Ex", in: context)
        gone.deletedAt = now
        for member in [owner, partner, child, gone] { member.household = household }
        #expect(Set(HouseholdActivation.caretakerIDs(in: household)) == [owner.uuid, partner.uuid])
    }

    @Test("The activation bit leaves once per install")
    func recordedOnce() {
        let defaults = UserDefaults(suiteName: "HouseholdActivationTests.\(UUID())")!
        let sink = RecordingTelemetrySink()
        let previous = Telemetry.sink
        Telemetry.sink = sink
        defer { Telemetry.sink = previous }
        let me = UUID(), partner = UUID()
        let activated = HouseholdActivation.measure(
            caretakers: [me, partner], anchor: now.addingTimeInterval(-3600),
            tasks: [captured(by: me, at: now)], entries: [completion(by: partner, at: now)], now: now)
        HouseholdActivation.recordIfNewlyActivated(activated, defaults: defaults)
        HouseholdActivation.recordIfNewlyActivated(activated, defaults: defaults)
        #expect(sink.events.filter { $0.name == "household_activated" }.count == 1)
    }
}
