//
//  TodaySequenceModel.swift
//  Project-Ezra
//
//  The state behind the two-scene cinematic Today briefing:
//
//    Scene 1 — Recap ("what you got done"), which doubles as the cover WHILE the AI
//              advisor reasons the day in the background (no spinner).
//    Scene 2 — the advisor briefing (headline · actions · tradeoffs · risks).
//
//  There is no timer: the transition to the briefing is DATA-driven — it fires when
//  generation completes AND the Recap's entrance has played (the View reports the
//  latter via `showBriefingIfReady`). Generation is guarded by a monotonic counter
//  checked before AND after the await, so a stale stream can never overwrite a newer
//  one (Replan invalidates whatever is in flight).
//
//  The advisor SELECTS/ORDERS/SIZES the plan itself (see `TodayPlanService`); this
//  model just provides the candidate set (open work, TaskRanking-ordered) and the
//  rolling-throughput context, then drives the two scenes.
//

import CoreData
import Foundation
import Observation

@MainActor
@Observable
final class TodaySequenceModel {

    /// Two scenes. Recap is also the generation cover; Briefing shows a "reading your
    /// day…" state while `isGenerating`, then the advisor's briefing.
    enum Beat { case recap, briefing }

    // MARK: - Observable state

    private(set) var beat: Beat = .recap
    private(set) var recap = TodayRecap(completedSince: .distantPast, completedTasks: [])
    /// The briefing as it stands — streamed validated-so-far, then final. Nil until
    /// generation produces something.
    private(set) var plan: GeneratedPlan?
    private(set) var isGenerating = false
    /// A repeat open landed on the cached briefing — render it, do not re-perform.
    private(set) var resting = false
    private(set) var started = false

    // MARK: - Collaborators + snapshot inputs

    private let brain: AppBrain
    private let store: TodayPlanStore
    /// The clock this run of the sequence is anchored to. Mutable ONLY through
    /// `restartIfDayRolledOver` — the app can outlive the day it launched in, and a
    /// briefing frozen at yesterday's `now` would keep resting on screen forever.
    private(set) var now: Date

    private var allTasks: [TaskItem] = []
    private var capacityLogs: [CapacityLog] = []
    private var context: NSManagedObjectContext?
    /// The device’s linked member id. Only consulted once `HouseholdSync.isLive` — see
    /// `candidateTasks` for why the ownership filter must not run before sync exists.
    private var currentUserID: UUID?

    /// The stale-generation guard (checked before and after each await).
    private var generation = 0

    init(brain: AppBrain, store: TodayPlanStore, now: Date = Date()) {
        self.brain = brain
        self.store = store
        self.now = now
    }

    // MARK: - Start

    /// Enter the surface: reconcile yesterday's plan into a CapacityLog, compute the
    /// Recap, then either rest on today's cached briefing or begin a fresh sequence
    /// (Recap cover + background generation).
    func start(
        tasks: [TaskItem], logs: [CapacityLog], currentUserID: UUID? = nil,
        context: NSManagedObjectContext
    ) {
        self.allTasks = tasks
        self.capacityLogs = logs
        self.currentUserID = currentUserID
        self.context = context

        store.reconcileIfNeeded(context: context, tasks: tasks, now: now)

        // Cold start (no prior `recapCutoff`): count everything completed since the start
        // of TODAY, so a brand-new user who finished a few tasks and opens Today sees
        // them immediately. On day 2+, `recapCutoff` (set at the last sequence completion)
        // governs the window instead.
        let since = store.recapCutoff ?? Calendar.current.startOfDay(for: now)
        recap = TodayQueries.recap(tasks: tasks, since: since, now: now)

        if let cached = store.cache(for: now), cached.completedAt != nil {
            // Fully played earlier today → resting briefing, no re-performance.
            plan = GeneratedPlan(
                actions: cached.actions, headline: cached.headline, tradeoffs: cached.tradeoffs,
                risks: cached.risks, tier: cached.tier)
            resting = true
            beat = .briefing
            started = true
            // Self-heal: if today's cached plan is the voiceless deterministic fallback
            // (the model was cold/unavailable at the first open) and the on-device advisor
            // is available now, quietly upgrade in the background — keeping the cached
            // briefing on screen until the voiced one lands, so nothing blanks out.
            if !(plan?.hasAdvisorVoice ?? false) && AppBrain.todayAdvisorAvailable() {
                AppBrain.prewarmTodayModel()
                Task { await generate(mode: .selfHeal) }
            }
            return
        }

        // Fresh run: start on the Recap cover (or straight to the briefing loading
        // state when nothing was completed), and reason the day in the background. Warm
        // the model now so it isn't cold when generation races the deadline.
        resting = false
        beat = recap.isEmpty ? .briefing : .recap
        started = true
        AppBrain.prewarmTodayModel()
        Task { await generate() }
    }

