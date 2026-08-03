import Foundation
import Testing
@testable import patchthrough

@Test func sharedEngineFixtureDecodes() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("schemas/fixtures/engine-transcript-v1.json"))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let transcript = try decoder.decode(EngineTranscript.self, from: data)

    #expect(transcript.engine == "fixture")
    #expect(transcript.words.count == 3)
    #expect(transcript.context.appliedTerms == ["Patchthrough"])
    #expect(transcript.segments.first?.words == transcript.words)
}

@Test func segmentationUsesNaturalBoundariesInsteadOfAWordCap() {
    let words = (0..<130).map { index in
        TimedWord(text: "w\(index)", startMs: index * 100, endMs: index * 100 + 50, confidence: 0.9)
    }
    let segments = TranscriptSegmentation.segments(from: words)

    #expect(segments.count == 1)
    #expect(segments[0].words.count == 130)
}

@Test func segmentationRespondsToPausesPunctuationAndConfidence() {
    let words = [
        TimedWord(text: "Ship", startMs: 0, endMs: 200, confidence: 0.95),
        TimedWord(text: "it.", startMs: 220, endMs: 500, confidence: 0.94),
        TimedWord(text: "Then", startMs: 600, endMs: 800, confidence: 0.95),
        TimedWord(text: "review", startMs: 820, endMs: 1_050, confidence: 0.94),
        TimedWord(text: "the", startMs: 1_060, endMs: 1_150, confidence: 0.93),
        TimedWord(text: "very", startMs: 1_160, endMs: 1_280, confidence: 0.94),
        TimedWord(text: "uncertain", startMs: 1_290, endMs: 1_600, confidence: 0.40),
        TimedWord(text: "result", startMs: 2_500, endMs: 2_800, confidence: 0.88),
    ]
    let segments = TranscriptSegmentation.segments(from: words)

    #expect(segments.map(\.text) == ["Ship it.", "Then review the very", "uncertain", "result"])
}
