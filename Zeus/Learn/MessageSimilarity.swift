import Foundation
import NaturalLanguage

struct MessageSimilarityResult: Sendable {
    var score: Double
    var engine: String
    var threshold: Double
}
protocol MessageSimilarityComparing: Sendable {
    func compare(_ incoming: String, with example: String) async -> MessageSimilarityResult?
}
/// Sentence embeddings are the local deterministic fallback; no remote inference or model download.
/// A cosine-distance similarity of 0.35 separates the recorded reminder paraphrases
/// from unrelated build/meeting/approval fixtures. Every hold records the threshold.
actor LocalMessageSimilarity: MessageSimilarityComparing {
    func compare(_ incoming: String, with example: String) async -> MessageSimilarityResult? {
        let language = NLLanguageRecognizer.dominantLanguage(for: incoming) ?? .english
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        let distance = embedding.distance(between: incoming, and: example)
        guard distance.isFinite else { return nil }
        return .init(score: max(0, min(1, 1 - distance)), engine: "naturalLanguage", threshold: 0.35)
    }
}
