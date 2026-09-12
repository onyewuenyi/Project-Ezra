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
//    3. your corrections and your history never leave this device
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
        cloudReachable: Bool, posture: CapturePosture = .open,
        telemetry: Bool = false, syncLive: Bool = HouseholdSync.isLive
    ) -> DataBoundary {
        var boundary = base(cloudReachable: cloudReachable, posture: posture)
        if telemetry { boundary.telemetry = Telemetry.boundarySentence }
        if syncLive { boundary.sync = syncSentence }
        return boundary
    }

    /// Sync, in the person's words: WHO sees, not which cloud carries it. No vendor.
    static let syncSentence =
        "Your household's tasks are shared only with the people you invite, and only after you invite them."

    private static func base(cloudReachable: Bool, posture: CapturePosture) -> DataBoundary {
        // The posture (F-03) is the person's own setting, so it is said first when it is
        // on: what leaves the device is something they chose, in their words.
        if posture == .onDevice {
            return DataBoundary(
                capture:
                    "You've set captures to stay on this device. Everything you capture is understood here and never sent anywhere.",
                judgment: cloudReachable
                    ? "Advice may use the cloud, and sends only the task itself — never your captures."
                    : "Nothing is sent anywhere to prepare your advice.",
                never: "Your corrections and your history never leave this device.")
        }
        guard cloudReachable else {
            return DataBoundary(
                capture: "Everything you capture is understood on this device.",
                judgment: "Nothing is sent anywhere to prepare your advice.",
                never: "Your corrections and your history never leave this device.")
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
            never: "Your corrections and your history never leave this device.")
    }
}
