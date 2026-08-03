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

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v2)
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
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)
        let words = Self.words(from: result.tokenTimings ?? [])
        let text = TranscriptSegmentation.normalizedText(result.text)
        let segments: [TranscriptSegment]
        if words.isEmpty {
            segments = text.isEmpty ? [] : [TranscriptSegment(
                startMs: 0,
                endMs: Int(result.duration * 1000),
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
            audioDurationMs: Int(result.duration * 1000),
            processingDurationMs: Int(result.processingTime * 1000),
            words: words,
            segments: segments,
            diagnostics: [
                "rtfx": String(format: "%.3f", result.rtfx),
                "result_confidence": String(format: "%.4f", result.confidence),
            ],
            context: EngineContextEvidence(
                requestedTerms: requested,
                detectedTerms: result.ctcDetectedTerms ?? detected,
                appliedTerms: result.ctcAppliedTerms ?? []
            )
        )
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
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
}
