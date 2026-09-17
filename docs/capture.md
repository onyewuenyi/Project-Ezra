# Ramble — the capture arc, in full

Extracted verbatim from `CLAUDE.md` on 2026-09-02, when that file crossed its size
limit. **CLAUDE.md keeps the invariants; this file keeps the reasoning, the device
measurements and the archaeology behind them** — the deleted confidence gate, the
two routing reversals, the inert duplicate detection, the orb's tuning traps, the
eval-instrument lessons. Read it before changing capture behaviour, and keep the
two in sync: a rule that changes here changes there.

- **Ramble is voice-first: the sheet opens INTO listening** (2026-08-27; `ComposerView.RamblePhase`: `.listening → .understanding → .confirm` (Create then dismisses; the `.created(n)` receipt phase was removed 2026-08-30), with `.capture` — the typed canvas — as the escape hatch reached only deliberately: "Type instead", the mic-denied/unavailable fallthrough, resumed captures, or an empty finish). **The governing invariant, written into ComposerView's and RambleOrb's headers: the orb never asks the user to understand the system; it only reflects that the system is present and receiving them — the reveal is where the system proves understanding.** While listening the orb shows RECEPTION (the mic level as presence) and never interpretation: **no live transcript** — a deliberate reversal of the two-tone listening transcript (the transcript still mirrors invisibly into `text`, so park/Close/resume always carry the words, and a capture dismissed mid-listening resumes VISIBLY in `.capture` — the invisible transcript is always seen before it is ever interpreted). **Silence auto-submits, and the arming rule is the honesty of it**: the 5s window arms ONLY on transcript deltas (`shouldArmSilence`, test-pinned — the system never finishes an EMPTY capture; an open mic over silence just stays present), because once words exist silence is the user's likely completion signal — a DELIBERATE fixed 5s, deterministic over adaptive. Tapping the orb finishes NOW (tappable but never button-shaped: no chrome, no press style, no "tap to finish" copy — VoiceOver users are told because for them it IS the primary control); an empty finish settles to the canvas, never a "Nothing actionable" reveal (`finishAction` — that reveal answers a question about words, and there were none). The countdown's visible last-2s line is muted microcopy; the PRIMARY finishing signal is the orb itself calming as the level envelope drains. A spoken `.local` capture earns the thinking beat via `submit(fromVoice:)` — **a parameter, never derived from the session-sticky `usedDictation`** (dictate → Type instead → edit → Ramble must not buy a typed submit the beat); typed `.local` still reveals instantly. **One lifecycle rule absorbs every failure**: while listening, any non-user drop of speech activity (interruption, denial, engine failure, the sim's missing transcriber) settles to `.capture` with the words so far — and backgrounding mid-listening NEVER submits (a suspended silence task must not fire a model call the user didn't witness). The initial phase is decided in `init` (`initialPhase`) so no surface flashes for a frame, and **every keyboard raise is a deliberate decision** — the implicit idle→focused return is deleted; the canvas focuses on arrival precisely because reaching it is now always deliberate. The hard UX invariant is unchanged: **at no point before confirmation may the user see an intermediate AI interpretation presented as truth** — zero AI presence, now scoped to listening + the typed canvas (test-enforced: typing produces no drafts and no model calls). The per-keystroke provisional pass, the rolling 400ms/1.2s cadence, `parseEpoch`, and **streamed partials rendering into cards** remain DELETED; `CaptureTriageRace`'s deadline and salvage stay, salvage becoming the timeout path into the reveal. **Deleted with the voice-first redesign**: `VoiceHeroBar`, `ListeningWaveform`, `LayoutMetrics.voiceHero`, the in-field two-tone transcript, `toggleDictation` (the mic never runs while the canvas is showing — "Speak" returns to the orb).
  - **A REVEALED INTERPRETATION IS FINAL** — the product's central AI-trust invariant, and the one that took three attempts to get right. *The system can think as much as it wants before showing you the answer; once it shows you the answer, it owns that interpretation until you change it.* Revealed means UI-committed, not database-committed: no AI-originated change to title, count, order, owner, date, type, relationships, splits or merges. **The user may always edit their own cards** — immutability constrains the system, never the person. It is enforced **structurally**, in `Interpretation` (`propose` refuses once `state == .revealed`, and a DEBUG fingerprint catches any mutation that didn't come through the user's edit path), because the three previous attempts held it as a RULE — "structure is decided once", "never progressively reinterpret", "the clamp is conditional on provenance" — and each left an API that could still mutate the screen. **"Progressively enrich, never progressively reinterpret" is retired**: nobody classifies a change as enrichment versus restructuring; they see an answer and then see it change. Minting the type deleted `DraftMerge.enrich`, `holdStructure`/`restructured`, `ComposerView.enrich`, `structureIsUserTyped`, and the `revealWhenDone` branch. The generalization, product-wide: **never expose an AI intermediate as user truth** — show activity, never intermediate semantic conclusions.
  - **Routing is device-first, escalate on evidence (2026-08-29 — the owner's re-weighting of capture's objectives, made after the first real device eval)** (`AI/CaptureRoute.swift` + `AI/CaptureEscalation.swift`). Two arms still — `.local` (deterministic) and `.cloud` (Gemini, the semantic authority) — but the policy is now two questions asked in order: *did the user draw the boundaries?* (`Segmentation`, an observation) and if not, *did the instant deterministic read visibly fall short?* (`CaptureEscalation`, a verifier over the read that already exists). The read is the DEFAULT interpretation — it held every corpus floor at p90 **2ms** on device while the FM arm measured p90 **21s** — and the capture transmits only with a named reason: `emptyRead` · `bigDump` (the existing ≥400-char/≥6-item depth floors — the population device evidence says deterministic segmentation fails on, sent straight to Gemini with no local attempt to double-pay for) · `underSegmented` (connective + time signals exceeding the draft count by ≥2 — UNACCOUNTED boundaries; the first shape fired only on exactly one draft, and case 50 — 251 chars, nine outcomes, two drafts — immediately sailed through, so the check generalized within the hour: two drafts hiding seven outcomes is the same failure as one hiding three; bare weekdays count as time signals for vocabulary parity with `resolveDate`, which expands them) · `unresolvedDetail` · `lowCoverage`. **Corpus numbers at landing (the `-RambleEval` policy report): 47 unstructured cases → 45 kept local, 2 escalated (both `underSegmented`), 0 false-keeps; on 2026-09-02, after the time-expression boundary, 46 kept / 1 escalated (case 50) / 0 false-keeps, and `interiorVerbSignals` joined the under-segmentation sum so a read that improves but stays short still escalates — see the real-utterance bullet below** — most captures down the instant path, escalation exactly where the deterministic count is wrong. The reason lands on the receipt (`CaptureRunTelemetry.escalationReason`), so the signals are tuned from provenance. **This is NOT the deleted confidence gate returning, and the difference is the direction of trust**: the gate asked a model a pre-parse meta-question (2.3s of overhead, escalated 95–100%); the verifier asks no model anything and can only ESCALATE — a false signal costs one cloud call, never the user's words (`.singleThought` died precisely because its lexicon KEPT reads on its own authority). The deliberate costs, stated: a clean-looking wrong read ships to the confirm card instead of Gemini (corpus rate: the false-keep line in `-RambleEval`'s policy report — read it before moving any floor), and "renew my passport" now stays private and instant instead of proving itself in the cloud. **The FM on-device model is OUT of the capture chain entirely** (its former slots — the unreachable-cloud degrade, the hedge's free arm, and triage's else-branch `engine` — all go deterministic now): no floor it held that the heuristic doesn't, an order of magnitude over the latency ceiling, kept measurable as `-RambleEval`'s pinned `on-device(direct)` arm and `-FMDiagnostics` — **Apple Foundation Models remain a CANDIDATE for synchronous Ramble primitives: the iOS 27 beta-8 runtime on iPhone 15 Pro Max did not meet the gates (p50 <500ms / p95 <1.5s / p99 <3s) — baseline evidence only, always stated with the runtime it was measured on; production routing is reopened after the GA evaluation (Campaign 5, `docs/capture.md` ▸ *Ramble economics*), by a human over the report, which may legitimately conclude any coverage share** (this sentence replaced the 2026-08-29 "intended primary" framing on 2026-09-04, on the team's review: a candidate, not a probable winner) — and as the Advisor's rung 2, where it belongs. The hedge machinery (`CaptureTriageRace.hedged`) stays built and tested with no caller passing an arm.
  - **The cloud default for unstructured rambles was a device-evidence REVERSAL (2026-08-18), itself re-weighted 2026-08-29** — the bullet above supersedes this one's routing policy (device-first with evidence-based escalation; the owner chose privacy + quota over the ~1s cloud read for captures the deterministic arm demonstrably handles), while everything else here — the free tail, the one-engine cloud arm, the capture contract at every rung — stands. Original reversal, kept because its evidence still defines the escalation targets (case 50 IS `bigDump`'s population): v1 said on-device-first for capture: the eval held ~100% floors, capture is latency-critical and the most intimate data in the product. What broke that premise was a measurement, not an argument — an unstructured spoken blob (nine outcomes, no punctuation, no connectives) failed to segment on device while a Flash-class cloud model read it cleanly with modifiers correctly attached. The floors had been earned in CI, which exercises the DETERMINISTIC path; a green suite proved the fallback, not the front door. **That exact utterance is now case 50 in `RambleEval.evalSet`, where it MISSES on both free arms (floors still held at 95%, one miss across the set) — a named target for the cloud arm to clear rather than an absent one.** It was **extended 2026-08-20 to the utterance as actually spoken on device** and now expects **9** drafts: three items longer, and carrying both directions of the outcome rule (the three-day lunch that must stay one, the Monday/Tuesday dog walk that must become two). Three things carry over and are load-bearing: **(a)** routing stays one function — `route(for:cloudAvailable:)`, and **structure the user typed never touches the network** (test-pinned: availability may never turn a local read into a transmission); **(b)** there is always a free tail, because **capture must never block** — the cloud arm degrades to an on-device parse and then to the deterministic read, asserted as BEHAVIOUR (`captureNeverBlocks` runs the whole corpus with no reachable model) rather than as the shape of a `fallbackChain` data structure nobody read; **(c)** the capture contract holds at EVERY rung — the model emits intents with raw expressions and `IntentResolver` does all date math, instance expansion and dedupe.
  - **The cloud arm is `FoundationModelsEngine` with a different `SessionSource`, not a second engine.** A `CloudModelProvider` hands back a `LanguageModelSession`, which is the only thing that file has ever talked to — so the same instructions, the same `@Generable` schema, the same verbatim-quote grounding and the same raw-expression rule apply on both arms *because it is the same code*. A parallel cloud engine would have been two places for the capture contract to rot. `AppBrain.triage(_:route:)` selects it, records the rung it ACTUALLY took (after the availability degrade — counting intent would report paid calls that never happened), and skips `SystemLanguageModel` token accounting on the cloud arm (the local tokenizer describes the wrong model). **Both arms present identically** — the orb never says which rung is thinking, because "thinking in the cloud" is an intermediate semantic disclosure in everything but name.
  - **Capture-time duplicate/child detection was INERT in production, and the backstop that was supposed to catch that was dead code** (found and fixed 2026-08-20). The chain is: the model may only cite candidate ids it was SHOWN (`TriageContext.candidates`); `preparedCandidates` is the rolling chain's hand-off from the *previous* parse; the shipped composer does exactly ONE parse and **no caller in the app passes that argument at all**. So every production prompt was candidate-blind → `duplicateOf`/`childOf` were always nil → `IntentResolver.edgeProposals` (whose first act is to drop ids that aren't candidates) always returned empty. The capture-time merge, the child-link proposal, the merge-at-commit path and the capture-form suppression were reachable **only from tests** — every one of them green, none of them running. `suggestsEnrichment` existed precisely to catch this case and was computed on every parse and **read by nobody**: its consumer was deleted when the reveal contract made a post-reveal enrichment illegal, and the flag stayed behind describing a mechanism that no longer existed. It is now removed rather than repaired, because after the reveal is too late *by construction* — the proposals have to land on the first parse. **The fix bounds audit A1 rather than reversing it**: `triage` now awaits its own retrieval for at most `AppBrain.candidateWaitSeconds` (0.25s) before prompting, so A1's real guarantee — first-draft latency must never scale with store size — becomes "never pay MORE THAN THIS" instead of "never pay". `EmbeddingStore.warmUp` already runs before the parse, so a warm cache lands well inside the bound and a cold or huge store prompts blind exactly as before. **The general lesson, which is the reusable half:** a feature whose enabling input is an unset default parameter fails silently and tests green forever, because the tests pass the input. When a capability depends on data threaded through a call chain, assert the data is actually there at the point of use — an empty package and a package with nothing relevant in it are indistinguishable downstream.
  - **The hedge is RETIRED from capture (2026-08-29); the race machinery survives it** (`CaptureTriageRace.hedged`, called with `hedge: nil`). The hedge's free arm WAS the FM on-device parse, and it left the chain with the rest of that arm — a slow cloud call now runs to the deadline, salvages what streamed, and falls to the instant deterministic tail, which is both faster and better-measured than the model it replaced. The race still owns the one budget, the salvage, and the cancellation semantics; its hedge capability stays built and tested (`CaptureHedgeTests`) for the day a rung worth racing exists. **A cancelled capture is not a timeout** (fixed 2026-08-22): the deadline arm slept with `try?`, which swallows cancellation, so dismissing the composer mid-parse raced the primary's honest `.cancelled` and landed as `.timedOutEmpty` about half the time — poisoning the very evidence `captureSeconds` is tuned on.
  - **Capture does NOT consult `CloudBudget`, deliberately** (reversed 2026-08-22). It used to, on the reasoning that the backstop belongs first on the highest-volume cloud workload. The reversal is a change of optimization target, not of arithmetic: capture's objective is *maximize intent preservation, minimize perceived latency*, with cost strictly tertiary — so a spend counter may not override an accuracy decision on the product's front door. The router asks *is local execution demonstrably safe?*, never *should we spend a call?* `CloudBudget` still guards the Advisor's speculative precompute, where what is being bought is a guess that a task will be opened.
  - **The orb has a minimum dwell, and it is a problem the pipeline getting FASTER created** (`Motion.orbMinimumDwellSeconds`, 1.1s). The orb was designed against an on-device parse measured in many seconds; a healthy cloud read answers a median ramble in about one, and `heroSettle` is a 0.5s spring — so without a floor the field morphs into an orb that is still arriving when it starts morphing into cards, the 3.2s breath never completes a cycle, and the signature moment renders as a stutter between two layouts. Sized as "entrance spring + enough held presence to read as an object", **not** as a fraction of the breath: making someone wait a full breath for an answer that already exists is theatre, which is one floor below a flicker. It can only fire when the model beat the animation, so it never lengthens a wait anyone is feeling. The hold happens **before** `propose`, so the reveal and the morph-out land on the same frame.
  - **One task per distinct intended OUTCOME — not per verb, and not per number** (2026-08-20). The count a ramble should produce is a product decision, and it has exactly two directions, which are the same rule read forwards and backwards. A **quantity or cadence inside one outcome does not multiply it**: "cook a lunch for three days of the week for next week" is ONE task, because it is one cooking session with a quantity attached. **Several named occasions of one outcome DO multiply it**: "walk my dog Monday and Tuesday" is TWO tasks, because the user named two days. Stated as the pipeline runs it: **parse the intent in the model, expand the schedule in app code.** `IntentResolver.expand` is the only fan-out in the pipeline and it lives beside the rest of the date math for the reason every other date decision does — the model must never do calendar arithmetic, and an expansion that only exists in a prompt cannot be tested. The model's whole job is to hand over the phrase intact (`dateExpression: "Monday and Tuesday"`), which the instructions now say explicitly, and `HeuristicEngine.weekdayEnumeration` does the same on the offline arm — a first-token extractor silently drops the later occasions, and expansion can only fan out what it is given. **The safety guard is all-or-nothing**: every comma/"and" fragment must resolve to a real date or the split is declined entirely, so "before the trip and after the meeting" cannot manufacture a task; a fan-out past `maxInstances` (7, a whole week) is declined rather than truncated, because past that the user is describing a recurrence this product has no model for, and one task they can correct beats eight they must delete. **The count-coupling this broke is the thing to watch**: `AppBrain.provisionalDrafts` stamped `provisionalSource` by INDEX behind a `drafts.count == clauses.count` guard, so the first expanding clause would have silently dropped the upgrade lineage for every card in the capture — it now carries the clause through the loop and there is no count to agree on. Scored in `RambleEval` (the extended case 50 expects 9, plus an isolated expansion case and a quantity guard) rather than only in unit tests, because expansion that works on a hand-built intent and never survives a real parse is not a feature.
  - **The on-device confidence GATE was built, measured, and deleted** (2026-08-22). Do not rebuild it without new evidence. The design was sound and the reasoning still reads well: ask the on-device model not *parse this* but *is there any reason NOT to treat this as one task?* — a strictly easier judgment than segmentation, with a deliberately asymmetric error budget (a false-local loses the user's work; a false-cloud costs a call). It was implemented twice. **Verdict + task**: warm p50 **6151ms**, 11 of 16 local answers misread (every one a CATEGORY error, on a corpus where the deterministic heuristic scores category 37/39). **Verdict-only, deterministic task construction**: 6151→**2303ms**, timeouts 7→0, misreads 11→**0** — the payload really was both the latency and the errors — and still 5.8× over the 400ms budget while escalating 95–100%, i.e. 2 local answers out of 39. False-local was **0.000 on both corpora throughout**: the safety property was never the problem. **The number that settled it is the comparison, not the threshold: Gemini answers a median ramble in about a second, and the gate needed 2.3. The "local-first" path was slower than the network it existed to avoid.** A gate that never says safe is equivalent to not having one, minus the cost of asking. Tripwire for revisiting: a materially faster on-device model, or a measurement showing cloud latency has grown past the gate's — not an argument that the design is elegant, because it is.
  - **The eval instrument lies more often than the code does** (2026-08-22, and this is the reusable half). Building the gate's measurement surfaced FIVE bugs in instruments against two in the pipeline: `-RambleEval`'s DEGRADED banner fired only at `served == 0`, so a cloud arm serving 2 of 52 printed "ALL FLOORS HELD" (now a ratio, and it names the error); the gate scorer used "is this capture one task?" as ground truth when the real question is "would the local path produce the right NUMBER of intents?", which diverges on every typed list and would have reported huge intent loss, driven the floor to 1.0, and produced a never-firing gate **with data appearing to justify it**; the oracle had perfect routing and dummy content, leaving the reading half of the headline with no baseline; a duplicated utterance across two corpora gave one text two labels and surfaced as a mysterious 0.023 loss rate on a *perfect* gate; and `CapabilityProfiles`' MAX_TOKENS fix was unreachable because `TodayPlanSession.generate` passed a per-call `GenerationOptions` that overrode it. **Bracket every new metric before pointing it at a model**: a known-perfect input must score clean and a known-reckless one must be caught, or a clean report is indistinguishable from a blind scorer.
  - **The privacy boundary is per-workload and stated in plain words** (Challenge 7). v1's line was "never raw captures"; the cloud default breaks it and pretending otherwise would be worse than crossing it deliberately — capture parsing needs the verbatim words, and there is no snapshot-shaped version of a brain dump. So: **Ramble's raw capture is the ONE sanctioned raw-text transmission** (`CaptureRoute.transmitsRawCapture`, test-pinned to exactly one case); Advisor and Brief send structured snapshots only; corrections and the change log never leave. `DataBoundary` says this in three sentences and renders **only when a provider is actually reachable**, because a standing warning about transmission on a device that transmits nothing is the mirror-image dishonesty. **Its capture sentence was rewritten again 2026-08-29** for the device-first policy — each routing change owes this copy its honest half: 08-22's version said only typed lists stayed local (true then); now every capture is read on-device first and the words travel only on escalation evidence, so the sentence leads with "read here first" and names the exception in the user's terms (a big dump needing a deeper read), never the mechanism's. The tests tying copy to `CaptureRoute` moved to the policy call with it.
  - **Capture is the conservative stage.** Its only job is to understand what the user said; deciding what matters and noticing what they might need belong downstream (Ranking/Today/Capabilities). The instructions used to open *"You are a **proactive** personal assistant… you fill in the sensible defaults they didn't spell out"* with **no anti-invention rule at all** — Today/anticipation behaviour leaking backward — and it produced a capture of "pick up food from the store later today" returning a second task, "buy new printer paper". Filling in a task's FIELDS is the job; inventing a task's EXISTENCE is not. **The model names its evidence and the SYSTEM verifies it**: `ExtractedTask.sourceQuote` must be found in the raw capture (`AppBrain.grounded`), or a lexical anchor must survive as a cheap anomaly detector, or the task is DROPPED and never substituted. Model-authored evidence for model-authored output would be circular, which is why the quote is checked rather than trusted; a verbatim quote beats character offsets because small models count characters unreliably.
  - **Structure is decided ONCE, at submit**, and never changes under the user. `Segmentation.structure(of:)` returns TWO states — `.explicit([items])` when the boundaries are the user's own punctuation and layout, `.unstructured` otherwise — and the second goes to the authority. **It used to return three**, and the middle one (`.singleThought`: one item that passed `readsAsOneThought`, an 18-word ceiling plus an interior-action-verb check) is the 2026-08-11 regression's fix and the 2026-08-22 deletion both. The fix was right about its own problem — the old gate called ANY one-item read certain, when one item out of a long dictation means every boundary test failed, which is the LEAST certain outcome a splitter can produce. It was wrong about who should answer: a lexicon deciding "this is probably one task" is a semantic judgment, and the whole point of the current architecture is that those belong to the authority. The five tests that pinned its corners (subordinating words, determiners before verbs, the word ceiling) were deleted with it — good tests of a function that should not have existed, and keeping them would have preserved the interpretation in the suite after removing it from the product. What they protected is still measured end-to-end by `RambleEval`'s segmentation floor.
  - **There is no clamp any more, because there is nothing to clamp.** This bullet used to describe `DraftMerge.enrich` + `holdStructure`: a model parse allowed to enrich a revealed set's metadata but not restructure it, with the permission depending on whether the read was `.typed` or `.singleThought`. All of it is gone — `enrich`, `holdStructure`, `structureDisagreements`, and the three-state provenance the rule keyed on. What replaced it is stronger and much smaller: **one route produces one interpretation and `Interpretation` refuses any later proposal**, so "the model cannot add, drop or move a card" is unrepresentable rather than enforced by a flag. `DraftMerge` survives for exactly one job — the RE-SUBMIT path, where `backToCapture()` keeps the user's cards and edits and a second parse has to land on them (`passCSurvivesTheResubmitPath`). Pass C in particular looks dead under two exclusive arms and is not: reveal a typed list locally, go back, add a sentence, and the cloud's answer merges into cards still carrying `provisionalSource`.
  - **One object carries the whole arc.** `RambleOrb` + `matchedGeometryEffect(id: "ramble")`: the field's rect becomes the orb, which becomes the card composition. It is a **screen-filling `MeshGradient` sphere** (4×4, interior control points wandering on the deliberately **incommensurate** `Motion.orbDriftPeriods` so the surface has no short repeat; corners pinned or the mesh tears), sized from the surface's geometry via `LayoutMetrics.rambleOrbScreenFraction`. **Two hues only** — everything is `Palette.accentStart`/`accentEnd` mixed toward black and white via `Color.mix(…, in: .perceptual)`, so richness comes from VALUE and motion, never a third hue. It is **deliberately not a spinner and must never become one** — no rotation, no track, no determinate arc, no percentage, no counts, no candidate titles; note that RATE decides this more than shape does. If it ever reads as a loader the fix is slower, more organic motion, never a progress affordance. **Three tuning traps, all measured:** blur past ~0.04·diameter smears the mesh so evenly that full control-point travel becomes invisible (frame-to-frame peak fell 80→13, a moving orb that looked frozen); the light must POOL at two non-adjacent interior cells — a clean left/right hue split renders as one diagonal band however much the points move; and **"slow" is not the same as "alive"** — the first version breathed ±1.7% on an 11s period (a drift period reused for the breath) and read as a static blob, so the breath has its own token (`Motion.orbBreathPeriod`, 3.2s — the rate a calm person actually breathes) and drives scale, glow radius and the specular together. **Judge this beat on VIDEO, not screenshots**: `simctl io recordVideo` + frame extraction, because 1s screenshot sampling aliases against a 3.2s breath and reports whatever phase it happens to catch. The 14s `orbGatherSeconds` settle (turbulence decays, rim tightens) is what keeps a long wait reading as calm rather than stalled, and it reports nothing. Reduce Motion genuinely `paused`s the timeline (verified pixel-identical). A quiet reassurance line appears at 8s. **The orb now has a `mode`** (`.listening(AudioLevelMonitor)` / `.thinking`, default `.thinking` so every pre-voice call site is untouched): listening HOLDS turbulence at `Motion.orbListeningUnsettledFloor` — no 14s burn-down while someone talks, because the gather is the THINKING gesture and running it under speech reads as the system finishing with them — and layers the voice on top as smoothed energy (`approach`, half-life `orbLevelSmoothingHalfLife`; then the soft-knee `energy` curve — steep out of silence so a whisper visibly registers, compressed at the top so emphatic speech swells without agitation), driving scale (≤ `orbLevelSwellMax`), glow, wander amplitude and the specular. **Audio controls the orb's PRESENCE, never its speed — energy must never touch a drift period**: a level-scaled rate is what turns a listening presence into a VU meter, and "smart VU meter" is THE visual failure mode (the reception test — watch silence/whisper/normal/emphatic ON VIDEO and ask *does it feel like it's listening to the person, or operating a voice recorder?* — is the core product test for this surface, not cosmetic QA). Speech adds presence to an already-alive baseline: the breath is unconditional across modes, so a pause to think never reads as the orb going dead. **Two traps, both pinned in `RambleOrbEnergyTests`**: the listening→thinking contraction decays FROM the floor (`thinkingUnsettled(0) == orbListeningUnsettledFloor`; the swap clock is tracked in the same body pass that renders it, not via `.onChange`, so no frame can draw the settled gather and then step UP) — and the swap lives in ONE combined `case .listening, .understanding:` switch branch in ComposerView, because two branches are two `ConditionalContent` arms: the orb's `@State` clock resets, the mesh re-phases, and matchedGeometry animates a spurious orb→orb morph. Under Reduce Motion the drift stays frozen but the level still applies by direct value change — a level meter is data, not decoration.
  - **The reveal shows the consequence, not the classifier.** "Here's what I understood" · N things · a card per draft carrying only what is consequential (due, non-self owner, urgent, blocked, dependents, merge/child proposal); category, effort and the empty affordances sit behind a per-card **Details** toggle. This **revises** the creation-confirmation spec's "the glance only works if the user can SEE every field" to **"every field is reachable in one tap; the glance shows what's consequential"** — rendering all eight made the two chips that carried information look identical to the six empty invitations, which is the opposite of a glance. **`workIntent` is never rendered as a label**: `.planning` reads "Needs a plan". The axis stays internal. **The consequence line reads `isJudgmentCall` ONLY — never `draft.needsDecision`**, which is `isJudgmentCall || confidence < 0.5`: correct for the flag a task is born with, false as a sentence, because it told the user that cooking dinner needs a decision when the model was merely unsure of its own parse. **Uncertainty is NO LONGER a visual state** (2026-08-22): the 0.75 dim and the "Not sure" chip are deleted. That threshold (`confidence < 0.5`) was calibrated against a deterministic-first pipeline whose confidence ceiling was 0.85 — sub-0.5 was ordinary output. It is not ordinary now that the semantic authority reads the capture, and a reveal that hedges about its own answer invites the user to audit every card, which is the cognitive work the product exists to remove. The dim also reduced legibility of the title field and the delete button — the two affordances for fixing whatever it was worried about. Confidence is still recorded (`CaptureProvenance`, `ModelMetrics`, the eval); it is an internal routing and measurement property. **What replaced it is a TARGETED ASK**: `TaskDraft.unresolved` marks a detail the user SPOKE that the resolver could not land — today only `.date`, written when a time phrase fails `resolveDate` — rendered as a "When?" chip that opens the picker. The distinction is the whole feature and is test-pinned: an UNDATED task is not an unresolved one, so the ask never fires on a card where nobody mentioned a time. `.owner` is deliberately absent — `ownerChip` already names an unrecognised person and offers "Add … to household", which is a better affordance than a second, vaguer chip beside it.
  - **The arrival is designed, and the canvas is the deliberate landing.** The reveal was a cut — cards simply present on the next frame, because the list's stagger transition never fires when the list itself is what got inserted. `RevealEntrance` drives it off a `revealedAt` timestamp instead (per-index delay, re-fires on a restructure, settled when nil), plus a **light** impact haptic (`.success` belongs to the commit) and a composition that **centres in its space** via `GeometryReader` — top-aligned, a one-card reveal read as an empty state. On the canvas (reached only deliberately since the voice-first entry — Type instead, mic-denied, resume, empty finish): the keyboard comes up on arrival — the old "never focus a fresh canvas" rule moved up a level, because the fresh entry is now the orb. **The 2026-08-27 device pass reshaped the canvas** (owner feedback: cursor drawn ON the placeholder, buttons sliding through content on keyboard transitions, off-system Ramble): the field has a **quiet container at rest** (primarySurface + `Palette.border` hairline; the gradient border + glow stay reserved for the model reading) — "no container at rest" is retired with the canvas's demotion to escape hatch; the placeholder is inset to the insertion point's exact origin (`Spacing.sm` + TextEditor's own ~5pt/8pt text-container insets), so the cursor blinks BEFORE the first glyph, never on it; the controls live in **`captureBar`, a `safeAreaInset(edge: .bottom)` pinned bar** (solid background, hint + optional Ramble + one compact Speak/photo row), because in the content stack every keyboard transition relaid the cluster through the field — as an inset nothing can cross content and Ramble stays reachable above the keyboard; **`rambleButton` wears the design system's primary-CTA gradient** (the `accentFlat` "don't spend the gradient twice" variant read as off-system to the owner and is retired — one primary-CTA treatment everywhere); `micButton` is always the compact capsule (a full-width Speak argued with the landing the user deliberately picked, and a disabled full-width Speak was a dead affordance in the primary slot). The orb tap is an EXIT in any non-listening speech state (a hung warm-up must not swallow taps), and a 30s `preparingWatchdog` folds a warm-up that never resolves into the lifecycle rule — generous because first-run model downloads legitimately run long. Discard stays in `.destructiveAction`; leaving parks the words, so the leading action is "Close" (from the orb too — the toolbar label upgrades the moment there are words to keep). **Two layout traps, both hit and both fixed:** `maxHeight: .infinity` on the composer field hangs the layout pass (a greedy `TextEditor` with no ceiling — the composer never presents), and animating the empty↔non-empty button area cross-fades two different CONTAINERS into overlapping capsules, so that swap is explicitly `.animation(nil)`.
  - **Create ends the loop — immediately.** Tapping Create dismisses straight back to wherever the user was; capture is something you do mid-life, not a place you go. There WAS a ✓ "N tasks added" receipt holding 0.9s before the dismiss, and it was **removed 2026-08-30** (owner's call) because it read as an extra screen between Create and getting on with things. Confirmation is now the success haptic plus the tasks themselves, visible in the list the instant the sheet is gone — both stronger signals than a count. **The count is deliberately unstated.** The `UndoNotice` still fires for the one outcome the list cannot show you, a merge (`CommitSummary.messageBeyondReceipt`); it is now the only thing that speaks after a commit, so if a second message is ever added there, the "don't end the arc twice" rule applies to it alone.
  - **Private Capture — the FM viability campaigns, and what they bought (2026-08-29 → 08-30).** The question was never "is FM good?" but "which workload is FM good at TODAY, on this device?", and three `-FMDiagnostics`/`-QuickCaptureDiag` device campaigns answered it in numbers. Campaign 1 attributed the 21s p90: 62% of it was OUTPUT VOLUME (the guided `TriageResult` array ran 1,200–1,900 tokens even for one task) and `contextSizeExceeded` on a 251-char run-on was the true mechanism behind the historical "648-char ramble never finished". Campaign 2 found pre-first-token is instruction-token-driven (~1.5ms/token over a ~1.4s FIXED base), so the 500ms p50 gate is runtime-bound out of reach — but a short prompt + single-object schema segmented the case-50 run-on 5/5 where production config and the heuristic both missed. Campaign 3 measured Apple's true intercept (zero-instructions pre-first-token p50 1335ms) and the envelope that works: **one thought → one capture**, p50 1.8s / p95 2.4s / p99 3.1s, grounding 43/43, burst-stable, 100% local. The product that shipped on that data is the second orb (long-press): FM's proving ground, scoped to its measured strengths. Two of its rules were earned the hard way: **the multi-intent detector is deterministic** because FM's "several things?" boolean measured 43% precision (it would nag one single thought in two) against the free signal detector's 90%; and **a "blocker" that resolves as a date IS a date** (`classifiedTimePhrase`) because the model filed "today" under `blockerPhrase` — linguistically defensible, wrong three ways (no date, inference suppressed, phantom wait) — and that ONE mechanism was the whole 76% due regression. The 2026-09-02 addition, **deterministic backfill of every field the schema omits** (`HeuristicEngine.intent(from:)` on the same words), follows the architecture's oldest philosophy: the model's job is the interpretation, the app's job is the metadata — a private capture used to reach the card as "Admin" with nothing else known about it. The same day's UX audit found the reveal card itself was the bigger leak: a title field, a due chip and the quote, which rendered none of the model's judgment/wait reading, allowed no date change, and reached commit without `markEdited` — so the learning loop had a hole exactly where FM does its most interesting work. The fix was reuse, not design: one draft through `ConfirmCreationList` is the hero confirm card, the surface Ramble's single-task fast path already uses, and the sheet now feeds it the composer's roster and learned rules.
  - **The real-utterance corpus and the four rulings (2026-09-02).** The first 26 captures anyone actually spoke to the orb (device store, 08-27 → 08-30) looked nothing like the authored fixtures: bare clock times, fragments cut by the silence window, the mic catching a room full of children, retry siblings, meta-narration. They forced four policy decisions the authored corpus had never asked — **P1** a bare clock time means today (`resolveDate`'s last arm; 8 of 26 captures retired their "When?" chip in one change); **P2** ambient captures label the buried task when one exists and ZERO when none, the first labeled anti-invention rows; **P3** a verb+object fragment is one task and a bare word is none (a task you delete costs a swipe, a thought the system dropped costs the thought); **P4** narration is stripped, the capture is the content. Two instrument lessons rode along: **a day word and the clock beside it are ONE occasion** ("tomorrow at 3 PM" counted as two time signals made the detector nag a single thought and `underSegmented` escalate a one-line capture — the clock vocabulary is now ONE shared regex, `IntentResolver.clockTimePattern`, so the resolver, the extractor and the verifier cannot disagree about what a time is); and **each arm is scored only on the population it is built for** — the single-object schema always captures, so scoring it on zero-task rows would measure the label, not the arm; those rows are PRINTED for a human to read. The corpus is quarantined (`Floors.real`, calibrated downward from the deterministic arm's observed numbers, never the authored floors) and a child's name is substituted consistently so no real name sits in a public repository.
  - **The Ramble UX walk (2026-09-02, simulator, every beat by launch seam).** Three findings, all shipped. (1) A correctly-read three-item capture sat 30 seconds behind "Making sense of it — that was a big one": the new interior-verb signal had counted the noun in "action plan" as a fifth boundary signal against three drafts, the capture escalated, and the simulator's dead-quota cloud stalled to the full `captureSeconds`. Two fixes: an interior verb counts only when an OBJECT follows it (`CaptureEscalation.objectStarters`), and the budget is sized by the escalation reason — a second opinion over a read in hand waits `captureStandbySeconds` (10s), a dump the local arm cannot represent waits the full 30s. The reassurance copy was the third symptom: "that was a big one" now requires an actual `captureDepth` dump. (2) The deterministic title for "I want to add that I need to be ready to go to brunch at" was the whole sentence: the meta-narration lead-ins are now stripped (P4 applied to the splitter's `leadIns`), the dangling "at" leaves the title, and — the part the ask exists for — that "at" is handed over as the date phrase so the "When?" chip fires on a capture cut by the silence window. (3) Nothing on the listening beat or the canvas needed changing; they matched their specs. The audit method is the lesson: seams + screenshots at three timestamps per beat, because a reveal that lands eventually looks identical to one that lands instantly in a single screenshot.
  - **The primary CTA was under the keyboard, and the cause was a floor, not the keyboard (2026-09-12).** A screenshot of the typed canvas with words in it showed the Ramble capsule cut flat at the keyboard's predictive strip. Theories were cheap — the `.large` detent, keyboard-avoidance excluding the predictive bar — so a temporary DEBUG logger wrote the bar's global frame and every `UIKeyboard*FrameNotification` to the app container instead. Keyboard top: 546pt (h=328 on 874). Bar: settled at `maxY=577` and never moved again. Bisecting the detent changed nothing. The content log had the answer: with the keyboard up the content region reported `h=314` — exactly title + subtitle + the field's 160pt floor + paddings — and a VStack that cannot shrink its children below their floors OVERFLOWS, so the `safeAreaInset` bar was pushed 31pt below the safe area it was supposed to sit in. The comment in `captureBar` already recorded an earlier fight with the same symptom ("the secondary row above it was the half getting clipped"), resolved by moving Ramble last — which chose which control lost, not whether one did. **The fix is a room clamp, measured, not a constant**: a `GeometryReader` in the field's slot reports what the stack has left, the field takes `min(clamped, room)` with a one-line floor, and no device size can push the bar. The same pass fixed the row above it, which wrapped every label on a 402pt phone: `ViewThatFits` over single-line fixed-width labels, degrading full labels → short verbs → glyph-only verbs → glyph-only posture, with the posture label yielding LAST because it is the privacy posture in the person's words and the other two are universal glyphs. On the iPhone 17 Pro the second candidate fits, so every capsule keeps a label. **Lesson, the eval-instrument one again in a layout costume: the clip was visible in one screenshot and its cause in none of them; the three-line logger settled in ten minutes what an hour of reading the layout code could not.**
  - **The first brain dump a new user ever types was not routed at all (2026-09-11, found by looking at onboarding).** `-OnboardingResult` revealed *"I found 1 area · From 1 item"* off a ten-line sample, sixty seconds after launch. The cause was one unset default: `AppBrain.triage`'s `route:` parameter defaulted to `.cloud`, so a caller that never mentioned it claimed the transmitting rung and skipped `CaptureRoute.route(for:localRead:)` entirely — and `OnboardingView.transform()`, the real production path, was such a caller. Both halves of the routing policy were bypassed at once. **Privacy:** "structure the user typed never touches the network" is pinned in `CaptureRouteTests` and held perfectly *inside* `CaptureRoute` — while the view above it transmitted a newline-separated list on a configured build, because the invariant was never asked. **Quality:** the model was handed a segmentation problem the user had already solved, and got it wrong, on the one screen whose entire job is to show chaos becoming clarity. The reveal now reads *"I found 8 areas · From 10 items. 2 I'm leaving for you to decide"*, grouped by area with the two judgment calls flagged, and it lands instantly because the deterministic read is 2ms. The fix is the shape, not the value: the default is REMOVED, so every call site states its route, and the callers with no composer around them share `CaptureFlow.route(for:posture:)` — posture first (it outranks the router everywhere), then the deterministic read, then the router. The test pins AGREEMENT with the router rather than a hardcoded verdict, so moving an escalation floor cannot fail a call-site test for a reason unrelated to what it checks. **This is the candidate-blind prompt's lesson inverted**: there an unset default silently DISABLED a feature and every test stayed green; here it silently enabled the expensive, transmitting one, and every test stayed green for the same reason — the tests called the policy directly, and the policy was never the thing that was broken.
  - **A pronoun is not a blocker (2026-09-11, found by looking at the confirm card).** "renew my passport, book flights for the trip after that, and pay the water bill by Friday" revealed three correct cards and one phantom: the second wore a wait chip reading *after that*. The extractor had done exactly what it was written to do — `after` is a dependency signal, so the phrase following it became the wait — and the phrase was a demonstrative. The asymmetry is what decides it. A wait that names nothing still costs the task everything a real wait costs: it recesses, it sinks under `TaskRanking`'s blocked band, it opens the Advisor's `.blocked` gate, and it can never resolve, because no title will ever match `that` — only a human noticing and clearing it by hand ends it. What declining gives up is a dependency the phrase never carried. So `namesSomething` requires one content word (a phrase that merely BEGINS with a determiner, "the passport renewal", still passes), and the referent the demonstrative points at is left to the machinery built for it: the duplicate/child retrieval proposing an edge between two real tasks, which is a graph question, not a lexical one. **The second half was a disagreement between two answers to one question.** `isBlocked` (a lexicon scan, feeding the reasoning line and the confidence band) and `blockerPhrase` (the extraction) were computed independently, so a line that read blocked but yielded nothing usable was explained to the user as *"Looks like it depends on something else finishing first"* over a draft carrying no dependency at all. `blocked` is now derived from the phrase, so the explanation and the record cannot drift. The lesson is the one the walk above already taught: the confirm card is where capture's quality is legible, and looking at it beats reasoning about it — every floor stayed green through this, because a phantom wait is not a segmentation error and no corpus field was measuring it.
  - **The metric is time to trustworthy result**, not time to first token: `ModelMetrics` records `lastConfirmMs` + `lastFirstCardSource` (local/model), `lastEnrichmentMs`, and `structureDisagreements`, surfaced in the DEBUG footer.


