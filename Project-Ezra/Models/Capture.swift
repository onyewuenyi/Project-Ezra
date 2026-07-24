//
//  Capture.swift
//  Project-Ezra
//
//  A capture event is its own record, not a Task field: one voice/text/forward
//  event can yield multiple tasks ("need dentist, fix car, plan vacation" →
//  three), and if `rawCapture` lived only on Task that grouping would be lost.
//  Tasks reference their Capture via `TaskItem.captureID`. This is also the
//  ground truth for "the AI got something wrong": the raw text is kept verbatim
//  forever and never mutated after the fact.
//

import CoreData

/// Which entry point produced a capture. Recorded so entry-point usage is
/// measurable; most cases are reserved for future surfaces (share extension,
/// Siri, widgets, watch).
enum CaptureSource: String, Codable {
    case voice, text, forward, image, siri, widget, watch
}

/// Which processing path a capture took. `localOnly` is the default fast path
/// (on-device, zero round-trip); `escalated` marks a low-confidence cleanup pass —
/// the escalation rate is a metric worth watching, not just an implementation
/// detail. Escalation itself is a deferred feature; the field ships now so the
/// distribution is measured from day one.
enum CaptureProcessingPath: String, Codable {
    case localOnly, escalated
}

@objc(Capture)
final class Capture: NSManagedObject {
    @NSManaged var uuid: UUID?
    /// The original, unprocessed transcript/text — kept verbatim forever.
    @NSManaged var rawText: String
    @NSManaged private var sourceRaw: String
    /// Set when `source == .image` (reserved — image capture is deferred).
    @NSManaged var imageRef: String?
    /// JSON-encoded `[UUID]` of the tasks extracted from this capture (Core Data has no
    /// native array type; the `parsedTaskIDs` accessor is the API).
    @NSManaged private var parsedTaskIDsData: Data?
    @NSManaged private var processingPathRaw: String
    /// When a low-confidence item was sent for a cleanup pass. Nil on the fast path.
    @NSManaged var escalatedAt: Date?
    @NSManaged var createdAt: Date

    /// The one or more TaskItem uuids extracted from this capture.
    var parsedTaskIDs: [UUID] {
        get { parsedTaskIDsData.flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? [] }
        set { parsedTaskIDsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var source: CaptureSource {
        get { CaptureSource(rawValue: sourceRaw) ?? .text }
        set { sourceRaw = newValue.rawValue }
    }

    var processingPath: CaptureProcessingPath {
        get { CaptureProcessingPath(rawValue: processingPathRaw) ?? .localOnly }
        set { processingPathRaw = newValue.rawValue }
    }

    convenience init(
        rawText: String,
        source: CaptureSource = .text,
        imageRef: String? = nil,
        parsedTaskIDs: [UUID] = [],
        processingPath: CaptureProcessingPath = .localOnly,
        escalatedAt: Date? = nil,
        createdAt: Date = Date(),
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(entity: NSEntityDescription.entity(forEntityName: "Capture", in: context)!, insertInto: context)
        self.uuid = UUID()
        self.rawText = rawText
        self.sourceRaw = source.rawValue
        self.imageRef = imageRef
        self.parsedTaskIDs = parsedTaskIDs
        self.processingPathRaw = processingPath.rawValue
        self.escalatedAt = escalatedAt
        self.createdAt = createdAt
    }
}
