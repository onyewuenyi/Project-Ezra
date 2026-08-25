//
//  ChangeLogEntry.swift
//  Project-Ezra
//
//  The change log backs both Undo and the Activity Trail: every AI-initiated
//  action records what it did (field-level old/new where applicable), or Undo has
//  nothing to reverse and the trail nothing to show. Human entries feed the
//  Attention Feed ("Maya was assigned…") but never the trail's "AI handled N"
//  count — that trust number must only ever count the AI's own actions.
//

import CoreData

/// Who caused a change. Stored raw on the entry so the trail and metrics can
/// filter without joins.
enum ChangeInitiator: String, Codable {
    case ai
    case human
}

@objc(ChangeLogEntry)
final class ChangeLogEntry: NSManagedObject {
    /// Stable identity, mirroring the other models' UUID idiom.
    @NSManaged var uuid: UUID?
    /// Human-readable one-liner ("Filed 'Book repair' under Car").
    @NSManaged var summary: String
    /// Longer reasoning/context, optional.
    @NSManaged var detail: String?
    /// Which action produced this ("filed", "unblocked", "archived", "assigned",
    /// "completed", "confirmed", …). A loose vocabulary, not an enum — new verbs
    /// must never require a migration.
    @NSManaged var action: String?
    /// Field-level change record, when the action changed a single field.
    @NSManaged var fieldChanged: String?
    @NSManaged var oldValue: String?
    @NSManaged var newValue: String?
    @NSManaged private var initiatedByRaw: String
    @NSManaged var isReversible: Bool
    @NSManaged var undone: Bool
    /// Link back to the affected task's title, for undo context and feed sentences.
    @NSManaged var taskTitle: String?
    /// Stable link to the affected task, so Undo can revert the real task.
    @NSManaged var taskUUID: UUID?
    /// For a human-initiated action, WHO did it — a `FamilyMember.uuid`. Drives the
    /// Activity feed's leading avatar ("Maya completed…"). Nil for AI actions (the feed
    /// renders a gradient sparkles tile instead) and for pre-redesign entries.
    @NSManaged var actorID: UUID?
    @NSManaged var timestamp: Date

    var initiatedBy: ChangeInitiator {
        get { ChangeInitiator(rawValue: initiatedByRaw) ?? .ai }
        set { initiatedByRaw = newValue.rawValue }
    }

    /// The verb reserved for a human's manual field edit on a task (priority, title, due
    /// date, category, effort, description, stage, blockers). These live ONLY in the
    /// task's own Activity timeline — never the global Activity feed — so this one string is
    /// the discriminator both the feed predicate and the unread badge read (see
    /// `isActivityVisible` / `activityVisiblePredicate`), and the timeline's context-menu Undo
    /// routes on (`ChangeLogUndo`).
    static let editedAction = "edited"

    /// The verb for a Today-plan generation. Excluded from Activity for the same
    /// reason `Metrics.acceptanceRate` already excludes it: a daily plan is not a
    /// per-task action the user accepts or rejects, so it is neither household news
    /// nor something an Undo can meaningfully reverse.
    ///
    /// It used to be inbox-visible AND `isReversible`, which cost twice: it badged the
    /// tab on first open, on every Replan, and on every self-heal upgrade (writing
    /// "Planned 0 actions for today" on an empty day), and its Undo button struck the
    /// row through and then did nothing — `ChangeLogUndo` has no arm for it, and the
    /// entry carries no `taskUUID` for `linkedTask` to resolve. A control that appears
    /// to succeed while doing nothing is the most corrosive thing a product built on
    /// "every AI action is reversible" can ship.
    static let plannedAction = "planned"

    /// The verb for one committed capture — "Captured 3 tasks".
    ///
    /// It exists because the Activity feed had a hole exactly where the most interesting
    /// provenance was: only a `.silent`-autonomy draft writes a `"filed"` entry, so a
    /// capture whose drafts all came back `.suggest`/`.ask` left no row at all. This one
    /// entry per commit is the handle on the capture → N tasks event, and carries the
    /// capture's uuid in `oldValue` (the `"prunedCapture"` convention) so the provenance
    /// detail can resolve the run.
    ///
    /// **Activity-visible, deliberately** — unlike the two verbs above, being seen is the
    /// entire point. But **never** acceptance-counted: see `nonAcceptanceActions`.
    static let capturedAction = "captured"