    /// The calendar day rolled over while the app stayed alive — re-arm the sequence for
    /// the new day and return true so the caller can replay the Recap entrance.
    ///
    /// Without this, "the briefing plays once a day" only held across cold launches: a
    /// phone left on the Today tab overnight (or backgrounded and reopened the next
    /// morning — the exact path the daily nudge creates) kept resting on yesterday's
    /// briefing, and the rollover reconciliation that turns yesterday's plan into a
    /// `CapacityLog` + deferral counts never ran.
    ///
    /// The date test routes through `TodayPlanStore.shouldReplay` — the single reset
    /// predicate — rather than comparing days here, so the swappable trigger stays
    /// swappable.
    @discardableResult
    func restartIfDayRolledOver(
        now newNow: Date, tasks: [TaskItem], logs: [CapacityLog], currentUserID: UUID? = nil,
        context: NSManagedObjectContext
    ) -> Bool {
        guard started, !isGenerating, store.shouldReplay(now: newNow) else { return false }
        generation += 1  // orphan anything still in flight against the old day
        now = newNow
        started = false
        resting = false
        plan = nil
        beat = .recap
        start(tasks: tasks, logs: logs, currentUserID: currentUserID, context: context)
        return true
    }

    /// The store was emptied under the sequence (Settings ▸ Clear all tasks). Drop the
    /// briefing and re-arm, so the caller can start a fresh one against what is left.
    ///
    /// Not folded into `restartIfDayRolledOver`: that one is gated on the day predicate
    /// and on `started`, and both gates are wrong here — the day has NOT changed, and a
    /// wipe has to land whether or not a briefing is in flight. What it shares is the
    /// generation bump, which orphans anything still generating against the old tasks.
    func rearmAfterDataCleared() {
        generation += 1
        started = false
        resting = false
        plan = nil
        beat = .recap
        // The orphaned run returns at its stale guard, BEFORE it lowers this flag — so
        // lower it here, or a sequence nobody restarts sits on the loading cover forever.
        isGenerating = false
        recap = TodayRecap(completedSince: now, completedTasks: [])
        allTasks = []
        capacityLogs = []
    }

    // MARK: - Scene transition (data-driven, never timed)

    /// The View calls this once the Recap's entrance has played; it transitions to the
    /// briefing only when generation is also done. No timer — the transition lands the
    /// moment there's something worth showing.
    func showBriefingIfReady(recapEntrancePlayed: Bool) {
        guard beat == .recap, recapEntrancePlayed, !isGenerating, plan != nil else { return }
        beat = .briefing
    }

    /// A tap on the Recap to skip straight to the briefing — only meaningful once the
    /// briefing is ready (otherwise the Recap stays as the cover).
    func skipRecap() {
        guard beat == .recap, !isGenerating, plan != nil else { return }
        beat = .briefing
    }

