//
//  Telemetry.swift
//  Project-Ezra
//
//  Product telemetry — the ONE seam through which anything about how the app is used may
//  leave the device, and the boundary that decides what "anything" can be.
//
//  **User data is local-first. Product telemetry is not.** (2026-09-12.) Until this file
//  existed the two were one rule — "metrics are local-only, never transmitted" — which was
//  the right rule for a product nobody but its author was running, and the wrong rule for
//  one whose whole launch plan turns on questions this device cannot answer alone: did the
//  second caretaker ever install; how many minutes from install to the first accepted
//  capture; did the Advisor's advice make anything move. Those are questions about the
//  PRODUCT, and the data that answers them is not the person's data. The boundary this
//  file draws is the one OpenAI's and Anthropic's privacy policies draw between "usage
//  data" and "content": which features were used, when, and whether they worked may be
//  observed; what the person said, who is in their household, and what the model told
//  them never leave through this door. (`CaptureRoute.transmitsRawCapture` is the ONE
//  sanctioned raw-text transmission, and it is not this one.)
//
//  **The allowlist is a TYPE, not a review.** Every event is a case of `TelemetryEvent`,
//  and every associated value is an enumeration or a bucket — there is no `String`
//  parameter anywhere in the enum, and `TelemetryAllowlistTests` greps the source to keep
//  it that way. A task title cannot be logged because there is no parameter it could go
//  into. That is a stronger property than "redact PII before sending": redaction is a
//  filter someone has to remember to route through, and a filter over free text is only
//  as good as its regexes. This is the candidate-blind prompt's lesson pointed the other
//  way — a capability that exists only if a caller remembers to thread it fails silently;
//  a boundary that exists only if a caller remembers to redact leaks silently.
//
//  **Counts and durations are BUCKETED** (`CountBucket`, `DurationBucket`) rather than sent
//  raw. A raw count is a fingerprint in a small cohort ("the household with 47 tasks"); a
//  bucket answers the product question ("did the first capture land in under five
//  minutes") with nothing left over.
//
//  **The domain never knows the vendor exists.** `Telemetry.log` writes to a
//  `TelemetrySink`; `StatsigSink` (`AI/StatsigSink.swift`) is the only file that imports
//  the vendor, and the allowlist test pins that. Swapping vendors — or going back to
//  nothing — is one conformance and one line in `AppDelegate`.
//
//  **Opt-out, and the sink respects it before the vendor does.** `Telemetry.isEnabled`
//  is a persisted preference the person flips in Settings, under the same card that says
//  what leaves the device. A disabled sink logs nothing — the check is here, in front of
//  the vendor, not delegated to a vendor option that might default differently in a
//  future SDK.
//
//  **Feature gates are KILL SWITCHES, never floors.** `TelemetryGate` names the handful
//  of remotely-switchable things (Ramble economics rule 5: a pillar's cloud arm may be
//  switched off; a floor, a threshold or a routing invariant may not). Each gate is a
//  kill switch with a safe default, so a vendor outage, an unconfigured key or a test host
//  all read as "not killed".
//

import CryptoKit
import Foundation

// MARK: - Buckets

/// A count with its identifying precision removed.
enum CountBucket: String, CaseIterable, Sendable {
    case zero, one, twoToThree = "2-3", fourToSix = "4-6", sevenToTwelve = "7-12", thirteenPlus = "13+"

    init(_ count: Int) {
        switch count {
        case ...0: self = .zero
        case 1: self = .one
        case 2...3: self = .twoToThree
        case 4...6: self = .fourToSix
        case 7...12: self = .sevenToTwelve
        default: self = .thirteenPlus
        }
    }
}

/// A duration as the product reads it — the buckets are the launch plan's targets
/// (install → first accepted capture under five minutes; a model call under a second).
enum DurationBucket: String, CaseIterable, Sendable {
    case underOneSecond = "<1s", oneToTwoSeconds = "1-2s", twoToFiveSeconds = "2-5s"
    case fiveToFifteenSeconds = "5-15s", fifteenToSixtySeconds = "15-60s"
    case oneToFiveMinutes = "1-5m", fiveToThirtyMinutes = "5-30m", overThirtyMinutes = "30m+"

