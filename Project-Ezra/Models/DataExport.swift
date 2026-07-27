//
//  DataExport.swift
//  Project-Ezra
//
//  "Export everything" — a readable, self-contained JSON snapshot of the user's own
//  data, reachable from Settings.
//
//  This exists because the store is now the only copy of real captured work, and the
//  clean-break schema policy can still destroy it (see `StoreResetRecord`). The raw
//  sqlite safety copy is the *restore* path; this is the path that lets you read what
//  you had, on any machine, without Core Data.
//
//  Pure by construction: `build` takes plain arrays of managed objects and returns
//  `Codable` value types, so it is unit-testable without a store on disk (the
//  architecture principle in prev-docs/product-guardrails.md — logic outside views).
//
//  Deliberately NOT exported: photo blobs (`photoData`), the embedding cache and the
//  attention/state-timeline blobs. Those are derived or re-derivable, and inlining
//  base64 images would turn a readable document into an unreadable one. The graph
//  edges ARE exported, decoded into readable form, because they carry user intent
//  that nothing else records.
//

import CoreData
import Foundation

// MARK: - The document

struct EzraExport: Codable, Equatable {
    var exportedAt: Date
    var appVersion: String?
    var schemaGeneration: Int
    var tasks: [Task]
    var captures: [Capture]
    var changeLog: [Change]
    var corrections: [Correction]
    var capacityLog: [Capacity]
    var profile: Profile?
    var members: [Member]

    struct Task: Codable, Equatable {
        var id: UUID?
        var title: String
        var category: String
        var status: String
        var workIntent: String?
        var notes: String?
        var reasoning: String
        var rawCapture: String
        var isUrgent: Bool
        var isJudgmentCall: Bool
        var needsDecision: Bool
        var confidence: Double
        var dueDate: Date?
        var createdAt: Date?
        var confirmedAt: Date?
        var updatedAt: Date?
        var completedAt: Date?
        var canceledAt: Date?
        var ownerID: UUID?
        var ownerOrigin: String?
        var creatorID: UUID?
        var captureID: UUID?
        var deferralCount: Int
        var carriedOverCount: Int
        var lastHumanTouchAt: Date?
        var relationships: [Edge]
    }

    struct Edge: Codable, Equatable {
        var kind: String
        var targetID: UUID?
        var note: String?
        var origin: String
        var confidence: Double?
        var createdAt: Date
    }

    struct Capture: Codable, Equatable {
        var id: UUID?
        /// The verbatim text. The one field the product promises to keep forever.
        var rawText: String
        var source: String
        var createdAt: Date?
        var committedAt: Date?
    }

    struct Change: Codable, Equatable {
        var id: UUID?
        var summary: String
        var detail: String?
        var action: String?
        var fieldChanged: String?
        var oldValue: String?
        var newValue: String?
        var initiatedBy: String
        var isReversible: Bool
        var undone: Bool
        var taskTitle: String?
        var taskID: UUID?
        var timestamp: Date?
    }

    struct Correction: Codable, Equatable {
        var id: UUID?
        var taskID: UUID?
        var captureID: UUID?
        var fieldCorrected: String
        var aiValue: String
        var userValue: String
        var createdAt: Date?
    }

    struct Capacity: Codable, Equatable {
        var date: Date?
        var capacity: String
    }

    struct Profile: Codable, Equatable {
        var id: UUID?
        var displayName: String?
        var linkedMemberID: UUID?
        var createdAt: Date?
    }

    struct Member: Codable, Equatable {
        var id: UUID
        var name: String
        var relationship: String
        var role: String
        var createdAt: Date?
        var deletedAt: Date?
    }
}

// MARK: - Building & encoding

enum DataExport {

