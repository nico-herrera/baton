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

@Test func consensusUsesTheComplementaryEnginesConfidence() {
    func hypothesis(_ engine: String, _ words: [TimedWord]) -> EngineTranscript {
        EngineTranscript(
            engine: engine,
            model: "\(engine)-model",
            version: "1",
            settings: [:],
            text: words.map(\.text).joined(separator: " "),
            language: "en",
            audioDurationMs: words.last?.endMs ?? 0,
            processingDurationMs: 1,
            words: words,
            segments: TranscriptSegmentation.segments(from: words),
            diagnostics: [:],
            context: EngineContextEvidence(requestedTerms: [], detectedTerms: [], appliedTerms: [])
        )
    }
    let primary = hypothesis("parakeet", [
        TimedWord(text: "Patchthrough", startMs: 100, endMs: 600, confidence: 0.95),
        TimedWord(text: "ships", startMs: 700, endMs: 1_000, confidence: 0.55),
    ])
    let secondary = hypothesis("apple-speech", [
        TimedWord(text: "patchthrough", startMs: 120, endMs: 620, confidence: 0.70),
        TimedWord(text: "ships.", startMs: 710, endMs: 1_010, confidence: 0.96),
    ])

    let result = TranscriptConsensus.combine(primary, secondary)

    #expect(result.text == "Patchthrough ships.")
    #expect(result.words[0].startMs == 100)
    #expect(result.words[1].endMs == 1_010)
}

@Test func maxAccuracyConsensusIsEvidenceGated() {
    #expect(!QualityProfile.safeDefault.consensusQualified)
    #expect(!QualityProfile.safeDefault.maxAccuracyAvailable)
    #expect(QualityProfile.safeDefault.engines(configured: "auto", mode: .standard) == ["parakeet"])
    #expect(QualityProfile.safeDefault.engines(configured: "auto", mode: .maxAccuracy) == ["parakeet"])
}

@Test func maxAccuracyAvailabilityRequiresAQualifiedReleaseProfile() {
    let profile = QualityProfile(
        standardEngine: "parakeet",
        maxAccuracyEngines: ["apple-speech"],
        consensusQualified: false,
        calibration: [:],
        evidence: .init(
            releaseQualified: true,
            dualEngineRelativeWerImprovement: nil,
            consensusNoCategoryRegression: nil
        )
    )

    #expect(profile.maxAccuracyAvailable)
    #expect(profile.engines(configured: "auto", mode: .maxAccuracy) == ["apple-speech"])
}

@Test func consensusDoesNotAlignIdenticalWordsAtUnrelatedTimes() {
    func hypothesis(_ engine: String, _ word: TimedWord) -> EngineTranscript {
        EngineTranscript(
            engine: engine, model: engine, version: "1", settings: [:], text: word.text,
            language: "en", audioDurationMs: word.endMs, processingDurationMs: 1,
            words: [word], segments: TranscriptSegmentation.segments(from: [word]), diagnostics: [:],
            context: EngineContextEvidence(requestedTerms: [], detectedTerms: [], appliedTerms: []))
    }
    let early = hypothesis("parakeet", TimedWord(text: "yes", startMs: 0, endMs: 300, confidence: 0.9))
    let late = hypothesis("apple-speech", TimedWord(text: "yes", startMs: 8_000, endMs: 8_300, confidence: 0.9))

    let result = TranscriptConsensus.combine(early, late)

    #expect(result.words.count == 2)
}

@Test func formattingIsDeterministicWithoutRewritingWords() {
    #expect(TranscriptSegmentation.normalizedText("  Ship   it  ,  now ! ") == "Ship it, now!")
}
