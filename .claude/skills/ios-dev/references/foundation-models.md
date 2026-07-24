# Foundation Models (On-Device AI)

Apple's Foundation Models framework (iOS 26+) gives you the same on-device language model that powers Apple Intelligence, via a small Swift API. It is built for focused tasks: summarizing, extracting structure from text, classifying, tagging, and short generation. Everything runs on device: private, offline-capable, no per-call cost, no app-size bloat. The default model is tuned for practical device-scale tasks, not world-knowledge trivia.

`import FoundationModels` to use any of this.

---

## 1. Check availability first

The model isn't available on every device or in every state (older hardware, Apple Intelligence disabled, model downloading). Always branch on availability before building UI around it.

```swift
import FoundationModels
import SwiftUI

struct SmartCaptureView: View {
    private let model = SystemLanguageModel.default

    var body: some View {
        switch model.availability {
        case .available:
            captureUI
        case .unavailable(let reason):
            // Degrade gracefully: hide the AI affordance, fall back to manual entry,
            // or fall back to a cloud path. Don't show a dead button.
            ManualEntryView(reason: reason)
        }
    }
}
```

Treat the on-device model as an enhancement, not a hard dependency. Every AI affordance needs a non-AI fallback path.

---

## 2. Guided generation with @Generable and @Guide

The headline feature. Instead of prompting for text and parsing brittle JSON, you describe the output as a Swift type. `@Generable` makes the type a generation target; `@Guide` adds per-field constraints and descriptions that steer the model.

```swift
@Generable
struct ParsedTask {
    @Guide(description: "A short imperative title, e.g. 'Pick up Ezra'")
    let title: String

    @Guide(description: "ISO-8601 date/time if the text implies one, else nil")
    let dueDate: String?

    @Guide(description: "Any concrete sub-steps mentioned")
    let subtasks: [String]

    @Guide(.anyOf(["low", "medium", "high"]))
    let priority: String
}

func parse(_ note: String) async throws -> ParsedTask {
    let session = LanguageModelSession()
    let response = try await session.respond(
        to: "Extract a structured task from this note: \(note)",
        generating: ParsedTask.self
    )
    return response.content
}
```

You get back a typed `ParsedTask`, not a string you have to parse and validate. This is dramatically more reliable than asking for JSON in a prompt. Keep `@Generable` types small and composable; nest them rather than building one giant type.

---

## 3. Sessions, instructions, and state

A `LanguageModelSession` holds a transcript. Set persistent `instructions` to fix the model's role and reuse the session across related calls so it keeps context.

```swift
let session = LanguageModelSession(
    instructions: "You turn casual family notes into structured tasks. Be literal; never invent details."
)
```

Sessions are stateful: reuse one for a multi-turn flow, create a fresh one when context should reset. Cap input length to avoid overloading the model on very long text.

---

## 4. Streaming partial output

For responsive UI, stream snapshots of the structure as it generates rather than waiting for the whole thing, and animate the partial values in.

```swift
let stream = session.streamResponse(to: prompt, generating: ParsedTask.self)
for try await partial in stream {
    // `partial` is a PartiallyGenerated view of ParsedTask;
    // bind its fields into @State and let SwiftUI animate them filling in.
    self.draftTitle = partial.title ?? draftTitle
}
```

---

## 5. Tool calling

Let the model call your code mid-generation (look up the user's calendar, hit WeatherKit/MapKit, query a local store) and fold the result into its answer. Define a `Tool`, hand it to the session, and the model decides when to invoke it.

Use this when the answer depends on live app or device data the model can't know on its own. Keep tools narrow and deterministic; validate their inputs.

---

## 6. Performance and correctness notes

- Run generation off the interaction path and show a clear loading state; first call after launch can pay a model warm-up cost.
- The on-device model is small. Keep tasks focused and prompts concrete. If quality is poor, tighten `@Guide` descriptions and instructions before concluding the task needs a cloud model.
- Handle errors with user-facing messages, never a silent failure. Guided generation can still fail (unsatisfiable constraints, guardrail blocks); catch and fall back.
- Validate model output before persisting. Typed output reduces parsing bugs but does not guarantee semantic correctness (e.g. a plausible-but-wrong date).

---

## 7. On-device vs cloud: the decision

| Favor on-device (Foundation Models) | Favor cloud (e.g. Haiku-first, escalate to Sonnet) |
|--------------------------------------|----------------------------------------------------|
| Privacy-sensitive content (personal notes, health, family) | Content that's fine to send off device |
| Must work offline | Connectivity assumed |
| Latency-sensitive, frequent small calls | Occasional, latency-tolerant calls |
| Per-call cost matters at scale | Cost acceptable for the value |
| Focused task: parse, classify, tag, summarize, short gen | Broad world knowledge, long context, high-quality long-form reasoning |

Many production apps use both: on-device for fast, private, high-frequency parsing, and a cloud model for the occasional heavy lift. Make the split explicit in your architecture (e.g. an `IntelligenceService` protocol with on-device and cloud implementations) so you can route per task and test each path.
