//
//  HouseholdMemory.swift
//  Project-Ezra
//
//  Reserved. Durable facts about how a household runs — "Trash out Tuesday", "Ezra
//  naps at one", "Costco run monthly", "dog takes medication". This is the biggest
//  future lever on assistant quality: the AI reasons far better with these than
//  without. One fact per record; no V1 UI.
//

import CoreData

@objc(HouseholdMemory)
final class HouseholdMemory: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var fact: String
    @NSManaged var createdAt: Date
    @NSManaged var household: Household?

    convenience init(fact: String = "", in context: NSManagedObjectContext = PersistenceStack.scratch) {
        self.init(entity: NSEntityDescription.entity(forEntityName: "HouseholdMemory", in: context)!, insertInto: context)
        self.id = UUID()
        self.fact = fact
        self.createdAt = Date()
    }
}