    convenience init(
        summary: String,
        detail: String? = nil,
        action: String? = nil,
        fieldChanged: String? = nil,
        oldValue: String? = nil,
        newValue: String? = nil,
        initiatedBy: ChangeInitiator = .ai,
        isReversible: Bool = true,
        taskTitle: String? = nil,
        taskUUID: UUID? = nil,
        actorID: UUID? = nil,
        timestamp: Date = Date(),
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(
            entity: NSEntityDescription.entity(forEntityName: "ChangeLogEntry", in: context)!,
            insertInto: context)
        self.uuid = UUID()
        self.summary = summary
        self.detail = detail
        self.action = action
        self.fieldChanged = fieldChanged
        self.oldValue = oldValue
        self.newValue = newValue
        self.initiatedByRaw = initiatedBy.rawValue
        self.isReversible = isReversible
        self.undone = false
        self.taskTitle = taskTitle
        self.taskUUID = taskUUID
        self.actorID = actorID
        self.timestamp = timestamp
    }
}

// MARK: - Activity visibility (one seam, two forms)

extension ChangeLogEntry {
    /// Verbs that never reach the global Activity feed. `editedAction` lives only in the
    /// task's own Activity timeline; `plannedAction` is the app's own daily background
    /// work rather than an action anyone took. Both forms below read THIS list, so a
    /// future verb can't be excluded from one and not the other.
    static let activityHiddenActions = [ChangeLogEntry.editedAction, ChangeLogEntry.plannedAction]

    /// Verbs excluded from `Metrics.acceptanceRate`, because they are not AI actions on a
    /// task that a user accepts or rejects.
    ///
    /// `planned` was already excluded for that reason. `captured` joins it for a sharper
    /// one: it is AI-initiated and permanently `isReversible == false`, so it can only ever
    /// count as KEPT — an entry the metric is structurally incapable of scoring against.
    /// Left in, every commit would drag acceptance toward 1.0 and the product's primary
    /// trust number would improve simply because the user captured more. A metric that
    /// cannot fail cannot support the claim it is making.
    static let nonAcceptanceActions = [ChangeLogEntry.plannedAction, ChangeLogEntry.capturedAction]

    /// The single predicate deciding whether an entry belongs in the global Activity
    /// feed. (`action == nil` keeps pre-redesign entries.)
    ///
    /// The two forms exist because the predicate can only filter a FETCH and the mirror
    /// can only filter an already-fetched set; they were once read by different call
    /// sites (the feed and the tab's unread badge), and drifting them apart was the
    /// specific bug this seam prevents. The badge died with the tab in the v2 collapse —
    /// the mirror stays because filtering in memory is still the cheaper answer wherever
    /// a live `FetchedResults` is already in hand.
    static let activityVisiblePredicate = NSPredicate(
        format: "action == nil OR NOT (action IN %@)", ChangeLogEntry.activityHiddenActions)

    /// The in-memory mirror of `activityVisiblePredicate`.
    var isActivityVisible: Bool {
        guard let action else { return true }
        return !ChangeLogEntry.activityHiddenActions.contains(action)
    }
}

// MARK: - Date codec (stable string encoding for dueDate edits' old/new values)

extension ChangeLogEntry {
    /// Encode a `Date?` as a stable string for `oldValue`/`newValue` on a "dueDate" edit —
    /// the reference-date interval, so Undo restores the exact instant with no formatter
    /// or timezone drift. `nil` (a cleared due date) encodes as `nil`.
    static func encodeDate(_ date: Date?) -> String? {
        date.map { String($0.timeIntervalSinceReferenceDate) }
    }

    /// Inverse of `encodeDate` — used by `ChangeLogUndo` to restore a dueDate edit.
    static func decodeDate(_ raw: String?) -> Date? {
        raw.flatMap(Double.init).map(Date.init(timeIntervalSinceReferenceDate:))
    }
}
