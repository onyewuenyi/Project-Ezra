//
//  AppBrain.swift
//  Project-Ezra
//
//  The AI coordinator injected into the environment. It owns engine selection
//  (real on-device model when available, deterministic rules otherwise), exposes
//  a `isProcessing` flag for the "thinking" UI, and commits triaged drafts into
//  SwiftData — logging silent-tier filings to the AI Activity Trail so autonomy
//  never reads as loss of control.
//

import Foundation
import CoreData
import FoundationModels
import Observation

@MainActor
@Observable
final class AppBrain {
    /// Human-readable availability status for the trust/settings surface.
    enum Status {
        case onDevice  // Foundation Models available
        case fallback(reason: String)  // heuristic engine in use

        var isOnDevice: Bool { if case .onDevice = self { return true }; return false }

        var description: String {
            switch self {
            case .onDevice: return "Apple Intelligence · on-device"
            case .fallback(let reason): return "Rules engine · \(reason)"
            }
        }
    }

    private(set) var status: Status
    private let engine: AIEngine

    /// Beta instrumentation (opens, time-to-first-payoff). Lives on the brain so the
    /// commit seam can stamp the first payoff wherever the capture came from.
    let metrics = MetricsRecorder()

    /// Where committed captures' receipts are written (`CaptureProvenance`).
    ///
    /// A `var` so a test can point it at a throwaway file, for the same reason
    /// `PersistenceStack.StoreLocation` is injectable: this one WRITES AND TRIMS A REAL
    /// FILE, so a suite reaching the shared instance would churn the developer's own
    /// capture history as a side effect of testing something else.
    var provenanceStore: CaptureProvenanceStore = .shared

    /// True while a triage call is in flight — drives the soft-glow processing UI.
    var isProcessing = false

    /// What the last confirm produced, for the transient notice the PRESENTING surface
    /// shows once the composer has closed. Parked on the brain rather than returned,
    /// because the notice has to outlive the sheet that earned it — the composer is gone
    /// by the time there is anywhere to draw it. Consumed (read + cleared) by
    /// `RootTabView`, which owns the sheet; cleared again whenever the composer opens, so
    /// a seed-path commit can never leave a stale summary to fire on a later dismiss.
    var lastCommitSummary: CommitSummary?

    init() {
        let (engine, status) = Self.resolveEngine()
        self.engine = engine
        self.status = status
    }

    private static func resolveEngine() -> (AIEngine, Status) {
        // Under XCTest, never probe Foundation Models. The simulator has no on-device
        // model — the heuristic is the path the sim exercises regardless — so this is
        // behavior-identical for tests. It also sidesteps an environmental flake: under
        // a heavy serial test run the `SystemLanguageModel.default.availability` XPC can
        // fault the process against the beta sim's unstable intelligence daemon (a
        // process-level SIGSEGV, not a logic bug). The env var is set only by the test
        // runner, so production is unaffected.
        if isRunningUnderXCTest {
            return (HeuristicEngine(), .fallback(reason: "test"))
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return (FoundationModelsEngine(), .onDevice)
        case .unavailable(let reason):
            return (HeuristicEngine(), .fallback(reason: Self.describe(reason)))
        @unknown default:
            return (HeuristicEngine(), .fallback(reason: "unavailable"))
        }
    }

