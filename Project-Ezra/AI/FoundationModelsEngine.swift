//
//  FoundationModelsEngine.swift
//  Project-Ezra
//
//  Real on-device intelligence via Apple's Foundation Models (iOS 26+). Used when
//  `SystemLanguageModel.default.availability == .available`. Everything runs
//  locally — nothing about the user's messy life leaves the device, which is the
//  right default for family logistics / personal task data.
//
//  Guided generation (@Generable) constrains the model's output to a typed schema,
//  so we never parse fragile JSON. The model emits INTENTS with raw ambiguity
//  intact — time phrases and person names verbatim, never resolved. Resolution is
//  the deterministic `IntentResolver`'s job, in app code, so which Friday "next
//  week" means is never a generation artifact.
//

import Foundation
import FoundationModels

struct FoundationModelsEngine: AIEngine {
    let engineName = "Apple Intelligence (on-device)"
    let isOnDevice = true

    func triage(
        rawText: String,
        context: TriageContext,
        onPartial: (@MainActor ([TaskIntent]) -> Void)?
    ) async throws -> [TaskIntent] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let session = Self.makeSession(context: context)
        let prompt = Self.prompt(for: trimmed, context: context)

        guard let onPartial else {
            let result = try await session.respond(to: prompt, generating: TriageResult.self).content
            return result.tasks.map { $0.toIntent() }
        }

