//
//  HouseholdStoreAffinity.swift
//  Project-Ezra
//
//  Which persistent store a new object lands in, decided ONCE, at save.
//
//  With CloudKit sharing there are two stores in one container: the PRIVATE store (what
//  this person owns) and the SHARED store (a household someone else owns and invited them
//  into). Core Data does not infer a store from a relationship reliably enough to build a
//  product on — Apple's own sharing sample assigns every new object explicitly — and this
//  codebase creates tasks and trail entries in a dozen places (`AppBrain.commit`,
//  `splitInto`, `TaskMutations`, the seeds, the fixtures). Assigning per creation site is
//  the shape of bug this repo has documented three times ("a capability decided by a
//  default parameter is a capability nobody is deciding about"): one forgotten site and a
//  task the second caretaker created lands in THEIR private store, invisible to the
//  household, with nothing wrong in the code you are reading.
//
//  So the decision is made in one place: an observer on the view context's
//  `willSave`. For every inserted object it (1) gives a task or trail entry with no
//  household the current one — the household a save happens INSIDE — and (2) assigns any
//  object related to a household to the store that household lives in. A `Correction`, a
//  `Capture`, a `UserProfile` have no household relationship, so they are never touched and
//  fall to the first store: the private one. That ordering is `PersistenceStack.makeContainer`'s
//  and is the other half of this file.
//
//  Under XCTest there is one in-memory store and `Household.current` is whatever the test
//  built, so this is inert there by construction — the assignment to the only store is a
//  no-op, and the household backfill only fires when a household exists.
//

import CoreData

@MainActor
enum HouseholdStoreAffinity {

    /// The entities that belong to a household but are created without saying so. Every
    /// other household-related entity (`FamilyMember`, `Invitation`, `HouseholdSettings`,
    /// `HouseholdMemory`, `HouseholdAIContext`) sets `household` at creation already.
    static let backfilledEntities: Set<String> = ["TaskItem", "ChangeLogEntry"]

    /// Start deciding for `context`. Returns the observation token; the caller keeps it
    /// for the life of the context (the app does, in `Project_EzraApp`).
    static func install(on context: NSManagedObjectContext) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave, object: context, queue: nil
        ) { notification in
            guard let context = notification.object as? NSManagedObjectContext else { return }
            // `willSave` is posted on the context's own queue; the view context is main.
            MainActor.assumeIsolated { assign(insertedIn: context) }
        }
    }

    /// The decision, as a pure function of the inserted set — callable directly by tests.
    static func assign(insertedIn context: NSManagedObjectContext) {
        let inserted = context.insertedObjects
        guard !inserted.isEmpty else { return }

        // The household a save happens inside. Fetched, NEVER created here — inserting a
        // root object from inside a save notification is exactly the kind of side effect a
        // save must not have. Every real launch bootstraps identity (and so the household)
        // before the first capture can be committed.
        lazy var current: Household? = Household.existing(in: context)

        for object in inserted {
            guard let relationship = object.entity.relationshipsByName["household"],
                relationship.destinationEntity?.name == "Household"
            else { continue }

            if backfilledEntities.contains(object.entity.name ?? ""),
                object.value(forKey: "household") == nil,
                let household = current
            {
                object.setValue(household, forKey: "household")
            }

            // Follow the edge to the store the household is in. A household inserted in
            // this same save has no store yet; Core Data then assigns both to the first
            // store, which is the private one — correct for an owner's first launch.
            guard let household = object.value(forKey: "household") as? NSManagedObject,
                let store = household.objectID.persistentStore,
                object.objectID.persistentStore == nil
            else { continue }
            context.assign(object, to: store)
        }
    }
}
