import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v2 (English) via FluidAudio's Core ML port. Models
/// download once into FluidAudio's managed cache (~600 MB); after that,
/// transcription runs entirely on-device at roughly 20 seconds per hour of
/// audio on Apple Silicon.
actor ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .notPrepared: return "parakeet engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    nonisolated let name = "parakeet"
    nonisolated let model = "parakeet-tdt-0.6b-v2-coreml"

    private var manager: AsrManager?
    private var ctcModels: CtcModels?

    func prepare() async throws {
        guard manager == nil else { return }
        let directory = try await AsrModels.download(version: .v2)
        try ModelIntegrity.verify(.parakeetV2, at: directory)
        let models = try await AsrModels.load(from: directory, version: .v2)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ audio: URL, context: TranscriptionContext) async throws -> EngineTranscript {
        guard let manager else { throw EngineError.notPrepared }

        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler. Swift cannot catch that exception, so it takes the whole
        // daemon down. Check readability up front instead.
        let audioDurationMs: Int
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
            audioDurationMs = Int(Double(probe.length) / probe.processingFormat.sampleRate * 1000)
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)
        var words = Self.words(from: result.tokenTimings ?? [])
        var text = TranscriptSegmentation.normalizedText(result.text)
        var detectedTerms = result.ctcDetectedTerms ?? []
        var appliedTerms = result.ctcAppliedTerms ?? []
        var vocabularyDiagnostic = "not_requested"
        if !context.vocabulary.isEmpty, let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty {
            do {
                let rescored = try await rescoreVocabulary(
                    audio: audio,
                    transcript: text,
                    tokenTimings: tokenTimings,
                    vocabulary: context.vocabulary
                )
                text = TranscriptSegmentation.normalizedText(rescored.text)
                words = Self.apply(rescored.replacements, to: words)
                detectedTerms = rescored.detected
                appliedTerms = rescored.applied
                vocabularyDiagnostic = "acoustic_ctc"
            } catch {
                // Vocabulary is optional. The untouched single-engine output
                // remains complete and recoverable when its evidence model fails.
                vocabularyDiagnostic = "failed: \(error)"
            }
        }
        let segments: [TranscriptSegment]
        if words.isEmpty {
            segments = text.isEmpty ? [] : [TranscriptSegment(
                startMs: 0,
                endMs: audioDurationMs,
                text: text,
                confidence: Double(result.confidence),
                words: []
            )]
        } else {
            segments = TranscriptSegmentation.segments(from: words)
        }

        let requested = context.vocabulary.map(\.text)
        let detected = requested.filter { term in
            text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return EngineTranscript(
            engine: name,
            model: model,
            version: "FluidAudio-0.15.5",
            settings: [
                "decoder": "tdt-greedy",
                "sample_rate_hz": "16000",
                "quality_mode": context.qualityMode.rawValue,
            ],
            text: text,
            language: "en",
            audioDurationMs: audioDurationMs,
            processingDurationMs: Int(result.processingTime * 1000),
            words: words,
            segments: segments,
            diagnostics: [
                "rtfx": String(format: "%.3f", result.rtfx),
                "result_confidence": String(format: "%.4f", result.confidence),
                "vocabulary_booster": vocabularyDiagnostic,
            ],
            context: EngineContextEvidence(
                requestedTerms: requested,
                detectedTerms: detectedTerms.isEmpty ? detected : detectedTerms,
                appliedTerms: appliedTerms
            )
        )
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
        ctcModels = nil
    }

    private static func words(from tokens: [TokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        var text = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var confidences: [Double] = []

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            words.append(TimedWord(
                text: trimmed,
                startMs: Int(start * 1000),
                endMs: Int(end * 1000),
                confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
            ))
        }

        for timing in tokens where !timing.token.isEmpty && timing.token != "<blank>" && timing.token != "<pad>" {
            let token = timing.token
            let startsWord = token.hasPrefix("▁") || token.hasPrefix(" ") || text.isEmpty
            if startsWord && !text.isEmpty {
                flush()
                text = ""
                confidences = []
            }
            if startsWord {
                var cleaned = token
                while cleaned.first == "▁" || cleaned.first == " " {
                    cleaned.removeFirst()
                }
                text = cleaned
                start = timing.startTime
            } else {
                text += token
            }
            end = timing.endTime
            confidences.append(Double(timing.confidence))
        }
        flush()
        return words
    }

    private func rescoreVocabulary(
        audio: URL,
        transcript: String,
        tokenTimings: [TokenTiming],
        vocabulary: [VocabularyTerm]
    ) async throws -> (
        text: String,
        detected: [String],
        applied: [String],
        replacements: [VocabularyRescorer.RescoringResult]
    ) {
        let models: CtcModels
        if let cached = ctcModels {
            models = cached
        } else {
            let directory = try await CtcModels.download(variant: .ctc110m)
            try ModelIntegrity.verify(.parakeetCTC110M, at: directory)
            models = try await CtcModels.load(from: directory, variant: .ctc110m)
            ctcModels = models
        }
        let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        let terms = vocabulary.prefix(128).compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term.text,
                weight: Float(term.weight),
                ctcTokenIds: ids
            )
        }
        let context = CustomVocabularyContext(terms: terms)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let samples = try AudioConverter().resampleAudioFile(audio)
        let spotted = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: samples,
            customVocabulary: context,
            minScore: nil
        )
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: context,
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: .ctc110m)
        )
        let output = rescorer.ctcTokenRescore(
            transcript: transcript,
            tokenTimings: tokenTimings,
            logProbs: spotted.logProbs,
            frameDuration: spotted.frameDuration
        )
        return (
            output.text,
            spotted.detections.map(\.term.text),
            output.replacements.filter(\.shouldReplace).compactMap(\.replacementWord),
            output.replacements
        )
    }

    private static func apply(
        _ replacements: [VocabularyRescorer.RescoringResult],
        to original: [TimedWord]
    ) -> [TimedWord] {
        var words = original
        for replacement in replacements where replacement.shouldReplace {
            guard let revised = replacement.replacementWord else { continue }
            let source = replacement.originalWord.split(whereSeparator: \.isWhitespace).map(normalize)
            guard !source.isEmpty, words.count >= source.count else { continue }
            var match: Range<Int>?
            for start in 0...(words.count - source.count) {
                if words[start..<(start + source.count)].map({ normalize($0.text) }) == source {
                    match = start..<(start + source.count)
                    break
                }
            }
            guard let match,
                  let first = words[match].first,
                  let last = words[match].last else { continue }
            let pieces = revised.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !pieces.isEmpty else { continue }
            let duration = max(0, last.endMs - first.startMs)
            let confidence = words[match].compactMap(\.confidence).min()
            let timed = pieces.enumerated().map { index, text in
                TimedWord(
                    text: text,
                    startMs: first.startMs + duration * index / pieces.count,
                    endMs: first.startMs + duration * (index + 1) / pieces.count,
                    confidence: confidence
                )
            }
            words.replaceSubrange(match, with: timed)
        }
        return words
    }

    private static func normalize(_ word: Substring) -> String { normalize(String(word)) }
    private static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