        // Streaming fast path: each snapshot surfaces the complete-enough
        // candidates immediately, so tasks appear while generation is still
        // running — the felt-magic half of the two-speed loop. The final,
        // fully-generated result is still what the caller gets back.
        let stream = session.streamResponse(to: prompt, generating: TriageResult.self)
        for try await snapshot in stream {
            let intents = Self.intents(fromPartial: snapshot.content)
            if !intents.isEmpty {
                await onPartial(intents)
            }
        }
        let final = try await stream.collect().content
        return final.tasks.map { $0.toIntent() }
    }

    // MARK: - Household narrative

    /// Phrase the household's operating status in one or two calm sentences, over
    /// the facts the engine already computed. Guided generation constrains the
    /// output to a single string; the instructions forbid inventing anything, so
    /// the model can only rephrase the facts it's handed — never fabricate tasks,
    /// people, or numbers. Device-verify: the simulator can't exercise `@Generable`.
    func householdNarrative(_ facts: HouseholdFacts) async throws -> String {
        let session = LanguageModelSession(instructions: Self.narrativeInstructions)
        let result = try await session.respond(
            to: Self.narrativePrompt(facts), generating: HouseholdNarrative.self
        ).content
        let sentence = result.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never surface an empty bubble — fall back to the deterministic template.
        return sentence.isEmpty ? HeuristicEngine.narrative(from: facts) : sentence
    }

    private static let narrativeInstructions = """
        You are a calm, understated household coordinator. Given a set of FACTS about
        how a family's shared work is going, write ONE or at most TWO short, plain
        sentences summarizing how the household is operating right now.

        Hard rules:
        - Restate ONLY the facts you are given. Never invent a task, a person, a
          number, or a commitment that is not in the facts.
        - No pep talk, no exclamation marks, no emoji. Warm but plain.
        - Name a person only if they appear in the facts, and spell their name exactly.
        - If nothing needs attention, say so briefly rather than manufacturing concern.
        """

    private static func narrativePrompt(_ facts: HouseholdFacts) -> String {
        var lines = ["Status: \(facts.status)"]
        if !facts.memberSummaries.isEmpty {
            lines.append("People: " + facts.memberSummaries.joined(separator: "; "))
        }
        lines.append(
            "Counts: overdue \(facts.overdueCount), blocked \(facts.blockedCount), "
                + "needs-decision \(facts.needsDecisionCount), unowned \(facts.unownedCount)")
        if !facts.upcoming.isEmpty {
            lines.append("Upcoming: " + facts.upcoming.joined(separator: "; "))
        }
        return "FACTS\n" + lines.joined(separator: "\n")
    }

    /// The user prompt: the raw brain-dump, plus the open working set when
    /// present so the model can flag reverse dependencies (existing tasks that
    /// must wait on a new one). Capped — the context budget is small.
    private static func prompt(for text: String, context: TriageContext) -> String {
        var prompt = "Here is the user's raw brain-dump. Turn it into structured task intents:\n\n\(text)"
        if !context.candidates.isEmpty {
            let lines = context.candidates.map { "[\($0.id.uuidString)] \($0.title) — \($0.facts)" }
            prompt +=
                "\n\nCANDIDATES — the user's existing tasks most related to this capture. These "
                + "uuids are the ONLY valid ids for blocksExistingTasks, duplicateOfID, and "
                + "childOfID: copy one EXACTLY, or use null. Never invent an id.\n"
                + lines.joined(separator: "\n")
        }
        return prompt
    }

    /// Sessions are per-call today (stateless), so personalization is plain
    /// instruction text appended at creation; `LanguageModelSession
    /// .DynamicInstructions` is the API to adopt when the session becomes
    /// continuous. The resolve-person tool attaches only when a roster exists.
    private static func makeSession(context: TriageContext) -> LanguageModelSession {
        var instructions = Self.instructions
        if let personalization = context.personalization {
            instructions += "\n\n" + personalization
        }
        guard !context.roster.isEmpty else {
            return LanguageModelSession(instructions: instructions)
        }
        instructions += """


            When the capture names a person, call the resolve_person tool once for that \
            name and use the returned name verbatim as personReference. Do not call it \
            for pronouns or when no person is named.
            """
        return LanguageModelSession(
            tools: [ResolvePersonTool(roster: context.roster)],
            instructions: instructions
        )
    }

    /// Map a partial snapshot to the candidates that are complete enough to
    /// show: title + category present, everything else defaulted. Total and
    /// tiny by design — this is the only code that touches macro-generated
    /// `PartiallyGenerated` shapes.
    private static func intents(fromPartial partial: TriageResult.PartiallyGenerated) -> [TaskIntent] {
        (partial.tasks ?? []).compactMap { task in
            guard let title = task.title, !title.isEmpty else { return nil }
            let category =
                task.category.flatMap { raw in
                    TaskCategory.all.first { $0.caseInsensitiveCompare(raw) == .orderedSame }
                } ?? "Admin"
            return TaskIntent(
                title: title,
                category: category,
                dateExpression: task.dateExpression ?? nil,
                personReference: task.personReference ?? nil,
                blockerPhrase: (task.isBlocked ?? false) ? (task.blockedBy ?? nil) : nil,
                confidence: min(max(task.confidence ?? 0.5, 0), 1),
                isJudgmentCall: task.isJudgmentCall ?? false,
                reasoning: task.reasoning ?? "",
                isUrgent: task.isUrgent ?? false,
                importance: (task.importance ?? nil).map { min(max($0, 0), 1) },
                effortMinutes: (task.effortMinutes ?? nil).flatMap { $0 > 0 ? min($0, 8 * 60) : nil }
            )
        }
    }

    private static let instructions = """
        You are a proactive personal assistant. You turn a person's informal, messy
        list of errands and to-dos into clean, structured task intents — and, like a
        good assistant, you fill in the sensible defaults they didn't spell out so
        nothing needs babysitting. Infer; don't interrogate. For each distinct task:

        - title: rewrite as a short verb-led action, max 8 words. No trailing period.
        - category: exactly one of \(TaskCategory.all.joined(separator: ", ")). \
          Use Admin only when nothing else fits.
        - confidence: 0.0 to 1.0 — how sure you are the CATEGORY AND FRAMING are right, \
          nothing else. Be honest; use lower values when the text is vague. Do NOT raise \
          confidence just because you filled in a date, effort, priority, or person — \
          those are helpful guesses the user can correct, not certainties.
        - isJudgmentCall: true ONLY when the item is a values or life-priority \
          decision that a person must make themselves (e.g. "should I quit this \
          project", "is this goal still worth it", "cancel the commitment"). \
          These are never yours to resolve, no matter how confident you are.
        - isBlocked: true when the task depends on something else happening first — \
          both explicit ("after X", "once Y", "waiting on Z") and clearly implied \
          (you can't book the flight before the dates are confirmed).
        - blockedBy: when isBlocked, the short name of the thing it waits on \
          ("passport", "the Q3 deck"), without filler words; otherwise null.
        - isUrgent: true ONLY when the wording carries real time pressure — a hard \
          deadline, a bill about to be late, "asap". False otherwise.
        - importance: 0.0 to 1.0, judged by CONSEQUENCE not urgency — real fallout if \
          missed is high (~0.8+), an ordinary task is ~0.4, someday / no-rush is low. \
          Always give your best estimate.
        - personReference: the other person's first name EXACTLY as the user said it \
          whenever the task most naturally belongs to them ("ask Sarah to book the \
          venue" → Sarah); null when it reads as the user's own. Copy the name \
          verbatim — never resolve or normalize it.
        - effortMinutes: ALWAYS give your best rough estimate for a real task — never \
          leave it null. A quick call/text/reply ≈ 5–15, a simple errand ≈ 30, a \
          meaningful chunk of focused work ≈ 60 or more. Cap at a full workday (480).
        - reasoning: one short, plain sentence explaining your categorization.
        - dateExpression: the user's time phrase COPIED VERBATIM ("tomorrow", "next \
          week", "friday", "before the trip") whenever the task has any time \
          dimension. Do NOT resolve it to a date — never output a computed date the \
          user didn't say. Null only for genuinely open-ended items with no time \
          pressure at all.

        - duplicateOfID / childOfID: when a CANDIDATES list is provided, decide whether \
          this task is the SAME as one of them (set duplicateOfID + duplicateConfidence) \
          or a STEP OF one of them (set childOfID + childConfidence). Copy the id EXACTLY \
          from CANDIDATES; use null when unsure. Never set both for one task.
        - workIntent: what KIND of work this is — action, decision, planning, or \
          reference. Use "decision" ONLY when the task is genuinely choosing between options.

        If a line is a header, a note to self with no action, or empty, skip it.
        """
}