    init(seconds: TimeInterval) {
        switch seconds {
        case ..<1: self = .underOneSecond
        case ..<2: self = .oneToTwoSeconds
        case ..<5: self = .twoToFiveSeconds
        case ..<15: self = .fiveToFifteenSeconds
        case ..<60: self = .fifteenToSixtySeconds
        case ..<300: self = .oneToFiveMinutes
        case ..<1800: self = .fiveToThirtyMinutes
        default: self = .overThirtyMinutes
        }
    }
}

/// An age in whole days — Linear's lead and cycle times, for a family (2026-10-04). A
/// timestamp is a fingerprint; "done within the week it was captured" is the product
/// question, and the bucket answers it with nothing left over.
enum AgeBucket: String, CaseIterable, Sendable {
    case underOneDay = "<1d", oneToTwoDays = "1-2d", threeToSevenDays = "3-7d"
    case oneToTwoWeeks = "1-2w", twoToFourWeeks = "2-4w", overFourWeeks = "4w+"

    init(seconds: TimeInterval) {
        switch seconds / 86_400 {
        case ..<1: self = .underOneDay
        case ..<3: self = .oneToTwoDays
        case ..<8: self = .threeToSevenDays
        case ..<15: self = .oneToTwoWeeks
        case ..<29: self = .twoToFourWeeks
        default: self = .overFourWeeks
        }
    }
}

/// A fraction with its precision removed — the group snapshot's shares (stale, hand-off,
/// participation, load). The edges are the launch plan's: "the busiest member does 90%+ of
/// the completing" is the mental-load question, and it needs no more precision than that.
enum ShareBucket: String, CaseIterable, Sendable {
    case zero = "0", underQuarter = "<25", quarterToHalf = "25-50", halfToSeventy = "50-70"
    case seventyToNinety = "70-90", ninetyPlus = "90+"

    init(_ fraction: Double) {
        switch fraction {
        case ...0: self = .zero
        case ..<0.25: self = .underQuarter
        case ..<0.5: self = .quarterToHalf
        case ..<0.7: self = .halfToSeventy
        case ..<0.9: self = .seventyToNinety
        default: self = .ninetyPlus
        }
    }
}

/// How many adults plan in a group. A solo parent is a group of one, never "not counted".
enum GroupSizeBucket: String, CaseIterable, Sendable {
    case one = "1", two = "2", threePlus = "3+"

    init(_ adults: Int) {
        switch adults {
        case ...1: self = .one
        case 2: self = .two
        default: self = .threePlus
        }
    }
}

// MARK: - Events

/// How a capture arrived. Mirrors `CaptureSource` without depending on Core Data.
enum TelemetryCaptureChannel: String, CaseIterable, Sendable {
    case voice, typed, photo, siri, onboarding
}

/// Where an invite flow failed, if it did — the funnel the plan says to instrument
/// from "invite sent" to "first action".
enum TelemetryInviteStage: String, CaseIterable, Sendable {
    case linkCreated = "link_created", linkFailed = "link_failed"
    case accepted, acceptFailed = "accept_failed", identityLinked = "identity_linked"
}

/// Which chat a question was typed into. Ask is the home since 2026-09-23, so "Ask
/// opened" would fire on every launch and say nothing; a QUESTION is the signal.
enum TelemetryAskScope: String, CaseIterable, Sendable {
    case household, task
}

/// Which rung answered a question: the deterministic floor (instant, with rows) or the
/// on-device model. The pair is what decides whether the home earns its place — a home
/// people ask on, against one they only pass through on the way to the list.
enum TelemetryAskRoute: String, CaseIterable, Sendable {
    case floor, model
}

/// What a person did with a line the home offered back as a to-do (2026-09-23).
enum TelemetryCaptureOfferOutcome: String, CaseIterable, Sendable {
    case added, askedAnyway = "asked_anyway"
}