    /// Recompose the day (the Replan affordance / day-changed hint) — now a DELTA
    /// TURN on the per-day advisor session rather than a cold regeneration: the
    /// prompt leads with what changed since the morning, the transcript (when the
    /// process survived) carries the morning's reasoning, and the current briefing
    /// stays on screen until the recomposition lands. After a process restart the
    /// delta block alone reconstructs the continuity — same product behavior.
    func replan() {
        let delta = deltaContext()
        Task { await generate(mode: .recompose(delta: delta)) }
    }

    /// The observable since-this-morning facts, as one prompt block. Deterministic:
    /// resolved planned actions + candidates the cached briefing wasn't built against.
    private func deltaContext() -> String? {
        guard let cached = store.cache(for: now) else { return nil }
        var lines: [String] = []
        let resolved = cached.actions.filter { action in
            allTasks.first { $0.uuid == action.taskID }?.status.isResolved ?? false
        }
        if !resolved.isEmpty {
            lines.append("completed \(resolved.count) of this morning's plan")
        }
        let known = Set(cached.docketSignature)
        let fresh = candidateTasks(from: allTasks).filter { task in
            task.uuid.map { !known.contains($0) } ?? false
        }
        if !fresh.isEmpty {
            lines.append(
                "new since then: " + fresh.prefix(3).map(\.title).joined(separator: "; "))
        }
        guard !lines.isEmpty else { return nil }
        return "SINCE THIS MORNING: " + lines.joined(separator: " · ") + "."
    }

    // MARK: - Generation

    /// Generate the briefing. `preservePlan` is the SELF-HEAL upgrade path: it keeps the
    /// currently-shown (cached deterministic) briefing on screen — no blank loading cover,
    /// no streamed partials swapped in — and replaces it only if a *voiced* briefing lands.
    /// A still-voiceless result leaves the cached plan untouched (no re-freeze, no flicker).
    /// How a generation relates to what is on screen. `.fresh` blanks to the loading
    /// cover and streams partials in; `.selfHeal` keeps the cached plan and swaps only
    /// a VOICED upgrade in; `.recompose` keeps the current briefing and replaces it
    /// with whatever the delta turn returns (a deterministic recomposition is still
    /// the correct updated plan — the day really did change).
    enum GenerationMode: Equatable {
        case fresh
        case selfHeal
        case recompose(delta: String?)
    }

    private func generate(mode: GenerationMode = .fresh) async {
        guard let context else { return }
        generation += 1
        let token = generation
        isGenerating = true
        if mode == .fresh {
            plan = nil  // fresh briefing; the loading cover shows until it arrives
        }

        var request = makeRequest()
        if case .recompose(let delta) = mode { request.deltaContext = delta }
        // Only the fresh path streams partials (into the loading cover); the self-heal
        // and recompose paths keep the current briefing on screen, no flicker.
        var handler: (@MainActor (GeneratedPlan) -> Void)?
        if mode == .fresh {
            handler = { [weak self] partial in
                guard let self, self.generation == token else { return }  // stale guard (during)
                self.plan = partial
            }
        }
        let generated = await brain.todayPlan(for: request, in: context, onPartial: handler)

        guard generation == token else { return }  // stale guard (after the await)
        isGenerating = false

        switch mode {
        case .selfHeal:
            // Only swap in — and re-cache — a genuinely voiced upgrade; otherwise keep
            // showing the cached plan exactly as-is.
            guard generated.hasAdvisorVoice else { return }
            plan = generated
            finalize()
        case .fresh, .recompose:
            plan = generated
            finalize()
        }
    }

