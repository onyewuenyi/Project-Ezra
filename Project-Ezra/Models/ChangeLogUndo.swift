//
//  ChangeLogUndo.swift
//  Project-Ezra
//
//  The action-aware revert behind the Activity feed's per-entry Undo. Every change-log
//  entry — AI-initiated or human — knows how to be reversed by its `action` verb, so
//  the feed can offer a single Undo that does the right thing per action rather than
//  one blunt "send it to Activity". Extracted from the old AI-trail so the logic
//  lives in one testable place.
//
//  The critical rule: a HUMAN "completed"/"killed" undoes by *reopening* (restoring
//  the exact prior live status via the timeline) — never a blunt reset to the state
//  every task is born into, which would wrongly strand a finished task at the start
//  of the pipeline.
//
//  **Undo-completeness.** An arm must restore EVERY field its action wrote, not just
//  the headline one. `"assigned"` is the worked example: `claim` stamps
//  `ownerOrigin = .human`, and the affinity denominator counts `.human` only, so an
//  arm that restored the owner id alone would leave an AI-inferred ownership marked
//  human and quietly pollute the denominator. New arms inherit this rule.
//

import CoreData

@MainActor
enum ChangeLogUndo {
    /// Reverse the effect of `entry` on its linked task, keyed on the action verb.
    /// Callers still mark the entry `undone` and `save()`.
    static func revert(_ entry: ChangeLogEntry, in context: NSManagedObjectContext, now: Date = Date()) {
        // A pruned capture is the one entry that points at a Capture rather than a
        // task, so it is resolved before the task guard below.
        if entry.action == "prunedCapture" {
            revertCapturePrune(entry, in: context)
            return
        }
        // A rejected merge/parent suggestion. Resolved before the task guard because the
        // suppression lives in its OWN store, not on either task — undoing it must work
        // even if the created task has since been deleted, and there is no task field to
        // restore. Undo-completeness: `undoRejection` removes the capture form AND the
        // pair form, or the suggestion would stay vetoed from the other direction.
        if entry.action == "suppressed" {
            guard let payload = SuppressionUndoPayload.decode(entry.oldValue) else { return }
            SuppressionStore.undoRejection(payload, in: context)
            return
        }
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
                // Removing the mis-added edge can be the task's last active blocker, which
                // makes `removeBlocker` stamp `lastUnblockedAt` — but undoing a wrong edge
                // must not reward the task with the recently-unblocked boost (it was never
                // legitimately blocked-then-freed). Snapshot and restore the fact.
                let priorUnblockedAt = task.lastUnblockedAt
                task.removeTaskBlockerEdges(to: targetID, among: fetchAll(in: context))
                task.lastUnblockedAt = priorUnblockedAt
            }
        case "merged":
            // A capture folded into `task` (the merge target) — undo resurrects the folded
            // draft as a real task from the JSON snapshot. It was a confirmed task before
            // the merge, so it comes back `.todo`, not to some pre-confirm limbo (there
            // isn't one). The merge destroyed no data; the target keeps its capture note.
            guard let snapshot = MergedTaskSnapshot.decode(entry.oldValue) else { return }
            let resurrected = TaskItem(
                title: snapshot.title, category: snapshot.category, status: .todo,
                reasoning: snapshot.reasoning, isUrgent: snapshot.isUrgent, in: context)
            context.insert(resurrected)
            AttentionEngine.recompute([resurrected], among: fetchAll(in: context))
        case "completed", "killed":
            // Human resolution → reopen to the prior live status.
            task.reopenAndReblock(in: context, now: now)
        case "mergedPair":
            // A sweep merged two EXISTING tasks (kill-don't-delete): `task` is the
            // winner; the loser's row never died, so reopening restores its
            // identity, timeline, and edges outright. Undo-completeness: the exact
            // absorbed note line comes off the winner (left alone if the user has
            // since rewritten it — their words outrank the unwind), and the pair is
            // SUPPRESSED — an unwound merge is a human "no", and the sweep must
            // never re-propose it.
            guard let payload = MergedPairPayload.decode(entry.oldValue),
                let loserID = payload.loserID,
                let loser = fetchAll(in: context).first(where: { $0.uuid == loserID })
            else { return }
            loser.reopenAndReblock(in: context, now: now)
            if let notes = task.notes {
                let kept = notes.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { $0 != payload.noteLine }
                    .joined(separator: "\n")
                task.notes = kept.isEmpty ? nil : kept
            }
            if let winnerID = task.uuid {
                SuppressionStore.recordRejectedPair(winnerID, loserID, in: context, now: now)
            }
        case "assigned":
            // Restore the previous owner AND the previous origin — see the
            // undo-completeness note in the file header. An empty owner means it was
            // handed back to the household.
            let previous = TaskItem.decodeOwnership(entry.oldValue)
            task.claim(ownerID: previous.ownerID, among: fetchAll(in: context), origin: previous.origin)
        case "decided":
            // The human's "Mark decided" re-escalates to the open decision — and if the
            // decide carried a CHOICE, the exact appended notes line comes back out
            // (undo-completeness: the action wrote it, so the arm removes it). Spare a
            // note the user has since rewritten: strip only an exact-line match.
            task.escalateToDecision()
            if let appendedLine = entry.newValue, let notes = task.notes {
                let lines = notes.components(separatedBy: "\n").filter { $0 != appendedLine }
                let restored = lines.joined(separator: "\n")
                task.notes = restored.isEmpty ? nil : restored
            }
        case "unblocked":
            // Restore every edge the force-unblock dropped — tracked and external, human
            // and inferred alike — through the graph's own write primitive so the DEBUG
            // `Relationship.validate` still runs.
            //
            // Undo-completeness: `lastUnblockedAt` goes back too. The unblock stamped it,
            // and `TaskRanking.recentUnblockBoost` reads it, so restoring only the edges
            // would leave the task lifted in the stack by an unblock the user just took
            // back — while simultaneously reading as blocked again.
            guard let snapshot = TaskItem.decodeUnblock(entry.oldValue) else { return }
            task.restoreBlockerEdges(snapshot, now: now)
        case "split":
            // Undo of a breakdown: delete the children this split created, and with them
            // their `.parent` edges (the edge lives ON the child, so deleting the child
            // removes it — but a child the user has since edited or completed is NOT
            // reclaimed, because the split is no longer the only thing that happened to
            // it). The parent itself is untouched.
            let ids = (entry.newValue ?? "").split(separator: ",").compactMap {
                UUID(uuidString: String($0))
            }
            guard !ids.isEmpty else { return }
            let all = fetchAll(in: context)
            for child in all where child.uuid.map(ids.contains) ?? false {
                // Only reclaim an untouched step. A completed or human-edited child is
                // real work now; silently deleting it would destroy something the undo
                // never promised to reverse.
                guard !child.status.isResolved, child.lastHumanTouchAt == nil else { continue }
                context.delete(child)
            }
            task.touch(now: now)
        case ChangeLogEntry.editedAction:
            // A manual field edit → restore the named field from `oldValue`. Writes go
            // through the raw property (NOT the logged seams), so the revert never
            // spawns a fresh "edited" entry. Undone entries stay in the timeline
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
            case "status":
                // A todo ↔ doing move. Written through `transition` so the state
                // timeline stays honest (the dwell record must show the round trip),
                // but never through `setStatus`, which would log a fresh entry.
                if let previous = entry.oldValue.flatMap(TaskStatus.init(rawValue:)), previous.isLive {
                    task.transition(to: previous, now: now)
                }
            case "workIntent":
                task.workIntent = entry.oldValue.flatMap(WorkIntent.init(rawValue:))
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
            // archived / anything else → reopen if resolved, so the task is
            // back in the working set and the human has it again. There is no
            // pre-confirm state to demote it to; `.todo` is where a task lives.
            //
            // "filed" is deliberately NOT in this list any more: the arm was a no-op on a
            // task born `.todo`, so those entries are logged non-reversible and never
            // reach here (see `AppBrain.commit`). If an action has no honest arm, the
            // fix is to stop offering the button — not to route it to a default that
            // pretends.
            if task.status.isResolved {
                task.reopenAndReblock(in: context, now: now)
            } else {
                task.status = .todo
            }
        }
    }

    /// Undo of the stale-capture prune. The row was never deleted — only its derived
    /// drafts were dropped — so re-parking is a re-parse from the verbatim `rawText`,
    /// which is exactly the fallback a decode failure takes.
    private static func revertCapturePrune(
        _ entry: ChangeLogEntry, in context: NSManagedObjectContext
    ) {
        guard let idString = entry.oldValue, let captureID = UUID(uuidString: idString) else {
            return
        }
        let request = NSFetchRequest<Capture>(entityName: "Capture")
        request.predicate = NSPredicate(format: "uuid == %@", captureID as CVarArg)
        request.fetchLimit = 1
        guard let capture = try? context.fetch(request).first else { return }
        // Re-parking with no drafts is deliberate: the composer re-parses on open, so
        // the user gets the same candidates back without this arm needing an engine.
        capture.parkedDrafts = []
        capture.committedAt = nil
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