// MARK: - Guided-generation schema

/// The household summary, constrained to a single calm string so the model can
/// only rephrase the given facts — not emit a structure it might pad with invention.
@Generable
struct HouseholdNarrative {
    @Guide(
        description:
            "One or two short, plain sentences summarizing how the household is operating. Restate only the given facts; invent nothing; no exclamation marks."
    )
    let sentence: String
}

@Generable
struct TriageResult {
    @Guide(description: "Every distinct actionable task found in the user's text.")
    let tasks: [ExtractedTask]
}

@Generable
struct ExtractedTask {
    @Guide(description: "Short verb-led action, max 8 words, no trailing period.")
    let title: String

    @Guide(description: "Exactly one category name from the provided list.")
    let category: String

    @Guide(description: "Confidence from 0.0 to 1.0 that the category and framing are correct.")
    let confidence: Double

    @Guide(description: "True only for values/life-priority decisions the user must make themselves.")
    let isJudgmentCall: Bool

    @Guide(
        description:
            "True when the task depends on something else finishing first, whether stated or clearly implied."
    )
    let isBlocked: Bool

    @Guide(
        description:
            "When isBlocked, the short name of what it waits on (e.g. \"passport\"); otherwise null.")
    let blockedBy: String?

    @Guide(
        description:
            "True when the wording marks this as urgent — a hard deadline, a bill about to be late, \"asap\", real time pressure. False otherwise."
    )
    let isUrgent: Bool

