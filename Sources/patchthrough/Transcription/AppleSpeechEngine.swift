import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Apple's on-device SpeechTranscriber is an evidence candidate on macOS 26+.
/// It is never selected merely because it is built in; the quality profile
/// must name it after it passes the same Patchthrough corpus.
actor AppleSpeechEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case unavailable
        case unsupportedLocale
        case unsupportedOperatingSystem

        var description: String {
            switch self {
            case .unavailable: return "Apple SpeechTranscriber is unavailable on this device"
            case .unsupportedLocale: return "Apple SpeechTranscriber has no compatible English locale"
            case .unsupportedOperatingSystem: return "Apple SpeechTranscriber requires macOS 26 or newer"
            }
        }
    }

    nonisolated let name = "apple-speech"
    nonisolated let model = "speech-transcriber-system"
    private var transcriber: Any?

    func prepare() async throws {
        guard #available(macOS 26, *) else { throw EngineError.unsupportedOperatingSystem }
        guard SpeechTranscriber.isAvailable else { throw EngineError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw EngineError.unsupportedLocale
        }
        let module = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        transcriber = module
    }

    func transcribe(_ audio: URL, context: TranscriptionContext) async throws -> EngineTranscript {
        guard #available(macOS 26, *) else { throw EngineError.unsupportedOperatingSystem }
        guard let module = transcriber as? SpeechTranscriber else { throw EngineError.unavailable }
        let audioFile = try AVAudioFile(forReading: audio)
        let analysisContext = AnalysisContext()
        analysisContext.contextualStrings[.general] = context.vocabulary.prefix(64).map(\.text)
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.setContext(analysisContext)

        let collector = Task { () throws -> [SpeechTranscriber.Result] in
            var output: [SpeechTranscriber.Result] = []
            for try await result in module.results { output.append(result) }
            return output
        }
        let started = ContinuousClock.now
        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let results = try await collector.value
        let elapsed = ContinuousClock.now - started

        var words: [TimedWord] = []
        for result in results {
            for run in result.text.runs {
                let text = String(result.text[run.range].characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let time = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] ?? result.range
                let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                // A run can contain more than one token. Split only when the
                // framework did not provide finer attribute ranges, and share
                // the run's interval rather than inventing acoustic precision.
                let pieces = text.split(whereSeparator: \.isWhitespace).map(String.init)
                let start = CMTimeGetSeconds(time.start)
                let duration = max(0, CMTimeGetSeconds(time.duration))
                for (index, piece) in pieces.enumerated() {
                    let fraction = Double(index) / Double(max(1, pieces.count))
                    let next = Double(index + 1) / Double(max(1, pieces.count))
                    words.append(TimedWord(
                        text: piece,
                        startMs: Int((start + duration * fraction) * 1000),
                        endMs: Int((start + duration * next) * 1000),
                        confidence: confidence
                    ))
                }
            }
        }
        words.sort { $0.startMs < $1.startMs }
        let text = TranscriptSegmentation.normalizedText(words.map(\.text).joined(separator: " "))
        let requested = context.vocabulary.map(\.text)
        let detected = requested.filter {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let applied = VocabularyEvidence.acousticallySupported(requested, in: words)
        let audioDuration = Int(Double(audioFile.length) / audioFile.processingFormat.sampleRate * 1000)
        return EngineTranscript(
            engine: name,
            model: model,
            version: ProcessInfo.processInfo.operatingSystemVersionString,
            settings: ["preset": "time-indexed-with-alternatives", "on_device": "true"],
            text: text,
            language: "en",
            audioDurationMs: audioDuration,
            processingDurationMs: Int(Double(elapsed.components.seconds) * 1000),
            words: words,
            segments: TranscriptSegmentation.segments(from: words),
            diagnostics: ["runtime": "apple-speech-on-device", "result_count": String(results.count)],
            context: EngineContextEvidence(
                requestedTerms: requested,
                detectedTerms: detected,
                appliedTerms: applied
            )
        )
    }

    func release() async { transcriber = nil }
}
