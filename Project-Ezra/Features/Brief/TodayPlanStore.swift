//
//  TodayPlanStore.swift
//  Project-Ezra
//
//  The persistence + lifecycle behind "the sequence plays once a day". It owns the
//  day cache (so repeat opens land on the resting plan, not a re-performance), the
//  single reset predicate, and the day-rollover reconciliation that turns
//  yesterday's plan into one `CapacityLog` row.
//
//  The reset mechanism is deliberately held open by the team spec pending separate
//  input, so it lives in exactly ONE swappable predicate — `shouldReplay(now:)`.
//  Nothing else in the app may test the date to decide a replay; swap that one
//  method and the trigger changes wholesale.
//
//  Injectable `UserDefaults` (the `MetricsRecorder` idiom) so the store is testable
//  against a scratch suite.
//

import CoreData
import Foundation
import Observation

/// The cached result of one day's sequence: enough to render the resting plan
/// without regenerating, plus the signature to detect a docket that has since
/// moved. Codable so it round-trips through `UserDefaults`.
struct TodayPlanCache: Codable, Sendable, Hashable {
    /// The calendar-day key the plan belongs to ("2026-07-20").
    let dateKey: String
    var tier: PlanTier
    var headline: String?
    var tradeoffs: String?
    var risks: String?
    var actions: [PlannedAction]
    var generatedAt: Date
    /// The open candidate ids this briefing was generated against — a new open id
    /// absent from here means the day has changed (the quiet "Replan" affordance).
    var docketSignature: [UUID]
    /// Stamped when the sequence played through. Nil while generation is in flight, so
    /// an interrupted open resumes at the briefing without re-consuming the Recap.
    var completedAt: Date?
}

@MainActor
@Observable
final class TodayPlanStore {
    private let defaults: UserDefaults

