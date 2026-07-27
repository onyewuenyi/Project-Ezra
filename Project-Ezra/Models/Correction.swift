//
//  Correction.swift
//  Project-Ezra
//
//  Every field a user edits on the creation-confirm card is a free labeled pair:
//  what the AI produced vs. what the user changed it to. This is the compounding
//  loop that makes the app measurably better for a specific user over time —
//  stored locally, never uploaded. Write-only in this release (the
//  session-instruction injection that consumes it is deferred), but the
//  measurement starts now: correction rate per field IS the eval data.
//
//  Guardrail (carried forward from the Learn-step decision): this loop must
//  reduce required user attention over time, not increase engagement.
//

import CoreData

@objc(Correction)
final class Correction: NSManagedObject {
    @NSManaged var uuid: UUID?
    /// The task whose field was corrected.
    @NSManaged var taskUUID: UUID?
    /// The capture that produced the task, for tracing corrections to inputs.
    @NSManaged var captureID: UUID?
    /// Which field was corrected — the vocabulary `TaskDraft.corrections` actually
    /// writes: "title", "category", "dueDate", "urgent", "workIntent", "owner",
    /// "effort", "blocker", "blocks", "duplicate", "parent". "workIntent" is shared
    /// with the detail sheet's own correction, so a kind fixed at confirm and a kind
    /// fixed later read as the same signal. Loose vocabulary, not an enum —
    /// same reasoning as `ChangeLogEntry.action`. ("priority" is retired; nothing
    /// writes it — eval tooling should key on "urgent".)
    @NSManaged var fieldCorrected: String
    /// What the model produced, string-encoded.
    @NSManaged var aiValue: String
    /// What the user changed it to, string-encoded.
    @NSManaged var userValue: String
    @NSManaged var createdAt: Date

    convenience init(
        taskUUID: UUID?,
        captureID: UUID? = nil,
        fieldCorrected: String,
        aiValue: String,
        userValue: String,
        createdAt: Date = Date(),
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(
            entity: NSEntityDescription.entity(forEntityName: "Correction", in: context)!, insertInto: context
        )
        self.uuid = UUID()
        self.taskUUID = taskUUID
        self.captureID = captureID
        self.fieldCorrected = fieldCorrected
        self.aiValue = aiValue
        self.userValue = userValue
        self.createdAt = createdAt
    }
}
