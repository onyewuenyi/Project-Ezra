//
//  HouseholdSettings.swift
//  Project-Ezra
//
//  Reserved. Shared household configuration that future features read — NOT a bag of
//  raw knobs. Following the "expose behavior, not settings" principle, the only
//  user-facing dial planned here is `planningStyle` (Relaxed / Balanced / Proactive);
//  everything else is context the AI infers or integrates (a home *location* not an
//  address, a time zone, an EventKit calendar *identifier* not events). No V1 UI.
//
//  Local UI preferences (dark mode, sort order, onboarding completion) deliberately do
//  NOT live here — those stay device-local (`@AppStorage`), not shared household state.
//

import CoreData

/// The one behavior-level dial we plan to expose (later): how forward the AI leans.
enum PlanningStyle: String, CaseIterable, Identifiable, Codable {
    case relaxed, balanced, proactive
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

@objc(HouseholdSettings)
final class HouseholdSettings: NSManagedObject {
    @NSManaged var id: UUID
    /// "Home" as a place the AI reasons about (distance, travel time, weather), never a
    /// postal address. Coordinates only; nil until set.
    @NSManaged var homeLatitude: NSNumber?
    @NSManaged var homeLongitude: NSNumber?
    @NSManaged var timeZoneIdentifier: String?
    /// EventKit calendar identifier — we integrate the system calendar, never store events.
    @NSManaged var calendarIdentifier: String?
    @NSManaged var planningStyleRaw: String
    @NSManaged var createdAt: Date
    @NSManaged var household: Household?

    convenience init(
        planningStyle: PlanningStyle = .balanced,
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(entity: NSEntityDescription.entity(forEntityName: "HouseholdSettings", in: context)!, insertInto: context)
        self.id = UUID()
        self.planningStyleRaw = planningStyle.rawValue
        self.createdAt = Date()
    }

    var planningStyle: PlanningStyle {
        get { PlanningStyle(rawValue: planningStyleRaw) ?? .balanced }
        set { planningStyleRaw = newValue.rawValue }
    }
}