/// Which count on the home's glance strip opened the list (2026-09-23) — the strip
/// deep-links into the Tasks sheet filtered, so the kind is the whole payload.
enum TelemetryGlanceKind: String, CaseIterable, Sendable {
    case overdue, dueToday = "due_today", inProgress = "in_progress", waiting, decisions
    case member, done
}

/// The verb a person tapped on a home row (2026-09-23): the recommended action, run
/// from the answer instead of the swipe. "Decide" opens the page rather than acting.
enum TelemetryRowVerb: String, CaseIterable, Sendable {
    case start, resume, markDone = "mark_done", unblock, claim, decide
}

/// Why a weekly digest did NOT go out. Silence is a decision and gets a reason.
enum TelemetryDigestSkip: String, CaseIterable, Sendable {
    case nothingToSay = "nothing_to_say", optedOut = "opted_out", noPermission = "no_permission"
    case killed
}

/// The closed vocabulary of things the product may say about itself.
///
/// Every associated value is an enum or a bucket. **Never add a `String`, `Int`, `Date`,
/// `UUID` or `Double` parameter** — a raw value is either a fingerprint or free text, and
/// both are the person's, not the product's. Add a bucket or an enum instead.
enum TelemetryEvent: Sendable {
    /// The composer opened into a channel.
    case captureStarted(channel: TelemetryCaptureChannel)
    /// The router decided where the words go, and why.
    case captureRouted(route: CaptureRoute, reason: CaptureEscalationReason?)
    /// Confirm — the single publish boundary — fired.
    /// `triage` is words-to-confirmed (the capture's arrival to the Confirm tap) — Linear's
    /// triage time, for a family. Nil when the capture has no arrival stamp.
    case captureCommitted(created: CountBucket, merged: CountBucket, corrected: Bool, triage: DurationBucket?)
    /// Install → first committed capture. Fires once per install.
    case firstPayoff(elapsed: DurationBucket)
    /// A task reached `.done`. `lead` is capture → done and `cycle` is first start → done
    /// (Linear's two times); `cycle` is nil for a task that was never started.
    case taskCompleted(lead: AgeBucket, cycle: AgeBucket?)
    /// A person typed or tapped a question into a chat, and which rung answered it.
    case askAsked(scope: TelemetryAskScope, route: TelemetryAskRoute)
    /// The Tasks list was opened from the Ask home — the swap's other half, so the two
    /// verbs can be compared per session.
    case tasksOpened
    /// A glance-strip count opened the list, filtered (2026-09-23).
    case glanceOpened(kind: TelemetryGlanceKind)
    /// How long the Tasks sheet stayed up before Done or a swipe — the modal-depth
    /// meter: a sheet that is open for minutes at a time is a home in exile.
    case tasksSheetDwell(elapsed: DurationBucket)
    /// A row on the home performed its verb in place (2026-09-23).
    case homeRowActed(verb: TelemetryRowVerb)
    /// The Today return, tapped on a thread (2026-09-25): how often the home is come
    /// back to after a question, against how often it is left behind.
    case homeReturned
    /// A capture landed during this look and rank did not seat it in the answer's rows
    /// (2026-09-25): how many sit under "Just added".
    case captureLandedBelow(count: CountBucket)
    /// The home seated a "since you last looked" line, and how much it had to say —
    /// whether the shared half of the home ever fires, without a word of what it said.
    case catchUpSeated(changes: CountBucket)
    /// The home held a to-do-shaped line back from the model and the person chose a door.
    case captureOffer(outcome: TelemetryCaptureOfferOutcome)
    /// The on-device judge read this capture (`CaptureJudge`, 2026-10-04): how many
    /// pieces it set aside as nothing to do, and how many of those the person added
    /// back at Confirm — the false-drop meter, observed without asking.
    case captureJudged(leftOut: CountBucket, restored: CountBucket)
    /// The Advisor spoke, and what happened next.
    case advisorOffered(move: AdvisorMove)
    case advisorActed(move: AdvisorMove)
    case advisorDismissed(move: AdvisorMove)
    /// A model call, at the seam every call goes through.
    case modelCall(feature: ModelFeature, served: Bool, latency: DurationBucket)
    /// The second-caretaker funnel.
    case invite(stage: TelemetryInviteStage)
    /// Both caretakers acted within the window — the activation metric, observed on device.
    case householdActivated
    /// The Sunday digest.
    case digestScheduled
    case digestSkipped(reason: TelemetryDigestSkip)
    case digestOpened
    /// The weekly group snapshot (2026-10-04): the shape of the group's open work and how
    /// the doing is spread across its adults. Participation and load are nil for a group of
    /// one, where they would always read 100%. Every phone in a group sends its own, so
    /// the dashboard keeps one per group per week (`GroupMetrics`).
    case groupSnapshot(
        open: CountBucket, stale: ShareBucket?, handOff: ShareBucket?, participation: ShareBucket?,
        load: ShareBucket?)

