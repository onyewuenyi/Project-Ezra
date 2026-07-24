//
//  PersonalContextTools.swift
//  Project-Ezra
//
//  Personal context as callable tools, not prompt stuffing: the context budget
//  is small, so the local index is exposed as narrow, deterministic tools the
//  model invokes only when it needs them. This is the wedge a server-side
//  parser structurally can't match — the on-device model can know the user's
//  life because the data never leaves the device.
//
//  v1 ships exactly one tool. `resolveTimeframe`/`resolveProject` are
//  deliberately absent: dates must stay OUT of the model (deterministic
//  resolution is `IntentResolver`'s whole point), and there is no project
//  concept. Known Xcode 27 beta caveat (see CLAUDE.md): guided generation can
//  over-call tools — keep tools narrow, tighten wording before blaming code.
//

import Foundation
import FoundationModels

/// Resolve a spoken name against the household roster. "Call Sarah about the
/// thing" → the one Sarah the user actually lives with, plus the relationship
/// context — the ambiguity gap a task server can't close.
struct ResolvePersonTool: Tool {
    let name = "resolve_person"
    let description =
        "Look up a person the user mentioned by name against their household roster. "
        + "Call this whenever the capture names a person, before setting personReference."

    /// Value snapshot of the roster — Sendable, no NSManagedObjectContext in the loop.
    let roster: [RosterPerson]

    @Generable
    struct Arguments {
        @Guide(description: "The person's name exactly as the user said it.")
        let name: String
    }

    func call(arguments: Arguments) async throws -> String {
        let query = arguments.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return "No name given." }
        let match =
            roster.first { $0.name.lowercased() == query }
            ?? roster.first {
                $0.name.lowercased().hasPrefix(query) || query.hasPrefix($0.name.lowercased())
            }
        if let match {
            return
                "\(match.name) — \(match.relationship) in the user's household. "
                + "Use “\(match.name)” verbatim as personReference."
        }
        return
            "No household match for “\(arguments.name)” — treat them as outside the household "
            + "and copy the name exactly as the user said it."
    }
}
