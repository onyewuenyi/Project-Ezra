# Capture roadmap — the next two phases, and the gate in front of them

Written 2026-08-07, after the deep-dive program (audit waves 1–8) and the iOS 27
Foundation Models adoption tier landed. This records the two phases that are
PLANNED but deliberately not implemented, and why the device gate comes first.

## The standing device gate (blocks both phases)

Everything below assumes numbers only Charles's iPhone can produce
(`-CaptureDiagnostics`, phone unlocked for launch; build/install headless):

1. **Single-use baseline**: time-to-first-partial, `retr` ms, partial count,
   prompt tokens vs context size, drafts-at-deadline — the post-A1 numbers.
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

## Phase B — Image capture (Vision OCR first)

**What**: a photo/library affordance in the composer; V1 pipeline is a **Vision
OCR pre-pass** feeding the recognized text into the EXISTING text pipeline
(segmentation → resolver → confirm cards) — the deferred-list note already says
"Vision-OCR first", and it means the whole downstream loop (cards, corrections,
parking, eval) works unchanged, on-device AND on the heuristic path. The
`Attachment` entity is confirmed in the schema for keeping the source image.

**V2 (on-device only)**: image-in-prompt with the Vision-provided tools
(`OCRTool`, `BarcodeReaderTool` — they live in the Vision framework, not
FoundationModels; verified absent from the FM swiftinterface), letting the model
read layout/context a flat OCR string loses (flyers, forms). Gated on device
verification like every `@Generable`-adjacent change.

**UI shape**: the composer's footer gains an image affordance beside the mic
(both are "capture by other means"); a captured image shows as a thumbnail chip
above the field while its text streams into the normal live-parse loop. No new
confirm surface — the cards ARE the confirm, per the always-confirm invariant.

## Explicitly not planned

- **Commit-path pass consolidation** (`AppBrain.commit`'s seven passes): bounded,
  per-commit, no felt cost at current scale — measure first if commit ever lags.
- **F6-append** (per-delta `TextEditor` rewrite): inherent to the String binding;
  the listening state already swaps to a read-only surface while dictating.