    /// The wire name: snake_case, stable, never user-facing.
    var name: String {
        switch self {
        case .captureStarted: return "capture_started"
        case .captureRouted: return "capture_routed"
        case .captureCommitted: return "capture_committed"
        case .firstPayoff: return "first_payoff"
        case .taskCompleted: return "task_completed"
        case .askAsked: return "ask_asked"
        case .tasksOpened: return "tasks_opened"
        case .glanceOpened: return "glance_opened"
        case .tasksSheetDwell: return "tasks_sheet_dwell"
        case .homeRowActed: return "home_row_acted"
        case .homeReturned: return "home_returned"
        case .captureLandedBelow: return "capture_landed_below"
        case .catchUpSeated: return "catch_up_seated"
        case .captureOffer: return "capture_offer"
        case .captureJudged: return "capture_judged"
        case .advisorOffered: return "advisor_offered"
        case .advisorActed: return "advisor_acted"
        case .advisorDismissed: return "advisor_dismissed"
        case .modelCall: return "model_call"
        case .invite: return "invite"
        case .householdActivated: return "household_activated"
        case .digestScheduled: return "digest_scheduled"
        case .digestSkipped: return "digest_skipped"
        case .digestOpened: return "digest_opened"
        case .groupSnapshot: return "group_snapshot"
        }
    }

    /// The wire payload. Every value is a raw value of a closed type.
    var metadata: [String: String] {
        switch self {
        case .captureStarted(let channel):
            return ["channel": channel.rawValue]
        case .captureRouted(let route, let reason):
            var fields = ["route": route.metricName]
            if let reason { fields["reason"] = reason.rawValue }
            return fields
        case .captureCommitted(let created, let merged, let corrected, let triage):
            var fields = [
                "created": created.rawValue, "merged": merged.rawValue, "corrected": corrected ? "yes" : "no",
            ]
            if let triage { fields["triage"] = triage.rawValue }
            return fields
        case .firstPayoff(let elapsed):
            return ["elapsed": elapsed.rawValue]
        case .tasksOpened, .homeReturned, .householdActivated, .digestScheduled, .digestOpened:
            return [:]
        case .taskCompleted(let lead, let cycle):
            var fields = ["lead": lead.rawValue]
            if let cycle { fields["cycle"] = cycle.rawValue }
            return fields
        case .groupSnapshot(let open, let stale, let handOff, let participation, let load):
            var fields = ["open": open.rawValue]
            if let stale { fields["stale"] = stale.rawValue }
            if let handOff { fields["hand_off"] = handOff.rawValue }
            if let participation { fields["participation"] = participation.rawValue }
            if let load { fields["load"] = load.rawValue }
            return fields
        case .askAsked(let scope, let route):
            return ["scope": scope.rawValue, "route": route.rawValue]
        case .catchUpSeated(let changes):
            return ["changes": changes.rawValue]
        case .captureLandedBelow(let count):
            return ["count": count.rawValue]
        case .glanceOpened(let kind):
            return ["kind": kind.rawValue]
        case .tasksSheetDwell(let elapsed):
            return ["elapsed": elapsed.rawValue]
        case .homeRowActed(let verb):
            return ["verb": verb.rawValue]
        case .captureOffer(let outcome):
            return ["outcome": outcome.rawValue]
        case .captureJudged(let leftOut, let restored):
            return ["left_out": leftOut.rawValue, "restored": restored.rawValue]
        case .advisorOffered(let move), .advisorActed(let move), .advisorDismissed(let move):
            return ["move": move.rawValue]
        case .modelCall(let feature, let served, let latency):
            return [
                "feature": feature.rawValue, "served": served ? "yes" : "no", "latency": latency.rawValue,
            ]
        case .invite(let stage):
            return ["stage": stage.rawValue]
        case .digestSkipped(let reason):
            return ["reason": reason.rawValue]
        }
    }

