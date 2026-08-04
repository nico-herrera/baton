import Foundation
import Testing
@testable import patchthrough

@Test func corpusBenchmarkUsesTheSharedRunShape() throws {
    let manifestData = Data(#"{"items":[{"id":"meeting-mic","audio":"mic.caf","context_terms":["Patchthrough"]}]}"#.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let manifest = try decoder.decode(BenchmarkCorpusManifest.self, from: manifestData)
    #expect(manifest.items.first?.contextTerms == ["Patchthrough"])

    let run = BenchmarkRun(
        runVersion: 1,
        platform: "macos",
        qualityMode: .maxAccuracy,
        models: ["speech-transcriber-system"],
        items: [.init(
            id: "meeting-mic",
            text: "Patchthrough",
            processingMs: 42,
            appliedVocabulary: ["Patchthrough"],
            words: [TimedWord(text: "Patchthrough", startMs: 0, endMs: 500, confidence: 0.9)]
        )]
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(run)) as? [String: Any])
    #expect(object["quality_mode"] as? String == "max_accuracy")
    let items = try #require(object["items"] as? [[String: Any]])
    #expect(items.first?["processing_ms"] as? Int == 42)
    let words = try #require(items.first?["words"] as? [[String: Any]])
    #expect(words.first?["start_ms"] as? Int == 0)
}
