//
//  HouseholdAIContext.swift
//  Project-Ezra
//
//  Reserved. The consolidated home for the household's AI personalization — planning
//  style resolution, automation level, learned preferences, ignored suggestions —
//  rather than scattering `aiPreferences` fields across the app. Paired with
//  `HouseholdMemory` (durable household facts), this is where the assistant gets
//  dramatically better over time. Minimal today; no V1 UI.
//

import CoreData

@objc(HouseholdAIContext)
final class HouseholdAIContext: NSManagedObject {
    @NSManaged var id: UUID
    /// Reserved: how much the household lets the AI act on its own (raw value of a
    /// future automation-level enum). Nil = use the default policy.
    @NSManaged var automationLevelRaw: String?
    /// Reserved free-form notes the model maintains about how this household works.
    @NSManaged var notes: String?
    @NSManaged var createdAt: Date
    @NSManaged var household: Household?

    convenience init(in context: NSManagedObjectContext = PersistenceStack.scratch) {
        self.init(entity: NSEntityDescription.entity(forEntityName: "HouseholdAIContext", in: context)!, insertInto: context)
        self.id = UUID()
        self.createdAt = Date()
    }
}