## 2026-09-02 — the capture pillar's four features

The invariants are in `CLAUDE.md` (the capture bullets); this is the why.

- **The conversation guard (F-02).** §16 of the spec listed it as known and accepted: a
  conversation the microphone catches becomes a dozen cards, because dictated sentence
  punctuation reads as explicit structure and explicit structure never transmits. The fix
  respects both existing rules by being VOICE-ONLY: typed text still never transmits, and
  the escalate-only asymmetry (a wrong escalation costs one call) is what licenses a
  deterministic talk detector at 50%/30% thresholds. The new thing is an authority allowed
  to answer NOTHING — and the composer treating a served empty as a verdict (settle to the
  canvas with the words) rather than a failure (re-manufacture the cards).
- **One door with a posture (F-03).** Two doors made the person classify their own thought
  before speaking it. The engine was the finding; the surface was the scaffolding. The
  posture is a control because a privacy promise reachable only by long-press is not one a
  person can rely on.
- **Capture without opening the app (F-01).** The one form of capture friction Ramble did
  nothing about. The intent parks and resumes with auto-submit — landing on Confirm, never
  past it — so the single publish boundary survives the fastest path into the product.
- **Parked captures findable (F-04).** A gap the Brief cut created. A row, not a nudge.
- **Learning two more shapes (F-05).** Effort fills an EMPTY estimate only (a spoken
  duration beats a learned default); urgency is additive.

