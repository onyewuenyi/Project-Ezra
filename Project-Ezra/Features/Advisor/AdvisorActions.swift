//
//  AdvisorActions.swift
//  Project-Ezra
//
//  The moves an Advisor reading can be acted on with — one implementation, two
//  callers. The reading used to live only in the detail page's body, so its actions
//  lived in `TaskDetailView` as private functions. Now the reading opens the task's
//  CHAT (the page keeps one line in the bar), and the same moves have to be
//  performable from there: choose an option, pin as a decision, create the steps,
//  do it now / defer / let it go. Two copies of "accept a breakdown" — with its
//  Corrections for declined steps, its Undo pill wired to the split entry's own
//  revert, and its reclassification — would have drifted by the second week.
//
//  Every move funnels through `acted(_:)`: the acted metric (recording the status it
//  acted FROM, the progression baseline), the stall-clearing rule (`touchHuman` while
//  a stall diagnosis is present — a card its own buttons can't dismiss is a scold),
//  and the haptic pulse the caller owns.
//

import CoreData
import SwiftUI

@MainActor
struct AdvisorActions {
    let task: TaskItem
    let allTasks: [TaskItem]
    let context: NSManagedObjectContext
    /// The Undo pill's home — the pager's, so a resolution that slides the page away
    /// doesn't take its own way back with it.
    let notice: Binding<UndoNotice?>
    /// The task left the working set (done / let go) — the pager advances.
    let onResolved: () -> Void
    /// A haptic beat per move, owned by the presenting view's `sensoryFeedback`.
    let pulse: () -> Void

    /// Every Advisor action funnels here — see the header.
    func acted(_ move: AdvisorMove, _ action: () -> Void) {
        AdvisorMetrics.shared.recordActed(move, taskID: task.uuid, status: task.status)
        if StallDetector.diagnose(task, among: allTasks) != nil {
            task.touchHuman()
        }
        pulse()
        action()
    }

    /// Mark the decision made, with the outcome on the record when one was named.
    func markDecided(choice: String?) {
        acted(.decide) {
            Motion.withMotion(Motion.decide) {
                task.resolveDecisionAndLog(in: context, choice: choice)
            }
            if !context.saveChanges() { notice.wrappedValue = .saveFailed() }
        }
    }

    /// Pin as a decision — the human accepting the reading's "this is a choice".
    func escalate() {
        acted(.decide) {
            Motion.withMotion(Motion.decide) {
                task.escalateToDecision()
                task.touchHuman()
            }
            if !context.saveChanges() { notice.wrappedValue = .saveFailed() }
        }
    }

    /// Accept a breakdown: the selected steps become real child tasks.
    ///
    /// `proposed` is the full set the model offered, so each deselection is recorded as
    /// a `Correction` — the user telling the model it over-reached is exactly the
    /// signal the correction loop wants, and it exists nowhere else.
    func createSteps(accepted steps: [BreakdownStep], proposed: [BreakdownStep]) {
        guard !steps.isEmpty else { return }
        acted(.createSteps) {
            Motion.withMotion(Motion.decide) {
                task.splitInto(steps, in: context)
            }
            let kept = Set(steps.map(\.title))
            for declined in proposed where !kept.contains(declined.title) {
                context.insert(
                    Correction(
                        taskUUID: task.uuid, captureID: task.captureID,
                        fieldCorrected: "split", aiValue: declined.title, userValue: "declined",
                        in: context))
            }
            guard context.saveChanges() else {
                notice.wrappedValue = .saveFailed()
                return
            }
            // A task that has just become a container is a different kind of work than
            // it was a moment ago — re-read axis 2 through the one classifier write.
            reclassifyWorkIntent()
            // The same pill a resolution gets. An AI-authored structural act with no
            // in-place receipt made the page reshape FEEL unilateral. Undo routes
            // through `ChangeLogUndo.revert` (the split entry's own arm), so there is
            // exactly one revert path and this pill cannot drift from it.
            let count = steps.count
            let taskUUID = task.uuid
            let undoContext = context
            notice.wrappedValue = UndoNotice(
                message: "Split into \(count) step\(count == 1 ? "" : "s")"
            ) {
                let request = NSFetchRequest<ChangeLogEntry>(entityName: "ChangeLogEntry")
                request.predicate = NSPredicate(
                    format: "action == %@ AND taskUUID == %@ AND undone == NO",
                    "split", (taskUUID ?? UUID()) as CVarArg)
                request.sortDescriptors = [
                    NSSortDescriptor(keyPath: \ChangeLogEntry.timestamp, ascending: false)
                ]
                request.fetchLimit = 1
                guard let entry = try? undoContext.fetch(request).first else { return }
                ChangeLogUndo.revert(entry, in: undoContext)
                if !undoContext.saveChanges() { notice.wrappedValue = .saveFailed() }
            }
        }
    }

    /// A lifecycle move from the reading's fallback links (do it now / let it go).
    func setStatus(_ state: TaskStatus) {
        guard state != task.status else { return }
        acted(.advise) {
            Motion.withMotion(Motion.decide) { task.setStatus(state, in: context) }
            guard context.saveChanges() else {
                notice.wrappedValue = .saveFailed()
                return
            }
            if state.isResolved {
                let task = self.task
                let context = self.context
                notice.wrappedValue = .resolution(
                    state == .canceled ? "Canceled" : "Completed", task.title,
                    unblocked: [], steps: task.stepProgress(among: allTasks)
                ) {
                    task.reopenAndReblock(in: context)
                    if !context.saveChanges() { notice.wrappedValue = .saveFailed() }
                }
                onResolved()
            }
        }
    }

    /// Defer a week — the reading's "not now" move.
    func deferWeek() {
        acted(.advise) {
            let cal = Calendar.current
            let date = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: Date()))
            guard date != task.dueDate else { return }
            let old = task.dueDate
            task.dueDate = date
            let summary = date.map { "Set due date to \(Self.dueText($0))" } ?? "Cleared due date"
            task.logHumanEdit(
                field: "dueDate", oldValue: ChangeLogEntry.encodeDate(old),
                newValue: ChangeLogEntry.encodeDate(date), summary: summary, in: context)
            if !context.saveChanges() { notice.wrappedValue = .saveFailed() }
        }
    }

    /// Navigation counted as an advisor move — the reading pointed somewhere and the
    /// person went.
    func followed(_ move: AdvisorMove) {
        acted(move) {}
    }

    private func reclassifyWorkIntent() {
        guard !task.status.isResolved else { return }
        let snapshot = WorkIntentContext(task: task, among: allTasks)
        let task = self.task
        let context = self.context
        Task {
            let outcome = await WorkIntentClassifier().classify(snapshot)
            guard case .success(let intent) = outcome, !Task.isCancelled else { return }
            task.reclassify(to: intent, in: context)
            context.saveChanges()
        }
    }

    private static func dueText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}
