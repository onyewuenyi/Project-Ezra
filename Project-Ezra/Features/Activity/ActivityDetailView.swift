//
//  ActivityDetailView.swift
//  Project-Ezra
//
//  What the system did, for one Activity row. Pushed from `ActivityView`.
//
//  This is a DEVELOPER surface living on a product screen, and the tension is deliberate:
//  the rest of the app is built so the user never hears "AI", never sees a vendor name and
//  never watches a latency number, while the one question this screen exists to answer is
//  "which model, on which rung, at what cost, and what did it decide". It is reachable only
//  by tapping a row — nothing here is rendered in the feed itself beyond a one-line byline —
//  so the surface stays honest for someone who came looking and invisible to someone who
//  didn't.
//
//  **One screen, conditional sections, so every row type lands somewhere.** The entry's own
//  fields always render. A capture is then resolved — directly for a `captured` row, or via
//  `taskUUID → TaskItem.captureID` for a row about a task — and the run sections appear only
//  when `CaptureProvenanceStore` actually holds that capture's receipt.
//
//  **A missing receipt prints "not recorded" and stops.** Provenance records forward only:
//  every capture committed before this shipped has no run, and reconstructing a
//  plausible-looking one out of whatever the store happens to hold would be a fabricated
//  measurement — the same failure `-RambleEval`'s DEGRADED banner exists to catch, which is
//  precisely the failure this screen is supposed to expose.
//

import CoreData
import SwiftUI

