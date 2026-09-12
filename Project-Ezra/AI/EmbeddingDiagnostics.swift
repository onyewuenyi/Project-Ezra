//
//  EmbeddingDiagnostics.swift
//  Project-Ezra
//
//  **Is there a sentence embedding on THIS device, and if not, why?** (`-EmbeddingDiag`)
//
//  On 2026-09-12 the dogfooding phone turned out to have 0 `EmbeddingCache` rows against
//  70 tasks: `NLEmbedding.sentenceEmbedding(for: .english)` had been nil on the device for
//  the whole dogfooding period, so semantic retrieval was lexical-only and the duplicate
//  sweep had never judged a pair. `EmbeddingStore` had assumed nil meant "the simulator".
//  Nothing could see it, because the degrade is graceful and unmetered.
//
//  This seam asks every question that distinguishes the possible causes, on the device
//  where the answer lives, and prints them as facts — it does not guess a fix. The three
//  hypotheses it separates: the legacy sentence embedding is simply gone on this OS; the
//  asset exists but is not downloaded; the modern `NLContextualEmbedding` is the supported
//  path and needs an explicit asset request. Whichever it is, the fix follows from the
//  printout rather than from a Mac.
//

#if DEBUG

import Foundation
import NaturalLanguage

enum EmbeddingDiagnostics {

    static func runIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-EmbeddingDiag") else { return }
        if args.contains("-EvalToFile") { Instrument.teeStdoutToDocuments("embedding-report.txt") }
        let markers = Instrument.Markers(name: "EMBEDDING DIAG")
        print(markers.begin)
        print(Instrument.runStamp(model: "n/a", configuration: "NLEmbedding+NLContextualEmbedding"))

        // 1. The legacy API the store uses today.
        let sentence = NLEmbedding.sentenceEmbedding(for: .english)
        print("NLEmbedding.sentenceEmbedding(.english): \(sentence == nil ? "NIL" : "present")")
        if let sentence {
            print("  revision \(sentence.revision) · dimension \(sentence.dimension) · languages \(sentence.language.map(\.rawValue) ?? "?")")
            let vector = sentence.vector(for: "renew passport")
            print("  vector(for: \"renew passport\"): \(vector == nil ? "NIL" : "\(vector!.count) dims")")
        }
        print("NLEmbedding.currentRevision(.english): \(NLEmbedding.currentRevision(for: .english))")
        print("NLEmbedding.supportedRevisions(.english): \(NLEmbedding.supportedRevisions(for: .english).map { String($0) }.sorted().joined(separator: ","))")

        // 2. The word embedding, as a control — if THIS is present and the sentence one
        //    is not, the sentence asset specifically is what is missing.
        let word = NLEmbedding.wordEmbedding(for: .english)
        print("NLEmbedding.wordEmbedding(.english): \(word == nil ? "NIL" : "present (dim \(word!.dimension))")")

        // 3. The modern path. iOS 17+; assets are requested explicitly.
        if let contextual = NLContextualEmbedding(language: .english) {
            print("NLContextualEmbedding(.english): present · identifier \(contextual.modelIdentifier) · revision \(contextual.revision) · dim \(contextual.dimension)")
            print("  hasAvailableAssets: \(contextual.hasAvailableAssets)")
            if !contextual.hasAvailableAssets {
                print("  requesting assets…")
                let result: String = await withCheckedContinuation { continuation in
                    contextual.requestAssets { availability, error in
                        continuation.resume(returning: "\(availability)\(error.map { " · error \($0)" } ?? "")")
                    }
                }
                print("  requestAssets → \(result)")
                print("  hasAvailableAssets now: \(contextual.hasAvailableAssets)")
            }
            do {
                try contextual.load()
                let embedded = try contextual.embeddingResult(for: "renew passport", language: .english)
                print("  load + embeddingResult: OK · \(embedded.sequenceLength) tokens")
            } catch {
                print("  load/embeddingResult FAILED: \(Instrument.oneLine("\(error)"))")
            }
        } else {
            print("NLContextualEmbedding(.english): NIL")
        }

        // 4. What the store believes, and what it has.
        print("EmbeddingStore.sentenceEmbedding: \(EmbeddingStore.sentenceEmbedding == nil ? "NIL" : "present") · revision \(EmbeddingStore.revision)")
        print("EmbeddingStore.computeVector(\"renew passport\"): \(EmbeddingStore.computeVector(for: "renew passport") == nil ? "NIL" : "OK")")
        print(markers.end)
    }
}

#endif
