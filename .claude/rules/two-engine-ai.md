---
paths:
  - "Project-Ezra/AI/{AIEngine,FoundationModelsEngine,HeuristicEngine,AppBrain,EmbeddingStore,ContextRetrieval,CaptureSessionPool}.swift"
---

<!-- Moved verbatim from CLAUDE.md on 2026-10-02 (lossless move). Loads only when Claude reads a matching file. Change a rule here AND in docs/decisions.md. -->

## Two-engine AI

`AI/AIEngine.swift` is the seam; `FoundationModelsEngine` (on-device / cloud by `SessionSource`) and `HeuristicEngine` (deterministic) both emit `[TaskIntent]`; `AppBrain` selects at launch and degrades to the heuristic. **The simulator may run the REAL on-device model** (it follows the host Mac's Apple Intelligence) — read the DEBUG footer, never assume; the sim cannot verify off-device behaviour. **`EmbeddingStore.sentenceEmbedding` is a RETRYING accessor, never a `static let`** (2026-09-12): `NLEmbedding.sentenceEmbedding(for:)` returns nil on the FIRST call in a process and succeeds later — on the phone AND the simulator — and a `static let` froze that nil at `prewarm` for weeks (0 `EmbeddingCache` rows against 70 tasks; retrieval lexical-only; the sweep never judged a pair). A success is cached, a nil is re-asked, `settle()` for callers comparing two retrievals, `EmbeddingStore.statusLine()` is the meter in the diagnostics card. *A `static let` over a platform lookup that can transiently fail is a frozen failure; a graceful degrade with no meter is a feature that can be off for a month.* Reasoning: `docs/capture.md`. Unit tests always see the heuristic (`onDeviceAvailable()` is false under XCTest). Keep both engines consistent through `AutonomyPolicy.tier` + `IntentResolver` (incl. `applyRules`). `TriageContext` carries personalization, roster (`ResolvePersonTool`), candidates (`ContextRetrieval`, cap 12 — the ONLY ids the model may cite) and suppressions; `CaptureSessionPool` prewarms single-use sessions; edge proposals are tiered by destructiveness (`duplicateOf` 0.85/0.5, `childOf` ≥0.5).
