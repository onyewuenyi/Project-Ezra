//
//  ChangeLogUndo.swift
//  Project-Ezra
//
//  The action-aware revert behind the Inbox feed's per-entry Undo. Every change-log
//  entry — AI-initiated or human — knows how to be reversed by its `action` verb, so
//  the feed can offer a single Undo that does the right thing per action rather than
//  one blunt "send it to the Inbox". Extracted from the old AI-trail so the logic
//  lives in one testable place.
//
//  The critical rule: a HUMAN "completed"/"killed" undoes by *reopening* (restoring
//  the exact prior status via the timeline) — NEVER the AI's inbox fallback, which
//  would wrongly strand a finished task awaiting re-confirm.
//

import CoreData

@MainActor
enum ChangeLogUndo {
    /// Reverse the effect of `entry` on its linked task, keyed on the action verb.
    /// Callers still mark the entry `undone` and `save()`.
    static func revert(_ entry: ChangeLogEntry, in context: NSManagedObjectContext) {
        guard let task = linkedTask(for: entry, in: context) else { return }
        switch entry.action {
        case "linked":
            // An edge the AI added at capture — undo removes exactly that edge; the task
            // itself is untouched. `fieldChanged` says which kind: a parent link or a blocker.
            guard let idString = entry.newValue, let targetID = UUID(uuidString: idString)
            else { return }
            if entry.fieldChanged == "parent" {
                task.unlinkParent(targetID)
            } else {
                task.removeTaskBlockerEdges(to: targetID, among: fetchAll(in: context))
            }
        case "merged":
            // A capture folded into `task` (the merge target) — undo resurrects the folded
            // draft as a fresh inbox item from the JSON snapshot. The merge destroyed no
            // data; the target keeps its (harmless) capture note.
            guard let snapshot = MergedTaskSnapshot.decode(entry.oldValue) else { return }
            let resurrected = TaskItem(
                title: snapshot.title, category: snapshot.category, status: .inbox,
                reasoning: snapshot.reasoning, isUrgent: snapshot.isUrgent, in: context)
            context.insert(resurrected)
            AttentionEngine.recompute([resurrected], among: fetchAll(in: context))
        case "completed", "killed":
            // Human resolution → reopen to the prior status. NEVER the inbox fallback.
            task.reopenAndReblock(in: context)
        case "assigned":
            // Restore the previous owner (nil oldValue = it was shared/unowned).
            let previous = entry.oldValue.flatMap { UUID(uuidString: $0) }
            task.claim(ownerID: previous, among: fetchAll(in: context))
        case "decided":
            // The human's "Mark decided" re-escalates to the open decision.
            task.escalateToDecision()
        case ChangeLogEntry.editedAction:
            // A manual field edit → restore the named field from `oldValue`. Writes go
            // through the raw property / `setStage` (NOT the logged seams), so the revert
            // never spawns a fresh "edited" entry. Undone entries stay in the timeline
            // struck through; the caller marks `undone` + saves.
            switch entry.fieldChanged {
            case "urgent":
                task.isUrgent = entry.oldValue == "true"
                AttentionEngine.recompute([task], among: fetchAll(in: context))
            case "category":
                if let value = entry.oldValue { task.category = value }
            case "effortMinutes":
                task.effortMinutes = entry.oldValue.flatMap { Int($0) }
            case "dueDate":
                task.dueDate = ChangeLogEntry.decodeDate(entry.oldValue)  // nil clears it
            case "title":
                if let value = entry.oldValue { task.title = value }
            case "notes":
                task.notes = entry.oldValue
            case "stage":
                if let display = entry.oldValue.flatMap(TaskDisplayStatus.init(rawValue:)),
                    let stage = display.asStage
                {
                    task.setStage(stage)
                }
            case "blockers":
                // Add-undo removes the edge it created (matched by target task id, as the
                // "linked" case does). A blocker *removal* is logged non-reversible.
                if let idString = entry.newValue, let blockerTaskID = UUID(uuidString: idString) {
                    task.removeTaskBlockerEdges(to: blockerTaskID, among: fetchAll(in: context))
                }
            default:
                break
            }
            task.touch()
        default:
            // filed / archived / unblocked / anything else → reopen if resolved, then
            // return control to the human in the Inbox.
            if task.status.isResolved { task.reopenAndReblock(in: context) }
            task.status = .inbox
        }
    }

    /// The task an entry points at: by stable uuid first, then a title fallback for
    /// pre-uuid entries (matched among unresolved tasks).
    static func linkedTask(for entry: ChangeLogEntry, in context: NSManagedObjectContext) -> TaskItem? {
        if let targetUUID = entry.taskUUID {
            let descriptor = NSFetchRequest<TaskItem>(entityName: "TaskItem")
            descriptor.predicate = NSPredicate(format: "uuid == %@", targetUUID as CVarArg)
            descriptor.fetchLimit = 1
            if let match = try? context.fetch(descriptor).first { return match }
        }
        guard let title = entry.taskTitle else { return nil }
        let descriptor = NSFetchRequest<TaskItem>(entityName: "TaskItem")
        descriptor.predicate = NSPredicate(format: "title == %@", title)
        return (try? context.fetch(descriptor))?.first { !$0.status.isResolved }
    }

    private static func fetchAll(in context: NSManagedObjectContext) -> [TaskItem] {
        TaskItem.fetchAll(in: context)
    }
}