    /// Persist the final briefing and advance the recap high-water mark. Also stamps
    /// `lastSurfacedAt` on every planned task — the fact the next rollover's deferral
    /// discriminator compares the human clock against.
    ///
    /// FIRST surfacing of the day wins: a same-day replan/upgrade must NOT re-stamp, or a
    /// task the user actively worked at 10am would look surfaced-at-2pm and, since the
    /// human touch now predates the stamp, be miscounted as *deferred* at the next rollover
    /// (the inverted signal). (TODO: a task the replan DROPS from the plan escapes deferral
    /// counting entirely — a known gap that awaits the deferred replan-mechanism design.)
    private func finalize() {
        guard let plan else { return }
        let planned = Set(plan.actions.map(\.taskID))
        for task in allTasks where task.uuid.map(planned.contains) ?? false {
            if let surfaced = task.lastSurfacedAt, Calendar.current.isDate(surfaced, inSameDayAs: now) {
                continue
            }
            task.lastSurfacedAt = now
        }
        context?.saveChanges()
        // Carry today's existing completion stamp forward. A replan/self-heal rewrites the
        // cache for a day that already played, and resetting `completedAt` to nil here
        // would make `markSequenceComplete` treat the re-performance as the day's first —
        // moving the recap cutoff past hours the morning Recap already covered.
        let playedAt = store.cache(for: now)?.completedAt
        store.save(
            TodayPlanCache(
                dateKey: TodayPlanStore.dayKey(for: now), tier: plan.tier, headline: plan.headline,
                tradeoffs: plan.tradeoffs, risks: plan.risks, actions: plan.actions,
                generatedAt: now, docketSignature: candidateIDs, completedAt: playedAt))
        store.markSequenceComplete(now: now)
    }

    private func makeRequest() -> TodayPlanRequest {
        let baseline = CapacityBaseline.baseline(for: .steady, logs: capacityLogs)
        let typical = baseline.isPersonalized ? baseline.typicalCompletedCount : nil
        // The measured budget (context-sized, once the session has computed it) —
        // heavy days fill the model's real window instead of a fixed guess.
        var request = TodayPlanRequest.make(
            candidateItems: candidateTasks(from: allTasks), allTasks: allTasks,
            recapCount: recap.count, typicalCompleted: typical, now: now,
            cap: brain.advisorCandidateCap)
        request.yesterdayOutcome = YesterdayDigest.make(
            tasks: allTasks, logs: capacityLogs, now: now)
        return request
    }

    /// The advisor's candidate set: my live work plus open decisions, in `TaskRanking`
    /// order (so the most important land in the capped candidate list).
    ///
    /// One exclusion, deliberate:
    ///
    /// - **Ownership, but only once sync is live.** Today is *my* execution and
    ///   Household is *our* coordination, so work owned by someone else does not
    ///   belong here. That filter is gated on `HouseholdSync.isLive` because without
    ///   sync the other person has no device in the graph: applying it now would let a
    ///   task leave your briefing and land nowhere anyone can act on it. Single-device
    ///   installs therefore keep everything, exactly as before.
    private func candidateTasks(from tasks: [TaskItem]) -> [TaskItem] {
        let open = tasks.filter {
            ($0.status.isLive || ($0.needsDecision && !$0.status.isResolved))
                && (!HouseholdSync.isLive || $0.isMine(currentUserID: currentUserID))
        }
        return TaskRanking.sorted(open, among: tasks, now: now)
    }

    private var candidateIDs: [UUID] { candidateTasks(from: allTasks).compactMap(\.uuid) }

    // MARK: - Day-changed signal (resting hint only)

    /// Whether the live candidate set has gained an id the cached briefing wasn't built
    /// against — the quiet "Replan" hint.
    func dayChanged(currentTasks: [TaskItem]) -> Bool {
        let ids = candidateTasks(from: currentTasks).compactMap(\.uuid)
        if store.hasDocketChanged(currentOpenDocketIDs: ids) { return true }
        // Completing planned work is also a material change — the rest of the day
        // deserves recomposition, not a plan frozen around finished items.
        guard let cached = store.cache(for: now) else { return false }
        return cached.actions.contains { action in
            currentTasks.first { $0.uuid == action.taskID }?.status.isResolved ?? false
        }
    }
}
