import Foundation
import FoundationModels
import Testing
@testable import Zeus

struct LocalRedactorTests {
    struct Sample: Decodable { let text: String; let `private`: [String] }
    @Test func syntheticPatternPrecisionAndRecall() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestFixtures/redactor/synthetic.json")
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: source))
        var expected = 0, found = 0, falsePositive = 0
        for sample in samples {
            let spans = LocalRedactor.patternSpans(sample.text)
            let result = LocalRedactor.replace(sample.text, spans: spans)
            for secret in sample.private { expected += 1; if !result.value.contains(secret) { found += 1 } }
            if sample.private.isEmpty { falsePositive += result.report.total }
        }
        let recall = Double(found) / Double(expected)
        let precision = Double(found) / Double(found + falsePositive)
        #expect(recall >= 0.95, "Synthetic pattern recall: \(recall)")
        #expect(precision >= 0.95, "Synthetic pattern precision: \(precision)")
    }
    struct FakeProse: ProseRedacting {
        func spans(in text: String) async -> [ProsePrivateSpan]? {
            [.init(text: "medical appointment", kind: .health), .init(text: "hallucinated value", kind: .secret),
             .init(text: "‹email›", kind: .name), .init(text: "secret", kind: .secret)]
        }
    }
    @Test func semanticPassOnlyAddsExactValidatedSubstrings() async {
        let result = await LocalRedactor(prose: FakeProse()).redact("A medical appointment. a@example.test secret")
        #expect(!result.value.contains("medical appointment"))
        #expect(!result.value.contains("a@example.test"))
        #expect(result.value.contains("‹email›")); #expect(!result.value.contains("hallucinated"))
        #expect(result.report.counts[.health] == 1)
        #expect(result.report.semanticEngine == .onDeviceModel)
        let oversized = await LocalRedactor(useOnDeviceModel: false).redact(String(repeating: "x", count: 129_000))
        #expect(oversized.value == "‹secret›")
    }
    @Test func payloadKeysAndValuesAreRedactedWithoutRawReport() async throws {
        let result = await LocalRedactor(useOnDeviceModel: false).redact(JournalPayload(description: "mail a@example.test",
            text: "pwd: synthetic-only", details: ["b@example.test": "c@example.test"]))
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!encoded.contains("@example.test")); #expect(!encoded.contains("synthetic-only"))
        #expect(result.report.total >= 4)
        #expect(LocalRedactor.luhn("4111 1111 1111 1111"))
        #expect(!LocalRedactor.luhn("4111 1111 1111 1112"))
    }
    @Test func nativeOnDevicePassWhenAvailable() async {
        guard case .available = SystemLanguageModel.default.availability else {
            print("SKIP LM2 on-device redaction: Apple Intelligence isn't available on this test host."); return
        }
        let result = await LocalRedactor().redact("A medical appointment for knee pain costs 4200 euros.")
        if result.report.semanticEngine != .onDeviceModel {
            print("LM2 native model declined/failed/busy: mandatory patterns + NLTagger fallback retained.")
        }
        #expect(!result.value.isEmpty)
        // Accuracy is measured separately: probabilistic output never replaces the mandatory deterministic pass.
    }
}
