import Foundation
import Testing

@testable import Project_Ezra

/// The sentence embedding is a RETRYING accessor, never a frozen first answer.
///
/// `NLEmbedding.sentenceEmbedding(for: .english)` returns nil on the first call of a
/// process and succeeds on a later one — on the dogfooding phone AND on the simulator
/// (this suite's first draft assumed the test host had no embedding; it does, after the
/// first nil). A `static let` captured that nil at launch and served it for weeks:
/// retrieval lexical-only, the duplicate sweep never judging a pair, 0 cached vectors
/// against 70 tasks. What is pinned here is the SHAPE in either world: a success is
/// cached and never re-asked; a nil is asked again.
@Suite("embedding availability")
struct EmbeddingAvailabilityTests {

    @Test("a success is cached; a nil is retried")
    func nilRetriedSuccessCached() {
        EmbeddingStore.resetForTesting()
        #expect(EmbeddingStore.sentenceEmbeddingAttempts == 0)
        let first = EmbeddingStore.sentenceEmbedding
        #expect(EmbeddingStore.sentenceEmbeddingAttempts == 1)
        _ = EmbeddingStore.sentenceEmbedding
        // Nil → asked again (2). Present → served from cache (still 1). A frozen
        // `static let` would be indistinguishable from the second case even when nil —
        // which is exactly the bug.
        #expect(EmbeddingStore.sentenceEmbeddingAttempts == (first == nil ? 2 : 1))
    }

    @Test("settle() leaves the store answering, when an embedding exists at all")
    func settleConverges() {
        EmbeddingStore.resetForTesting()
        let available = EmbeddingStore.settle()
        // Once settled, further accesses are cache hits.
        let attempts = EmbeddingStore.sentenceEmbeddingAttempts
        _ = EmbeddingStore.sentenceEmbedding
        #expect(available ? EmbeddingStore.sentenceEmbeddingAttempts == attempts : true)
        #expect(attempts <= 3)
    }

    @Test("the meter says the state in words")
    func meterIsHonest() {
        EmbeddingStore.resetForTesting()
        let line = EmbeddingStore.statusLine()
        #expect(line.hasPrefix("sentence embedding: "))
        #expect(line.contains("UNAVAILABLE") || line.contains("available"))
        #expect(line.contains("cached vector") && line.contains("lookup"))
    }
}
