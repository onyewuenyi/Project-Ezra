//
//  CapturePosture.swift
//  Project-Ezra
//
//  **Privacy as a posture on the one capture door, not a second door.** (F-03)
//
//  Private Capture shipped as its own surface — long-press the orb — because that is
//  how the capability was discovered: three device campaigns looking for a workload the
//  on-device model wins. That was a good reason for the ENGINE to exist and a poor
//  reason for a second surface: two doors made the person classify their own thought
//  before speaking it (is this one thing or many? is this sensitive?), which is the
//  exact demand Ramble exists to remove, and the strongest privacy promise in the app
//  was reachable only by a gesture nobody discovers.
//
//  So the promise became a control. One door; this is the switch beside it. When it is
//  on, a capture NEVER escalates — the deterministic read is the interpretation, and a
//  single thought goes through `PrivateCaptureEngine` (the envelope the local model was
//  measured to win) when a model is present. When it is off, the device-first router
//  decides as before. Persisted, visible in the capture bar, and stated in the data
//  boundary sentences — so what leaves the device is something the person set, not
//  something they have to remember.
//

import Foundation

enum CapturePosture: String, CaseIterable, Sendable {
    /// Device-first, escalate on evidence — the default router.
    case open
    /// Never transmit. The deterministic read, or the on-device single-thought engine.
    case onDevice

    static let storageKey = "capture.posture"

    /// The persisted posture. Read at submit, never cached across it.
    static func current(defaults: UserDefaults = .standard) -> CapturePosture {
        defaults.string(forKey: storageKey).flatMap(CapturePosture.init(rawValue:)) ?? .open
    }

    /// The chip's label — the user's terms, never the mechanism's.
    var label: String {
        switch self {
        case .open: return "Read anywhere"
        case .onDevice: return "On device"
        }
    }

    var glyph: String {
        switch self {
        case .open: return "lock.open"
        case .onDevice: return "lock"
        }
    }

    var toggled: CapturePosture { self == .open ? .onDevice : .open }
}