    /// Pure: managed objects in, value types out. No fetching, no I/O.
    static func build(
        tasks: [TaskItem],
        captures: [Capture],
        changes: [ChangeLogEntry],
        corrections: [Correction],
        capacity: [CapacityLog],
        profile: UserProfile?,
        members: [FamilyMember],
        appVersion: String? = nil,
        schemaGeneration: Int = 0,
        now: Date = Date()
    ) -> EzraExport {
        EzraExport(
            exportedAt: now,
            appVersion: appVersion,
            schemaGeneration: schemaGeneration,
            // A closure literal, not a `map(row(for:))` function reference: the reference
            // converts to a nonisolated function type and loses the enclosing actor.
            tasks: tasks.map { row(for: $0) },
            captures: captures.map { capture in
                EzraExport.Capture(
                    id: capture.uuid, rawText: capture.rawText,
                    source: capture.source.rawValue, createdAt: capture.createdAt,
                    committedAt: capture.committedAt)
            },
            changeLog: changes.map { entry in
                EzraExport.Change(
                    id: entry.uuid, summary: entry.summary, detail: entry.detail,
                    action: entry.action, fieldChanged: entry.fieldChanged,
                    oldValue: entry.oldValue, newValue: entry.newValue,
                    initiatedBy: entry.initiatedBy.rawValue, isReversible: entry.isReversible,
                    undone: entry.undone, taskTitle: entry.taskTitle, taskID: entry.taskUUID,
                    timestamp: entry.timestamp)
            },
            corrections: corrections.map { correction in
                EzraExport.Correction(
                    id: correction.uuid, taskID: correction.taskUUID,
                    captureID: correction.captureID,
                    fieldCorrected: correction.fieldCorrected, aiValue: correction.aiValue,
                    userValue: correction.userValue, createdAt: correction.createdAt)
            },
            capacityLog: capacity.map {
                EzraExport.Capacity(date: $0.date, capacity: $0.capacity.rawValue)
            },
            profile: profile.map { profile in
                EzraExport.Profile(
                    id: profile.id, displayName: profile.displayName,
                    linkedMemberID: profile.linkedMemberID, createdAt: profile.createdAt)
            },
            members: members.map { member in
                EzraExport.Member(
                    id: member.uuid, name: member.name,
                    relationship: member.relationship.rawValue, role: member.role.rawValue,
                    createdAt: member.createdAt, deletedAt: member.deletedAt)
            }
        )
    }

    private static func row(for task: TaskItem) -> EzraExport.Task {
        EzraExport.Task(
            id: task.uuid,
            title: task.title,
            category: task.category,
            status: task.status.rawValue,
            workIntent: task.workIntent?.rawValue,
            notes: task.notes,
            reasoning: task.reasoning,
            rawCapture: task.rawCapture,
            isUrgent: task.isUrgent,
            isJudgmentCall: task.isJudgmentCall,
            needsDecision: task.needsDecision,
            confidence: task.confidence,
            dueDate: task.dueDate,
            createdAt: task.createdAt,
            confirmedAt: task.confirmedAt,
            updatedAt: task.updatedAt,
            completedAt: task.completedAt,
            canceledAt: task.killedAt,
            ownerID: task.ownerID,
            ownerOrigin: task.ownerID == nil ? nil : task.ownerOrigin.rawValue,
            creatorID: task.creatorID,
            captureID: task.captureID,
            deferralCount: Int(task.deferralCount),
            carriedOverCount: Int(task.carriedOverCount),
            lastHumanTouchAt: task.lastHumanTouchAt,
            relationships: task.relationships.map { edge in
                EzraExport.Edge(
                    kind: edge.kind.rawValue, targetID: edge.targetID, note: edge.note,
                    origin: edge.origin.isHuman ? "human" : "inferred",
                    confidence: edge.origin.inferredConfidence, createdAt: edge.createdAt)
            }
        )
    }

    /// ISO-8601 dates and sorted keys, so two exports of the same data diff cleanly.
    static func encode(_ export: EzraExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    static func decode(_ data: Data) throws -> EzraExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EzraExport.self, from: data)
    }

    // MARK: - Store-backed convenience (the Settings call site)

    /// Fetch everything and build the document. Failures fetch as empty rather than
    /// throwing: a partial export beats no export when the user is trying to rescue data.
    static func everything(in context: NSManagedObjectContext, now: Date = Date()) -> EzraExport {
        func all<T: NSManagedObject>(_ entity: String) -> [T] {
            (try? context.fetch(NSFetchRequest<T>(entityName: entity))) ?? []
        }
        return build(
            tasks: all("TaskItem"),
            captures: all("Capture"),
            changes: all("ChangeLogEntry"),
            corrections: all("Correction"),
            capacity: all("CapacityLog"),
            profile: all("UserProfile").first,
            members: all("FamilyMember"),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            schemaGeneration: UserDefaults.standard.integer(forKey: "appSchemaGeneration"),
            now: now
        )
    }

    /// A dated file in the temporary directory, ready for `ShareLink`. Rebuilt each time
    /// Settings opens, so what you share is what you have.
    static func writeTemporaryFile(
        in context: NSManagedObjectContext, now: Date = Date()
    ) throws -> URL {
        let data = try encode(everything(in: context, now: now))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ezra-export-\(formatter.string(from: now)).json")
        try data.write(to: url, options: .atomic)
        return url
    }
}
