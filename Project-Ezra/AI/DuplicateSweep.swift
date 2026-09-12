//
//  DuplicateSweep.swift
//  Project-Ezra
//
//  Duplicates that entered on DIFFERENT days: capture-time edge proposals only see
//  the capture in hand, so "Renew passport" (Monday) and "passport renewal"
//  (Thursday) coexist forever. This sweep finds embedding-near pairs of existing
//  open tasks, asks the on-device model to judge each, and auto-merges at the SAME
//  ≥0.85 tier capture-time merges use — the destructive-tier rule extended to
//  existing pairs, with Activity entry + one-tap Undo as the human boundary
//  (product decision, 2026-08-07). Deliberately NOT part of `BrainSweeps`' silent
//  tier: a merge is the auto-accept invariant's destructive exception, so it lives
//  here, named, with its own rules.
//
//  Containment, layered:
//  - Deterministic prefilter first: embedding similarity AND lexical overlap must
//    BOTH clear floors; suppressed pairs drop; top `maxPairsPerRun` only.
//  - The model judges each surviving pair through `ModelRun` (background deadline,
//    `maxJudgmentsPerRun` cap) — off-device the seam answers `.unavailable` before
//    any session exists, and the sweep is simply absent, like every proposal
//    feature on the heuristic path.
//  - Merge is KILL-DON'T-DELETE: the older task wins (it has the history), absorbs
//    "Also captured: …", and the loser is `kill`ed — fully reversible, so the
//    `"mergedPair"` undo arm restores identity, timeline, and edges by reopening,
//    and writes a pair suppression so the sweep never re-proposes what a human
//    already unwound. A judgment call or open decision is never the loser —
//    killing IS resolving, and that carve-out is permanent.
//  - V1 limitation, recorded: the loser's edges are not migrated to the winner
//    (kill semantics handle dependents exactly as any archive does; everything
//    restores on undo).
//

import CoreData
import Foundation
import FoundationModels

/// The model's verdict on one candidate pair.
@Generable
struct DuplicateJudgment {
    @Guide(description: "true only if these two to-do items describe the SAME task")
    var isDuplicate: Bool
    @Guide(description: "confidence 0...1 that they are the same task")
    var confidence: Double
    @Guide(description: "one short sentence explaining the call")
    var reason: String
}

enum DuplicateSweep {

    // MARK: - Tuning (containment constants, named)

    /// Both floors must clear — semantic nearness alone sweeps in siblings
    /// ("book flights" / "book the hotel"), lexical overlap alone sweeps in
    /// re-uses of common words. Near-duplicates clear both. The lexical floor is
    /// DELIBERATELY `DraftMerge.retitleSimilarityFloor` (0.3), the codebase's one
    /// established "same thought, re-phrased" word-overlap line — "renew my
    /// passport" vs "passport renewal" scores exactly 1/3, and a floor above it
    /// would exclude the flagship duplicate shape this sweep exists to catch.
    static let embeddingFloor = 0.82
    static let lexicalFloor = DraftMerge.retitleSimilarityFloor
    static let maxPairsPerRun = 20
    static let maxJudgmentsPerRun = 5
    /// The SAME destructive-tier threshold capture-time merges use.
    static let acceptThreshold = IntentResolver.acceptThreshold

    struct CandidatePair {
        var a: OpenTaskSnapshot
        var b: OpenTaskSnapshot
        var score: Double
    }

    // MARK: - Prefilter (pure, deterministic, tested)

