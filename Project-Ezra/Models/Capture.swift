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
//  A Capture row is written at PARSE time, not commit time, which is what makes an
//  abandoned capture survivable. Until this existed, drafts lived in composer `@State`
//  on a sheet with interactive dismissal and the row was only created inside
//  `AppBrain.commit` — so swiping the sheet down destroyed the thought outright.
//  Losing a rambled thought to an interruption is the one failure that breaks trust in
//  capture, which is the product's whole wedge.
//
//  A capture is PARKED while `committedAt == nil && draftsData != nil`. A parked
//  capture is emphatically NOT a task: it has never been through Confirm, so it must
//  never enter ranking, Today, My Tasks, or anyone's plate.
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
    /// The unconfirmed drafts, JSON-encoded in a versioned envelope. Non-nil only while
    /// this capture is parked. Bridged by `parkedDrafts`.
    @NSManaged private var draftsData: Data?
    /// When this capture's drafts became real tasks. Nil while parked (or discarded).
    @NSManaged var committedAt: Date?

    /// Is this an unfinished capture waiting to be confirmed?
    var isParked: Bool { committedAt == nil && draftsData != nil }

    /// The parked drafts, or nil when there are none / the payload can no longer be
    /// read.
    ///
    /// **Two failure modes, handled differently on purpose.** A decode that THROWS is
    /// benign — the caller re-parses from `rawText`, which is the irreplaceable part
    /// (drafts are derived). A decode that SUCCEEDS but means something different is
    /// worse, and a plain `[TaskDraft]` blob would do exactly that after a field is
    /// added or repurposed. Hence the explicit version envelope: an unrecognized
    /// version is discarded rather than trusted.
    var parkedDrafts: [TaskDraft]? {
        get {
            guard let draftsData,
                let envelope = try? JSONDecoder().decode(ParkedDrafts.self, from: draftsData),
                envelope.version == ParkedDrafts.currentVersion
            else { return nil }
            return envelope.drafts
        }
        set {
            // nil un-parks; an EMPTY array parks with nothing decoded yet. The
            // difference is load-bearing: the prune-undo re-parks a capture whose
            // drafts were dropped, and the composer re-parses from `rawText` on open —
            // so "parked, drafts pending" has to be representable, not collapse to
            // "not parked".
            guard let newValue else {
                draftsData = nil
                return
            }
            draftsData = try? JSONEncoder().encode(ParkedDrafts(drafts: newValue))
        }
    }

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
        committedAt: Date? = nil,
        createdAt: Date = Date(),
        in context: NSManagedObjectContext = PersistenceStack.scratch
    ) {
        self.init(
            entity: NSEntityDescription.entity(forEntityName: "Capture", in: context)!, insertInto: context)
        self.uuid = UUID()
        self.rawText = rawText
        self.sourceRaw = source.rawValue
        self.imageRef = imageRef
        self.parsedTaskIDs = parsedTaskIDs
        self.processingPathRaw = processingPath.rawValue
        self.escalatedAt = escalatedAt
        self.committedAt = committedAt
        self.createdAt = createdAt
    }
}

/// The versioned envelope around parked drafts. Bump `currentVersion` whenever a
/// `TaskDraft` change alters what an existing payload MEANS — an unrecognized version
/// is dropped, and the caller re-parses from the raw text.
struct ParkedDrafts: Codable {
    static let currentVersion = 1

    var version: Int = ParkedDrafts.currentVersion
    var drafts: [TaskDraft]
}