    @Guide(
        description:
            "Importance from 0.0 (trivial) to 1.0 (critical), judged by CONSEQUENCE not urgency — real fallout if missed is high (~0.8+), ordinary is ~0.4, someday is low. Always give a best estimate."
    )
    let importance: Double?

    @Guide(
        description:
            "The other person's first name copied verbatim from the user's words (\"ask Sarah to…\" → Sarah); null when it reads as the user's own. Never normalize or resolve the name."
    )
    let personReference: String?

    @Guide(
        description:
            "ALWAYS a best-guess rough effort in minutes for a real task — never null. Quick call ≈ 5–15, errand ≈ 30, focused work ≈ 60+. Cap at 480."
    )
    let effortMinutes: Int?

    @Guide(description: "One short plain-language sentence explaining the categorization.")
    let reasoning: String

    @Guide(
        description:
            "The user's time phrase copied VERBATIM (\"tomorrow\", \"next week\", \"friday\") when the task has a time dimension; null otherwise. Never a computed or resolved date the user didn't say."
    )
    let dateExpression: String?

    @Guide(
        description:
            "Titles of the user's EXISTING open tasks (copied exactly from the provided list) that logically cannot proceed until THIS new task is done. Only when the dependency is clear (e.g. booking flights waits on the passport). Empty when none or when no list was provided."
    )
    let blocksExistingTasks: [String]?

    @Guide(
        description:
            "If this task is the SAME as one in CANDIDATES (a duplicate), that candidate's id copied EXACTLY from the list; otherwise null. Never invent an id."
    )
    let duplicateOfID: String?

    @Guide(description: "Confidence 0.0–1.0 that duplicateOfID is truly the same task; 0 when null.")
    let duplicateConfidence: Double?

    @Guide(
        description:
            "If this task is a STEP OF a larger one in CANDIDATES (its child/subtask), that parent's id copied EXACTLY; otherwise null. Never invent an id."
    )
    let childOfID: String?

    @Guide(description: "Confidence 0.0–1.0 that childOfID is truly the parent; 0 when null.")
    let childConfidence: Double?

    @Guide(
        description:
            "What KIND of work this is — exactly one of: action, decision, planning, reference. Use decision ONLY when the task is choosing between options."
    )
    let workIntent: String?

    func toIntent() -> TaskIntent {
        let cat = TaskCategory.all.first { $0.caseInsensitiveCompare(category) == .orderedSame } ?? "Admin"
        return TaskIntent(
            title: title,
            category: cat,
            dateExpression: Self.trimmedOrNil(dateExpression),
            personReference: Self.trimmedOrNil(personReference),
            blockerPhrase: isBlocked ? Self.trimmedOrNil(blockedBy) : nil,
            confidence: min(max(confidence, 0), 1),
            isJudgmentCall: isJudgmentCall,
            reasoning: reasoning,
            isUrgent: isUrgent,
            importance: importance.map { min(max($0, 0), 1) },
            effortMinutes: effortMinutes.flatMap { $0 > 0 ? min($0, 8 * 60) : nil },
            blocksExisting: (blocksExistingTasks ?? []).compactMap(Self.trimmedOrNil),
            duplicateOf: Self.edgeRef(duplicateOfID, duplicateConfidence),
            childOf: Self.edgeRef(childOfID, childConfidence),
            workIntent: Self.trimmedOrNil(workIntent)?.lowercased()
        )
    }

    /// Parse a model-supplied candidate id + confidence into an `EdgeReference`. Nil for a
    /// null/blank/unparseable id — the resolver additionally validates membership.
    private static func edgeRef(_ id: String?, _ confidence: Double?) -> EdgeReference? {
        guard let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines),
            let uuid = UUID(uuidString: trimmed)
        else { return nil }
        return EdgeReference(targetID: uuid, confidence: min(max(confidence ?? 0, 0), 1))
    }

    private static func trimmedOrNil(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.count > 1
        else { return nil }
        return trimmed
    }
}
