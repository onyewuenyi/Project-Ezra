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
    ///
    /// `rung` chooses WHERE it generates. Same prompt, same `@Generable` schema, same
    /// `validated(against:)` boundary — the cloud arm is not trusted more for being
    /// expensive, and `ValidatedReading` still drops or degrades rather than substituting.
    /// **Silence survives the upgrade too**: a cloud model must be allowed to answer
    /// `nothing`, or the spend buys noise.
    ///
    /// The DEADLINE, however, is per rung and per presence — see
    /// `ModelDeadline.advisorSeconds`. One number for every rung was a real bug: 20s is
    /// right for a local read and far too short for deep reasoning, so the paid rung would
    /// have timed out routinely while everything said it worked.
    func read(
        _ facts: TaskAdvisorFacts, rung: IntelligenceRung = .onDevice, presenceTime: Bool = true
    ) async -> ModelResult<ValidatedReading> {
        // The on-device arm answers inside a 4096-token window on the phone, and the
        // facts block carries free text the person wrote (notes, the capture, the
        // reasoning) plus five retrieved neighbours. A block that overflows fails the
        // call outright — `contextSizeExceeded`, the reading falls to rung 0 and nothing
        // says why. Fit it FIRST, by the model's own count, giving up the cheapest lines.
        // Only the PROMPT is fitted: the scope (the session key), the validation and
        // the evidence all read the original facts, so a clipped notes line can never
        // change which session answers or what "Why this?" shows.
        //
        // **The CLOUD arm gets none of the person's own words (2026-09-20).** It used to
        // get `facts` whole — `NOTES:`, `THEY SAID:` (the verbatim capture) and
        // `WHY IT EXISTS:` included, unclipped, straight to the provider — while the
        // screen where the app states what leaves this device said, in as many words,
        // "only structured task information goes out — titles, dates and flags, never
        // your raw notes". The design note in `DataBoundary` says the same thing and
        // explains why it matters: capture parsing genuinely needs the verbatim words,
        // and judgment does not, and that asymmetry is what makes the capture sentence
        // acceptable at all. The code had drifted off its own contract, and the drift
        // ran the wrong way — an explicit negative promise about a transmission that was
        // happening. `.bare` is exactly the promised shape: title, sensors and graph,
        // with the free text and the learned preferences (which are built from the
        // person's corrections, and those never leave) dropped.
        //
        // It costs the cloud reading the notes and the capture quote, which is a real
        // quality cost, knowingly paid. Safe defaults for data is one of the two things
        // this project never relaxes, and a promise on the privacy screen is not a place
        // to spend quality budget.
        let fitted = rung == .cloud ? facts.trimmed(to: .bare) : await Self.fitted(facts)
        let outcome = await ModelRun.perform(
            .taskAdvisor,
            deadline: ModelDeadline.advisorSeconds(rung: rung, presenceTime: presenceTime)
        ) {
            switch rung {
            case .cloud:
                // Per call, no pool: a warm spare buys a hot LOCAL prefix, and there is
                // no local prefix on a network call. Throws surface through `ModelRun`.
                let session = try CloudModel.provider.session(
                    instructions: Self.instructions, config: CapabilityProfiles.taskAdvisor)
                return try await session.respond(
                    to: Self.prompt(for: fitted), generating: TaskAdvisorReading.self
                ).content
            case .onDevice, .facts, .memory:
                // The ZERO-TURN inquiry (G2): the reading is generated over the task's own
                // scope in `.reading` mode — the same session home the chat uses, keyed
                // by (task, fingerprint), adopting the spare `prewarm()` left. `.facts` /
                // `.memory` never reach here — they are answered before a judge is called
                // — so treating them as on-device is a total switch, not a fallback.
                let scope = TaskInquiryScope(taskID: facts.id ?? UUID(), facts: facts, mode: .reading)
                return try await InquiryService.shared.respond(
                    scope, prompt: Self.prompt(for: fitted), generating: TaskAdvisorReading.self)
            }
        }
        // **Salvage down a rung rather than surfacing a failure.** A deep read that ran out
        // of time has not shown there is nothing to say — it has shown THIS rung could not
        // say it in the time available, which is a different claim. Falling back to
        // on-device produces a real judgment (cheaper, and the one most tasks get anyway)
        // where the alternative is an empty surface or a retry line asking the user to
        // request thinking they never asked for.
        //
        // Guarded on `.cloud`, so it cannot recurse: the on-device arm's own timeout is a
        // genuine failure with nowhere cheaper to go.
        if rung == .cloud, case .timedOut = outcome {
            return await read(facts, rung: .onDevice, presenceTime: presenceTime)
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

    /// The facts, trimmed until their prompt fits the on-device window beside the fixed
    /// overhead (instructions, the guided schema, the answer budget). The count is the
    /// model's own (`tokenCount(for:)`, iOS 27), never a character estimate — the two
    /// disagree by a factor that depends on the text. Off-device, or when the model
    /// cannot count, the facts return untouched: fitting is a courtesy, not a gate.
    ///
    /// The prompt's token count is recorded for `.taskAdvisor` on every fit, so the
    /// diagnostics card can show how close the phone's readings run to the window.
    static func fitted(_ facts: TaskAdvisorFacts) async -> TaskAdvisorFacts {
        guard AppBrain.onDeviceModelAvailable() else { return facts }
        let model = SystemLanguageModel.default
        guard let overhead = await fixedOverheadTokens() else { return facts }
        let budget = model.contextSize - overhead
        var current = facts
        for level in TaskAdvisorFacts.TrimLevel.allCases {
            current = facts.trimmed(to: level)
            guard let tokens = try? await model.tokenCount(for: current.promptBlock) else { return facts }
            if tokens <= budget {
                ModelMetrics.shared.recordTokens(
                    .taskAdvisor, promptTokens: tokens, contextSize: model.contextSize)
                return current
            }
        }
        return current
    }

    /// Instructions + schema + the answer budget + a margin, in the model's tokens.
    /// Counted once per launch — none of it changes.
    private static var overheadCache: Int?

    private static func fixedOverheadTokens() async -> Int? {
        if let cached = overheadCache { return cached }
        let model = SystemLanguageModel.default
        guard let instructionTokens = try? await model.tokenCount(for: Instructions(instructions)),
            let schemaTokens = try? await model.tokenCount(for: TaskAdvisorReading.generationSchema)
        else { return nil }
        let answer =
            CapabilityProfiles.taskAdvisor.maximumResponseTokens ?? CapabilityProfiles.defaultAnswerTokens
        let total = instructionTokens + schemaTokens + answer + overheadMargin
        overheadCache = total
        return total
    }

    /// Room for the framework's own framing around a guided call.
    static let overheadMargin = 128

    /// Warm the Advisor's prefix while a detail page settles — a spare for the static
    /// instructions, adopted by the first task judged. A no-op off-device and under tests;
    /// safe to call on every page activation because a waiting spare is not rebuilt.
    static func prewarm() {
        InquiryService.shared.prewarmSpare(instructions: instructions, config: CapabilityProfiles.taskAdvisor)
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
        - decide: a choice must be made before this can move; provide the options.
          A task worded as a choice, or carrying a decision flag, is a decide — not an
          observation that it is a choice.
        - createSteps: it is too large to start as one action; provide the steps.
          A broad job with several parts is a createSteps, even when you could instead
          describe it.
        - openBlocker: something named in the facts is in the way; the blocker is the
          work, not this task.
        - advise: the words are the help and no specific move above applies. This is the
          fallback, not the default — if one of the three above fits, use it.
        - nothing: the small, clear, unobstructed task where anything you could say is
          already on the screen. An honest answer — but the rare one.

        Default to saying ONE useful thing. Most tasks a family captures are not
        trivial — "renew the car insurance", "sort out the school forms", "get the loft
        measured" all have something worth naming. A short useful line beats both
        silence and a paragraph. Do not force output: when the facts genuinely contain
        nothing you can add, say nothing. But do not reach for silence, or for a vague
        remark, because choosing the specific move is harder.

        Every emission must answer: what became better for the person because I said
        this? Improvement means one of: named the real obstacle · sized the first step ·
        surfaced a dependency they would have missed · framed a choice they were
        circling · said what a fact MEANS rather than that it exists. If none apply, say
        nothing.

        The next move is the SMALLEST USEFUL COMMITMENT that changes the task's state —
        "Choose the destination", never "Plan the vacation". You are reducing
        uncertainty or adding momentum by one step; you are not trying to finish the
        task in one instruction.

        Every sentence must earn its space. The observation is ONE sentence, at most 20
        words. Guidance is the second layer, read only if the person asks for more — so
        put the single most useful thing in the observation and let guidance carry the
        why. Three fields in the schema is not a reason to write three sentences.

        Certainty lives in your grammar, never in a number. Match the wording to the
        evidence you actually have:
        - settled fact → "You're overdue."
        - evidence-based read → "The blocker appears to be choosing a provider."
        - weak evidence → "It may be worth deciding whether…"
        - not enough → "There's not enough information here to recommend one option."

        Never restate what the screen already shows. The person can see the due date, the
        estimate, the blocker list and the step count. An observation that only repeats
        one of them is noise. Say what it MEANS, or say nothing:

        Task: "Renew car insurance" — due in 14 days, no notes
          BAD:  "This task is due in two weeks. Make sure to check rates."
          GOOD: (nothing)

        Task: "Renew car insurance" — note: "Policy #88102 expires 8/20"
          BAD:  "Policy #88102 expires on August 20th."
          GOOD: "Switching carriers needs a few days' overlap, so the call is this week."

        Task: "Renovate the kitchen" — 120 min, note: "cabinets, counters, leaking sink"
          BAD:  "The task involves renovating the kitchen, including cabinets, counters
                 and the leaking sink, and is not started."
          GOOD: createSteps — the sink leak is the one with a deadline attached to it.

        Task: "Get the loft measured" — the insulation quote waits on it
          BAD:  "This task is blocking one other task."
          GOOD: "The insulation quote can't move until this is done."

        Hard rules:
        - The FACTS are authoritative and complete. Never invent a blocker, a person, a
          date, a number, or a consequence that is not in them. SENSOR lines are
          deterministic readings — interpret them, never contradict them.
        - Never invent urgency and never issue a progress verdict. Call something
          urgent only when the facts say URGENT; say the person hasn't moved on it only
          when a SENSOR line says so.
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
