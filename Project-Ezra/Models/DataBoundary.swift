//
//  DataBoundary.swift
//  Project-Ezra
//
//  What leaves this device, in three sentences a person can actually read.
//
//  **Privacy is part of Ramble's product contract, not a settings footnote.** Ramble is
//  the "tell Ezra anything" surface, so the boundary has to be stated where the trust is
//  being asked for — and it has to be stated in sentences, not in a toggle, a provider
//  name, or a paragraph of hedging. Three lines, one idea each:
//
//    1. your raw words may be understood in the cloud when Ezra needs to understand better
//    2. only structured task information leaves for advice
//    3. your corrections and your history never reach US, and never reach the people
//       you share with (they DO sit in your own iCloud — see `neverSentence`)
//
//  It is a value type rather than copy inlined in a view for the reason every policy in
//  this codebase is: the claim has to be checkable. "Only structured task information
//  leaves" is a promise the code either keeps or breaks, and a promise living inside a
//  `Text(...)` is one nobody can test.
//
//  **It adapts to what is actually true on this device.** With no cloud provider
//  reachable, nothing leaves at all — and saying "your words may be processed in the
//  cloud" there would be the mirror image of hiding it: alarming someone about something
//  that is not happening. Both states are three sentences, and both are true.
//

import Foundation

struct DataBoundary: Equatable {
    /// Where captures are understood.
    let capture: String
    /// What the Advisor sends. (It said "the Brief and the Advisor" until 2026-09-11,
    /// nine days after the Brief was cut — the `.onDevice` arm below had been updated and
    /// the other two had not, which is how a promise about a feature that no longer exists
    /// stayed on the one screen where the app states what leaves the device.)
    let judgment: String
    /// What never leaves, under any configuration.
    let never: String
    /// The product-telemetry line (2026-09-12) — present only while telemetry is live on
    /// this install, so a build with no sink or a person who opted out is not told about
    /// a transmission that isn't happening. Says what is NOT sent first.
    var telemetry: String? = nil
    /// The household-sync line — present only once `HouseholdSync.isLive`, because before
    /// that nothing claims another person will see anything.
    var sync: String? = nil

    var sentences: [String] { [capture, judgment, never] + [sync, telemetry].compactMap { $0 } }

    /// The boundary as it currently stands.
    ///
    /// `cloudReachable` is the ONE input, because it is the one thing that changes the
    /// answer. Note what is NOT a parameter: which provider, which model, how many calls
    /// remain. The user experiences "Ezra thought", never a vendor or a budget — v5 cuts
    /// provider names and usage mechanics from customer-facing language entirely.
    static func current(
        cloudReachable: Bool,
        telemetry: Bool = false, syncLive: Bool = HouseholdSync.isLive
    ) -> DataBoundary {
        var boundary = base(cloudReachable: cloudReachable)
        if telemetry { boundary.telemetry = Telemetry.boundarySentence }
        if syncLive { boundary.sync = syncSentence }
        return boundary
    }

    /// The capture boundary in one short line, for a surface that has no room for the
    /// paragraph (2026-09-20).
    ///
    /// Written for onboarding's paste screen, which asks for "everything on your mind" —
    /// the largest block of raw personal text this product will ever receive, typed by
    /// someone ninety seconds into knowing it, and (being unstructured) exactly the shape
    /// the router escalates. It said nothing at all about where those words were read.
    /// The full `capture` sentence is around two hundred characters; under a 220-point
    /// editor at accessibility-extra-large that is a wall, and the screen already has a
    /// primary and a secondary button to fit. So: the same two facts, in the same
    /// vocabulary the Activity byline uses ("Read on your device"), short enough to read.
    ///
    /// It carries the SAME truth conditions as the long form, including the one that
    /// matters most — on a build with no cloud reachable it promises the words are not
    /// sent to be read, because they are not. It says "to be understood" rather than
    /// "anywhere" on purpose (2026-09-20): this screen is shown without the sync
    /// sentence beside it, and on a signed-in phone the person's own copy does go to
    /// their own iCloud. Claim the thing that is true. See `neverSentence`.
    /// The capture sentence for the moment it is read — the empty home's, which cannot
    /// name the cloud seam itself (the household chat is grep-pinned on-device).
    static var captureShortNow: String { captureShort(cloudReachable: CloudModel.isAvailable) }

    static func captureShort(cloudReachable: Bool) -> String {
        cloudReachable
            ? "Read on your device first. A long brain dump may go to the cloud for a deeper read."
            : "Read on your device. Your words are not sent anywhere to be understood."
    }

    /// The promise that holds under every configuration — and it is about US, not about
    /// the device (corrected 2026-09-20).
    ///
    /// **It used to read "Your corrections and your history never leave this device", and
    /// that was not true.** The private store carries
    /// `NSPersistentCloudKitContainerOptions` at `.private` scope with no entity
    /// exclusions, so on a signed-in phone EVERY entity — `Correction`, `Capture`,
    /// `UserProfile`, the learned caches — mirrors to the person's own iCloud. What the
    /// old sentence was actually describing is the `CKShare`: those entities carry no
    /// `household` edge, so they never reach anyone the person invites. That is a real
    /// and important guarantee, and it is not the one the words made.
    ///
    /// A privacy sentence that is wrong in the person's favour is still wrong, and this
    /// one is on the screen where the app asks to be believed. So it says the two things
    /// that ARE true and are the ones a person actually cares about: nothing reaches us,
    /// and nothing reaches the people they share with. Where their own copy lives is the
    /// sync sentence's job, because "your own iCloud" is a place they already understand.
    static let neverSentence =
        "Your corrections and the record of what you changed never reach us, and are never "
        + "shared with anyone you invite."

    /// Sync, in the person's words: WHO sees, not which cloud carries it. No vendor.
    static let syncSentence =
        "Your tasks are kept in your own iCloud, so they are on all your devices — and "
        + "shared with someone else only after you invite them."

    private static func base(cloudReachable: Bool) -> DataBoundary {
        guard cloudReachable else {
            return DataBoundary(
                capture: "Everything you capture is understood on this device.",
                judgment: "Nothing is sent anywhere to prepare your advice.",
                never: neverSentence)
        }
        return DataBoundary(
            // Rewritten 2026-08-29, the honest half of the device-first routing change
            // (its 08-22 predecessor said the reverse: only typed lists stayed local).
            // Now every capture is read on the device first, and the raw words travel
            // only when that instant read shows evidence it fell short — a big dump,
            // one draft against many boundary signals, an unresolved time phrase,
            // dropped content. Say the common case first and name the exception in the
            // user's terms, never the mechanism's.
            capture:
                "Ezra reads everything you capture here on your device first. Your words "
                + "go to the cloud only when that quick reading doesn't look good enough — "
                + "usually a big brain dump that needs a deeper read.",
            // The asymmetry that makes the first sentence acceptable: capture parsing
            // genuinely needs the verbatim words (there is no snapshot-shaped version of a
            // brain dump); judgment does not, and never gets them.
            judgment:
                "To prepare your advice, only structured task information "
                + "goes out — titles, dates and flags, never your raw notes.",
            never: neverSentence)
    }
}
