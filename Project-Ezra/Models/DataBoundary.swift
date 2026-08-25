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
//    2. only structured task information leaves for briefings and advice
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
    /// What the Brief and the Advisor send.
    let judgment: String
    /// What never leaves, under any configuration.
    let never: String

    var sentences: [String] { [capture, judgment, never] }

    /// The boundary as it currently stands.
    ///
    /// `cloudReachable` is the ONE input, because it is the one thing that changes the
    /// answer. Note what is NOT a parameter: which provider, which model, how many calls
    /// remain. The user experiences "Ezra thought", never a vendor or a budget — v5 cuts
    /// provider names and usage mechanics from customer-facing language entirely.
    static func current(cloudReachable: Bool) -> DataBoundary {
        guard cloudReachable else {
            return DataBoundary(
                capture: "Everything you capture is understood on this device.",
                judgment: "Nothing is sent anywhere to prepare your brief or your advice.",
                never: "Your corrections and your history never leave this device.")
        }
        return DataBoundary(
            // Rewritten 2026-08-22, and the rewrite is the honest half of a routing
            // change. This used to read "…long, unstructured thoughts, mostly", which
            // was true while a lexicon kept short single sentences local. Routing now
            // keeps local exactly what the user punctuated themselves, so "mostly" had
            // become a comfortable word for "usually not" — the everyday one-liner does
            // go out. Say the common case first and name the exception precisely.
            capture:
                "When you write a list, Ezra reads it here on your device. Anything else — "
                + "a sentence, a paragraph, a brain dump — is understood in the cloud.",
            // The asymmetry that makes the first sentence acceptable: capture parsing
            // genuinely needs the verbatim words (there is no snapshot-shaped version of a
            // brain dump); judgment does not, and never gets them.
            judgment:
                "To prepare your brief and your advice, only structured task information "
                + "goes out — titles, dates and flags, never your raw notes.",
            never: "Your corrections and your history never leave this device.")
    }
}