    /// The current day cache, mirrored in memory for observation and written through
    /// to `UserDefaults`. Nil when there is no plan for any day yet.
    private(set) var cache: TodayPlanCache?
    /// The high-water mark of acknowledged completions — the Recap window's start.
    /// Advanced ONLY by `markSequenceComplete`, so an abandoned mid-sequence day
    /// never consumes the recap.
    private(set) var recapCutoff: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cache = Self.decodeCache(from: defaults)
        self.recapCutoff = defaults.object(forKey: Key.recapCutoff) as? Date
    }

    // MARK: - The one reset predicate

    /// The calendar-day key — the ONLY place the date is read for the replay
    /// decision.
    static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// THE single reset predicate (V0: first open each day). Swapping the reset
    /// trigger means changing only this method.
    func shouldReplay(now: Date) -> Bool {
        cache?.dateKey != Self.dayKey(for: now)
    }

    /// Whether today's sequence has already been played all the way through — the one
    /// input `BriefingReminder` needs to skip a day, readable without owning a store
    /// instance (the app's scene-phase handler has no view context).
    static func sequencePlayedToday(
        now: Date = Date(), defaults: UserDefaults = .standard
    ) -> Bool {
        guard let cache = decodeCache(from: defaults) else { return false }
        return cache.dateKey == dayKey(for: now) && cache.completedAt != nil
    }

    // MARK: - Cache access

    /// The resting plan for today, or nil when a replay is due (so the caller runs
    /// the sequence instead of resting).
    func cache(for now: Date) -> TodayPlanCache? {
        shouldReplay(now: now) ? nil : cache
    }

    /// Persist a cache (write-through to observation + defaults).
    func save(_ cache: TodayPlanCache) {
        self.cache = cache
        persistCache()
    }

    /// Drop the day cache entirely.
    func clear() {
        cache = nil
        defaults.removeObject(forKey: Key.cache)
    }

    // MARK: - Outliving the work (self-healing, no broadcast)

    /// Has this cached briefing outlived the work it describes?
    ///
    /// The cache is the app's one decoded snapshot of tasks — it names ids by hand, in
    /// `UserDefaults`, where Core Data's change notifications can't reach it. Ids can stop
    /// resolving for several unrelated reasons (Settings ▸ Clear, a duplicate-sweep merge,
    /// an undo), so the durable answer is to VALIDATE ON READ rather than have each of
    /// those sites remember to announce itself. Same instinct as
    /// `GeneratedPlan.validated(against:)`: trust nothing decoded, check it against the
    /// live set.
    ///
    /// **All-or-nothing on purpose.** A plan that lost SOME tasks is still a plan (the
    /// render path compacts those rows); a plan that lost every task is a briefing about
    /// nothing, and its headline would go on describing a day that no longer exists.
    /// Pure and static so the rule is testable without a store, a context or a clock.
    static func hasOutlivedItsWork(_ cache: TodayPlanCache, liveTaskIDs: Set<UUID>) -> Bool {
        guard !cache.actions.isEmpty else { return false }
        return !cache.actions.contains { liveTaskIDs.contains($0.taskID) }
    }

    /// Drop the cache if it has outlived its work, reporting whether it did.
    @discardableResult
    func dropCacheIfWorkVanished(liveTaskIDs: Set<UUID>) -> Bool {
        guard let cache, Self.hasOutlivedItsWork(cache, liveTaskIDs: liveTaskIDs) else {
            return false
        }
        clear()
        return true
    }

    /// Stamp the sequence as fully played and advance the recap high-water mark. The
    /// resting state renders from here on; the next day's Recap counts completions
    /// since `now`.
    ///
    /// **The FIRST completion of the day owns the cutoff.** A same-day replan (or the
    /// on-device self-heal upgrade) lands here again, and re-stamping would move the
    /// window forward over hours the morning Recap already covered — every task finished
    /// between the two generations would be swallowed and never appear in tomorrow's
    /// Recap. Same rule as `lastSurfacedAt` in `BriefSequenceModel.finalize`, for the
    /// same reason: a re-performance is not a new day.
    func markSequenceComplete(now: Date) {
        let playedToday = cache?.dateKey == Self.dayKey(for: now) && cache?.completedAt != nil
        if !playedToday {
            recapCutoff = now
            defaults.set(now, forKey: Key.recapCutoff)
        }
        if var current = cache {
            current.completedAt = current.completedAt ?? now
            save(current)
        }
    }

    // MARK: - Docket-changed signal

    /// True when the live open docket contains an id the cached plan was not built
    /// against — the quiet "Your docket changed — Replan" trigger. V0 never
    /// auto-regenerates; this is only a hint.
    func hasDocketChanged(currentOpenDocketIDs: [UUID]) -> Bool {
        guard let signature = cache?.docketSignature else { return false }
        let known = Set(signature)
        return currentOpenDocketIDs.contains { !known.contains($0) }
    }

    // MARK: - Day-rollover reconciliation

    /// On the first open of a new day, turn yesterday's plan into one `CapacityLog`
    /// row before clearing it — reusing the Recap moment, no new surface.
    /// `completedCount` = planned actions now resolved `.done`; `skippedCount` = the
    /// rest. This is the rolling-throughput substrate the advisor reads as context;
    /// with the capacity input gone, the capacity dimension is vestigial (`.steady`),
    /// so `CapacityBaseline(for: .steady)` reads as the overall daily-completion
    /// average. Empty-plan days aren't logged (they'd drag the average down).
    ///
    /// This is also the per-task deferral write seam: a planned task still OPEN at
    /// rollover increments `deferralCount` when no human touched it since it surfaced
    /// (the true skip), or `carriedOverCount` when someone worked on it without
    /// finishing (multi-day work must NOT read as deferral — ranking would pull down
    /// actively-worked tasks, the inverted signal). The discriminator is the HUMAN
    /// clock (`humanTouchedAt`), never `updatedAt` — a system edge-write between
    /// surface and rollover can't fake engagement. This is the only site that RAISES
    /// `deferralCount`; `touchHuman` is the only site that clears it, which is what
    /// makes the count consecutive rather than lifetime.
    func reconcileIfNeeded(context: NSManagedObjectContext, tasks: [TaskItem], now: Date) {
        guard let stale = cache, stale.dateKey != Self.dayKey(for: now) else { return }

        if !stale.actions.isEmpty {
            let byID = Dictionary(
                uniqueKeysWithValues: tasks.compactMap { task in task.uuid.map { ($0, task) } })
            let completed = stale.actions.filter { byID[$0.taskID]?.status == .done }.count
            let skipped = stale.actions.count - completed
            for action in stale.actions {
                guard let task = byID[action.taskID], !task.status.isResolved else { continue }
                let surfacedAt = task.lastSurfacedAt ?? stale.generatedAt
                if task.humanTouchedAt > surfacedAt {
                    task.carriedOverCount += 1
                } else {
                    task.deferralCount += 1
                }
            }
            let day = Calendar.current.startOfDay(for: stale.generatedAt)
            let log = CapacityLog(
                date: day, capacity: .steady, planCount: stale.actions.count,
                completedCount: completed, skippedCount: skipped, in: context)
            context.insert(log)
            context.saveChanges()
        }
        clear()
    }

    // MARK: - Persistence

    private func persistCache() {
        guard let cache, let data = try? JSONEncoder().encode(cache) else {
            defaults.removeObject(forKey: Key.cache)
            return
        }
        defaults.set(data, forKey: Key.cache)
    }

    private static func decodeCache(from defaults: UserDefaults) -> TodayPlanCache? {
        guard let data = defaults.data(forKey: Key.cache) else { return nil }
        return try? JSONDecoder().decode(TodayPlanCache.self, from: data)
    }

    private enum Key {
        static let cache = "today.planCache"
        static let recapCutoff = "today.recapCutoff"
    }
}