    /// True inside the XCTest host process. Checks both the runner env var and the
    /// presence of the XCTest runtime (loaded into the host for XCTest *and* Swift
    /// Testing bundles) so the probe-skip is reliable regardless of how the bundle is
    /// launched. The shipping app links neither, so production is never affected.
    /// Internal so the Today plan seam can gate its own availability probe the same way.
    static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "device not eligible"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence off"
        case .modelNotReady: return "model downloading"
        @unknown default: return "unavailable"
        }
    }

    // MARK: - Triage

    /// Warm everything the first capture parse of a session pays for: the shared
    /// on-device model (a no-op off-device / under tests), the `NLEmbedding`
    /// first-touch, and the persisted-vector warm-up — all currently costs that
    /// otherwise land inside the first debounce, on the thread the keyboard needs.
    /// Fire at the moment intent-to-capture is declared (the FAB, `openCapture`,
    /// `resumeCapture`), so the sheet-presentation animation absorbs the cost —
    /// the same trick the Today sequence plays behind its Recap cover.
    static func prewarmCapture(in context: NSManagedObjectContext) {
        // The REAL prefix, not `ModelWarmup`'s anonymous session: a pooled capture
        // session with the true instruction block and prompt head starts warming
        // behind the sheet-presentation animation.
        FoundationModelsEngine.prewarmCaptureSession()
        // The confidence gate runs BEFORE the parse and is the only thing standing
        // Touch the embedding early so the model is resident before the first capture —
        // and, because the first lookup in a process can return nil (see
        // `EmbeddingStore.sentenceEmbedding`), ask again shortly after off the main
        // actor. The accessor caches a success and retries a nil, so this is at most one
        // extra catalog check; without it the first capture's retrieval is the retry.
        if EmbeddingStore.sentenceEmbedding == nil {
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                _ = EmbeddingStore.sentenceEmbedding
            }
        }
        EmbeddingStore.warmUp(in: context)
    }

    // MARK: - The provisional pass (the instant answer)

    /// The deterministic pipeline, rendered BEFORE any model runs — the fix for
    /// capture's real latency problem, which was never that the model is slow but
    /// that it sat on the critical path to seeing anything at all. On device the
    /// heuristic previously ran only as a post-failure fallback (see `triage`), so
    /// the answer this returns in microseconds went unshown for seconds.
    ///
    /// No model, no Core Data, no `await`: `Segmentation` → `HeuristicEngine.intent`
    /// → `IntentResolver.resolve` → `proposeOwners`, all pure value work. It
    /// deliberately passes NO open tasks and NO candidates — `detectDependents` is
    /// O(open set) per draft and `edgeProposals` needs ids only the model emits, and
    /// both are refinements a later parse adds rather than anything the card needs to
    /// render or commit. Everything else the confirm card shows (title, category,
    /// date + reason, owner, blocker, urgent, importance, effort, work intent,
    /// autonomy, `aiOriginal`, learned rules) is here at full parity.
    @MainActor
    static func provisionalDrafts(
        _ rawText: String, learned: [LearnedRule] = [],
        ownership: OwnershipContext = .none, now: Date = Date()
    ) -> [TaskDraft] {
        drafts(
            fromClauses: Segmentation.items(from: rawText), learned: learned,
            ownership: ownership, now: now)
    }

    /// The provisional pass's second half, with the CLAUSES handed in rather than cut by
    /// `Segmentation`.
    ///
    /// It exists because `OnDeviceSegmenter` produces the boundaries for exactly the
    /// population `Segmentation` gets wrong — an unpunctuated spoken run-on — and the
    /// clauses it produces must reach drafts through the same code that every other
    /// capture uses. Two paths would be two places for the per-clause lineage, the
    /// expansion fan-out and the ownership pass to drift.
    @MainActor
    static func drafts(
        fromClauses clauses: [String], learned: [LearnedRule] = [],
        ownership: OwnershipContext = .none, now: Date = Date()
    ) -> [TaskDraft] {
        guard !clauses.isEmpty else { return [] }
        // Resolved per clause, so each draft is stamped with the clause it actually came
        // from. This used to resolve the whole batch and index drafts against clauses
        // positionally, behind a `drafts.count == clauses.count` guard — correct while
        // `resolve` mapped 1:1, and quietly self-disabling the day it stopped:
        // `IntentResolver.expand` fans one clause out into several drafts ("walk the dog
        // monday and tuesday"), the counts diverge, and the guard drops the lineage for
        // EVERY card in the capture rather than the one that expanded. Carrying the
        // clause through the loop makes the fan-out a non-event — every instance keeps
        // the source its upgrade match needs, and there is no count to agree on.
        var drafts: [TaskDraft] = []
        for clause in clauses {
            var resolved = IntentResolver.resolve(
                [HeuristicEngine.intent(from: clause)], rules: learned, now: now)
            for index in resolved.indices { resolved[index].provisionalSource = clause }
            drafts.append(contentsOf: resolved)
        }
        // Clauses resolve one at a time above, so a wait that points back at the
        // previous clause ("…after it comes through") can only be resolved here, over
        // the assembled list.
        drafts = IntentResolver.resolvingAnaphoricWaits(drafts)
        proposeOwners(to: &drafts, ownership: ownership)
        return drafts
    }

    /// One completed live parse. `candidates` is everything retrieval found — what the
    /// prompt was given, plus whatever landed after it — so a caller running a burst can
    /// hand it forward as the next parse's package.
    ///
    /// `suggestsEnrichment` used to live here: a flag saying "this parse prompted blind,
    /// so chain one more with candidates". It is gone rather than fixed. Its consumer was
    /// deleted when the reveal contract made a post-reveal enrichment illegal, and the
    /// flag stayed behind — computed on every parse, read by nothing, and describing a
    /// mechanism that no longer existed. Duplicate/child proposals now land on the FIRST
    /// parse (see the bounded retrieval wait in `triage`), which is where they always
    /// needed to be: after the reveal is too late by construction.
    struct TriageRun {
        var drafts: [TaskDraft] = []
        var candidates: [RetrievalCandidate] = []
        /// How this parse actually ran — rung, arm, outcome, cost. Every field on it was
        /// already computed inside `triage` and then discarded at this `return`; the
        /// winning arm in particular (`CaptureTriageRace.HedgedResult.arm`) was read
        /// nowhere at all. It rides out on the run so `commit` can write one durable
        /// receipt per capture (`CaptureProvenance`) instead of the app knowing only the
        /// last-write-wins average in `ModelMetrics`.
        var telemetry = CaptureRunTelemetry()
    }

    /// How long a parse will wait for its own retrieval before prompting the model
    /// candidate-blind.
    ///
    /// The bound is the whole design: it converts "never pay retrieval on the critical
    /// path" (audit A1) into "never pay MORE THAN THIS", which restores duplicate/child
    /// detection in the common case while keeping A1's guarantee that first-draft latency
    /// cannot scale with store size. Imperceptible against a parse measured in seconds,
    /// and `EmbeddingStore.warmUp` runs before this, so a warm cache lands well inside it.
    static let candidateWaitSeconds: Double = 0.25

    /// Run the raw capture through the active engine, then the deterministic
    /// resolver (dates, learned rules, needs-decision, always-inbox). Never throws
    /// to the caller; on failure it degrades to the heuristic engine so capture
    /// never fails.
    ///
    /// - `roster`: household snapshot — gates the ownership check (empty = solo
    ///   no-op) and backs the on-device resolve-person tool.
    /// - `learned`: the user's learned corrections — injected as instructions for
    ///   the model AND applied deterministically by the resolver.
    /// - `openTasks`: the open working set — reverse dependency detection
    ///   ("should anything already open wait on this new task?").
    /// - `preparedCandidates`: the candidate package for the MODEL PROMPT — the
    ///   previous parse's retrieval, carried by the rolling chain. Empty = this
    ///   parse goes candidate-blind and generation starts immediately (audit A1);
    ///   this parse's own retrieval runs concurrently and comes back in the
    ///   returned run for the next prompt.
    /// - `onPartial`: streaming seam — resolved partial candidates as the model
    ///   generates (device only; the heuristic is instant and never calls it).
    func triage(
        _ rawText: String,
        roster: [RosterPerson] = [],
        learned: [LearnedRule] = [],
        openTasks: [OpenTaskSnapshot] = [],
        suppressions: [RelationshipSuppression] = [],
        ownership: OwnershipContext = .none,
        preparedCandidates: [RetrievalCandidate] = [],
        // **No default, deliberately.** This parameter decides whether the user's raw
        // words leave the device, and it defaulted to `.cloud` — so any caller that
        // simply didn't mention it claimed the transmitting rung and skipped
        // `CaptureRoute.route(for:localRead:)` entirely. `OnboardingView.transform()`
        // was one of those callers, which put a brand-new user's very first brain dump
        // on the network no matter how plainly they had structured it, and handed a
        // ten-line dump to the model's segmentation instead of the instant deterministic
        // read that gets those ten lines exactly right. A function that transmits must
        // not hold a default opinion about transmitting; every call site now states it.
        route: CaptureRoute,
        escalation: CaptureEscalationReason? = nil,
        onPartial: (@MainActor ([TaskDraft]) -> Void)? = nil
    ) async -> TriageRun {
        isProcessing = true
        defer { isProcessing = false }
        Telemetry.log(.captureRouted(route: route, reason: escalation))
        // The parse clock starts HERE — before retrieval — so the recorded latency is
        // what the user experiences from the debounce surviving, not just generation.
        let parseStarted = Date()
        // The receipt for this parse, filled in as the facts become known and handed back
        // on the `TriageRun`. Seeded with the routing DECISION (which is knowable now)
        // rather than only its outcome, because "which rung was chosen and why" and "which
        // rung answered" are different questions and a degrade makes them diverge.
        var telemetry = CaptureRunTelemetry(
            route: route.metricName,
            rung: route.rung.rawValue,
            segmentation: Segmentation.structure(of: rawText).label,
            reasoningDepth: CaptureRoute.captureDepth(for: rawText).map(String.init(describing:)),
            // REACHABILITY, not configuration: the receipt's job is to explain why this
            // run took the rung it took, and "configured" cannot explain an on-device
            // parse on a build that has Firebase wired up. The Activity detail already
            // labels this row "Cloud reachable".
            cloudAvailable: CloudModel.isReachable(for: .ramble))
        // Retrieval runs CONCURRENTLY with generation (audit A1): the model is
        // prompted the moment the debounce survives, with whatever candidate package
        // the CALLER prepared — the previous parse's retrieval, riding the rolling
        // chain. The first parse of a burst goes candidate-blind (duplicate/child
        // proposals are card refinements, not prerequisites), so first-draft latency
        // no longer pays for up to 21 sentence-embedding inferences, and stops
        // scaling with store size. This parse's retrieval lands before the FINAL
        // resolve below — generation takes seconds, retrieval tens of milliseconds —
        // and is returned for the next parse's prompt.
        let retrievalTask = Task.detached(priority: .userInitiated) {
            let retrievalStarted = Date()
            let ranked = ContextRetrieval.candidates(matching: rawText, among: openTasks)
            return (ranked, Int(Date().timeIntervalSince(retrievalStarted) * 1000))
        }
        // The candidate package the MODEL is shown — and, before this, the reason an
        // entire shipped feature was inert.
        //
        // `preparedCandidates` is the rolling chain's hand-off: the PREVIOUS parse's
        // retrieval, carried forward so a burst's later parses prompt with neighbours
        // already in hand. The shipped composer does exactly ONE parse and so has no
        // previous one — and no caller in the app passes this argument at all. Every
        // production prompt was therefore candidate-blind, which means the model was
        // never shown an id it could cite, which means `duplicateOf`/`childOf` were
        // always nil, which means `IntentResolver.edgeProposals` (whose first act is to
        // drop ids that aren't candidates) always returned empty. Capture-time duplicate
        // detection, the child-link proposal, the merge-at-commit path and the
        // capture-form suppression were all reachable only from tests. The backstop meant
        // to catch exactly this (`suggestsEnrichment`) was computed and read by nobody,
        // because the reveal contract had since made a post-reveal enrichment illegal and
        // the composer's arm was deleted without the signal going with it.
        //
        // The fix keeps audit A1's guarantee rather than reversing it. A1's concern was
        // that first-draft latency must not scale with store size, so retrieval was moved
        // off the critical path entirely. Here it is awaited, but under a hard, small
        // bound: retrieval can add at most `candidateWaitSeconds` and then generation
        // starts regardless. `EmbeddingStore.warmUp` has already primed the cache by this
        // point, so the common case lands in milliseconds; a cold or huge store simply
        // prompts blind exactly as it did before, and the enrichment signal below stays
        // honest about which happened.
        var promptCandidates = preparedCandidates
        if promptCandidates.isEmpty {
            promptCandidates =
                (try? await ModelDeadline.race(timeout: Self.candidateWaitSeconds) {
                    await retrievalTask.value.0
                }) ?? []
        }
        let context = TriageContext(
            personalization: CorrectionProfile.instructionLines(learned),
            roster: roster,
            openTasks: openTasks,
            candidates: promptCandidates,
            suppressions: suppressions
        )
        // Resolve intents → drafts and propose an owner for each — the one path both
        // the streaming partials and the final result run through. Partials resolve
        // against what the model was actually SHOWN; the final result resolves against
        // shown ∪ fresh, so a parse that prompted blind (retrieval missed its bound)
        // still validates against everything retrieval eventually found.
        var gateCandidates = promptCandidates
        func resolveAndGate(_ intents: [TaskIntent]) -> [TaskDraft] {
            // Grounding first: an intent the capture contains no evidence for never becomes
            // a draft at all, so nothing downstream has to decide what to do with it.
            let grounded = intents.filter { Self.grounded($0, in: rawText) }
            let dropped = intents.count - grounded.count
            if dropped > 0 {
                ModelMetrics.shared.recordUngroundedDrop(dropped)
                telemetry.ungroundedDrops += dropped
            }
            var drafts = IntentResolver.resolve(
                grounded, rules: learned, openTasks: openTasks, candidates: gateCandidates,
                suppressions: suppressions)
            Self.proposeOwners(to: &drafts, ownership: ownership)
            return drafts
        }
        // Coalesced: Foundation Models emits snapshots at token-ish cadence, and every
        // applied snapshot pays the full resolver + owner-proposal + merge + spring on
        // the main thread. The eye can't use more than ~10 updates/s, so intermediate
        // snapshots inside the window are skipped — the SALVAGE box still sees every
        // raw snapshot (the race tees before this handler), and the final result never
        // routes through here, so nothing is ever lost to the throttle.
        // Parse-shape instrumentation: first-applied-partial latency and applied-partial
        // count, recorded with the outcome — the numbers the deadline and the streaming
        // cadence are tuned on. Cadence control lives AT THE SOURCE now
        // (`FoundationModelsEngine.partialThrottleSeconds` gates before the
        // O(tasks-so-far) snapshot mapping, not merely before the resolver), so this
        // handler applies every partial it receives — a second gate here would
        // double-drop against the engine's jitter.
        var firstPartialMs = -1
        var appliedPartials = 0
        let partialHandler: (@MainActor ([TaskIntent]) -> Void)? = onPartial.map { handler in
            { intents in
                if firstPartialMs < 0 {
                    firstPartialMs = Int(Date().timeIntervalSince(parseStarted) * 1000)
                }
                appliedPartials += 1
                handler(resolveAndGate(intents))
            }
        }
        // Which engine drives the model arm of THIS parse, if any.
        //
        // The cloud arm is the same `FoundationModelsEngine` with a cloud session
        // source — same instructions, same schema, same grounding — so everything below
        // this line is rung-agnostic, and the capture contract cannot drift between
        // arms. `nil` means no model: the deterministic branch, which is also the branch
        // every capture test exercises (XCTest forces the heuristic).
        let modelEngine: AIEngine? = {
            switch route {
            case .local:
                return nil
            case .cloud where CloudModel.isReachable(for: .ramble):
                return FoundationModelsEngine(sessionSource: .cloud)
            case .cloud:
                // A cloud route with no reachable provider is not an error — it is the
                // routing answer for "offline" AND for "the last calls all failed"
                // (`CloudHealth`), and it now degrades STRAIGHT to the deterministic
                // tail below. The FM on-device parse used to sit here as DEGRADED
                // OFFLINE CAPTURE; the 2026-08-29 device eval retired it from this
                // chain — p90 21s against the deterministic read's 2ms, with the
                // deterministic arm holding every floor the FM arm was kept around to
                // protect. An offline capture now answers in milliseconds from the
                // heuristic instead of half a minute from a model with no measured
                // accuracy advantage; the FM model remains the Advisor's rung 2, where
                // seconds-long judgment is the job and nobody is mid-capture.
                return nil
            }
        }()
        // Which model this parse ACTUALLY reached, recorded after the availability
        // degrade rather than from the route — a `.cloud` route on a device with no
        // reachable provider runs on-device, and a receipt that named the intent would
        // claim a paid call that never happened (the same rule the ledger follows).
        telemetry.engineName = modelEngine?.engineName
        telemetry.rung =
            modelEngine.map { $0.isOnDevice ? IntelligenceRung.onDevice : .cloud }?.rawValue
            ?? IntelligenceRung.facts.rawValue
        if let modelEngine, !modelEngine.isOnDevice {
            telemetry.modelIdentifier = CloudModel.provider.identifier
            telemetry.modelVersion = CloudModel.provider.modelVersion
        }

        var intents: [TaskIntent]
        if let modelEngine {
            // The model parse is bounded (`captureSeconds` — the user is watching the
            // composer) with streamed-partial salvage, and it is the one place capture
            // metrics are recorded: completed calls only, so debounce cancellations
            // can't pollute the deadline-tuning evidence. The deadline is the same on
            // both arms deliberately: it measures the user's patience, not the model's
            // speed, and a slower rung does not buy more of it.
            IntelligenceLedger.shared.record(modelEngine.isOnDevice ? .onDevice : .cloud, for: .ramble)
            // The race still owns the deadline, salvage and cancellation; what it no
            // longer has is a hedge arm to start. The hedge's free runner WAS the FM
            // on-device parse, and it retired from capture with the rest of that arm
            // (2026-08-29) — a slow cloud call now runs to the deadline, salvages what
            // streamed, and falls to the instant deterministic tail below, which is
            // both faster and better-measured than the model it replaced. The race's
            // hedge machinery stays built and tested (`CaptureHedgeTests`) for the day
            // a rung worth racing exists again.
            let raced = await CaptureTriageRace.hedged(
                // Sized by WHY the words left the device: a second opinion over a
                // read already in hand gets the standby budget; a dump the local arm
                // cannot represent gets the full one (`ModelDeadline.captureSeconds(for:)`).
                budget: ModelDeadline.captureSeconds(for: escalation),
                hedgeAfter: ModelDeadline.captureHedgeSeconds,
                onPartial: partialHandler,
                primary: { tee in
                    // The cloud arm's health is recorded HERE, around the call, rather
                    // than from the race's result. The race reports the arm that WON, so
                    // a capture the hedge rescued would otherwise hide the cloud failure
                    // that made the rescue necessary — which is precisely the run whose
                    // failure has to be counted. Capture is also the highest-volume cloud
                    // workload, so it is the one that trips the breaker first and the
                    // Brief/Advisor inherit a verdict they never had to pay for.
                    do {
                        let value = try await modelEngine.triage(
                            rawText: rawText, context: context, onPartial: tee)
                        // Any answer, including an empty parse, proves the round trip.
                        if !modelEngine.isOnDevice { CloudHealth.shared.recordSuccess() }
                        return value
                    } catch {
                        // Cancellation is the user leaving, never a verdict on the rung.
                        if !modelEngine.isOnDevice, !(error is CancellationError) {
                            CloudHealth.shared.recordFailure(error)
                        }
                        throw error
                    }
                },
                hedge: nil
            )
            let outcome = raced.outcome
            telemetry.hedgeStarted = raced.hedgeStarted
            telemetry.armWon = raced.arm.map(String.init(describing:))
            if case .cancelled = outcome {
                // Debounce supersession — the caller already dropped this generation.
                return TriageRun()
            }
            // Fold this parse's retrieval in before anything records or resolves —
            // generation took seconds, so this await is effectively free.
            let (fresh, retrievalMs) = await retrievalTask.value
            mergeFresh(fresh, into: &gateCandidates)
            // Latency includes retrieval and the fold (the clock starts at parse
            // start) — it is the user's wait, not the model's.
            let latency = Int(Date().timeIntervalSince(parseStarted) * 1000)
            telemetry.parseMs = latency
            telemetry.retrievalMs = retrievalMs
            telemetry.firstPartialMs = firstPartialMs.nonNegative
            telemetry.partialCount = appliedPartials
            func recordCapture(_ outcome: ModelMetrics.Outcome) {
                // One label, two destinations: the aggregate counter that tunes the
                // deadline, and this parse's own receipt.
                telemetry.outcome = Self.outcomeLabel(outcome)
                ModelMetrics.shared.record(
                    .captureTriage, outcome, latencyMs: latency, retrievalMs: retrievalMs,
                    firstPartialMs: firstPartialMs, partialCount: appliedPartials)
            }
            switch outcome {
            case .finished(let value):
                recordCapture(.success)
                intents = value
            case .salvaged(let value):
                // Recorded as SALVAGED, not timed out: the deadline fired, but the user
                // was served real candidates. Device measurement showed this is the
                // NORMAL outcome for a long ramble (see `ModelDeadline.captureSeconds`),
                // and counting it as a failure made the footer report "0 ok" for
                // captures that produced perfectly good tasks.
                recordCapture(.salvaged)
                intents = value
            case .timedOutEmpty:
                recordCapture(.timedOut)
                intents = []
            case .cancelled:
                return TriageRun()  // handled above; keeps the switch total
            case .failed(let error):
                recordCapture(.failed(Self.errorLabel(error)))
                intents = []
            }
            // Token accounting, AFTER the outcome is recorded and never inside the
            // user's wait: the exact prompt this parse sent, counted by the model's
            // own tokenizer, against its context size — the evidence the chunking
            // and context-budget decisions are designed on.
            //
            // On-device only. `SystemLanguageModel.default`'s tokenizer and context size
            // describe the LOCAL model; asking it about a prompt that went to a cloud
            // provider would record a confident number about the wrong model, which is
            // worse than recording none.
            if modelEngine.isOnDevice {
                Task {
                    let prompt = FoundationModelsEngine.prompt(for: rawText, context: context)
                    guard let tokens = try? await SystemLanguageModel.default.tokenCount(for: prompt)
                    else { return }
                    ModelMetrics.shared.recordTokens(
                        .captureTriage, promptTokens: tokens,
                        contextSize: SystemLanguageModel.default.contextSize)
                }
            }
            // The on-device retry that used to live here is gone: it ran only AFTER the
            // cloud arm had spent the entire capture deadline, and then took a fresh one
            // of its own — two full waits for one capture. It is now the hedge arm above,
            // which starts while the cloud arm is still stalling rather than after it has
            // finished failing, and shares the one budget. What remains below is the
            // deterministic read, which is instant and cannot fail.
            // The one case an EMPTY authority answer is the answer (F-02): a spoken
            // capture the verifier read as a caught conversation, sent with permission to
            // return nothing. A served empty is "nothing here", and the deterministic tail
            // would only re-manufacture the dozen cards the escalation exists to prevent.
            // A FAILED or timed-out call still falls to the tail — capture never blocks.
            let authorityAnsweredNothing =
                escalation == .conversation && intents.isEmpty
                && (telemetry.outcome == Self.outcomeLabel(.success)
                    || telemetry.outcome == Self.outcomeLabel(.salvaged))
            if intents.isEmpty, !authorityAnsweredNothing {
                intents = (try? await HeuristicEngine().triage(rawText: rawText)) ?? []
            }
        } else {
            // The deterministic branch — explicitly `HeuristicEngine`, never
            // `self.engine`. On a device the brain's selected engine is the FM model,
            // and this branch used to route through it, which meant the "deterministic"
            // arm of an offline capture quietly became a 20-second model call (the
            // fourth leg of the FM-in-capture retirement, found 2026-08-29). Synchronous
            // string work, no deadline needed, zero overhead — and the branch every
            // capture test exercises.
            do {
                intents = try await HeuristicEngine().triage(
                    rawText: rawText, context: context, onPartial: partialHandler)
            } catch {
                intents = []
            }
            let (fresh, retrievalMs) = await retrievalTask.value
            mergeFresh(fresh, into: &gateCandidates)
            // The deterministic arm is instrumented too. It costs nothing and it is the
            // baseline every model arm is argued against — an arm with no number cannot
            // be the thing a slower one has to beat.
            telemetry.parseMs = Int(Date().timeIntervalSince(parseStarted) * 1000)
            telemetry.retrievalMs = retrievalMs
        }
        let drafts = resolveAndGate(intents)
        // What the MODEL was shown, not everything retrieval eventually found: these are
        // the only ids it was permitted to cite for a duplicate/child proposal, so they
        // are what explains a proposal's presence or absence.
        telemetry.candidateTitles = promptCandidates.map(\.title)
        return TriageRun(drafts: drafts, candidates: gateCandidates, telemetry: telemetry)
    }

    /// The parse outcome as one stable word for the receipt. `salvaged` is deliberately
    /// distinct from `timedOut`: the deadline fired in both, but salvage SERVED the user
    /// real candidates, and device measurement showed it is the normal path for a long
    /// ramble rather than a failure.
    private static func outcomeLabel(_ outcome: ModelMetrics.Outcome) -> String {
        switch outcome {
        case .success: return "success"
        case .salvaged: return "salvaged"
        case .timedOut: return "timedOut"
        case .failed(let label): return "failed(\(label))"
        }
    }

    /// Does the capture contain evidence that this task should exist?
    ///
    /// The model names its evidence (`TaskIntent.sourceQuote`) and **the system checks it** —
    /// otherwise it is model-authored evidence for model-authored output, which proves
    /// nothing. This is the guard against the failure that motivated it: "pick up food from
    /// the store later today" came back carrying a second task, "buy new printer paper",
    /// plausible household work the user never said.
    ///
    /// Two rungs, in order of strength:
    ///
    /// 1. **The quote, verified.** The model copies the user's own words; we confirm they
    ///    actually appear in the capture. Normalized for whitespace and case only — never
    ///    for meaning, or the check would start accepting paraphrase as proof.
    /// 2. **A lexical anchor, as an anomaly detector.** When the quote is missing or doesn't
    ///    check out, require at least one significant word in common. This is deliberately
    ///    NOT the semantic authority: "take care of the house before guests arrive" →
    ///    "Clean the living room" is a legitimate reading with zero shared words, so a
    ///    lexical rule as the primary test would reject good work. It exists to catch the
    ///    obvious invention when the stronger evidence is absent.
    ///
    /// A failure DROPS the task and never substitutes one. `Capture.rawText` keeps the
    /// user's words verbatim forever, so nothing they said is lost by refusing something
    /// they didn't.
    static func grounded(_ intent: TaskIntent, in rawText: String) -> Bool {
        let haystack = normalizedForGrounding(rawText)
        if let quote = intent.sourceQuote, !quote.isEmpty {
            let needle = normalizedForGrounding(quote)
            // Rung 1: a verified quote is sufficient — paraphrases can share zero
            // words with their source ("Clean the living room" ← "take care of the
            // house"), so a lexical check against the quote or the capture cannot
            // distinguish a good paraphrase from an unrelated fabricated title.
            // The remaining guard is RambleEvalTests: a model that consistently
            // attaches real quotes to unrelated titles fails the accuracy floor.
            if !needle.isEmpty, haystack.contains(needle) { return true }
        }
        let captureWords = CorrectionProfile.significantWords(rawText)
        let titleWords = CorrectionProfile.significantWords(intent.title)
        guard !titleWords.isEmpty else { return true }  // nothing to judge; let it through
        return !titleWords.isDisjoint(with: captureWords)
    }

    /// Whitespace- and case-insensitive, nothing more. Deliberately not stemming or
    /// stripping stop words: this comparison's whole value is that it is literal.
    private static func normalizedForGrounding(_ text: String) -> String {
        text.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Fold freshly-retrieved candidates over the prepared set, keeping any prepared
    /// entry the fresh ranking no longer surfaces — the model could only have cited
    /// ids from its PROMPT, and the resolver's anti-hallucination check must not
    /// drop a legitimate claim because the ranking shifted under it mid-parse.
    private func mergeFresh(
        _ fresh: [RetrievalCandidate], into candidates: inout [RetrievalCandidate]
    ) {
        let prepared = candidates
        candidates = fresh
        for entry in prepared where !fresh.contains(where: { $0.id == entry.id }) {
            candidates.append(entry)
        }
    }

    // MARK: - Parking (the durable half of capture)

    /// Park an in-flight capture so dismissing the composer cannot destroy it.
    ///
    /// Writes/updates ONE `Capture` row per composer session, carrying the verbatim raw
    /// text plus the current drafts. Returns the row so the session can keep updating
    /// it as the user types and hand it to `commit` on confirm.
    ///
    /// A parked capture is not a task and must never behave like one — see `Capture`.
    @discardableResult
    func park(
        _ drafts: [TaskDraft], rawCapture: String, source: CaptureSource,
        imageRef: String? = nil,
        into existing: Capture?, in context: NSManagedObjectContext
    ) -> Capture? {
        let trimmed = rawCapture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        // Defense in depth for the one-row-per-event invariant: a deleted row can't be
        // updated (fall through and mint a fresh one — the thought still survives), and
        // a committed row is spent history (re-parking it would rewrite the verbatim
        // record of an event that already produced tasks — refuse, unchanged).
        let live: Capture? = existing.flatMap { row in
            guard row.managedObjectContext != nil, !row.isDeleted else { return nil }
            return row
        }
        if let live, live.committedAt != nil { return live }
        let capture = live ?? Capture(rawText: trimmed, source: source, in: context)
        if live == nil { context.insert(capture) }
        capture.rawText = trimmed
        capture.source = source
        capture.imageRef = imageRef
        capture.parkedDrafts = drafts
        context.saveChanges()
        return capture
    }

    /// Every capture still waiting to be confirmed, newest first.
    ///
    /// The `draftsData != nil` half of "parked" is filtered IN MEMORY, deliberately:
    /// Core Data cannot evaluate a fetch predicate against a Binary Data attribute, and
    /// attempting it throws at the store layer rather than returning empty. The
    /// uncommitted set is tiny by construction, so the predicate narrows on the cheap
    /// date attribute and `isParked` does the rest.
    static func parkedCaptures(in context: NSManagedObjectContext) -> [Capture] {
        let request = NSFetchRequest<Capture>(entityName: "Capture")
        request.predicate = NSPredicate(format: "committedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return ((try? context.fetch(request)) ?? []).filter(\.isParked)
    }

    /// The user explicitly throwing a capture away. The ONLY destructive path —
    /// swipe-to-dismiss parks, so nothing is lost by accident.
    static func discard(_ capture: Capture, in context: NSManagedObjectContext) {
        context.delete(capture)
        context.saveChanges()
    }

    /// Give every draft an owner. Replaces the retired `applyOwnershipGate`, which did
    /// the opposite — it flagged a confident household draft `ownerPending` and made
    /// the card ask. Every other field already reaches the confirm card populated and
    /// editable; owner is no longer the exception. See `OwnerProposer` for the ladder
    /// and for why load can only ever adjust a choice, never make one.
    ///
    /// The proposal writes `ownerName`, `ownerReason`, and `ownerBasis` — nothing is
    /// published and nobody is notified here. **Assignment side effects bind to the
    /// Confirm event, not to this field being populated** (see `commit`).
    static func proposeOwners(to drafts: inout [TaskDraft], ownership: OwnershipContext) {
        for i in drafts.indices {
            let proposal = OwnerProposer.propose(
                draft: drafts[i], roster: ownership.candidates,
                adjacentOwners: adjacentOwnerNames(for: drafts[i], in: ownership),
                history: ownership.history)
            drafts[i].ownerName = proposal.memberName
            drafts[i].ownerReason = proposal.reason
            drafts[i].ownerBasis = proposal.basis
        }
    }

    /// Owner names reachable through a draft's capture-graph proposals, in preference
    /// order: a duplicate target is literally the same work, a parent is the umbrella
    /// it belongs under. **Blockers are absent by design** — a blocker is frequently
    /// owned by someone else precisely *because* they are the bottleneck, so it points
    /// the wrong way as often as not.
    private static func adjacentOwnerNames(
        for draft: TaskDraft, in ownership: OwnershipContext
    ) -> [String] {
        let ordered =
            draft.edgeProposals.filter { $0.kind == .duplicateOf }
            + draft.edgeProposals.filter { $0.kind == .childOf }
        return ordered.compactMap { proposal in
            proposal.decision == .rejected ? nil : ownership.ownersByTaskID[proposal.targetID]
        }
    }

    // MARK: - Household narrative

    /// Phrase the household's operating status over the engine's deterministic
    /// facts. Runs through the `ModelRun` seam like every other model call — this
    /// was the one straggler constructing its session unbounded, so a cold model
    /// could hang the narrative task indefinitely with nothing recorded. Any
    /// non-success (unavailable, deadline, failure, cancellation) falls back to
    /// the deterministic template so the surface always has a sentence.
    func householdNarrative(_ facts: HouseholdFacts) async -> String {
        let engine = self.engine
        let result = await ModelRun.perform(
            .householdNarrative, deadline: ModelDeadline.seconds(for: .background)
        ) {
            try await engine.householdNarrative(facts)
        }
        if case .success(let sentence) = result { return sentence }
        return (try? await HeuristicEngine().householdNarrative(facts)) ?? ""
    }

    // MARK: - Commit

    /// **This IS Confirm.** A `TaskItem` comes into existence here and nowhere else —
    /// there is no pre-confirm task state to transition out of. Before this runs, the
    /// capture is single-player: parked on the capturer's device as raw text plus
    /// drafts, invisible to everyone else even when the inferred owner is somebody
    /// else.
    ///
    /// **Assignment side effects bind to this event, never to the owner field being
    /// populated** — see `publishAssignments`. That distinction is the seam a future
    /// "Confirm all" fast-path would otherwise leak a notification through.
    ///
    /// Persists drafts, records the Capture they came from (raw text kept verbatim
    /// forever — one capture, many tasks), and logs silent-tier filings to the change
    /// log. Capture Graph Awareness: a draft with an ACCEPTED duplicate proposal does
    /// NOT create a task — it MERGES into the target (the capture rides along); all
    /// other drafts create real tasks and may gain a parent link (accepted child) or
    /// write suppression records (rejected duplicate/child — see `SuppressionStore`).
    @discardableResult
    func commit(
        _ drafts: [TaskDraft], rawCapture: String, source: CaptureSource = .text,
        imageRef: String? = nil,
        parked: Capture? = nil,
        telemetry: CaptureRunTelemetry? = nil,
        groupTitle: String? = nil,
        into context: NSManagedObjectContext
    ) -> [TaskItem] {
        let commitStarted = Date()
        // The Capture row is written at PARSE time now (`park`), so a commit usually
        // ADOPTS the existing row rather than creating one — otherwise a parked capture
        // that is then confirmed would leave two rows for one event. Creating one here
        // is the path for callers with no composer session (onboarding, seeds).
        let capture: Capture
        if let parked {
            capture = parked
        } else {
            capture = Capture(rawText: rawCapture, source: source, imageRef: imageRef, in: context)
            context.insert(capture)
        }
        // Committed: no longer parked, and its derived drafts are spent. The photo
        // reference rides the event's provenance (or clears if the chip was removed).
        capture.imageRef = imageRef
        capture.committedAt = Date()
        capture.parkedDrafts = nil

        // Partition: accepted-duplicate drafts fold into an existing task; the rest create.
        let creating = drafts.filter { $0.acceptedDuplicate == nil }
        let merging = drafts.filter { $0.acceptedDuplicate != nil }

        // Author attribution: a real capture is created by the current user. Computed
        // once (only when there's something to stamp) so a commit never bootstraps the
        // you-identity for nothing. Feeds the My Tasks "Created" tab.
        let creatorID: UUID? = creating.isEmpty ? nil : UserProfile.currentMemberID(in: context)

        var created: [TaskItem] = []
        for draft in creating {
            let task = draft.makeTaskItem(rawCapture: rawCapture, captureID: capture.uuid, in: context)
            task.creatorID = creatorID
            context.insert(task)
            created.append(task)

            // A "recently tidied" change-log entry for confident filings. This records
            // that the CATEGORIZATION was the AI's, not that any card was skipped —
            // every task here is human-confirmed by construction, because commit is
            // the confirm.
            //
            // **Informational, NOT reversible.** There is nothing for an undo to
            // restore: commit IS the confirm, so there is no pre-AI category the task
            // ever held, and the task did not exist a moment ago. `ChangeLogUndo` has no
            // "filed" arm, so the default arm ran — setting `.todo` on a task born
            // `.todo`, a visible button that did nothing. Worse, the Activity renders Undo
            // on `isReversible && !undone` and `Metrics.acceptanceRate` counts `!undone`
            // AI entries, so tapping that dead button scored as the user REJECTING the
            // AI. An entry whose action can't be reversed must say so rather than mint a
            // false rejection signal. (Re-categorizing is a normal edit in the detail.)
            if draft.autonomy == .silent {
                let entry = ChangeLogEntry(
                    summary: "Filed “\(draft.title)” under \(draft.category)",
                    detail: draft.reasoning,
                    action: "filed",
                    initiatedBy: .ai,
                    isReversible: false,
                    taskTitle: draft.title,
                    taskUUID: task.uuid, in: context
                )
                context.insert(entry)
            }
        }

        // Every field the user edited at the confirm glance is a free labeled
        // pair — the local learning signal (write-only for now; consumed later).
        // The MERGING drafts get the same treatment inside `foldMerges`, against their
        // merge target: an edit is a labeled pair regardless of where the row lands.
        for (draft, task) in zip(creating, created) {
            recordCorrections(for: draft, taskUUID: task.uuid, captureID: capture.uuid, in: context)
        }

        // Fetch the working set ONCE — managed objects are unique per context, so every
        // helper below sees each other's mutations through this one array (no re-fetch buys
        // anything). `created` are already inserted, so they're included.
        let all = TaskItem.fetchAll(in: context)
        resolveBlockers(creating, created: created, all: all, in: context)
        resolveDependents(creating, created: created, all: all, in: context)
        resolveOwners(creating, created: created, in: context)
        publishAssignments(created, in: context)  // the ONE place assignment side effects fire
        resolveProposedEdges(creating, created: created, all: all, in: context)
        let mergeTargets = foldMerges(merging, capture: capture, all: all, in: context)
        capture.parsedTaskIDs = created.compactMap(\.uuid) + mergeTargets.compactMap(\.uuid)
        stampAttention(creating, created: created, mergeTargets: mergeTargets, all: all, in: context)

        // GROUP — the person's own act at the confirm card ("Group as one outcome"). The
        // umbrella is born HERE, at the publish boundary, never before; the created tasks
        // become its steps in the order the cards were shown. Nothing about it was proposed
        // by the system (that is a separate, later change), so it is a `.human` entry with
        // its own undo arm. Appended AFTER the resolvers, whose zips pair `creating` with
        // `created` one to one.
        if let umbrella = group(created, as: groupTitle, creatorID: creatorID, capture: capture, in: context)
        {
            created.append(umbrella)
            capture.parsedTaskIDs = created.compactMap(\.uuid) + mergeTargets.compactMap(\.uuid)
        }

        // The confirm boundary's own save. Its result decides whether the Create
        // moment's receipt is honest — see `CommitSummary.saveFailed`: a dropped
        // save here means the drafts are gone on next launch even though the
        // composer already showed "N tasks added".
        let saved = context.saveChanges()
        // A capture is when a group forms; the grouping sweep looks shortly after one
        // (debounced), so the row can ask while the thought is still warm.
        if saved, !created.isEmpty { GroupingSweep.runSoonAfterCommit(in: context) }
        if !created.isEmpty, metrics.recordFirstPayoffIfNeeded(),
            let elapsed = metrics.timeToFirstPayoff
        {
            Telemetry.log(.firstPayoff(elapsed: DurationBucket(seconds: elapsed)))
        }
        // Counts as BUCKETS, and "corrected" as a bit: whether any confirm-card edit
        // landed as a `Correction` — the capture-acceptance signal, observed without
        // asking (`RequiredAttention.capture` is the exact local form). `triage` is the
        // capture's arrival to this tap — Linear's triage time, for a family.
        Telemetry.log(
            .captureCommitted(
                created: CountBucket(created.count), merged: CountBucket(mergeTargets.count),
                corrected: drafts.contains { !$0.corrections.isEmpty },
                triage: DurationBucket(seconds: commitStarted.timeIntervalSince(capture.createdAt))))
        // The confirm tap's own wall clock — the other half of "instant capture", and
        // the number that decides whether the remaining commit-path work (the
        // per-created-task dependent rescan in `AttentionEngine.metadata`) is worth
        // restructuring. Measure before optimizing: nobody has seen this number yet.
        let commitMs = Int(Date().timeIntervalSince(commitStarted) * 1000)
        ModelMetrics.shared.recordCommit(latencyMs: commitMs)
        recordProvenance(
            telemetry: telemetry, capture: capture, drafts: drafts, created: created,
            mergeTargets: mergeTargets, commitMs: commitMs, in: context)
        lastCommitSummary = CommitSummary(
            saveFailed: !saved,
            created: created.count, mergedTitles: mergeTargets.map(\.title))
        return created
    }

    /// Write this capture's durable receipt, and the one Activity row that makes it
    /// reachable.
    ///
    /// **Why the row exists.** Only a `.silent`-autonomy draft logs a `"filed"` entry, so a
    /// capture whose drafts all came back `.suggest`/`.ask` left NO trace in the Activity
    /// feed at all — the captures with the most interesting provenance were exactly the
    /// ones with nothing to tap. One entry per commit closes that, and makes
    /// capture → N tasks the headline rather than something reconstructed from N separate
    /// rows.
    ///
    /// It is **not reversible**: commit IS the confirm, so there is no prior state for an
    /// undo to restore, and `ChangeLogUndo` has no arm for it. Shipping it reversible
    /// would repeat the `"filed"` mistake — a button that appears to work, does nothing,
    /// and scores as the user REJECTING the AI in `Metrics.acceptanceRate`.
    private func recordProvenance(
        telemetry: CaptureRunTelemetry?, capture: Capture, drafts: [TaskDraft],
        created: [TaskItem], mergeTargets: [TaskItem], commitMs: Int,
        in context: NSManagedObjectContext
    ) {
        guard let captureID = capture.uuid else { return }
        // A caller with no composer session (onboarding, the seed args) has no telemetry
        // and gets a receipt that says so, rather than one that quietly claims the
        // deterministic route ran.
        let run = telemetry ?? CaptureRunTelemetry(route: "unrecorded", rung: "unrecorded")
        let stats = ModelMetrics.shared.stats[.captureTriage]
        let provenance = CaptureProvenance(
            captureID: captureID,
            rawText: capture.rawText,
            capturedAt: capture.createdAt,
            committedAt: capture.committedAt ?? Date(),
            run: run,
            // Sampled rather than threaded: these live on `ModelMetrics`'s last-write-wins
            // fields, which is correct here because the composer is modal and exactly one
            // capture is ever in flight. The token count is the exception — it lands from
            // a detached `Task` — so a fast commit records nil, which the detail prints as
            // "pending" and never as zero.
            provisionalMs: stats.flatMap { $0.lastProvisionalMs.nonNegative },
            commitMs: commitMs,
            promptTokens: stats.flatMap { $0.lastPromptTokens.nonNegative },
            contextSize: stats.flatMap { $0.lastContextSize.nonNegative },
            drafts: drafts,
            createdTaskIDs: created.compactMap(\.uuid),
            mergedTaskIDs: mergeTargets.compactMap(\.uuid))
        provenanceStore.record(provenance)

        let noun = drafts.count == 1 ? "task" : "tasks"
        let entry = ChangeLogEntry(
            summary: "Captured \(drafts.count) \(noun)",
            detail: provenance.bylineLine,
            action: ChangeLogEntry.capturedAction,
            // The capture id rides `oldValue` — the existing convention for an entry that
            // points at a Capture rather than a task (`"prunedCapture"`, `BrainSweeps`).
            // `taskUUID` stays nil because this entry is about the EVENT, not one task.
            oldValue: captureID.uuidString,
            initiatedBy: .ai,
            isReversible: false,
            in: context)
        context.insert(entry)
        context.saveChanges()
    }

    /// Apply the reverse dependencies detected at capture: each open task the
    /// draft `blocks` gains a `.task` edge pointing at the newly created task —
    /// upgrading (replacing) the matching external note where one exists. Every
    /// edge is a reversible change-log entry; the trail's Undo removes the edge
    /// (never reopens the task). Cycle-safe via `addTaskBlocker`.
    private func resolveDependents(
        _ drafts: [TaskDraft], created: [TaskItem], all: [TaskItem], in context: NSManagedObjectContext
    ) {
        for (draft, task) in zip(drafts, created) {
            guard let newID = task.uuid, !draft.blocks.isEmpty else { continue }
            for ref in draft.blocks {
                guard let dependent = all.first(where: { $0.uuid == ref.id }),
                    !dependent.status.isResolved
                else { continue }
                // This upgrade churns the blocker set (drop the external note, add the new
                // task edge). If the external was the dependent's LAST active blocker,
                // `removeBlocker` stamps `lastUnblockedAt` — but the very next line re-blocks
                // it, so that "just unblocked" fact is spurious (it would hand a still-blocked
                // task the +12 recently-unblocked boost). Snapshot the fact and restore it
                // whenever the dependent ends this upgrade still blocked.
                let priorUnblockedAt = dependent.lastUnblockedAt
                // Upgrade: the external note this new task satisfies comes off first.
                for blocker in dependent.blockers
                where blocker.kind == .external
                    && blocker.note.map({ TaskItem.blockerMatches($0, resolvedTitle: task.title) }) == true
                {
                    dependent.removeBlocker(blocker.id, among: all)
                }
                let before = dependent.taskBlockerIDs.count
                // No-ops if it'd cycle.
                dependent.addTaskBlocker(newID, among: all, origin: .inferred(confidence: 0.9))
                if dependent.hasActiveBlockers(among: all) { dependent.lastUnblockedAt = priorUnblockedAt }
                guard dependent.taskBlockerIDs.count > before else { continue }
                context.insert(
                    ChangeLogEntry(
                        summary: "“\(dependent.title)” now waits on “\(task.title)”",
                        detail: "Detected at capture — undo removes the link, nothing else.",
                        action: "linked",
                        fieldChanged: "blockers",
                        newValue: newID.uuidString,
                        initiatedBy: .ai,
                        isReversible: true,
                        taskTitle: dependent.title,
                        taskUUID: dependent.uuid, in: context
                    ))
            }
        }
    }

    /// Stamp the attention score on every created task now that its graph edges exist,
    /// carrying each draft's AI importance estimate into the score. Existing tasks a new
    /// task now waits on gained a dependent, so their centrality is refreshed too.
    /// `created` is in draft order, so `drafts[i]` ↔ `created[i]`.
    private func stampAttention(
        _ drafts: [TaskDraft], created: [TaskItem], mergeTargets: [TaskItem] = [],
        all: [TaskItem], in context: NSManagedObjectContext
    ) {
        for (draft, task) in zip(drafts, created) {
            task.attention = AttentionEngine.metadata(
                for: task, among: all, aiImportance: draft.aiImportance)
        }
        let createdIDs = Set(created.compactMap(\.uuid))
        // Existing tasks whose centrality shifted: blocker targets of new tasks, parents a
        // new child was linked to, and merge targets (their graph may have changed).
        let blockerTargetIDs = Set(created.flatMap { $0.taskBlockerIDs })
        let parentIDs = Set(created.compactMap(\.parentTaskID))
        let mergeIDs = Set(mergeTargets.compactMap(\.uuid))
        let touchIDs = blockerTargetIDs.union(parentIDs).union(mergeIDs)
        let touchedExisting = all.filter { task in
            guard let id = task.uuid else { return false }
            return touchIDs.contains(id) && !createdIDs.contains(id)
        }
        AttentionEngine.recompute(touchedExisting, among: all)
    }

    /// Apply the accepted capture-graph proposals on the newly created tasks: an accepted
    /// child link becomes a `.parent` edge (with a reversible "linked" entry); a REJECTED
    /// proposal writes `SuppressionRecord`s (capture-form keyed on the normalized draft
    /// title so the same rejection sticks across captures, plus the pair form for
    /// both-tasks-exist consumers) so the pairing is never re-proposed. Accepted
    /// duplicates are handled separately by the merge fold (no task was created).
    private func resolveProposedEdges(
        _ drafts: [TaskDraft], created: [TaskItem], all: [TaskItem], in context: NSManagedObjectContext
    ) {
        let openIDs = Set(all.filter { !$0.status.isResolved }.compactMap(\.uuid))
        for (draft, task) in zip(drafts, created) {
            for proposal in draft.edgeProposals {
                switch (proposal.kind, proposal.decision) {
                case (.childOf, .accepted) where openIDs.contains(proposal.targetID):
                    task.linkParent(proposal.targetID)
                    context.insert(
                        ChangeLogEntry(
                            summary: "“\(task.title)” is now a step of “\(proposal.targetTitle)”",
                            detail: "Linked at capture — undo removes the link, nothing else.",
                            action: "linked", fieldChanged: "parent",
                            newValue: proposal.targetID.uuidString,
                            initiatedBy: .ai, isReversible: true,
                            taskTitle: task.title, taskUUID: task.uuid, in: context))
                case (.duplicateOf, .rejected):
                    SuppressionStore.recordRejectedDuplicate(
                        draftTitle: suppressionKeyTitle(for: draft), createdID: task.uuid,
                        targetID: proposal.targetID, in: context)
                    logSuppression(
                        kind: .duplicateMerge, draft: draft, task: task, proposal: proposal,
                        summary:
                            "Won't suggest merging “\(task.title)” into “\(proposal.targetTitle)” again",
                        in: context)
                case (.childOf, .rejected):
                    SuppressionStore.recordRejectedParent(
                        draftTitle: suppressionKeyTitle(for: draft), createdID: task.uuid,
                        parentID: proposal.targetID, in: context)
                    logSuppression(
                        kind: .parentLink, draft: draft, task: task, proposal: proposal,
                        summary:
                            "Won't suggest “\(task.title)” as a step of “\(proposal.targetTitle)” again",
                        in: context)
                default:
                    continue  // undecided / non-open → nothing
                }
            }
        }
    }

    /// Write the field diffs a draft accumulated at the confirm glance as `Correction`
    /// rows. The one seam both the creating and the merging paths use — a card whose
    /// duplicate-merge was accepted still taught the model something when the user fixed
    /// its category or owner before merging, and those pairs used to be dropped on the
    /// floor because the correction loop only zipped over the created tasks.
    /// The umbrella for a group made at the confirm card, or nil when there is nothing to
    /// group: no title, or fewer than two steps (one task is not a group). Owned and
    /// authored by the capturer, filed under the steps' commonest category, and logged
    /// as a reversible `"grouped"` entry whose undo unlinks the steps and removes an
    /// untouched umbrella (`ChangeLogUndo`).
    private func group(
        _ steps: [TaskItem], as title: String?, creatorID: UUID?, capture: Capture,
        in context: NSManagedObjectContext
    ) -> TaskItem? {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, steps.count >= 2 else { return nil }
        // The commonest step category, ties to the FIRST step's — deterministic, where a
        // dictionary max broke ties by hash order and filed the same capture differently
        // from run to run.
        var counts: [String: Int] = [:]
        for step in steps { counts[step.category, default: 0] += 1 }
        let category =
            steps.map(\.category).max { a, b in
                (counts[a] ?? 0, -(steps.firstIndex { $0.category == a } ?? 0))
                    < (counts[b] ?? 0, -(steps.firstIndex { $0.category == b } ?? 0))
            } ?? steps[0].category
        let umbrella = TaskItem(
            title: title, category: category, status: .todo, creatorID: creatorID,
            confidence: 1, reasoning: "Grouped at capture, by you.", in: context)
        umbrella.ownerID = creatorID
        umbrella.confirmedAt = Date()
        umbrella.captureID = capture.uuid
        umbrella.rawCapture = steps[0].rawCapture
        context.insert(umbrella)
        guard let umbrellaID = umbrella.uuid else { return nil }
        for (index, step) in steps.enumerated() {
            step.sortIndex = Int32(index)
            step.linkParent(umbrellaID)
        }
        context.insert(
            ChangeLogEntry(
                summary: "Grouped \(steps.count) tasks as “\(title)”",
                detail: steps.map(\.title).joined(separator: " · "),
                action: "grouped",
                newValue: steps.compactMap { $0.uuid?.uuidString }.joined(separator: ","),
                initiatedBy: .human,
                isReversible: true,
                taskTitle: title,
                taskUUID: umbrellaID,
                actorID: creatorID,
                in: context))
        let all = TaskItem.fetchAll(in: context)
        AttentionEngine.recompute([umbrella] + steps, among: all)
        return umbrella
    }

    private func recordCorrections(
        for draft: TaskDraft, taskUUID: UUID?, captureID: UUID?, in context: NSManagedObjectContext
    ) {
        for diff in draft.corrections {
            context.insert(
                Correction(
                    taskUUID: taskUUID,
                    captureID: captureID,
                    fieldCorrected: diff.field,
                    aiValue: diff.aiValue,
                    userValue: diff.userValue, in: context
                ))
        }
    }

    /// Record a rejection in the trail. A suppression is a **180-day veto the user cast
    /// in one tap on a chip**, and until now it was written invisibly: no entry, no way
    /// to see it, no way to lift it. That fails "every AI decision is explainable" from
    /// the wrong side — it's the HUMAN's decision that was unexplainable, and the AI's
    /// silence about it looked like the suggestion simply never recurring.
    ///
    /// `initiatedBy` is `.human` deliberately: the rejection is the user's, so it must
    /// not land in the AI-only "AI handled N" count or `Metrics.acceptanceRate` (where
    /// it would score as the AI acting and the user consenting — a doubled signal from
    /// one tap). The payload freezes exactly which rows were written so the arm can
    /// delete all of them.
    private func logSuppression(
        kind: RelationshipSuppression.SuppressionKind, draft: TaskDraft, task: TaskItem,
        proposal: EdgeProposal, summary: String, in context: NSManagedObjectContext
    ) {
        let payload = SuppressionUndoPayload(
            kind: kind.rawValue,
            targetID: proposal.targetID,
            normalizedTitle: RelationshipSuppression.normalizeTitle(suppressionKeyTitle(for: draft)),
            createdID: task.uuid)
        context.insert(
            ChangeLogEntry(
                summary: summary,
                detail: "You said no at capture. Undo lets the suggestion come back.",
                action: "suppressed",
                fieldChanged: kind.rawValue,
                oldValue: payload.encoded,
                newValue: proposal.targetID.uuidString,
                initiatedBy: .human,
                isReversible: true,
                taskTitle: task.title,
                taskUUID: task.uuid,
                actorID: UserProfile.currentMemberID(in: context), in: context))
    }

    /// The stable title a rejection is keyed on: the resolver builds its capture-form
    /// suppression key against the AI's ORIGINAL title (`normalizeTitle(intent.title)`), so
    /// the record must too — keying on the user-edited `draft.title` would let a
    /// renamed-then-rejected duplicate re-surface pre-accepted on the next capture.
    private func suppressionKeyTitle(for draft: TaskDraft) -> String {
        draft.aiOriginal?.title ?? draft.title
    }

    /// Fold each accepted-duplicate draft into its target: no new task, the target absorbs
    /// the capture (provenance note + parsedTaskIDs), and a reversible "merged" entry whose
    /// `oldValue` is the folded draft snapshot (so undo can resurrect it as an inbox task).
    /// Returns the merge targets so attention/parsedTaskIDs can account for them.
    private func foldMerges(
        _ merging: [TaskDraft], capture: Capture, all: [TaskItem], in context: NSManagedObjectContext
    ) -> [TaskItem] {
        guard !merging.isEmpty else { return [] }
        var targets: [TaskItem] = []
        for draft in merging {
            guard let proposal = draft.acceptedDuplicate,
                let target = all.first(where: { $0.uuid == proposal.targetID })
            else { continue }
            // The target absorbs this capture.
            let note = "Also captured: \(draft.title)"
            target.notes =
                [target.notes, note]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            target.touchHuman()  // the merge rode the user's confirm tap — real engagement
            context.insert(
                ChangeLogEntry(
                    summary: "Merged “\(draft.title)” into “\(target.title)”",
                    detail: "Same as an existing task — folded in rather than duplicated.",
                    action: "merged", oldValue: MergedTaskSnapshot(draft: draft).encoded,
                    newValue: capture.uuid?.uuidString,
                    initiatedBy: .human, isReversible: true,
                    taskTitle: target.title, taskUUID: target.uuid,
                    actorID: UserProfile.currentMemberID(in: context), in: context))
            context.insert(
                Correction(
                    taskUUID: target.uuid, captureID: capture.uuid,
                    fieldCorrected: "duplicate", aiValue: proposal.targetTitle, userValue: "accepted",
                    in: context))
            // The card's OTHER edits still teach. A user who fixed the category or the
            // owner and then accepted the merge produced exactly as valid a labeled pair
            // as one whose card became a task — the merge decides where the work lands,
            // not whether the correction happened. They attach to the merge TARGET,
            // which is the row that now carries this capture.
            recordCorrections(
                for: draft, taskUUID: target.uuid, captureID: capture.uuid, in: context)
            targets.append(target)
        }
        return targets
    }

    /// Turn each draft's owner name into a real `FamilyMember` reference, by
    /// case-insensitive match. Two captures naming "sarah" and "Sarah" resolve to one
    /// person.
    ///
    /// **An unmatched name creates nothing.** This used to silently mint a
    /// `FamilyMember`, which looked like the same mechanical-filing philosophy applied
    /// to categorization — but a category is a label and a person is not. A phantom
    /// minted from a misheard name becomes an *existing* member: it can accrue
    /// category ownership, feed the affinity denominator, and be proposed as an owner
    /// for future work. So an unresolved name leaves the task shared (`ownerID == nil`)
    /// and the confirm card's existing "Add person…" is the explicit human step that
    /// grows the roster.
    private func resolveOwners(_ drafts: [TaskDraft], created: [TaskItem], in context: NSManagedObjectContext)
    {
        // The roster fetch is only ever consumed by the spoken-name match below, so a
        // capture where nobody was named — the overwhelmingly common case, and the
        // whole of the fast path — must not pay a full-store fetch on the confirm tap.
        let namesSpoken = drafts.contains { draft in
            draft.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let members =
            namesSpoken
            ? ((try? context.fetch(NSFetchRequest<FamilyMember>(entityName: "FamilyMember"))) ?? [])
            : []
        for (draft, task) in zip(drafts, created) {
            guard let name = draft.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else { continue }
            if let match = members.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                task.ownerID = match.uuid
            }
        }

        // Everything the proposer left as the capturer's own work gets the linked
        // member id explicitly. The retired `nil == you` sentinel is gone, so "mine"
        // must be a real owner id (correct on every synced device); a `nil` owner means
        // genuinely shared. Bootstrap the you-identity only when something actually
        // needs it, so a commit of purely delegated work never creates a spurious member.
        let mine = zip(drafts, created).filter {
            $0.1.ownerID == nil && $0.0.ownerName == nil
        }
        if !mine.isEmpty {
            let me = UserProfile.currentMemberID(in: context)
            for (_, task) in mine { task.ownerID = me }
        }
    }

    /// The publish boundary. Called once per commit, AFTER ownership is resolved, and
    /// it is the ONLY place an assignment may have an outward effect.
    ///
    /// Nothing fires today: there is no sync (`PersistenceStack.cloudKitContainerID`
    /// is nil, the entitlement's container list is empty) and no notification
    /// machinery, so the interim behavior is a silent publish. The seam exists now
    /// because the *rule* is the load-bearing part — assignment side effects bind to
    /// Confirm, never to the owner field being populated — and a future "Confirm all"
    /// fast-path must have one obvious place to respect it.
    ///
    /// When delivery lands, the target behavior is three-part (see `docs/task-model.md`):
    /// one notification per assignment bound to this event, re-notify only on a genuine
    /// reassignment, and copy that names the source ("Charles assigned you: …").
    /// `syncIsLive` is a parameter so the SELECTION half can be tested at `true` while
    /// delivery stays unimplemented. Which tasks count as handed off — owned, and owned
    /// by somebody who is not me — is the part that has to be right on the day the gate
    /// flips; a notification bug is visible and fixable, publishing the wrong SET is a
    /// message sent to the wrong person.
    @discardableResult
    func handedOffAssignments(
        _ created: [TaskItem], in context: NSManagedObjectContext,
        syncIsLive: Bool = HouseholdSync.isLive
    ) -> [TaskItem] {
        guard syncIsLive else { return [] }
        let me = UserProfile.currentMemberID(in: context)
        return created.filter { $0.ownerID != nil && $0.ownerID != me }
    }

    private func publishAssignments(_ created: [TaskItem], in context: NSManagedObjectContext) {
        let handedOff = handedOffAssignments(created, in: context)
        guard !handedOff.isEmpty else { return }
        // Delivery lands here. Deliberately unimplemented rather than stubbed with a
        // local notification: notifying yourself about a task you just created is
        // theater, and the guardrails refuse notification-driven re-engagement.
    }

    /// Turn each draft's free-text blocker phrase into a real tracked-task blocker, now
    /// that every new task exists. Matches against the just-created batch plus existing
    /// not-done tasks. The AI only ever authors `.task` blockers — an "after X" it can't
    /// resolve to a real task (no match, or a cycle) creates nothing, and since every
    /// created task then re-derives, it lands unblocked rather than stranded in a
    /// phantom Blocked. `created` is in draft order, so `drafts[i]` ↔ `created[i]`.
    private func resolveBlockers(
        _ drafts: [TaskDraft], created: [TaskItem], all: [TaskItem], in context: NSManagedObjectContext
    ) {
        let createdIDs = Set(created.compactMap(\.uuid))
        // Candidates: everything unresolved, minus the just-created (added explicitly
        // so intra-batch references resolve even before the first save).
        let candidates =
            created
            + all.filter {
                !$0.status.isResolved && !createdIDs.contains($0.uuid ?? UUID())
            }
        for (draft, task) in zip(drafts, created) {
            guard let phrase = draft.blockedBy, !phrase.isEmpty else { continue }
            if let blockerID = TaskItem.resolveBlocker(
                phrase: phrase, among: candidates.filter { $0.uuid != task.uuid })
            {
                // No-ops if it'd cycle.
                task.addTaskBlocker(blockerID, among: candidates, origin: .inferred(confidence: 0.9))
            } else {
                // No matching task: the captured wait becomes an EXTERNAL blocker in
                // the user's own words ("waiting on receipts") rather than being
                // silently lost. This does not breach the "AI never authors external
                // blockers" rule's intent: the phrase rode the Confirm-Creation card
                // (visible, removable) — it is confirm-sanctioned, never a silent
                // post-creation invention. Blocked stays derived either way.
                task.addExternalBlocker(phrase, among: candidates, origin: .inferred(confidence: 0.9))
            }
        }
    }
}

// MARK: - Commit outcome

/// What one confirm produced. Values only, so the notice survives the composer's teardown.
///
/// The composer used to close on a haptic and nothing else: no count, no destination, no
/// evidence. For a product whose whole wedge is "dump it and trust that it landed", the
/// one moment that most needs a receipt had none — a capture that silently produced
/// nothing looked identical to one that produced five tasks.
struct CommitSummary: Equatable {
    /// True when the confirm boundary's own `context.saveChanges()` reported a
    /// dropped write — the drafts became `TaskItem`s in memory but the store never
    /// actually persisted them. The receipt ("N tasks added") is otherwise honest
    /// by construction; this is what lets a caller tell the difference before it
    /// shows the user a success it can't back up.
    var saveFailed: Bool = false
    var created: Int
    var mergedTitles: [String]

    var isEmpty: Bool { created == 0 && mergedTitles.isEmpty }

    /// "Added 3 tasks" · "Added 2 · 1 merged into “Renew passport”" · "Merged into “X”".
    /// A merge names its target because that's the answer to "where did my thought go?",
    /// which is the only question a merge leaves open.
    var message: String {
        var parts: [String] = []
        if created > 0 { parts.append("Added \(created) task\(created == 1 ? "" : "s")") }
        switch mergedTitles.count {
        case 0:
            break
        case 1:
            parts.append(
                created > 0 ? "1 merged into “\(mergedTitles[0])”" : "Merged into “\(mergedTitles[0])”")
        default:
            parts.append("\(mergedTitles.count) merged")
        }
        return parts.joined(separator: " · ")
    }

    /// What the Create moment's ✓ receipt ("5 tasks added") CANNOT say — nil when the
    /// count is the whole story. A toast that repeats the confirmation the user just
    /// watched is noise; a merge is different, because "where did my thought go?" is a
    /// question the count leaves open and only the target's name answers.
    var messageBeyondReceipt: String? {
        guard !mergedTitles.isEmpty else { return nil }
        switch mergedTitles.count {
        case 1: return "Merged into “\(mergedTitles[0])”"
        default: return "\(mergedTitles.count) merged into existing tasks"
        }
    }
}

// MARK: - Merge snapshot (undo resurrection)

/// The minimal frozen draft a "merged" change-log entry carries in `oldValue`, so Undo
/// can resurrect the folded task as a fresh inbox item (the merge never destroyed data).
struct MergedTaskSnapshot: Codable {
    var title: String
    var category: String
    var isUrgent: Bool
    var reasoning: String

    init(draft: TaskDraft) {
        title = draft.title
        category = draft.category
        isUrgent = draft.isUrgent
        reasoning = draft.reasoning
    }

    var encoded: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ raw: String?) -> MergedTaskSnapshot? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MergedTaskSnapshot.self, from: data)
    }
}