struct ActivityDetailView: View {
    let entry: ChangeLogEntry

    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: []) private var membersResults: FetchedResults<FamilyMember>
    @FetchRequest(sortDescriptors: []) private var profilesResults: FetchedResults<UserProfile>

    @State private var expanded: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header
                eventSection
                if let provenance {
                    runSection(provenance)
                    costSection(provenance)
                    inputSection(provenance)
                    draftsSection(provenance)
                    resultSection(provenance)
                } else {
                    notRecordedSection
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.background)
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Resolution

    /// The capture behind this row, if any.
    ///
    /// Two paths because the change log has two shapes of entry: a `captured` row IS the
    /// capture (its uuid rides `oldValue`, the `"prunedCapture"` convention), while every
    /// other row is about a task, which knows its origin through `TaskItem.captureID`.
    private var provenance: CaptureProvenance? {
        if entry.action == ChangeLogEntry.capturedAction,
            let raw = entry.oldValue, let id = UUID(uuidString: raw)
        {
            return CaptureProvenanceStore.shared.provenance(forCapture: id)
        }
        guard let taskUUID = entry.taskUUID,
            let captureID = task(taskUUID)?.captureID
        else { return nil }
        return CaptureProvenanceStore.shared.provenance(forCapture: captureID)
    }

    private func task(_ uuid: UUID) -> TaskItem? {
        let request = NSFetchRequest<TaskItem>(entityName: "TaskItem")
        request.predicate = NSPredicate(format: "uuid == %@", uuid as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private func title(ofTask uuid: UUID) -> String { task(uuid)?.title ?? "(deleted)" }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            ActorAvatar(
                entry: entry, members: Array(membersResults),
                currentUserID: profilesResults.first?.linkedMemberID,
                profile: profilesResults.first, size: 40)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(entry.summary)
                    .font(.bodyInput)
                    .foregroundStyle(Palette.primaryText)
                Text(entry.timestamp.formatted(.dateTime.weekday().month().day().hour().minute()))
                    .metadataStyle()
            }
        }
    }

    // MARK: - Sections

    private var eventSection: some View {
        section("Event") {
            row("Action", entry.action ?? "—")
            row("Initiated by", entry.initiatedBy == .ai ? "Ezra" : "Human")
            row("Reversible", entry.isReversible ? "yes" : "no")
            if entry.undone { row("Undone", "yes") }
            if let detail = entry.detail { row("Detail", detail) }
            if let field = entry.fieldChanged { row("Field", field) }
            // `oldValue` carries the capture id on a `captured` row rather than a prior
            // value; showing it as "Old" there would be a small lie about the schema.
            if entry.action != ChangeLogEntry.capturedAction {
                if let old = entry.oldValue { row("Old", old) }
                if let new = entry.newValue { row("New", new) }
            }
            if let title = entry.taskTitle { row("Task", title) }
        }
    }

    private var notRecordedSection: some View {
        section("Run") {
            Text("Not recorded.")
                .font(.supporting)
                .foregroundStyle(Palette.primaryText)
            Text(
                "Provenance records forward only. This capture was committed before run tracking shipped, and the facts — which rung answered, what it cost, what it proposed — are not recoverable. Nothing is inferred here on purpose."
            )
            .font(.metadata)
            .foregroundStyle(Palette.mutedText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runSection(_ p: CaptureProvenance) -> some View {
        section("Run") {
            row("Route", p.run.route)
            row("Rung", p.run.rung)
            row("Outcome", p.run.outcome)
            row("Segmentation", p.run.segmentation.isEmpty ? "—" : p.run.segmentation)
            // Nil is the common, correct case: short captures run reasoning-free because
            // the front door is the most latency-sensitive surface in the product.
            row("Reasoning depth", p.run.reasoningDepth ?? "none")
            row("Engine", p.run.engineName ?? "deterministic (no model)")
            if let identifier = p.run.modelIdentifier { row("Model family", identifier) }
            if let version = p.run.modelVersion { row("Model version", version) }
            row("Cloud reachable", p.run.cloudAvailable ? "yes" : "no")
            // Only meaningful when a hedge was possible at all; "no" on a route that could
            // never hedge would read as a result rather than an absence.
            if p.run.hedgeStarted || p.run.armWon == "hedge" {
                row("Hedge", p.run.hedgeStarted ? "started" : "not started")
            }
            if let arm = p.run.armWon { row("Winning arm", arm) }
        }
    }

    private func costSection(_ p: CaptureProvenance) -> some View {
        section("Cost") {
            row("Provisional read", ms(p.provisionalMs))
            row("Parse", ms(p.run.parseMs))
            row("Retrieval", ms(p.run.retrievalMs))
            row("First partial", ms(p.run.firstPartialMs))
            row("Partials applied", "\(p.run.partialCount)")
            row("Commit", ms(p.commitMs))
            // Token accounting is on-device only by design: the local tokenizer describes
            // the wrong model for a cloud parse, and a confident number about the wrong
            // model is worse than none. It also lands from a detached task, so a fast
            // commit legitimately records nothing yet.
            row("Prompt tokens", p.promptTokens.map { "\($0)" } ?? "pending / on-device only")
            row("Context size", p.contextSize.map { "\($0)" } ?? "—")
        }
    }

    private func inputSection(_ p: CaptureProvenance) -> some View {
        section("Input") {
            Text(p.rawText)
                .font(.supporting)
                .foregroundStyle(Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(Palette.secondarySurface))
            row("Captured", p.capturedAt.formatted(.dateTime.hour().minute().second()))
            row("Committed", p.committedAt.formatted(.dateTime.hour().minute().second()))
            // The candidate package is the ONLY set of ids the model was allowed to cite
            // for a duplicate or child proposal — so an empty list here is the explanation
            // for a capture that proposed no edges.
            row("Candidates shown", "\(p.run.candidateTitles.count)")
            ForEach(Array(p.run.candidateTitles.enumerated()), id: \.offset) { _, candidate in
                Text("· \(candidate)")
                    .font(.metadata)
                    .foregroundStyle(Palette.mutedText)
            }
            row("Ungrounded drops", "\(p.run.ungroundedDrops)")
        }
    }

    private func draftsSection(_ p: CaptureProvenance) -> some View {
        section("\(p.drafts.count) task\(p.drafts.count == 1 ? "" : "s")") {
            ForEach(p.drafts) { draft in
                draftBlock(draft)
            }
        }
    }

    @ViewBuilder private func draftBlock(_ draft: TaskDraft) -> some View {
        let isOpen = expanded.contains(draft.id)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button {
                Motion.withMotion(Motion.snap) {
                    if isOpen { expanded.remove(draft.id) } else { expanded.insert(draft.id) }
                }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.chipLabel)
                        .foregroundStyle(Palette.mutedText)
                    Text(draft.title)
                        .font(.supporting)
                        .foregroundStyle(Palette.primaryText)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    row("Category", draft.category)
                    row("Confidence", String(format: "%.2f", draft.confidence))
                    row("Autonomy", draft.autonomy.rawValue)
                    row("Judgment call", draft.isJudgmentCall ? "yes" : "no")
                    // Axis 2 is system-owned and never rendered as product UI; this is the
                    // diagnostics level, which is exactly where it may be inspected.
                    row("Work intent", draft.workIntent?.rawValue ?? "—")
                    if !draft.reasoning.isEmpty { row("Reasoning", draft.reasoning) }
                    // A `dueReason` is the marker that the DATE WAS INFERRED — nil means
                    // the user spoke it, which is not an inference and must not read as one.
                    if let due = draft.dueDate {
                        row("Due", due.formatted(.dateTime.month().day()))
                        row("Due basis", draft.dueReason ?? "spoken by the user")
                    }
                    row("Owner", draft.ownerName ?? "self")
                    row("Owner basis", draft.ownerBasis.rawValue)
                    if let reason = draft.ownerReason { row("Owner reason", reason) }
                    row("Urgent", draft.isUrgent ? "yes" : "no")
                    if let importance = draft.aiImportance {
                        row("AI importance", String(format: "%.2f", importance))
                    }
                    if let effort = draft.effortMinutes { row("Effort", "\(effort)m") }
                    if let blocker = draft.blockedBy { row("Blocked by", blocker) }
                    if !draft.blocks.isEmpty {
                        row("Blocks", draft.blocks.map(\.title).joined(separator: ", "))
                    }
                    ForEach(draft.edgeProposals, id: \.self) { proposal in
                        row(
                            "Proposed \(proposal.kind.rawValue)",
                            "\(proposal.targetTitle) · \(String(format: "%.2f", proposal.confidence)) · \(proposal.decision.rawValue)"
                        )
                    }
                    // The clause the instant deterministic read cut this card from — the
                    // lineage a model retitle was matched against.
                    if let source = draft.provisionalSource { row("Source clause", source) }
                    editsBlock(draft)
                }
                .padding(.leading, Spacing.md)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }

    /// What the human changed at confirm, diffed against the frozen AI snapshot — the same
    /// comparison that writes the `Correction` rows.
    @ViewBuilder private func editsBlock(_ draft: TaskDraft) -> some View {
        let corrections = draft.corrections
        if corrections.isEmpty {
            row("User edits", "none")
        } else {
            ForEach(Array(corrections.enumerated()), id: \.offset) { _, correction in
                row("Edited \(correction.field)", "\(correction.aiValue) → \(correction.userValue)")
            }
        }
    }

    private func resultSection(_ p: CaptureProvenance) -> some View {
        section("Result") {
            row("Created", "\(p.createdTaskIDs.count)")
            ForEach(p.createdTaskIDs, id: \.self) { id in
                Text("· \(title(ofTask: id))")
                    .font(.metadata)
                    .foregroundStyle(Palette.mutedText)
            }
            // A merged draft creates no task — it folds into an existing one — so the two
            // counts together are what explain "N drafts became M tasks".
            if !p.mergedTaskIDs.isEmpty {
                row("Merged into", "\(p.mergedTaskIDs.count)")
                ForEach(p.mergedTaskIDs, id: \.self) { id in
                    Text("· \(title(ofTask: id))")
                        .font(.metadata)
                        .foregroundStyle(Palette.mutedText)
                }
            }
        }
    }

    // MARK: - Primitives

    @ViewBuilder private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .metadataStyle()
                .textCase(.uppercase)
                .tracking(0.6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(.metadata)
                .foregroundStyle(Palette.mutedText)
                .frame(width: LayoutMetrics.diagnosticLabelColumn, alignment: .leading)
            Text(value)
                .font(.metadata)
                .monospacedDigit()
                .foregroundStyle(Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// A millisecond field, keeping "not measured" (`nil`) distinct from "measured as
    /// zero" — `ModelMetrics`' `-1` sentinels are bridged before they reach here.
    private func ms(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value >= 1000 ? String(format: "%.1fs", Double(value) / 1000) : "\(value)ms"
    }
}
