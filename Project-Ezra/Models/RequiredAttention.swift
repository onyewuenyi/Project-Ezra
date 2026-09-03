//
//  RequiredAttention.swift
//  Project-Ezra
//
//  **The master metric: how much human effort Ezra needs to turn life chaos into
//  progress.** It is the measurable form of "Managing Chaos. Effortlessly." — and the
//  reason it exists as one metric family rather than five scattered numbers is that the
//  unit of optimization is effort reduction across the WHOLE loop. A stronger model in one
//  stage that doesn't reduce net user effort is not progress; it's spend.
//
//  Four dimensions fall, one rises:
//
//    capture attention      how much correction does Ramble require?           ↓
//    orientation attention  how much manual sorting remains after the Brief?   ↓
//    execution attention    how many steps stand between advice and progress?  ↓
//    maintenance attention  how much manual upkeep is required afterward?      ↓
//    progression lift       do advised tasks move more than silent ones?       ↑
//
//  **A smarter product that demands more interaction has failed.** That is the whole
//  point of measuring it this way: every one of these can be made worse by a feature that
//  looks like an improvement. A more talkative Advisor raises execution attention. A Brief
//  that hedges raises orientation attention. A capture model that guesses more raises
//  capture attention. The scorecard is what makes those regressions visible.
//
//  Pure derivations over data the store already holds — the `Metrics.acceptanceRate`
//  pattern, for the same reason: a derived number cannot drift from reality, and nothing
//  here needs a new counter, a new entity, or a schema change.
//
//  **Local only, DEBUG-surfaced, never transmitted, and never shown as a score.** These
//  are instrument readings for whoever is building the product, not a report card for the
//  user — a productivity dashboard is precisely the cognitive work this product exists to
//  remove (principle 10, and the Brief's dashboard prohibition).
//

import Foundation

struct RequiredAttention: Equatable {

    /// One dimension's reading. Nil rate = not enough data to claim anything, which is
    /// deliberately distinct from zero: "no corrections needed" and "nothing captured yet"
    /// are opposite findings that would otherwise print identically.
    struct Reading: Equatable {
        var numerator = 0
        var denominator = 0
        var rate: Double? { denominator == 0 ? nil : Double(numerator) / Double(denominator) }

        var display: String {
            guard let rate else { return "—" }
            return String(format: "%.2f", rate)
        }
    }

    /// Corrections per confirmed task. The confirm card is the one human-in-the-loop
    /// moment in capture, so every edit there is a unit of work Ramble made the user do.
    /// Falls as the model and the learned rules get better at this person's life.
    var capture = Reading()

    /// Share of the day's worked tasks that the Brief did NOT put in front of the user.
    ///
    /// The Brief's job is attention compression: sixty open items into the few that
    /// matter. When someone works a task the Brief never surfaced, they found it
    /// themselves — that is the manual sorting the Brief was supposed to remove. Falls as
    /// selection improves.
    var orientation = Reading()

    /// Advisor interventions per advised task. One intervention → progress reads like an
    /// intelligent coworker; advise → act → advise → act reads agentic and annoying.
    /// Falls as the judgment gets sharper (and, notably, rises if the Advisor gets
    /// chattier — which is the regression this dimension is here to catch).
    var execution = Reading()

    /// Manual field edits per live task — the upkeep tax. Every `edited` entry is the user
    /// maintaining state the system was supposed to maintain for them. Falls as inference
    /// and defaults improve.
    var maintenance = Reading()

    /// Does advised work move more than comparable silent work? The one number that rises,
    /// and the only one that can falsify the Advisor. Nil until both cohorts exist —
    /// see `AdvisorMetrics.progression(among:)`.
    var progressionLift: Double?

    /// Derive the whole scorecard.
    ///
    /// `plannedTaskIDs` is the set the Brief surfaced (today's cached plan). Passing it in
    /// rather than reading the cache here keeps this a pure function over values, which is
    /// what makes every row testable without standing up a day.
    ///
    /// **Nil means nothing surfaced anything today** (the day answer — `HouseholdChatFloor`'s
    /// `.today` shape — stamps `lastSurfacedAt` on what it names; the Brief used to),
    /// which leaves orientation unread rather than perfect. An EMPTY set says "the answer ran
    /// and surfaced nothing", so every worked task counts as unsurfaced and the dimension
    /// reads 100% — a true and damning result. Nil says "nothing was measured", and the
    /// scorecard's own rule is that those two must never print the same.
    static func measure(
        tasks: [TaskItem],
        entries: [ChangeLogEntry],
        corrections: [Correction],
        plannedTaskIDs: Set<UUID>?,
        advisor: AdvisorMetrics,
        now: Date = Date()
    ) -> RequiredAttention {
        var scorecard = RequiredAttention()

        // ── Capture: corrections per confirmed task ──
        let confirmed = tasks.filter { $0.confirmedAt != nil }
        scorecard.capture = Reading(numerator: corrections.count, denominator: confirmed.count)

        // ── Orientation: worked-but-unsurfaced share ──
        // "Worked" is deliberately lifecycle movement rather than opens: opening a task to
        // look at it is not work, and counting it would reward a Brief that made people
        // browse.
        //
        // No Brief at all leaves this at its zero-denominator default, which reads `—`.
        if let plannedTaskIDs {
            let calendar = Calendar.current
            let workedToday = tasks.filter { task in
                guard let touched = task.lastHumanTouchAt else { return false }
                return calendar.isDate(touched, inSameDayAs: now) && task.status != .todo
            }
            let unsurfaced = workedToday.filter { task in
                guard let id = task.uuid else { return false }
                return !plannedTaskIDs.contains(id)
            }
            scorecard.orientation = Reading(
                numerator: unsurfaced.count, denominator: workedToday.count)
        }

        // ── Execution: interventions per advised task ──
        let advisedTaskCount = Set(advisor.actedEvents.map(\.taskID)).count
        scorecard.execution = Reading(
            numerator: advisor.actedEvents.count, denominator: advisedTaskCount)

        // ── Maintenance: manual edits per live task ──
        let edits = entries.filter { $0.action == ChangeLogEntry.editedAction }
        let live = tasks.filter { !$0.status.isResolved }
        scorecard.maintenance = Reading(numerator: edits.count, denominator: live.count)

        scorecard.progressionLift = advisor.progression(among: tasks).lift
        return scorecard
    }

    /// The DEBUG readout. One line, because the dimensions only mean something together —
    /// four falling numbers and one rising one is the shape of the product working.
    var footerLine: String {
        var parts = [
            "attention: cap \(capture.display)",
            "orient \(orientation.display)",
            "exec \(execution.display)",
            "maint \(maintenance.display)",
        ]
        if let progressionLift {
            let points = Int((progressionLift * 100).rounded())
            parts.append("lift \(points >= 0 ? "+" : "")\(points)pt")
        } else {
            parts.append("lift —")
        }
        return parts.joined(separator: " · ")
    }
}
