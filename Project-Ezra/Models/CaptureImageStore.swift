//
//  CaptureImageStore.swift
//  Models
//
//  Where a captured image's bytes live. Deliberately a FILE in the app container
//  with `Capture.imageRef` holding the filename — NOT a new entity and NOT an
//  inline blob: the schema is frozen-by-default (generation 10 spent the
//  clean-break budget), `imageRef` has been persisted since the entity landed,
//  and capture images are big enough that riding a task-list fetch would be a
//  self-inflicted wound. One writer (the composer's pick path), one destructive
//  path (discard).
//

import Foundation

enum CaptureImageStore {

    /// Application Support/CaptureImages — created lazily, excluded from nothing
    /// (these are user data; they belong in backups).
    nonisolated static var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CaptureImages", isDirectory: true)
    }

    /// Persist image bytes; returns the reference `Capture.imageRef` stores, or nil
    /// when the write fails (the capture proceeds text-only — losing the picture
    /// must never lose the words).
    nonisolated static func save(_ data: Data) -> String? {
        let ref = UUID().uuidString + ".jpg"
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(ref), options: .atomic)
            return ref
        } catch {
            return nil
        }
    }

    nonisolated static func url(for ref: String) -> URL {
        directory.appendingPathComponent(ref)
    }

    /// The one destructive path — called from the composer's discard and from a
    /// removed thumbnail chip. Parks and commits keep the file (verbatim-forever
    /// spirit: the photo is part of the capture's provenance).
    nonisolated static func delete(_ ref: String) {
        try? FileManager.default.removeItem(at: url(for: ref))
    }
}