- **The 2026-09-04 surface pass — nine small honesties, each closing a place the arc quietly worked against the person.** (1) **Discard is reachable from the reveal**, not only the canvas: the reveal is where "no, never mind" is most often decided, and its only exit was Close, which PARKED the capture and resurfaced it at the top of Tasks as unfinished work already decided against. (2) **Removing a card can be undone** — an in-place `UndoNotice` ("Removed “X”" · Undo) restores the card to the place it held and `RemovedDraftSet.forget` reverses the bookkeeping, so a re-read keeps it; before this, one mis-tap on the X was the only irreversible act on the surface and the merge then kept the card out of every re-read. (3) **The Create CTA says what pressing it does** (`ComposerView.createTitle(created:merged:)`): "Create 2 tasks · merge 1", never "Create 3 tasks" over a set with a merge in it — the commit pill used to correct the button a second later. (4) **The subtitle carries the ask** (`revealSubtitle(count:asks:)`: "3 things · 1 needs a date") — the one thing on the page that wants something back was findable by sighted users only by scanning every card for a "When?" chip, while VoiceOver users were told at the reveal. (5) **The transcript is captioned** in the register of its channel ("What I heard — edit it if I misheard." / "What you wrote — …" / "What the photo said — …"): under "Here's what I understood", an unlabelled editable box read as a notes field and its editability, the whole reason it is on the page, went unnoticed. (6) **"Nothing actionable" has a way forward the person owns** — `CaptureFlow.keepAsOneTask` makes ONE draft from the words as said (resolver-backfilled, confidence 1, `aiOriginal.title == title` so commit diffs no phantom correction), landing through `editableDrafts`, the user's own path: the system proposed nothing, the person vouched for it. (7) **The posture chip sits on the listening surface too** — the door most people use — above the controls row as an overlay so the orb keeps its size; it lived only on the typed canvas's bar, so someone opening INTO listening could not see or set whether a private thought would stay on the device without leaving the surface first. (8) **A parked capture says how old it is and can be let go without opening it** (`ParkedCapturesRow.age`, "2h ago"; long-press → Discard behind the same confirmation the composer wears): a row dismissable only by resuming it and finding Discard nags by construction. (9) **Just-created rows wash in** (`TaskRow.isFreshArrival`, `confirmedAt` within 8s; `Motion.arrivalWashHold`/`arrivalWashFade`): Create dismisses immediately and states no count, so the list has to show WHICH rows arrived or the receipt is a list that looks the same with more in it — a soft `accentSoft` tint held past the sheet's dismissal, then dissolved; never a badge, gated on the window so a relaunch or a later scroll never re-washes. Plus ⌘↩ on Ramble and Create for hardware keyboards. Pinned in `CaptureSurfaceTests`.


