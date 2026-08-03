import AVFoundation
import Foundation
import WhisperKit

/// Whisper Large v3 Turbo, compressed for Core ML. This complements
/// Parakeet's transducer with a sequence-to-sequence decoder, which is useful
/// for consensus because the engines fail differently.
actor WhisperKitEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case noResult(String)

        var description: String {
            switch self {
            case .notPrepared: return "WhisperKit used before prepare()"
            case .noResult(let file): return "WhisperKit returned no result for \(file)"
            }
        }
    }

    nonisolated let name = "whisperkit"
    nonisolated let model = "whisper-large-v3-turbo-coreml-626mb"

    private var kit: WhisperKit?

    func prepare() async throws {
        guard kit == nil else { return }
        let prepared = try await WhisperKit(WhisperKitConfig(
            model: "openai_whisper-large-v3-v20240930_626MB",
            modelRepo: "argmaxinc/whisperkit-coreml",
            verbose: false,
            prewarm: false,
            load: false,
            download: true
        ))
        guard let directory = prepared.modelFolder else {
            throw EngineError.noResult("downloaded model folder")
        }
        try ModelIntegrity.verify(.whisperLargeV3Turbo626MB, at: directory)
        try await prepared.prewarmModels()
        try await prepared.loadModels()
        kit = prepared
    }

    func transcribe(_ audio: URL, context: TranscriptionContext) async throws -> EngineTranscript {
        guard let kit else { throw EngineError.notPrepared }

        let prompt = Self.prompt(for: context.vocabulary)
        let promptTokens = prompt.isEmpty ? nil : kit.tokenizer?.encode(text: prompt)
        let options = DecodingOptions(
            language: nil,
            temperature: 0,
            usePrefillPrompt: false,
            detectLanguage: true,
            wordTimestamps: true,
            promptTokens: promptTokens,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )
        let groups = await kit.transcribe(audioPaths: [audio.path], decodeOptions: options)
        guard let results = groups.first ?? nil, !results.isEmpty else {
            throw EngineError.noResult(audio.lastPathComponent)
        }

        let words = results.flatMap(\.allWords)
            .map { word in
                TimedWord(
                    text: word.word.trimmingCharacters(in: .whitespacesAndNewlines),
                    startMs: Int(word.start * 1000),
                    endMs: Int(word.end * 1000),
                    confidence: Double(word.probability)
                )
            }
            .filter { !$0.text.isEmpty }
            .sorted { $0.startMs < $1.startMs }
        let text = TranscriptSegmentation.normalizedText(results.map(\.text).joined(separator: " "))
        let audioDuration: Int
        if let audioFile = try? AVAudioFile(forReading: audio) {
            let seconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            audioDuration = Int(seconds * 1000)
        } else {
            audioDuration = words.last?.endMs ?? 0
        }
        let processingMs = Int(results.reduce(0) { $0 + $1.timings.fullPipeline } * 1000)
        let sourceSegments = results.flatMap(\.segments)
        let requested = context.vocabulary.map(\.text)
        let detected = requested.filter { term in
            text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let applied = VocabularyEvidence.acousticallySupported(requested, in: words)

        return EngineTranscript(
            engine: name,
            model: model,
            version: "WhisperKit-1.0.0",
            settings: [
                "chunking": "vad",
                "compression_ratio_threshold": "2.4",
                "log_probability_threshold": "-1.0",
                "no_speech_threshold": "0.6",
                "prompt_terms": String(requested.count),
                "quality_mode": context.qualityMode.rawValue,
            ],
            text: text,
            language: results.first?.language,
            audioDurationMs: audioDuration,
            processingDurationMs: processingMs,
            words: words,
            segments: TranscriptSegmentation.segments(from: words),
            diagnostics: [
                "average_log_probability": Self.average(sourceSegments.map(\.avgLogprob)),
                "average_no_speech_probability": Self.average(sourceSegments.map(\.noSpeechProb)),
                "runtime": "coreml",
            ],
            context: EngineContextEvidence(
                requestedTerms: requested,
                detectedTerms: detected,
                appliedTerms: applied
            )
        )
    }

    func release() async {
        await kit?.unloadModels()
        kit = nil
    }

    /// A bounded prompt carries spellings, not assertions. Whisper remains
    /// free to omit every term when the acoustics do not support it.
    private static func prompt(for vocabulary: [VocabularyTerm]) -> String {
        let terms = vocabulary.prefix(64).map(\.text)
        guard !terms.isEmpty else { return "" }
        return String("Vocabulary: \(terms.joined(separator: ", ")).".prefix(1_000))
    }

    private static func average(_ values: [Float]) -> String {
        guard !values.isEmpty else { return "0" }
        return String(format: "%.4f", values.reduce(0, +) / Float(values.count))
    }
}
