//
//  DayAnswerTests.swift
//  Project-EzraTests
//
//  The home's first line, composed (2026-09-23): a reason on every row, time pressure
//  ahead of judgment, decisions collapsed to their oldest, outcomes over their steps,
//  the voice of the hour, the quick shape, the stall line, the way to the rest.
//

import Foundation
import Testing

@testable import Project_Ezra

@Suite("The day answer — composed, not recited")
struct ComposedDayAnswerTests {

    private let you = UUID()
    private let maya = UUID()

    private func at(hour: Int) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = 30
        return Calendar.current.date(from: components)!
    }

    private func line(
        _ title: String, owner: UUID? = nil, due: Int? = nil, urgent: Bool = false, decision: Bool = false,
        blockers: [String] = [], status: TaskStatus = .todo, effort: Int? = nil, touchedDaysAgo: Double = 0,
        parent: UUID? = nil, steps: (Int, Int) = (0, 0), sortIndex: Int = 0, now: Date, id: UUID = UUID()
    ) -> HouseholdChatFacts.Line {
        HouseholdChatFacts.Line(
            id: id, title: title, category: "Home", status: status,
            ownerName: owner == you ? "You" : owner == maya ? "Maya" : nil, ownerID: owner ?? you,
            dueDate: due.map { now.addingTimeInterval(Double($0) * 86_400) }, daysUntilDue: due,
            isUrgent: urgent, needsDecision: decision, blockerTitles: blockers, externalWaits: [],
            effortMinutes: effort, updatedAt: now.addingTimeInterval(-touchedDaysAgo * 86_400),
            parentID: parent, stepsDone: steps.0, stepsTotal: steps.1, sortIndex: sortIndex)
    }

    private func facts(
        _ open: [HouseholdChatFacts.Line], now: Date, done: [HouseholdChatFacts.Done] = []
    )
        -> HouseholdChatFacts
    {
        var facts = HouseholdChatFacts(
            now: now,
            members: [.init(id: you, name: "You", isYou: true), .init(id: maya, name: "Maya", isYou: false)],
            open: open, done: done)
        // Rank as the list would: decisions first, then the rest in the given order.
        facts.rankOrder = open.filter(\.needsDecision).map(\.id) + open.filter { !$0.needsDecision }.map(\.id)
        return facts
    }

    @Test("Four stalled decisions no longer outrank the overdue bill; they collapse to the oldest, after it")
    func decisionsCollapseBehindTimePressure() {
        let now = at(hour: 9)
        let open = [
            line("Deal with the thing from last week", decision: true, touchedDaysAgo: 9, now: now),
            line("Side project worth it?", decision: true, touchedDaysAgo: 4, now: now),
            line("Follow up with old client", decision: true, touchedDaysAgo: 2, now: now),
            line("Cancel streaming", decision: true, touchedDaysAgo: 1, now: now),
            line("Pay the water bill", due: -1, urgent: true, status: .doing, now: now),
            line("Submit expense report", due: 2, now: now),
            line("Water the plants", now: now),
        ]
        let composed = DayAnswer.compose(facts: facts(open, now: now), person: nil)
        #expect(composed.text == "4 things deserve you first.")
        #expect(
            composed.rows.map(\.title) == [
                "Pay the water bill", "Deal with the thing from last week", "Submit expense report",
                "Water the plants",
            ])
        #expect(composed.reasons[open[4].id] == "1 day overdue")
        #expect(composed.reasons[open[0].id] == "Oldest of 4 decisions waiting · 9 days")
        #expect(composed.reasons[open[5].id] == "Due in 2 days")
        #expect(composed.reasons[open[6].id] == "Nothing in the way")
        // The list's own order is untouched: the facts still rank the decisions first.
        #expect(composed.rows.count == 4)
    }

    @Test("A single decision keeps its own reason and its seat behind the pressed rows")
    func singleDecision() {
        let now = at(hour: 9)
        let open = [
            line("Pick a summer camp", decision: true, touchedDaysAgo: 1, now: now),
            line("Call the pharmacy", due: 0, now: now),
        ]
        let composed = DayAnswer.compose(facts: facts(open, now: now), person: nil)
        #expect(composed.rows.map(\.title) == ["Call the pharmacy", "Pick a summer camp"])
        #expect(composed.reasons[open[0].id] == "Needs a decision · since yesterday")
        #expect(composed.reasons[open[1].id] == "Due today")
    }

    @Test("Every row carries a reason, and the graph clause names the person waiting before the count")
    func reasons() {
        let now = at(hour: 10)
        let photos = line("Get passport photos", effort: 15, now: now)
        let passport = line("Renew passport", owner: maya, blockers: ["Get passport photos"], now: now)
        let flights = line("Book flights", blockers: ["Renew passport"], now: now)
        let started = line("Fix the gate", status: .doing, touchedDaysAgo: 3, now: now)
        let stale = line("Reorganize the garage", touchedDaysAgo: 12, now: now)
        let quick = line("Water the plants", effort: 5, now: now)
        let composed = DayAnswer.compose(
            facts: facts([photos, passport, flights, started, stale, quick], now: now), person: nil)
        #expect(composed.reasons[photos.id] == "Maya is waiting on this")
        #expect(composed.reasons[started.id] == "Started, untouched 3 days")
        let dated = line("Submit the report", due: 2, status: .doing, now: now)
        #expect(
            DayAnswer.compose(facts: facts([dated], now: now), person: nil).reasons[dated.id]
                == "In progress · Due in 2 days")
        #expect(composed.reasons[stale.id] == "Untouched 12 days")
        #expect(composed.reasons[quick.id] == "Nothing in the way · about 5 min")
        // Blocked rows never seat.
        #expect(!composed.rows.contains { $0.id == passport.id || $0.id == flights.id })
        for row in composed.rows { #expect(composed.reasons[row.id]?.isEmpty == false) }
        // Unblocks N when nobody else owns the dependent.
        let mine = line("Renew passport", blockers: ["Get passport photos"], now: now)
        let alone = DayAnswer.compose(facts: facts([photos, mine], now: now), person: nil)
        #expect(alone.reasons[photos.id] == "Unblocks 1 more")
    }

    @Test("An outcome speaks for its steps and names the next one")
    func outcomesOverSteps() {
        let now = at(hour: 9)
        let umbrellaID = UUID()
        let step1 = line("Renew passport", parent: umbrellaID, sortIndex: 0, now: now)
        let step2 = line(
            "Book flights", blockers: ["Renew passport"], parent: umbrellaID, sortIndex: 1, now: now)
        let umbrella = line("Travel preparation", steps: (1, 3), now: now, id: umbrellaID)
        let composed = DayAnswer.compose(facts: facts([step1, umbrella, step2], now: now), person: nil)
        #expect(composed.rows.map(\.title) == ["Travel preparation"])
        #expect(composed.reasons[umbrellaID] == "Next: Renew passport · 1 of 3 done")
    }

    @Test("The hour frames the lead: first in the morning, still in the evening, quiet at night")
    func voice() {
        let open = [line("Pay the water bill", due: 1, now: at(hour: 9))]
        #expect(
            DayAnswer.compose(facts: facts(open, now: at(hour: 9)), person: nil).text
                == "One thing deserves you first.")
        #expect(
            DayAnswer.compose(facts: facts(open, now: at(hour: 15)), person: nil).text
                == "One thing deserves you first.")
        #expect(
            DayAnswer.compose(facts: facts(open, now: at(hour: 20)), person: nil).text
                == "One thing still deserves you.")
        let empty = facts([], now: at(hour: 21))
        #expect(
            DayAnswer.compose(facts: empty, person: empty.members[0]).text
                == "Nothing more needs you tonight.")
        let morning = facts([line("Hers", owner: maya, now: at(hour: 8))], now: at(hour: 8))
        #expect(
            DayAnswer.compose(facts: morning, person: morning.members[0]).text
                == "Nothing is asking for you today. Maya has 1 open.")
    }

    @Test("The evening recap names what the day closed, and only in the evening")
    func eveningRecap() {
        let now = at(hour: 19)
        let done: [HouseholdChatFacts.Done] = [
            .init(
                id: UUID(), title: "Book the dentist", ownerName: "You",
                completedAt: now.addingTimeInterval(-3600)),
            .init(
                id: UUID(), title: "Order shoes", ownerName: "Maya",
                completedAt: now.addingTimeInterval(-7200)),
            .init(
                id: UUID(), title: "Old one", ownerName: "You",
                completedAt: now.addingTimeInterval(-3 * 86_400)),
        ]
        let recap = DayAnswer.eveningRecap(facts: facts([], now: now, done: done))
        #expect(recap?.text == "Today, you finished “Book the dentist”; Maya finished “Order shoes”.")
        #expect(recap?.citedTaskIDs.count == 2)
        #expect(DayAnswer.eveningRecap(facts: facts([], now: at(hour: 10), done: done)) == nil)
        // An act the catch-up already names is not said twice; nothing left → no line.
        let minusMaya = DayAnswer.eveningRecap(
            facts: facts([], now: now, done: done), excluding: [done[1].id])
        #expect(minusMaya?.text == "Today, you finished “Book the dentist”.")
        #expect(
            DayAnswer.eveningRecap(
                facts: facts([], now: now, done: done), excluding: [done[0].id, done[1].id]) == nil)
    }

    @Test(
        "I've got 15 minutes — unblocked work under the ceiling, in rank order, with the minutes as reasons")
    func quick() {
        let now = at(hour: 11)
        let open = [
            line("Water the plants", effort: 5, now: now),
            line("Reorganize the garage", effort: 120, now: now),
            line("Pay the water bill", effort: 15, now: now),
            line("Book flights", blockers: ["Renew passport"], effort: 10, now: now),
            line("Hers", owner: maya, effort: 10, now: now),
        ]
        let facts = facts(open, now: now)
        let mine = HouseholdChatFloor.answer(question: DayAnswer.quickChip, facts: facts)
        // "I've got" resolves to the person asking, so Maya's quick thing stays hers.
        #expect(mine?.citedTaskIDs == [open[0].id, open[2].id])
        #expect(mine?.text == "2 quick things — 15 minutes or less each.")
        #expect(mine?.reasons[open[0].id] == "about 5 min")
        #expect(HouseholdChatFloor.shape(of: "anything quick I can knock out?", facts: facts) == .quick)
        let none = HouseholdChatFloor.answer(
            question: DayAnswer.quickChip, facts: self.facts([open[1]], now: now))
        #expect(none?.text == "Nothing fits in 15 minutes.")
    }

    @Test("The stall line names started work the answer did not seat, and nothing while it is on screen")
    func stallOpener() {
        let now = at(hour: 9)
        let stalled = line("Fix the gate", status: .doing, touchedDaysAgo: 3, now: now)
        let fresh = line("Paint the fence", status: .doing, touchedDaysAgo: 0, now: now)
        let hers = line("Hers", owner: maya, status: .doing, touchedDaysAgo: 5, now: now)
        let facts = facts([stalled, fresh, hers], now: now)
        let opener = DayAnswer.stallOpener(facts: facts, excluding: [])
        #expect(opener?.text == "You started “Fix the gate” 3 days ago and haven't touched it since.")
        #expect(opener?.citedTaskIDs == [stalled.id])
        #expect(DayAnswer.stallOpener(facts: facts, excluding: [stalled.id]) == nil)
        // The scope seats it only when the day answer did not: here it did.
        let scope = HouseholdInquiryScope(facts: facts)
        #expect(scope.openers().count == 1)
    }

    @Test("The way to the rest counts what the answer did not show, for the person it is about")
    func moreInTasks() {
        let now = at(hour: 9)
        let open = (0..<8).map { line("Task \($0)", now: now) } + [line("Hers", owner: maya, now: now)]
        let facts = facts(open, now: now)
        #expect(
            DayAnswer.moreInTasks(facts: facts, person: facts.members[0], shown: 5) == "and 3 more in Tasks")
        #expect(DayAnswer.moreInTasks(facts: facts, person: nil, shown: 5) == "and 4 more in Tasks")
        #expect(DayAnswer.moreInTasks(facts: facts, person: facts.members[0], shown: 8) == nil)
    }

    @Test("Why this first is the floor's answer: the hero's reason, then what follows; a lower row is placed")
    func whyFirst() {
        let now = at(hour: 9)
        let bill = line("Pay the water bill", due: -1, now: now)
        let gym = line("Decide on the gym", decision: true, touchedDaysAgo: 9, now: now)
        let plants = line("Water the plants", effort: 5, now: now)
        let flights = line("Book flights", blockers: ["Renew passport"], now: now)
        let facts = facts([bill, gym, plants, flights], now: now)
        let q = "Why does “Pay the water bill” deserve me first?"
        #expect(HouseholdChatFloor.shape(of: q, facts: facts) == .whyFirst)
        let hero = HouseholdChatFloor.answer(question: q, facts: facts)
        #expect(
            hero?.text
                == "“Pay the water bill” is first because it's 1 day overdue. After it, “Decide on the gym” — it needs a decision and 9 days now."
        )
        #expect(hero?.citedTaskIDs == [bill.id, gym.id])
        let lower = HouseholdChatFloor.answer(
            question: "why does \"Water the plants\" deserve me first", facts: facts)
        #expect(
            lower?.text.hasPrefix(
                "“Water the plants” is number 3 today — nothing is in the way and it's about 5 min. Ahead of it, “Pay the water bill”"
            ) == true)
        #expect(
            DayAnswer.prose("Oldest of 3 decisions waiting · 10 days")
                == "it's the oldest of 3 decisions waiting and 10 days now")
        #expect(
            DayAnswer.prose("Started, untouched 3 days · Due in 2 days")
                == "you started it and haven't touched it for 3 days and it's due in 2 days")
        #expect(DayAnswer.prose("Maya is waiting on this") == "Maya is waiting on it")
        #expect(
            DayAnswer.prose("Next: Renew passport · 1 of 3 done")
                == "its next step is Renew passport and 1 of 3 done")
        let blocked = HouseholdChatFloor.answer(question: "Why this first? “Book flights”", facts: facts)
        #expect(
            blocked?.text.hasPrefix("“Book flights” is not up yet — it's waiting on Renew passport.") == true)
        #expect(DayAnswer.quotedTitle(in: "no quotes here") == nil)
    }

    @Test("What landed during this look, unseated, newest first, capped, live only")
    func landed() {
        let since = Date()
        let older = TaskItem(title: "Older", status: .todo)
        older.confirmedAt = since.addingTimeInterval(-60)
        let first = TaskItem(title: "First", status: .todo)
        first.confirmedAt = since.addingTimeInterval(1)
        let second = TaskItem(title: "Second", status: .todo)
        second.confirmedAt = since.addingTimeInterval(2)
        let shown = TaskItem(title: "Shown", status: .todo)
        shown.confirmedAt = since.addingTimeInterval(3)
        let done = TaskItem(title: "Done", status: .done)
        done.confirmedAt = since.addingTimeInterval(4)
        let unconfirmed = TaskItem(title: "Unconfirmed", status: .todo)
        let all = [older, first, second, shown, done, unconfirmed]
        let landed = DayAnswer.landed(among: all, since: since, shown: [shown.uuid!])
        #expect(landed.map(\.title) == ["Second", "First"])
        #expect(DayAnswer.landed(among: all, since: since, shown: [], cap: 1).map(\.title) == ["Shown"])
    }

    @Test("Reasons ride the opener into the thread")
    func reasonsReachTheStore() {
        let now = at(hour: 9)
        let facts = facts([line("Pay the water bill", due: -2, now: now)], now: now)
        let store = InquiryStore<HouseholdInquiryScope>()
        store.open(scope: HouseholdInquiryScope(facts: facts))
        let first = store.messages(key: HouseholdInquiryScope.singletonKey).first
        #expect(first?.reasons[facts.open[0].id] == "2 days overdue")
    }
}
