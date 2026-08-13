//
//  TaskAdvisorService.swift
//  Project-Ezra
//
//  The Advisor's one model call — deliberately CALL-shaped, not session-shaped, in V1.
//  The existing card-service pattern (`CapabilityProfiles.session` + `ModelRun.perform`)
//  is proven, and the deferred upgrades each have a named re-entry tripwire:
//  streaming + salvage returns iff device `ModelMetrics` shows meaningful `.timedOut`
//  counts here; a `related_task` tool returns iff readings are demonstrably starved for
//  context the deterministic package didn't carry; a per-task session with delta turns
//  returns when the evolving-Advisor loop wants conversational continuity. The risk
//  right now is overengineering before the judgment quality is proven — not the reverse.
//
//  The model never owns the diagnosis: `TaskAdvisorFacts` states the sensors' readings
//  as facts, the instructions walk the five questions, and `validated(against:)` is the
//  trust boundary that turns untrusted transport into the `ValidatedReading` contract.
//
//  ⚠️ Device-verify: the schema decode, reveal latency at `.moderate` reasoning, and
//  the `nothing` frequency on real data (`-AdvisorDiagnostics`).
//

import Foundation
import FoundationModels

struct TaskAdvisorService {

    /// One reading, bounded by `ModelDeadline.cardSeconds` — ambient, so nobody tapped,
    /// but the page is on screen and a hung generation would pin the loading treatment.
    /// Validation failure reads as `noUsableOutput`: a response arrived, but nothing a
    /// user could be shown survived the trust boundary.
    func read(_ facts: TaskAdvisorFacts) async -> ModelResult<ValidatedReading> {
        let outcome = await ModelRun.perform(.taskAdvisor, deadline: ModelDeadline.cardSeconds) {
            let session = CapabilityProfiles.session(
                instructions: Self.instructions, config: CapabilityProfiles.taskAdvisor)
            return try await session.respond(
                to: Self.prompt(for: facts), generating: TaskAdvisorReading.self
            ).content
        }
        switch outcome {
        case .success(let reading):
            guard let validated = reading.validated(against: facts) else {
                return .failed(ModelResult<ValidatedReading>.noUsableOutput)
            }
            return .success(validated)
        case .unavailable: return .unavailable
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .failed(let label): return .failed(label)
        }
    }

    /// The related-work package, computed at generation time (never in `make` — the
    /// facts build runs on every page activation and must stay cheap, while retrieval
    /// may run embedding inferences). Detached, pure over value snapshots.
    static func relatedLines(
        for facts: TaskAdvisorFacts, among tasks: [TaskItem]
    ) async
        -> [String]
    {
        let selfID = facts.id
        let exclude = Set(facts.blockerIDs + facts.childIDs)
        let query = facts.title
        let category = facts.category
        let snapshots = tasks.compactMap { task -> OpenTaskSnapshot? in
            guard let id = task.uuid, id != selfID, !exclude.contains(id),
                !task.status.isResolved
            else { return nil }
            return OpenTaskSnapshot(
                id: id, title: task.title, category: task.category,
                updatedAt: task.updatedAt, dueDate: task.dueDate)
        }
        return await Task.detached {
            ContextRetrieval.candidates(matching: query, category: category, among: snapshots)
                .prefix(TaskAdvisorFacts.relatedCap)
                .map { candidate in
                    candidate.facts.isEmpty
                        ? candidate.title : "\(candidate.title) (\(candidate.facts))"
                }
        }.value
    }

    /// The five questions ARE the prompt structure — the Advisor reasons through them
    /// before committing to a move. Stable instructions (this string) first, volatile
    /// facts last: the KV-cache discipline.
    static let instructions = """
        You are a quiet, competent advisor sitting inside one task, answering a single
        question: what would make this task easier right now?

        Reason through five questions, in order, before you answer:
        1. What is the person trying to accomplish?
        2. What is preventing progress?
        3. What do they need right now?
        4. What is the best intervention?
        5. What should happen next?

        Then return ONE reading — an observation, guidance, the best next move, and the
        shape of help (action). Exactly one of:
        - nothing: the task is clear and needs no help. A good answer — return it
          whenever you have nothing useful to add. Silence beats noise.
        - advise: the words are the help; no button applies.
        - decide: a choice must be made before this can move; provide the options.
        - createSteps: it is too large to start as one action; provide the steps.
        - openBlocker: something named in the facts is in the way; the blocker is the
          work, not this task.

        Hard rules:
        - The FACTS are authoritative and complete. Never invent a blocker, a person, a
          date, a number, or a consequence that is not in them. SENSOR lines are
          deterministic readings — interpret them, never contradict them.
        - Recommendation requires evidence. For decide: 2 to 4 options drawn only from
          the task's own wording and context, and a recommendation must copy one of
          YOUR OWN option labels exactly. When the facts don't clearly favor one, leave
          it empty — an honest abstention beats a coin flip dressed as advice.
        - For createSteps: 2 to 5 steps, each independently doable and phrased as an
          action, effortMinutes one of 15, 30, 60, or 120. Never invent scope.
        - An open DECISION FLAG is strong evidence for decide.
        - A Start button already exists on this screen. Express readiness as advice —
          "You're ready to start; begin with X" — never as an instruction to tap
          something.
        - You never decide, start, or change anything — the person does.
        - Reporting, never scoring: no streaks, no guilt, no pep talk, no exclamation
          marks, no emoji.
        - INTERNAL lines are context for you alone; never repeat their wording.
        """

    /// Pure — the whole per-task prompt is the facts block (pinned by
    /// `TaskAdvisorPromptTests`, and its "FACTS:" head is the prewarm prefix).
    static func prompt(for facts: TaskAdvisorFacts) -> String {
        facts.promptBlock
    }
}