## 2026-09-12 — the reveal can make a group: "Group as one outcome"

The list learned to render a container as a deck — a group with a current task — and the
same day it became obvious that a person had no way to MAKE one on purpose: only the
Advisor's split and a capture-time child link ever created an umbrella. The reveal now
carries a bordered secondary beside *Keep it as one task*: **Group as one outcome**. An
alert names the outcome, the CTA reads *Create “Trip to Lagos” · 3 steps*, and the
umbrella is born at Create — at the one publish boundary, nowhere before
(`AppBrain.commit(groupTitle:)`): owned and authored by the capturer, filed under the
steps' commonest category (ties to the first step's, deterministically — a dictionary
max filed the same capture differently run to run), its steps linked in card order with
`sortIndex`, logged as a reversible `.human` `"grouped"` entry whose undo arm unlinks the
steps and removes an untouched umbrella. One card is never a group; a blank title groups
nothing. When the capture NAMED its outcome — *"Lagos trip: renew my passport, book the
flights"* — the button itself reads *Group as “Lagos trip”* and one tap groups
(`CaptureFlow.suggestedOutcomeTitle`: the lead before the first colon, one to six words,
something after it); otherwise the alert starts empty, because a guess is not a starting
point. Nothing here is proposed by the system: the reveal boundary is untouched, the
person vouched for the structure. The AI proposing a group — the model naming membership
— stays the separate change, landing behind the same tap and the same receipt.
`-OpenCapture "text" -GroupAs "Title"` reaches the grouped reveal; Activity words the act
("Grouped", with the split's glyph) and undoes it whole.

## 2026-09-12 — embeddings have never worked on the dogfooding phone

Found by the duplicate-sweep eval's prefilter line on the DEVICE — "no sentence embedding
on this host" — and confirmed independently from the device store: **70 tasks, 0
`EmbeddingCache` rows.** `persistFresh` writes a row for every fresh vector, so zero rows
over weeks of daily use means `NLEmbedding.sentenceEmbedding(for: .english)` (or its
`vector(for:)`) has returned nil on this iPhone 15 Pro Max for the whole dogfooding period.

What that has silently meant, all of it invisible to every test and every prior eval:

- **`ContextRetrieval` has been lexical-only.** The capture-time candidate package — the
  only ids the model may cite for duplicate/child proposals — was ranked on word overlap,
  category and recency, never on meaning. A paraphrased duplicate ("passport renewal" for
  "Renew passport") could not reach the prompt.
- **`DuplicateSweep` has never judged a single pair.** `candidatePairs` skips any pair it
  has no vector for (correctly — it only reasons over evidence it has), so with no vectors
  it skips everything. The judge measured today at zero false merges and perfect separation
  has never once run in production.
- `EmbeddingStore`'s own header says nil means "the simulator". It meant the phone too.

Why no test caught it: `DuplicateSweepTests` inject a vector table; `ContextRetrieval`'s
tests exercise the lexical degrade path; the app degrades gracefully by design. **A feature
that degrades gracefully with no meter on the degrade is a feature that can be off for a
month.** The candidate-blind capture prompt (inert for weeks, every test green) was this
same shape; this is the third instance.

**Diagnosed on the device the same afternoon (`-EmbeddingDiag`), and it was neither the
asset nor the locale.** In ONE process: a direct `NLEmbedding.sentenceEmbedding(for:
.english)` at the top of the seam → **NIL**; `NLEmbedding.wordEmbedding` present; the
`NLContextualEmbedding` assets present and loadable; then `EmbeddingStore.sentenceEmbedding`,
touched seconds later → **present, dim 512, `vector(for:)` OK**. The lookup fails on the
FIRST call in a process and succeeds on a later one. `EmbeddingStore.sentenceEmbedding` was a
`static let`, touched at launch by `AppBrain.prewarm`, so it captured that first nil and
served it for the life of every process — which is the whole finding. And the simulator was
the same: `EmbeddingStore`'s "nil means the simulator" had been the frozen first nil the
entire time, on both hosts.

**The fix is a retrying accessor.** A successful load is cached forever; a nil is asked again
on the next access (a catalog check, not a model load); `settle()` asks up to three times
for callers that need both of two comparisons in the same world; `AppBrain.prewarm` asks once
more after two seconds off the main actor. A process that never gets an embedding degrades
exactly as before — the change is that it now RECOVERS. `EmbeddingStore.statusLine()` is the
meter in the DEBUG diagnostics card (`sentence embedding: available · N cached vectors · M
lookups`), because a graceful degrade with no meter is how this stayed off for weeks.
`EmbeddingAvailabilityTests` pins the shape in both worlds: a success is never re-asked, a nil
always is.


## 2026-09-12 — the sweep's prefilter, measured on real vectors for the first time

With the embedding fixed, `-DuplicateSweepEval`'s prefilter section stopped saying NOT
MEASURED, and the first real reading is the one the whole instrument was built to get:

```
floors: similarity ≥ 0.82 · word overlap ≥ 0.30
real duplicates reaching the judge: 0/10
                                          sim   lex
  Renew passport / passport renewal       0.17  0.33
  Book the dentist / make a dentist appt  0.00  0.25
  Cancel the gym membership / cancel gym  0.14  0.67
  …
  call the plumber / call the LANDLORD    0.57  0.60   ← a near-miss, and the top score
  fix the tap in the bathroom / KITCHEN   0.49  0.60   ← another
```

Two facts, in order of severity. **The floor is an order of magnitude off**: 0.82 was
calibrated in `DuplicateSweepTests` on synthetic 2-D unit vectors (cos 0.99 → 0.86), and no
real 512-d sentence vector for a paraphrase comes near it. **And the ordering is inverted**:
on this corpus the store's similarity ranks the near-misses ABOVE the real duplicates —
"call the plumber / call the landlord" outscores "renew passport / passport renewal" three
to one. A floor can be tuned; an inverted signal cannot. It is not the transform: `similarity` is
`1 − √(2 − 2·cos)`, i.e. one minus the Euclidean distance between unit vectors, verified
against `NLEmbedding.distance` when it was written — which explains the SCALE (0.82 needs
cos ≈ 0.984) but not the order. Back-solving the printed values, the raw cosines are
≈ 0.91 for plumber/landlord and ≈ 0.66 for passport/renewal: **the iOS 27 sentence embedding
itself ranks these backwards on three-to-six-word titles**, weighting sentence shape over the
noun that decides sameness. That is the question that decides whether the embedding half of
the prefilter survives at all, and it is answered: not as a duplicate detector for titles.

The lexical floor alone does not separate them either (duplicates 0.12–0.67, near-misses
0.20–0.60). **The judge does** — on this run perfectly, duplicates 0.90–1.00 against a flat
0.50 — but one run earlier it returned 1.00 on the prerequisite near-miss ("passport
photos"), so it is not yet a gate a destructive action can stand on alone.

**Decision taken: nothing moves yet, and that is the correct output of the instrument.**
The sweep stays inert (as it has been, now visibly), the floors stay where they are, and the
report prints each pair's real `sim`/`lex` against them so the next change is made on
evidence. What has to happen first, in order: diagnose the similarity scale on device; give
the judge the *prerequisite ≠ duplicate* rule and re-run until the adversarial pair holds
across repeats; only then move a floor — and re-run this report before ANY of those changes
ships, because the merge is the one inference that destroys a task.


## 2026-09-12 — the destructive gate, measured before the runtime moves

`DuplicateSweep` is the auto-accept invariant's one named exception: everything else the app
infers is auto-accepted because the confirm card is the human boundary and a wrong guess costs
an edit, but a merge takes an EXISTING task off the person's list, in the BACKGROUND, gated on
`confidence >= 0.85` — a number the model reports about itself.

`DuplicateSweepTests` covers the plumbing thoroughly: both prefilter floors, suppression, the
caps, best-first ordering, the kill/undo round trip, the judgment-call carve-out, the
off-device no-op. **Every one of those tests runs with no model, because the test host has
none — so the judge had never been scored, on device or in CI.** That was tolerable while the
runtime was frozen. It stops being tolerable the week the model changes: a self-reported
confidence is precisely the kind of value whose CALIBRATION moves between runtimes, and 0.85
was chosen against a model that is being replaced. A judge that becomes slightly more
confident under GA merges tasks a beta build left alone, silently, hourly, with an Activity
row as the only trace.

`-DuplicateSweepEval` answers three questions in the order they matter: how often does the
judge merge two tasks that are not the same (FALSE MERGE, printed first, ceiling zero); is
0.85 the right line (SWEPT, not asserted — the confidence distributions for true and false
pairs printed separately with a SEPARABLE/OVERLAPPING verdict, and false/true merge counts at
each candidate threshold, so the number is an output the way a routing percentage is); and
does the prefilter even let the duplicates through (a judge with perfect precision behind a
filter that drops half the real duplicates is a feature that does not work, and measuring only
the judge would report it as flawless).

The corpus is **paired**, the `gateAdversarialSet` shape, and its near-misses are built from
their partner's words — "book the dentist" / "book the vet", "order Mum's birthday present" /
"order Dad's", "fix the leaking tap in the bathroom" / "…in the kitchen". `DuplicateSweepEvalTests`
enforces that: a negative sharing no vocabulary with its positive measures nothing twice over,
since word overlap alone would ace it AND the production lexical floor would drop the pair
before the judge ever saw it. **That test failed on the first draft of the corpus** and caught
one such pair.

**`DuplicateSweep.judge` and `.accepts` were lifted out of `run`** so the harness measures the
judge the product uses. A harness carrying its own copy of the instructions and the prompt
scores a second implementation and reports it as the first — this codebase has paid for that
once already, in the confidence gate's scorer.

**And the first run tried to ship a false alarm.** It printed
`real duplicates reaching the judge: 0/10 ← the floors, not the model, are the ceiling on this
feature`, which reads as a devastating product finding. It was the simulator: with no
`NLEmbedding.sentenceEmbedding`, `candidatePairs` correctly skips every pair for want of a
vector. The report now distinguishes "the floors rejected this pair" from "there was nothing
here to judge with", prints JUDGE and PRODUCTION quadrants apart, and **refuses a verdict when
the production gate could not have merged anything** — because a vacuous zero in the
false-merge cell is the most dangerous number this report could print.


## 2026-09-12 — the boundary pass: the model draws the boundaries, the app does the cutting

**Built, measurable, off.** `AI/OnDeviceSegmenter.swift` + `AI/FMPrimitives.swift`
(`-FMPrimitives`) are WS4/Campaign 5's instrument and its candidate arm, landed together
two days before the iOS 27 GA runtime arrives so that reopening the routing decision costs
one launch argument instead of a week of deciding what to measure.

**The shape, and why it is this shape.** Capture escalates today when the deterministic read
looks under-segmented — connective, time and interior-verb signals exceeding the draft count
by two or more. That is a BOUNDARY failure and nothing else: the deterministic pipeline
already fills every field of a draft in microseconds, and the only thing it demonstrably
cannot do is find the seams inside an unpunctuated spoken run-on. So the arm asks the
on-device model for exactly that and nothing else — for each outcome, the first three or four
words, copied verbatim — and the app locates each anchor by TOKEN (the model reproduces the
words reliably and the spacing, case and trailing commas of a dictation unreliably) and cuts
there. Fragments go through the same `HeuristicEngine` → `IntentResolver` path every other
capture uses, via the extracted `AppBrain.drafts(fromClauses:)`, and the same
`CaptureEscalation.reason` judges the result.

Asking for anchors rather than tasks is Campaign 1's finding applied: 62% of FM's 20-second
capture latency was OUTPUT VOLUME, and a `TriageResult` array re-emits every title, category
and date the app is about to recompute anyway. Five words per outcome is the smallest artifact
that answers the question. It is the same move as `IntentResolver.expand` (*parse the intent in
the model, expand the schedule in app code*) and as `sourceQuote` (*the model names its
evidence and the SYSTEM verifies it*).

**Three properties fall out of cutting rather than generating,** and they are the reason this
shape beat a smaller `TriageResult`: nothing can be **invented** (every fragment is a substring
of what the person said — there is no path by which a printer-paper errand appears); nothing
can be **lost** (the fragments tile the text, so coverage is 100% by construction and
`lowCoverage` is unreachable from this arm); and grounding is **total rather than sampled** —
an anchor not found verbatim rejects the WHOLE artifact, because dropping one boundary silently
merges two outcomes back together, which is the exact failure the arm exists to fix. Rejection
costs a cloud call, which is what would have happened anyway.

**The arm can only ever remove a transmission.** It is unreachable on any escalation reason but
`underSegmented` (`bigDump` goes straight to the authority by standing policy rather than
paying twice; `emptyRead` has nothing to re-cut; `conversation` needs the authority's permission
to return nothing; `unresolvedDetail`/`lowCoverage` are field and content failures, not boundary
ones), it cannot propose anything the existing validator has not cleared, and
`OnDeviceSegmenterTests` greps the file for `CloudModel.`/`GeminiProvider`/`FirebaseAI` the way
Private Capture's does. **The one real cost, stated: a refused pass spends its own latency in
front of a cloud call it did not avoid** — paid only by captures that already escalate, bounded
by `generationCapSeconds` (3.5s, a wedge guard in `PrivateCaptureEngine`'s sense, set tighter
because a cheaper arm is waiting behind it).

**Why it ships off.** `isRoutingEnabled` is false, and that is not the posture's
"wait for the benchmark" default — it is this document's own standing decision: production
routing reopens after the GA evaluation, by a human over the report. `-OnDeviceSegment` runs
the arm live for dogfooding before then.

### The posture stops being a quality trade

The arm's second call site is the one that surprised the design. On the ON-DEVICE posture,
one thought ran `PrivateCaptureEngine` (measured p50 1.8s, grounding 100%) and **several
things fell to a single deterministic read of the whole run-on** — the very read whose
under-segmentation is what escalates on the open posture. So choosing "Read here only" cost
you segmentation on exactly the captures where boundaries are hardest, and the cost was
invisible: the confirm card looked the same, with fewer cards on it.

`CaptureFlow.Arm.boundaryPass` closes that. The two on-device envelopes are complementary by
construction — `soundsLikeSeveralThings` asks precisely "one thought or several?" — so one
thought keeps the private engine and several things get the boundary pass, behind the same
orb, onto the same confirm card. A refusal falls to the same deterministic read it would have
got anyway, because the posture forbids the network either way: **the person gets the better
of the two answers this device can give, and never a worse one than before.**

`boundaryPassAvailable` is a REQUIRED parameter of `CaptureFlow.plan` rather than a default
reading `isRoutingEnabled`, and that is scar tissue rather than style: this codebase has twice
shipped a capability decided by an unset default — the candidate-blind capture prompt (a
feature silently off for weeks, every test green) and `triage`'s `route:` defaulting to
`.cloud` (a new user's first brain dump silently transmitted). A capability the caller does not
name is a capability nobody is deciding about.

### `-FMPrimitives`: the report that flips it

P-A (segment) and P-D (artifact acceptance) — the two WS4 questions the decision rule turns
on. P-B is `-QuickCaptureDiag` Q1 and is not re-implemented; P-C needs a pair fixture that does
not exist, and a placeholder for it would be precisely the instrument-that-looks-like-a-
measurement §11 warns about. Gates, stated before the numbers and fixed for the campaign:
**false accept == 0** (the only cell that can hurt a person — a cut the validator cleared whose
count is still wrong is a confident misreading revealed as final; it is the routing quadrant's
`falseKeep`, asked of this arm), **exact fragments ≥ 70%** on the reachable cohort, **p50 ≤ 2s /
p95 ≤ 2.5s** (the renegotiated Private Capture envelope, which this arm inherits by sitting in
the same beat).

**Three cohorts, and printing all three is the point.** REACHABLE is what escalates as
`underSegmented` today — what the open posture's arm is worth as wired. **POSTURE** is what
the on-device posture's arm sees, which is its own population: it fires on the deterministic
multi-intent detector, not on the escalation reason, so it reaches rows REACHABLE never sees.
POTENTIAL is every unstructured row whose local read has the wrong count *and* whose label is
a boundary problem at all (`expected >= 2`; a row labeled zero tasks or one task cannot be
fixed by finding boundaries, and counting it would credit the arm with a population no
segmenter can serve). Scoring only on POTENTIAL would credit the arm for captures production
never hands it — the wrong-question failure in its most flattering direction; scoring only
REACHABLE would leave a live call site measured by nothing, which is the "documented and
untrue" shape.

**Posture regret**, printed under the POSTURE cohort, is the one number the two call sites do
not share. On the open posture a refused cut costs nothing — Gemini runs and answers. On the
on-device posture there is nothing behind the refusal but the deterministic read the cut was
trying to improve on, so strict validator acceptance can discard a cut that was *closer to the
truth* in exchange for no gain at all. The line counts exactly that: validator-refused cuts
whose fragment count was nearer the label than the read the person got instead. It is **not**
an argument for relaxing the validator — "closer to the label" is knowable in a corpus and
unknowable at runtime, where the validator is the only signal there is. It is printed so a
non-zero number becomes a named decision (find a runtime signal, or accept the regret) rather
than a cost nobody measured. Scoring it correctly is also why
`Refusal.validator` carries the CUT's own draft count: substituting the deterministic count —
which the first version of the scorer did — makes a cut that came apart and a cut that was
nearly right print identically.

**First run (sim, 2026-09-12, no model assets — numbers are cohort structure only, not P-A):**
86 labeled rows → 76 unstructured → **REACHABLE 3 · POTENTIAL 6**, and today's correct local
resolution rate on that corpus is **91% (69/76)**. The reachable cohort being three rows is a
real finding rather than a broken run: **as wired, the ESCALATION SIGNAL bounds this win, not
the model.** Whether that signal should widen is a separate, named decision the report
deliberately refuses to make quietly.

**The run also earned §11's lesson a tenth time — five instrument bugs, zero product bugs.**
An unclamped `LanguageModelError` description is eight lines of nested NSError and one of them
destroyed the table it landed in; `String(format:)` ignores a width specifier on `%@` here, so
every column ran together; the latency tail was built from calls that never served
("p90 2479ms" from nine errors); an empty latency list percentiles to zero and prints as a
triumph; and the POTENTIAL cohort swept in anti-invention rows. All five are fixed and the pure
half is pinned in `FMPrimitivesTests`, which is the durable answer — a scorer that only runs on
the two device sittings a campaign gets is a scorer nobody is watching. What the run got RIGHT
is the more important half: the model never served, and the harness said `DEGRADED · served
0/9` and refused a decision rather than reporting the fallback's numbers under the arm's name.

`Instrument.runStamp` landed with it, so economics invariant 4 (**every eval report carries the
run stamp**) is now structural rather than a rule each new harness has to remember — the failure
mode being a GA number and a beta number sitting in the same table looking comparable.


## 2026-09-04 — Ramble economics: unlimited to the person, bounded for the machine

The rules are in `CLAUDE.md` (the *Ramble economics* capture bullet); this is the why, the
numbers, the metrics and the workstreams. Source: the team memo of 2026-09-04 (three threads —
economics · Firebase-not-backend · Apple FM re-evaluation), three rounds of review, and the
plan file that came out of them. **Build state at writing: App Check not wired, cloud usage
not metered, Remote Config absent, model `gemini-3.7-flash`.** Everything below that reads as
present tense about the meter, the stamp or the switch is a rule that binds the work, not a
description of the tree.

### The architecture in one picture

```
RAMBLE
  ↓
deterministic local read
  ↓
CaptureRoute (deterministic spend decision)
  ├── acceptable → Tasks
  └── escalate
        ↓
     semantic engine            ← today: Gemini · candidate: Apple FM primitives
        ↓
     artifact
        ↓
     deterministic validator    ← today: AppBrain.grounded + CaptureEscalation
        ├── accept → Tasks
        └── reject → next escalation, or the safe fallback

every cloud call → token receipt → cost model → day ledger → run/config provenance → observable economics
```

Three sentences carry the whole design. **The system optimizes where inference happens, not
whether inference happens** — the question is never "Gemini or Apple" but *what is the
cheapest architecture that preserves the capture contract*. **Models produce artifacts;
deterministic validators decide whether an artifact is acceptable** — escalation is the
validator's negative result, never a model's confidence (the deleted confidence gate, above,
is what the alternative looks like). **False accept is the critical error; false reject is an
efficiency error** — a validator is tuned for zero or near-zero false accepts first, then for
fewer false rejects.

### The twelve invariants

1. **No visible usage quota.** No counter, credit, "remaining" or "AI unavailable" string
   reaches a user surface. `DataBoundary`'s three sentences stay the only cloud copy.
2. **Audio never leaves the device** (on-device `SpeechTranscriber`). Transcript text leaves
   only on the escalation path `CaptureRoute` authorizes (`transmitsRawCapture`, one case),
   and the on-device posture outranks the router.
3. **Routing is deterministic; a model never decides whether to spend money.** A model's
   self-reported confidence never triggers a call, on any engine.
4. **Cloud failure never exposes infrastructure mechanics.** Breaker open, quota hit, model
   retired, App Check rejected: the capture returns the local artifact already in hand;
   where there was none (`emptyRead`, the conversation guard's empty answer) it follows the
   existing safe fallback — the canvas with the words and *Keep it as one task*. This is
   sound because `CaptureEscalation` is escalate-only by design: a reason means "this read
   could be better upstairs", never "this read is invalid"; the local read is always cards
   the person edits, and a wrong escalation costs one call, never the words.
5. **Every cloud call produces token and cost telemetry**, on the receipt and in the day
   ledger. Dollars are computed at read time from a rate card — never stored, never shown
   outside DEBUG.
6. **Every evaluation is reproducible from its run stamp**: app build · OS · device · model
   · instruction fingerprint · workload-specific configuration fingerprint.
7. **No model or configuration reaches production without an accuracy + latency evaluation
   on device. Quality and latency are gates; cost is the optimizer; a human approves.**
8. **Quality metrics are corpus-defined; cost metrics never determine correctness.** An arm
   cannot become "successful" by changing the evaluator, relaxing labels, or trading
   correctness for spend. Quality floors are fixed for the duration of a campaign; changing
   one, in either direction, is a separate, named decision and invalidates every comparison
   it touches.
9. **No silent semantic drift.** A promotion requires a new evaluated (model · version ·
   config) stamp; changing the model, prompt contract, schema or validator invalidates prior
   claims. "3.8 passed Campaign 4" means *3.8 at config fingerprint X passed*.
10. **Remote Config may change operational parameters, never semantic routing invariants** —
    kill switches and an allow-listed model name; never floors, thresholds, correctness gates.
11. **Apple FM stays eligible for promotion after every major OS/model release**, and a
    conclusion about it is always stated with the runtime it was measured on.
12. **The cloud provider stays replaceable behind the engine seam.** The durable contract is
    the same semantic capture contract and deterministic validation on every engine (input ·
    output · grounding · resolver expansion); engine-specific prompting may differ once a
    measurement gives a reason. Today the two arms run the same code — a property worth
    keeping until then, not the invariant itself.

### The unit economics (illustrative — production cost derives from measured usage)

Rate card: Gemini 3.8 Flash on the Gemini API, **$0.75 / M input · $3.75 / M output through
2026-12-31, doubling to $1.50 / $7.50 on 2027-01-01** (Google AI for Developers pricing page,
read 2026-09-04; Batch/Flex half, Priority 1.8×; the Agent Platform path prices differently).
The memo's shape — ~1,500 input + ~500 output tokens per cloud capture — gives **~0.3¢ per
cloud capture** at intro rates. Two things make that a guess until WS1 lands: the production
instruction block alone is ~1,861 tokens (so real input is likely higher), and thinking
tokens bill as output (the bridge folds `thoughtsTokenCount` into `output.totalTokenCount`).

| User | Cloud captures / day | Monthly | Intro card | 2027 card | 3× tokens, 2027 |
|---|---|---|---|---|---|
| Light | 5 | 150 | ~$0.45 | ~$0.90 | ~$2.70 |
| Average | 15 | 450 | ~$1.35 | ~$2.70 | ~$8.10 |
| Engaged | 30 | 900 | ~$2.70 | ~$5.40 | ~$16.20 |
| Power | 60 | 1,800 | ~$5.40 | ~$10.80 | ~$32.40 |
| Extreme | 100 | 3,000 | ~$9.00 | ~$18.00 | ~$54.00 |

Those rows assume every capture goes to the cloud. **The real equation is `cost per Ramble =
cloud escalation rate × cost per cloud capture`** — on the authored corpus 1 of 47
unstructured cases escalates today, so the system cost is a small fraction of the table.
Internal targets, at the **2027 card**: average **< $2 / user / month**, p95 **< $8**, p99
**< $20**, abuse investigation **> $50**. Nowhere but the DEBUG diagnostics card and here.

### The metrics (all DEBUG / eval only), kept in families so none can be gamed through another

| Family | Metric | Definition |
|---|---|---|
| Quality | Ramble success rate | cases where the draft count matches the label AND every labeled field holds ÷ cases |
| Quality | **Correct local resolution rate** — the strategic number | **successful Rambles accepted without a cloud call ÷ all labeled Rambles.** Eval-only (live usage has no oracle and reports no proxy). *"What percentage of Rambles can we correctly resolve without spending a cloud dollar?"* — Campaign 5's headline |
| Task quality | precision · recall · false splits · false merges | per-draft against labels; split = drafts > expected, merge = drafts < expected |
| Efficiency | local share · cloud escalation rate · cloud avoidance · tokens avoided | local share = stayed local ÷ all (says nothing about correctness; never a stand-in for the row above); cloud ÷ all; local × measured mean tokens per cloud capture (an estimate, labelled) |
| Validator safety | false accept rate · false reject rate | accept on a wrong artifact ÷ wrong artifacts (critical); reject on a correct artifact ÷ correct artifacts (an unnecessary call) |
| Economics — cloud arm | cost / cloud capture · cost / successful cloud Ramble · tokens / cloud capture | measured usage × rate card |
| Economics — system | cost / all Rambles · cost / successful Ramble | cloud-arm cost × escalation rate — what the architecture actually costs |

Latency stays in `CapturePerformanceContract` (per tier, `settled p90`) and is a gate beside
quality. **Decision hierarchy for any promotion: (1) quality floors, (2) latency floors,
(3) among survivors the lowest cost, (4) a human approves.** The report prints a GATES line
and an OPTIMIZER line separately so nobody reads "cheapest" as the criterion.

### Protection is three layers, none of them in the interface

1. **Normal use — unlimited.** No counter, no warning, no token language.
2. **Invisible abuse protection — the console.** App Check (App Attest + DeviceCheck fallback,
   limited-use tokens; enforcement is mandatory 2026-11-02 and cannot be undone), a per-user
   rate limit (**60 RPM to start** — one number for the whole project, shared with the Advisor
   and any retry; tightened after receipts show legitimate burst percentiles; never an
   entitlement), AI monitoring (100% trace sampling through Campaign 4, then 10%).
3. **Infrastructure protection — the switch.** A **$20 budget alert** on the dev project; the
   emergency control is the Remote Config kill switch plus the in-app `CloudHealth` breaker.
   A hard spend stop is NOT assumed from a budget — whether the Cloud budget can pause the
   API is verified separately before any production traffic. `CloudBudget`'s daily cap stays
   what it was: a runaway backstop on the Advisor, not a capture control (the 08-22 reversal
   above still holds).

### Positions — deferred and refused, with reasons

- **Firebase Auth** — deferred to Phase 5 (sync brings identity). App Attest proves the
  request came from this app on a real device, and the console's per-user quota needs no uid.
- **Server-side prompt templates / template-only mode** — **deferred, not refused.** Enforce
  only once the cloud contract can be versioned and kept semantically equivalent to the
  on-device contract (invariant 12); Firebase's `GeminiLanguageModel` bridge (12.19, public
  preview) has no template path, and template-only mode is Preview and project-wide. Re-evaluate after
  Campaign 4.
- **A frontier tier behind Flash** — not now. One provider slot is test-pinned and the
  per-ramble `ReasoningBudget` (nil → light → moderate → deep, mapped by the bridge onto
  Gemini's low / medium / high) is already the escalation dial within one model. Tripwire:
  a named class of captures fails on *every* 3.8 arm in Campaign 4.
- **Per-user cost accounting in the app** — not built. The console meters the project; the
  app meters the call.
- **A visible quota of any kind** — refused (guardrails, *Things We Refuse to Build*).
- **Model lifecycle** — candidate → evaluated → production → deprecated → retired.
  `GeminiProvider.allowedModels` is an explicit allow-list (first entry `gemini-3.8-flash`);
  Remote Config can only select from it, so it cannot deploy an unevaluated model.
- **Apple FM** — *Apple Foundation Models remain a candidate for synchronous Ramble
  primitives. Current beta measurements are baseline evidence only; production routing is
  reopened after GA evaluation.* Campaign 5 may conclude 12% or 99% coverage; any routing
  change is a human decision over the report.

### What the tree already had (the memo asked for it; nothing to build)

Device-first routing with six named escalation reasons and zero authored false-keeps; the
escalation verifier as a validator over ANY read; the reasoning-level dial (the Firebase
bridge maps `.light/.moderate/.deep` → `low/medium/high`; capture sends nil below the depth
floors and `.moderate` above); `CloudHealth` on 429; the Advisor's daily cap;
`IntelligenceLedger.cloudCallsToday`; local share and escalation mix in
`CapturePerformanceReport`; the per-capture receipt; the single-object FM primitive
(`PrivateCaptureEngine`); one engine with a `SessionSource`; the `Instrument` bracket; the
quarantined real corpus; `captureNeverBlocks`.

### The workstreams (steps in the plan file; order WS0 → WS1 → WS3 → WS4 → WS2)

- **WS0 — attestation, quotas, model (deadline 2026-11-02).** `FirebaseAppCheck` linked;
  `AppCheckSetup.install()` before `configure()` inside the unit-test guard; the debug
  factory on the SIMULATOR (not `#if DEBUG`), App Attest + DeviceCheck fallback on device;
  `useLimitedUseAppCheckTokens: true`; the App Attest entitlement; `gemini-3.8-flash` behind
  the allow-list, proven by one served call (`-CaptureCompare -WithCloud`, `providerCalls 1`);
  console: register, enforce only after the served call, 60 RPM, $20 alert, monitoring.
- **WS1 — meter · reproducibility · safety.** (a) `TokenUsage` (billing-neutral: what the
  provider reported) read from `Response.usage`, every stream `Snapshot.usage`, and the
  session's cumulative usage on the salvage path; four additive optionals on
  `CaptureRunTelemetry` (no version bump); per-feature sums in `ModelMetrics`, the day
  counter in `IntelligenceLedger` (it owns the day clock — two day clocks would disagree
  across midnight); `ModelPricing` as a pure rate-card table that owns the cached-token
  policy; the DEBUG `cloud economics:` line in Settings and the tokens/cost rows on the
  Activity receipt. (b) `RunStamp` — build · OS · device · model · SHA-256 instruction
  fingerprint · **per-workload** configuration fingerprint (an Advisor switch must not
  re-key a Ramble evaluation) — printed by every harness header. (c) Invariant 4 as tests:
  a 429 with a local artifact in hand returns that artifact; a 429 on `emptyRead` lands on
  the canvas with the words; a denylist grep over user-facing strings finds no `quota`,
  `remaining`, `AI unavailable`, `rate limit`, `credits`, `budget`.
- **WS3 — Campaign 4, the cloud arm measured.** Five arms on 3.8 — production policy · no
  thinking · light · moderate · no thinking + the tier300 instructions with the minimal
  schema — over both corpora (5 × 78 = 390 calls, inside one day's cap, ~$1–2 intro). Per
  arm: quality (success rate, P/R, splits, merges, served ratio, settled p90), tokens,
  cloud-arm cost and system cost at the corpus's escalation rate; then GATES (arms holding
  every floor and latency) and OPTIMIZER (lowest system cost among survivors — promotion
  requires review). Feeds: the production `captureDepth` default (hard-coded from the
  winning arm; Remote Config only an emergency override, later), the cloud arm's instruction
  tier (shipping the minimal schema means resolver backfill, not a prompt swap), the
  server-template re-evaluation.
- **WS4 — Campaign 5, Apple FM on the iOS 27 GA runtime, four primitives.** Baseline row
  archived first (below). P-A **Segment** on the under-segmented cohort — the rows that force
  escalation today — scored on count, boundary precision/recall, assignment accuracy and
  over/under-segmentation against deterministic `Segmentation`; P-B **Extract** (Q1 re-run);
  P-C **Match** against the ≤12-line candidate package on a new ~20-pair fixture; P-D
  **Artifact Acceptance** — FM's artifact through the EXISTING validator, scored as a 2×2
  with false accept printed first. Headline: the correct local resolution rate, today and
  projected. If P-A + P-D hold within ~2s, one arm in `CaptureFlow.plan` (`underSegmented`
  → on-device segment pass → the same validator → Gemini only on reject); if not, nothing
  changes and the table says why.
- **WS2 — Remote Config.** WS2a (may be pulled forward): `cloud_capture_enabled`,
  `cloud_advisor_enabled`, `cloud_model_name` (allow-listed), cache-only reads on the routing
  path, `CloudModel.isReachable(for: .capture / .advisor)`, the privacy copy following the
  switch. WS2b, only after the campaigns: `capture_thinking_level` as an emergency override
  restricted to measured values. Never floors, thresholds or the conversation-guard ratios.

### Runtime rows — the FM baseline every later campaign is compared against

| Runtime (stamp) | Configuration | p50 | p95 | Notes |
|---|---|---|---|---|
| iOS 27 beta 8 · iPhone 15 Pro Max · 2026-08-29 | production instructions (~1,861 tok) + `TriageResult` array schema | 19.9 s | 37.1 s | Campaign 1: 62% output volume; `contextSizeExceeded` on a 251-char run-on |
| same | tier300 instructions + minimal schema | 4.5 s | — | Campaign 2: seg 5/5 incl. case 50; pre-first-token ~1.5 ms/instruction-token over a ~1.4 s fixed base |
| same · 2026-08-30 | zero instructions (Apple's intercept) | 1.34 s pre-first-token | — | Campaign 3 Q3: the 500 ms p50 gate is runtime-bound out of reach on this runtime |
| same | single-object `PrivateCaptureRead`, ~55-tok instructions | 1.8 s | 2.4 s | Campaign 3 Q1: seg 42/43, grounding 43/43, p99 3.1 s — the shipped Private Capture envelope |
| iOS 27.0 (beta) · iPhone16,2 · 2026-09-12 13:53 · config 90271fd1 | **boundary pass** (`-FMPrimitives`): 17 rows, served 17/17 | 1.41 s | 2.60 s (p95) | **FALSE ACCEPT 0 on both cohorts, precision 100%**; case 50 (nine outcomes) cut 9/9; exact 6/9 on POSTURE, 1/3 on REACHABLE — the two REACHABLE misses are FM answering "one thing" on the adversarial pairs (`no-gain`, correctly refused); p95 96 ms over the ceiling on the single nine-outcome row. **Verdict: hold** (two gates fail). The pre-GA baseline row. |
| same · 13:52 · config 7f4bc032 | **duplicate judge** (`-DuplicateSweepEval`): 20 pairs, served 20/20 | 1.62 s | 1.88 s (p90) | **FALSE MERGE 0**; every near-miss 0.50, every duplicate 0.90–1.00, gap 0.40 — SEPARABLE, threshold has room. BUT the prefilter could not run: **no sentence embedding on the phone** (see below). |
| **iOS 27.0 GA (24A437)** · iPhone16,2 · 2026-09-17 · config 90271fd1 | **boundary pass** (`-FMPrimitives`): 16 rows, served 16/16 | 1.31 s | 2.46 s (p95) | **FALSE ACCEPT 0 on both cohorts, precision 100%/100%**, POSTURE exact 7/8, correct-local-resolution 89% → 91% projected (+1pt, 1 of 3 reachable transmissions avoided). The morning's run had read FALSE ACCEPT 1 and precision 0% on case 50 — an INSTRUMENT bug: the scorer took `max(fragments, drafts.count)` against the intent count, so the resolver's fan-out of "walk my dog monday and tuesday" into two drafts marked the model's exactly-right 8-part cut as 9. Printing the anchors on the false-accept row is what exposed it (a prompt tweak tried first moved nothing and was reverted). Verdict HOLD on ONE gate — exact fragments 1/3 on the REACHABLE cohort, where the model answers "one part" (no-gain) for "text mom about sunday and the dentist about thursday" and "dentist on thursday and the vet on friday" — a recall question on three rows, not a safety one **Later that day, after the dated-clause split and the gain guard:** REACHABLE cohort 1 row (case 50) exact 1/1; POSTURE 8/8 exact with 7 stand-asides (local already right); POTENTIAL 3/3; precision 100%/100%; correct-local-resolution **92%** today, 93% projected; p50 1.36 s. HOLD on p95 alone (2.66 s — with one reachable row, p95 is case 50) |
| same · 13:12 · config 7f4bc032 | **duplicate judge** (`-DuplicateSweepEval`): 20 pairs, served 20/20 | 1.51 s | 1.65 s (p90) | **FALSE MERGE 0**, merge 10/10, left 10/10 — and the prerequisite near-miss ("passport photos") the beta merged at 1.00 now scores 0.50; gap 0.40, SEPARABLE. The prefilter still admits 0/10 real pairs: in the store's `1 − √(2 − 2cos)` unit, real duplicates read sim 0.00–0.18 and near-misses 0.03–0.57 — the embedding does not separate them, the judge does. The floor's 09-12 blocker (a judge that merges a prerequisite) is lifted on this corpus |
| same · 13:16 · config (tier300/800/floor) | **Campaign 2 re-run** (`-FMDiagnostics`, 5 cases): contextSize **4096** | arm C 1.99 s pre / 5.64 s total | 10.4 s (p95) | **YELLOW**: unguided floor (arm F) 1.58 s pre-first-token, up from 1.34 s on beta 8 — the 500 ms gate stays runtime-bound; production arm A 5.8 s pre / 22.3 s total and one `contextSizeExceeded`; due accuracy on minimal-schema arms 6–12/19. The simulator read GREEN (816 ms) the same morning on Mac silicon with contextSize 8192 — never a phone number |
| same · 13:2x · config (quickCapture 61 tok) | **Private Capture envelope** (`-QuickCaptureDiag`): 44 atomic × 2, valid 86/88 | 1.95 s | 2.38 s (p95) · 3.14 s (p99) | **the shipped promise HOLDS** (p50 <2 / p95 <2.5 / p99 <3.2); seg 43/43, title 43/44, due 42/44, grounding 43/43; live path perceived p50 1.67 s / p95 2.20 s, fallback 0/19. **New at GA: the guardrails refuse "file the taxes" (`guardrailViolation`, both reps) and "so basically I need to renew the insurance" (`refusal`)** — the deterministic tail catches both; the north-star gates (500/1500/3000) still miss. FM detector precision 44% / recall 100% — the deterministic detector still wins |
| same · 13:43 | **household chat** (`-HouseholdChatEval`) | 1.52 s | 2.16 s (p90) | 20/20 labeled cases hold (14 floor, 6 model), served 6/6, grounding flags 0 |
| same · 14:2x · config 92fe42f0 | **Advisor judgment** (`-AdvisorDiagnostics`, on-device arm, 3 runs per fixture) | 3.6–8.4 s per reading | — | agreement 5/8 fixtures; `capabilities.reasoning=false` still (the `.deep` ask is ignored, not refused). Every miss is the same direction, 3/3 consistent: the GA model returns a move where the fixture expects `advise`/nothing — `createSteps` for "in progress, ready to continue", `decide` for "stalled with no other signal" — and `advise` for the broad task that expects `createSteps`. A bias toward acting, not noise; `ValidatedReading` passes these because they are well-formed. The cloud ceiling is unmeasured (`-AdvisorBenchmark` refuses to score without `-WithCloud`) |
| same · 16:1x · config (quickCapture 61 tok) | **Private Capture, production shape** (`-QuickCaptureDiag -QuickRealOnly`, 19 real single thoughts): cold prewarm→finish vs speculate→2.5 s window→finish | cold 1.31 s · **after the window 5 ms** | cold 1.75 s · **after the window 8 ms** | 19/19 speculative, 19/19 captured, title 18/19, due 19/19. The engine's silence-window speculation had never run in the product — `ComposerView` built a fresh engine at submit — so every private capture paid the cold read; the composer now holds one engine for the sheet's life. Simulator shows the same shape (1–6 ms) |
| same · 17:23 | **cloud arm through Firebase 12.19** (`-CaptureCompare -WithCloud`, one call, twice) | — | — | The chain is PROVEN from the phone — config, App Check token, `GeminiLanguageModel`, a typed Gemini answer back — and the answer both times was `INTERNAL, HTTP 500: This model is currently experiencing high demand … try again later` from `gemini-3.7-flash`. Not our failure; now classified `.refused` so the breaker opens on the first, and the deterministic read serves. The on-device tripwire arm read the same 73 chars in 15.2 s |
| same · 15:0x · config e46f3298 | **Ramble** (`-RambleEval`, no cloud) — deterministic arm | 0–2 ms | 3 ms | every floor held (seg 98%, real-utterance seg 85%, false-keeps 0/46, 98% kept local) |
| same | **Ramble — on-device(direct)** (production instructions + `TriageResult`, the tripwire arm OUT of the capture chain): 52 cases, served 71 calls, timedOut 0, failed 7 | 13.2 s | 35.9 s | seg 83% · judgment 93% · due 93% · owner 0/2 — every floor broken, as on beta 8 (19.9 s / 37 s): a little faster, still not a capture engine. Two earlier attempts wedged at case 34 for 15 min with the deadline never firing — that was `ModelDeadline.race` awaiting its child on the main actor, fixed the same day, not the model |
| same · 15:37 | **capture chain** (`-CaptureDiagnostics`, 648-char dump, cloud guarded) | 155 ms wall | — | 3 provisional drafts, contract simple p50 733 ms pass. The continuous session (`CaptureConversation`, deferred) fails turn 2 with `contextSizeExceeded (4734 tok in a 4096 window)` — on a 4096-window phone the per-turn design overflows on the first continuation |

The gates (p50 <500 ms / p95 <1.5 s / p99 <3 s) stay the tripwire; the renegotiated Private
Capture envelope (p50 <2 s / p95 <2.5 s / p99 <3.2 s) stays the shipped promise. The earlier
"FM is the intended primary engine" framing (2026-08-29) was retired on 2026-09-04: a
candidate, not a probable winner, and the next facts are empirical — does 3.8 meet the cloud
floors, what does a successful Ramble cost, what share resolves correctly without the cloud,
and what does GA do to the primitive envelope.
