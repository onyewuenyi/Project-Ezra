# Capture roadmap — the next two phases, and the gate in front of them

Written 2026-08-07, after the deep-dive program (audit waves 1–8) and the iOS 27
Foundation Models adoption tier landed. This records the two phases that are
PLANNED but deliberately not implemented, and why the device gate comes first.

## Superseded in part by the Ramble re-architecture (2026-08-11)

Ramble became a four-phase arc — quiet capture, a single orb while the model
works, one composed reveal, a ✓ receipt — and the live parse was deleted (see
`docs/PRD.md` §6 and the CLAUDE.md invariant). Two consequences for what follows:

- **The headline number changed.** Time-to-first-partial is no longer a product
  metric: nothing is rendered mid-generation any more, by design. Measure **time
  to trustworthy result** instead — submit → stable confirmation (`confirm Xms`
  in the DEBUG footer, with its `local`/`model` source), then enrichment
  separately. A faster first partial that the user never sees buys nothing.
- **Streaming is still worth having, for a different reason.** Partials feed the
  salvage path (a deadline hit reveals the last viable partial) rather than the
  screen. Phases A and B below are unaffected — both are about what the model
  can *reach*, not about when the user sees it.

## The standing device gate (blocks both phases)

Everything below assumes numbers only Charles's iPhone can produce
(`-CaptureDiagnostics`, phone unlocked for launch; build/install headless):

1. **Single-use baseline**: submit→confirm ms (and its source), `retr` ms,
   partial count, prompt tokens vs context size, drafts-at-deadline — the
   post-A1 numbers. (Was time-to-first-partial; see the note above.)
2. **Continuous A/B arm**: per-turn wall-clock / intents / prompt tokens for the
   three-snapshot run. The continuous session (`AI/CaptureConversation.swift`)
   becomes the composer's default **only** if its turns beat the baseline and the
   delta-turn contract holds (the model must return the complete updated list per
   turn — instructions demand it; only real generation proves it).
3. **New-model recheck**: iOS 27 shipped a NEW on-device model ("test your
   prompts"). The 20s/30s deadline evidence and the 648-char finding predate it —
   re-measure before trusting either.
4. **Two micro-checks**: `stream.collect()` redundancy after a drained stream;
   `CaptureSessionPool` hit rate across a chained burst.
5. **Voice-first feel**: level bars, silence ring, morph, transcript two-tone,
   keyboard hand-off.
6. **On-device eval**: run the RambleEval fixture set against the FM path (the
   harness is engine-agnostic by design) — per-field FM-vs-heuristic numbers.

## Phase A — Agentic capture (the open-set query tool)

**What**: replace the *pushed* candidate package (12 lines chosen before the
model sees anything) with a **pulled** one: an `OpenSetQueryTool` (`Tool`) the
model calls with a query phrase mid-generation; the tool answers from
`OpenTaskSnapshotCache` + `EmbeddingStore` with the same blended ranking
`ContextRetrieval` uses today, top-k, same `[uuid] title — facts` line contract.

**Why**: the pushed package is a bet placed before generation starts — it must
guess which neighbours matter from the raw text alone, capped at 12 for context
budget. A pull moves the decision to the moment the model is actually reasoning
about a specific line ("renew my passport" → query "passport"), spends context
only on demand, and scales past 12 candidates naturally.

**Prerequisites, in order**:
- The continuous session flips default (tool round-trips amortize inside a
  session; per-parse single-use sessions would pay them repeatedly).
- `ToolCallingMode` verified on device against the documented beta over-calling
  caveat (`PersonalContextTools.swift` header) — the tool ships with
  `.toolCallingMode(_:)` constrained and an `onToolCall` cap (throw past N calls
  per turn, surfacing as a labeled error, never a hang).
- **A4's embed-on-write index** becomes worth building here, not before: queries
  arrive at model cadence, so embedding must move off the query path (compute at
  task create/retitle in the background, LRU eviction replacing the cliff-fixed
  wipe). Sequencing A4 behind this phase keeps it roadmap-shaped instead of
  speculative.

**Invariant to preserve**: the resolver's anti-hallucination guard stays — tool
answers define the valid id set exactly as the pushed package did; suppression
filtering stays at the resolver.

## Phase B — Image capture (Vision OCR first) — **V1 SHIPPED 2026-08-08**

**V1 (shipped)**: an "Add a photo" affordance beside the mic (library-only —
`PhotosPicker` is out-of-process, zero new permissions); Vision OCR
(`AI/ImageTextExtractor.swift`, `.accurate` + language correction) feeds the
recognized text into the EXISTING text pipeline (segmentation → resolver →
confirm cards), so the whole downstream loop works unchanged, on-device AND on
the heuristic path. **Storage correction**: there is NO `Attachment` entity —
an earlier note here claimed one was confirmed in the schema; the schema is
frozen post-gen-10, and the shipped design is a container FILE
(`Models/CaptureImageStore.swift`) with the long-persisted `Capture.imageRef`
holding the filename. Provenance: voice > image > text; the thumbnail chip
restores on resume; discard is the one path that deletes the file.

**Fast-follows**: live camera (`NSCameraUsageDescription` + capture-session UI),
and V2 image-in-prompt with the Vision-provided tools (`OCRTool` /
`BarcodeReaderTool` — they live in the Vision framework, not FoundationModels;
verified absent from the FM swiftinterface) so the model reads layout a flat
OCR string loses (flyers, forms). Both device-verify-gated.

## Explicitly not planned

- **Commit-path pass consolidation** (`AppBrain.commit`'s seven passes): bounded,
  per-commit, no felt cost at current scale — measure first if commit ever lags.
- **F6-append** (per-delta `TextEditor` rewrite): inherent to the String binding;
  the listening state already swaps to a read-only surface while dictating.