    /// One of every case, for the allowlist test and the DEBUG readout. Kept beside the
    /// enum so a new case cannot be added without being enumerated here — the switch
    /// above is exhaustive, and this list is what the test walks.
    static var exemplars: [TelemetryEvent] {
        [
            .captureStarted(channel: .voice),
            .captureRouted(route: .cloud, reason: .bigDump),
            .captureRouted(route: .local, reason: nil),
            .captureCommitted(
                created: .twoToThree, merged: .zero, corrected: true, triage: .fifteenToSixtySeconds),
            .captureCommitted(created: .one, merged: .zero, corrected: false, triage: nil),
            .firstPayoff(elapsed: .oneToFiveMinutes),
            .taskCompleted(lead: .threeToSevenDays, cycle: .underOneDay),
            .taskCompleted(lead: .overFourWeeks, cycle: nil),
            .askAsked(scope: .household, route: .floor),
            .askAsked(scope: .task, route: .model),
            .tasksOpened,
            .glanceOpened(kind: .overdue),
            .tasksSheetDwell(elapsed: .fiveToFifteenSeconds),
            .homeRowActed(verb: .start),
            .homeReturned,
            .captureLandedBelow(count: .one),
            .catchUpSeated(changes: .one),
            .captureOffer(outcome: .added),
            .captureJudged(leftOut: .twoToThree, restored: .one),
            .advisorOffered(move: .advise),
            .advisorActed(move: .createSteps),
            .advisorDismissed(move: .decide),
            .modelCall(feature: .captureTriage, served: true, latency: .oneToTwoSeconds),
            .invite(stage: .linkCreated),
            .householdActivated,
            .digestScheduled,
            .digestSkipped(reason: .nothingToSay),
            .digestOpened,
            .groupSnapshot(
                open: .sevenToTwelve, stale: .quarterToHalf, handOff: .underQuarter,
                participation: .halfToSeventy, load: .ninetyPlus),
            .groupSnapshot(open: .zero, stale: nil, handOff: nil, participation: nil, load: nil),
        ]
    }
}

// MARK: - Gates (kill switches)

/// The remotely-switchable things. Each is a KILL switch: the vendor answering `true`
/// turns the thing OFF, and every other state — no sink, no key, no network, a test
/// host — reads as not killed. A gate that could turn a floor or a threshold would be a
/// routing invariant living in a dashboard, which rule 5 forbids.
enum TelemetryGate: String, CaseIterable, Sendable {
    /// Ramble's cloud arm. Killed → every capture takes the deterministic read.
    case killCloudCapture = "kill_cloud_capture"
    /// The Advisor's cloud rung. Killed → deep judgments degrade to on-device.
    case killCloudAdvisor = "kill_cloud_advisor"
    /// The Sunday digest. Killed → nothing is scheduled, even for people opted in.
    case killWeeklyDigest = "kill_weekly_digest"
}

// MARK: - Sink

/// Where events go. One conformance per vendor, and the vendor is the only thing the
/// conformance knows about. `nil` from `isKilled` means "no opinion" — the caller's safe
/// default applies.
protocol TelemetrySink: AnyObject {
    func log(name: String, metadata: [String: String])
    func isKilled(_ gate: String) -> Bool?
    /// Which group later events belong to. Part of WHO is reporting, beside the install
    /// id — never an event payload, so the allowlist above is unchanged.
    func identify(group: TelemetryGroup)
}

