//
//  SchemaFreezeTests.swift
//  Project-EzraTests
//
//  The door that closed when `HouseholdSync.isLive` flipped (2026-09-12).
//
//  A deployed CloudKit schema is additive-only with no server-side reset, so from that
//  day: `schemaGeneration` never moves (a bump wipes every device's local store under a
//  schema that cannot follow), and every model version added after the freeze is a
//  SUPERSET of the one before it — no entity, attribute or relationship removed, no
//  attribute's type changed. These tests read the compiled `.mom` files, so the pin is
//  on what ships, not on a comment.
//

import CoreData
import Foundation
import Testing

@testable import Project_Ezra

@MainActor
@Suite("Schema freeze — additive-only under a live CloudKit schema")
struct SchemaFreezeTests {

    @Test("While sync is live, the schema generation is the frozen one")
    func generationIsFrozen() {
        if HouseholdSync.isLive {
            #expect(Project_EzraApp.frozenSchemaGeneration == 10)
        }
    }

    /// Every compiled model version, oldest first by version number in the file name.
    private func versions() throws -> [(name: String, model: NSManagedObjectModel)] {
        let urls = try #require(
            Bundle.main.urls(forResourcesWithExtension: "mom", subdirectory: "ProjectEzra.momd"))
        return
            urls
            .compactMap { url -> (String, NSManagedObjectModel)? in
                guard let model = NSManagedObjectModel(contentsOf: url) else { return nil }
                return (url.deletingPathExtension().lastPathComponent, model)
            }
            .sorted { lhs, rhs in
                // "ProjectEzra" < "ProjectEzra 2" < … < "ProjectEzra 10"
                let l = Int(lhs.0.split(separator: " ").last.flatMap { Int($0) }.map(String.init) ?? "1") ?? 1
                let r = Int(rhs.0.split(separator: " ").last.flatMap { Int($0) }.map(String.init) ?? "1") ?? 1
                return l < r
            }
            .map { (name: $0.0, model: $0.1) }
    }

    @Test("The current model is version 4, and v3 still ships beside it (migration has its source)")
    func currentVersionAndItsSource() throws {
        let names = try versions().map(\.name)
        #expect(names.contains("ProjectEzra 3"))
        #expect(names.contains("ProjectEzra 4"))
        // The current model is the one the app loads; its digest is the newest version's.
        let current = try #require(try versions().last)
        #expect(current.name == "ProjectEzra 4")
        #expect(
            PersistenceStack.modelDigest
                == current.model.entityVersionHashesByName.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value.base64EncodedString())" }.joined(separator: "|"))
    }

    @Test("Every version after v3 is a superset of the one before it — nothing removed, no type changed")
    func versionsAreAdditive() throws {
        let all = try versions()
        // v3 is the last pre-freeze version; the freeze binds every step from there on.
        guard let start = all.firstIndex(where: { $0.name == "ProjectEzra 3" }) else {
            Issue.record("v3 not found")
            return
        }
        for (older, newer) in zip(all[start...], all[start...].dropFirst()) {
            for (entityName, oldEntity) in older.model.entitiesByName {
                let newEntity = try #require(
                    newer.model.entitiesByName[entityName], "\(newer.name) dropped entity \(entityName)")
                for (attrName, oldAttr) in oldEntity.attributesByName {
                    let newAttr = try #require(
                        newEntity.attributesByName[attrName],
                        "\(newer.name) dropped \(entityName).\(attrName)")
                    #expect(
                        newAttr.attributeType == oldAttr.attributeType,
                        "\(newer.name) changed the type of \(entityName).\(attrName)")
                    // Optional → required is a tightening an existing record can violate;
                    // required → optional (v4's `FamilyMember.uuid`) is the allowed direction.
                    #expect(
                        !(oldAttr.isOptional && !newAttr.isOptional),
                        "\(newer.name) made \(entityName).\(attrName) required")
                }
                for (relName, oldRel) in oldEntity.relationshipsByName {
                    let newRel = try #require(
                        newEntity.relationshipsByName[relName],
                        "\(newer.name) dropped \(entityName).\(relName)")
                    #expect(newRel.isToMany == oldRel.isToMany)
                    #expect(newRel.destinationEntity?.name == oldRel.destinationEntity?.name)
                }
            }
        }
    }

    @Test(
        "The current model is CloudKit-shaped: every attribute optional or defaulted, every relationship inverse-paired"
    )
    func currentModelIsCloudKitShaped() {
        for (entityName, entity) in PersistenceStack.model.entitiesByName {
            for (attrName, attr) in entity.attributesByName {
                #expect(
                    attr.isOptional || attr.defaultValue != nil,
                    "\(entityName).\(attrName) is required with no default — CloudKit refuses the model")
            }
            for (relName, rel) in entity.relationshipsByName {
                #expect(rel.inverseRelationship != nil, "\(entityName).\(relName) has no inverse")
                #expect(rel.isOptional, "\(entityName).\(relName) is required")
            }
            #expect(entity.uniquenessConstraints.isEmpty, "\(entityName) declares a uniqueness constraint")
        }
    }
}
