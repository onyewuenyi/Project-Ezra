//
//  CoreDataIdentifiable.swift
//  Project-Ezra
//
//  SwiftData's `@Model` types were implicitly `Identifiable`; `NSManagedObject` is not,
//  so SwiftUI `ForEach` over model arrays needs an explicit conformance. The uuid-keyed
//  entities key off `objectID` (stable per object, unique within a render); the entities
//  that already carry an `id: UUID` conform through it.
//

import CoreData

extension TaskItem: Identifiable { public var id: NSManagedObjectID { objectID } }
extension FamilyMember: Identifiable { public var id: NSManagedObjectID { objectID } }
extension ChangeLogEntry: Identifiable { public var id: NSManagedObjectID { objectID } }
extension Capture: Identifiable { public var id: NSManagedObjectID { objectID } }
extension Correction: Identifiable { public var id: NSManagedObjectID { objectID } }

extension Household: Identifiable {}
extension UserProfile: Identifiable {}
extension HouseholdSettings: Identifiable {}
extension HouseholdAIContext: Identifiable {}
extension HouseholdMemory: Identifiable {}
extension Invitation: Identifiable {}