/// The group an install reports as (2026-10-04): one household of 1 or N, the unit the
/// launch plan counts. **The household's own id never leaves** — `id` is a salted SHA-256
/// of it, cut to 32 hex characters, so every phone in a shared household reports the same
/// value (the household's id arrives with the iCloud share) and nothing on the wire can be
/// matched against a CloudKit record. The salt is in this public file: it separates this
/// value from the raw id, it is not a secret. `size` is a bucket, never a roster count.
struct TelemetryGroup: Equatable, Sendable {
    let id: String
    let size: GroupSizeBucket

    static let salt = "ezra.telemetry.group.v1:"

    init(householdID: UUID, adults: Int) {
        let digest = SHA256.hash(data: Data((Self.salt + householdID.uuidString).utf8))
        id = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        size = GroupSizeBucket(adults)
    }
}

/// The DEBUG-visible sink: remembers the last few events so the diagnostics card can
/// show that the boundary is being exercised without anyone opening a dashboard.
final class RecordingTelemetrySink: TelemetrySink {
    private(set) var events: [(name: String, metadata: [String: String])] = []
    private(set) var killed: Set<String>
    private(set) var group: TelemetryGroup?
    static let keep = 50

    init(killed: Set<String> = []) { self.killed = killed }

    func log(name: String, metadata: [String: String]) {
        events.append((name, metadata))
        if events.count > Self.keep { events.removeFirst(events.count - Self.keep) }
    }

    func isKilled(_ gate: String) -> Bool? { killed.contains(gate) }

    func identify(group: TelemetryGroup) { self.group = group }
}

// MARK: - The seam

enum Telemetry {
    /// The active sink. Installed once from `AppDelegate`; nil (nothing leaves) under
    /// the unit-test host, with no key, or when the person opted out. Tests inject a
    /// `RecordingTelemetrySink` here.
    static var sink: TelemetrySink?

    /// The one-way install id telemetry is keyed on: a UUID minted on first use, stored
    /// in UserDefaults, never derived from the person's name, email or iCloud identity.
    /// Reset with the store (`DataReset`) so a wiped install is a new one.
    static let installIDKey = "telemetry.installID"
    /// The opt-out preference. Default ON — telemetry is part of the research-preview
    /// contract the landing page states ("free, changes weekly, we see which features are
    /// used"), and the Settings card names exactly what that means and offers the switch.
    static let enabledKey = "telemetry.enabled"

    static func installID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: installIDKey) { return existing }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: installIDKey)
        return minted
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    /// Log one event. The opt-out is checked HERE, in front of the vendor.
    static func log(_ event: TelemetryEvent, defaults: UserDefaults = .standard) {
        guard let sink, isEnabled(defaults: defaults) else { return }
        sink.log(name: event.name, metadata: event.metadata)
    }

    /// Tell the sink which group this install reports as. Behind the same opt-out as `log`.
    static func identify(_ group: TelemetryGroup, defaults: UserDefaults = .standard) {
        guard let sink, isEnabled(defaults: defaults) else { return }
        sink.identify(group: group)
    }

    /// Whether a kill switch is engaged. Unknown, absent or opted-out all read `false`:
    /// a kill switch that fails open is a feature flag, and this is not one.
    static func isKilled(_ gate: TelemetryGate, defaults: UserDefaults = .standard) -> Bool {
        guard let sink, isEnabled(defaults: defaults) else { return false }
        return sink.isKilled(gate.rawValue) ?? false
    }

    /// The sentence the data-boundary card adds when telemetry is live. Names no vendor,
    /// and names what is NOT sent before what is — the reader's question is the first half.
    static let boundarySentence =
        "Ezra never sends your tasks, your words, or anyone's name. It may send anonymous "
        + "product signals — which features were used and whether they worked, grouped by a "
        + "scrambled household code so a family counts once — so the research preview can "
        + "improve. You can turn that off below."
}