    /// Embedding-near AND lexically-overlapping pairs of open tasks, suppressed
    /// pairs dropped, best-first, capped. `vector` is injected so tests run
    /// without NLEmbedding (absent under XCTest); pairs missing a vector are
    /// skipped — the sweep only ever reasons over evidence it actually has.
    static func candidatePairs(
        among snapshots: [OpenTaskSnapshot],
        suppressions: [RelationshipSuppression],
        vector: (String) -> [Double]?
    ) -> [CandidatePair] {
        // **Each snapshot is prepared ONCE, and the cheap floor is checked first.**
        //
        // The first shape of this loop fetched the vector and re-tokenized the title
        // inside the pair loop — O(n²) lock acquisitions and tokenizations for a job
        // that needs O(n) of each — and ran the 512-dimension dot product before the
        // word-overlap check, so every pair paid for the expensive floor whether or not
        // it could pass the cheap one. At 206 open tasks that was 88ms on the main
        // actor (Debug, simulator, `ZZAIPathPerfProbeTests`), hourly, growing with the
        // square of the store; 23ms after. Both floors must clear, so checking the
        // lexical one first is a pure reordering of an AND: same pairs, same scores,
        // pinned against the original loop by
        // `DuplicateSweepTests.fastPathMatchesTheNaiveOne`.
        struct Prepared {
            let snapshot: OpenTaskSnapshot
            let vector: [Double]
            let words: Set<String>
        }
        let prepared: [Prepared] = snapshots.compactMap { snapshot in
            guard let vector = vector(snapshot.title) else { return nil }
            let words = CorrectionProfile.significantWords(snapshot.title)
            guard !words.isEmpty else { return nil }
            return Prepared(snapshot: snapshot, vector: vector, words: words)
        }

        var pairs: [CandidatePair] = []
        for i in prepared.indices {
            let a = prepared[i]
            for j in prepared.indices where j > i {
                let b = prepared[j]
                // Lexical first: a set intersection on a handful of words, and the floor
                // most pairs fail. The dot product runs only for survivors.
                let overlap = Double(a.words.intersection(b.words).count)
                let union = Double(a.words.union(b.words).count)
                guard union > 0, overlap / union >= lexicalFloor else { continue }
                let similarity = EmbeddingStore.similarity(a.vector, b.vector)
                guard similarity >= embeddingFloor else { continue }
                guard
                    !suppressions.contains(where: {
                        $0.suppressesPair(kind: .duplicateMerge, a.snapshot.id, b.snapshot.id)
                    })
                else { continue }
                pairs.append(CandidatePair(a: a.snapshot, b: b.snapshot, score: similarity))
            }
        }
        return
            pairs
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                // Deterministic tiebreak — dictionary order must never decide.
                return $0.a.id.uuidString < $1.a.id.uuidString
            }
            .prefix(maxPairsPerRun)
            .map { $0 }
    }

    // MARK: - The sweep

    /// Judge and merge, bounded. Returns the number of merges performed.
    @discardableResult
    static func run(in context: NSManagedObjectContext, now: Date = Date()) async -> Int {
        // Cheap double-gate: ModelRun would answer .unavailable per pair anyway, but
        // there is no reason to build snapshots on a device with no judge.
        guard AppBrain.onDeviceModelAvailable() else { return 0 }
        EmbeddingStore.warmUp(in: context)
        let snapshots = OpenTaskSnapshotCache.shared.snapshots(in: context)
        guard snapshots.count > 1 else { return 0 }
        let all = TaskItem.fetchAll(in: context)
        let suppressions = SuppressionStore.load(
            in: context, existingTaskIDs: Set(all.compactMap(\.uuid)))
        let pairs = candidatePairs(
            among: snapshots, suppressions: suppressions,
            vector: { EmbeddingStore.cachedVector(for: $0) })

        var merges = 0
        for pair in pairs.prefix(maxJudgmentsPerRun) {
            // Sweeps are on-device ONLY, hard-capped, and must never reach the cloud
            // rung: background work nobody is waiting on has no business costing money.
            // The counter is here so that stays a measured fact rather than an intention.
            IntelligenceLedger.shared.record(.onDevice, for: .sweeps)
            let result = await judge(pair)
            guard case .success(let judgment) = result, accepts(judgment) else { continue }
            if mergeJudgedPair(pair, in: context, now: now) { merges += 1 }
        }
        if merges > 0 { context.saveChanges() }
        return merges
    }

    /// THE judgment — one pair in, the model's verdict out, no merge and no side effect.
    ///
    /// Lifted out of `run` so `-DuplicateSweepEval` measures the judge the product
    /// actually uses. A harness with its own copy of the instructions and the prompt is a
    /// harness that scores a second implementation and reports it as the first; this
    /// codebase has already paid for that once (the confidence gate's scorer, whose ground
    /// truth asked the wrong question).
    static func judge(_ pair: CandidatePair) async -> ModelResult<DuplicateJudgment> {
        await ModelRun.perform(
            .duplicateSweep, deadline: ModelDeadline.seconds(for: .background)
        ) {
            let session = LanguageModelSession(instructions: Self.judgeInstructions)
            return try await session.respond(
                to: Self.judgePrompt(pair), generating: DuplicateJudgment.self
            ).content
        }
    }

    /// Whether a judgment clears the destructive tier. A function rather than an inline
    /// condition so the eval can sweep the threshold instead of asserting the constant —
    /// **0.85 is a number somebody chose, and a model-reported confidence is exactly the
    /// kind of value whose calibration moves when the runtime does.**
    static func accepts(_ judgment: DuplicateJudgment, threshold: Double = acceptThreshold) -> Bool {
        judgment.isDuplicate && judgment.confidence >= threshold
    }

    static let judgeInstructions = """
        You judge whether two to-do items from one person's task list describe the \
        SAME underlying task. Different phrasings of one errand are duplicates \
        ("renew passport" / "passport renewal"). Related but distinct steps are NOT \
        ("renew passport" / "book flights"). Judge conservatively: when unsure, they \
        are not duplicates.
        """

    static func judgePrompt(_ pair: CandidatePair) -> String {
        """
        Task A: \(pair.a.title) (category \(pair.a.category))
        Task B: \(pair.b.title) (category \(pair.b.category))

        Are these the same task?
        """
    }

    // MARK: - Merge (kill-don't-delete; internal so tests drive it model-free)

    /// Resolve the judged pair to live tasks and merge. False when the pair no
    /// longer qualifies (a task resolved mid-sweep, or the loser is a judgment
    /// call — never killable by a sweep).
    static func mergeJudgedPair(
        _ pair: CandidatePair, in context: NSManagedObjectContext, now: Date = Date()
    ) -> Bool {
        let all = TaskItem.fetchAll(in: context)
        guard let taskA = all.first(where: { $0.uuid == pair.a.id }),
            let taskB = all.first(where: { $0.uuid == pair.b.id }),
            !taskA.status.isResolved, !taskB.status.isResolved
        else { return false }
        // The OLDER task wins: it carries the history; the newer phrasing folds in.
        let (winner, loser) = taskA.createdAt <= taskB.createdAt ? (taskA, taskB) : (taskB, taskA)
        // The permanent carve-out: a judgment call or open decision is never
        // resolved by anything but the human — and killing IS resolving.
        guard !loser.isJudgmentCall, !loser.needsDecision else { return false }
        merge(winner: winner, loser: loser, in: context, now: now)
        return true
    }

    /// The merge itself. One reversible `"mergedPair"` entry carries everything the
    /// undo arm needs: the loser's id (reopen restores identity, timeline, and
    /// edges — the row never died) and the EXACT note line absorbed into the
    /// winner. Deliberately no `touchHuman` — a sweep is not engagement.
    static func merge(
        winner: TaskItem, loser: TaskItem, in context: NSManagedObjectContext,
        now: Date = Date()
    ) {
        let noteLine = "Also captured: \(loser.title)"
        winner.notes = winner.notes.map { $0 + "\n" + noteLine } ?? noteLine
        loser.kill(now: now)
        context.insert(
            ChangeLogEntry(
                summary: "Merged “\(loser.title)” into “\(winner.title)” — they read as the same task",
                detail: "Undo brings it back and keeps them separate.",
                action: "mergedPair",
                oldValue: MergedPairPayload(loserID: loser.uuid, noteLine: noteLine).encoded,
                initiatedBy: .ai,
                isReversible: true,
                taskTitle: winner.title,
                taskUUID: winner.uuid,
                timestamp: now, in: context
            ))
        AttentionEngine.recompute([winner], among: TaskItem.fetchAll(in: context))
    }
}

/// The `"mergedPair"` entry's payload — everything its undo must restore beyond
/// what reopening the loser already brings back.
struct MergedPairPayload: Codable {
    var loserID: UUID?
    var noteLine: String

    var encoded: String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ raw: String?) -> MergedPairPayload? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MergedPairPayload.self, from: data)
    }
}
