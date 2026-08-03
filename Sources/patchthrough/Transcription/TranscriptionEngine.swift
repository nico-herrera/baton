import Foundation

enum QualityMode: String, Codable, Sendable {
    case standard
    case maxAccuracy = "max_accuracy"
}

/// A term is evidence, never a replacement rule. Engines may use it while
/// decoding, but a term only appears in the transcript when audio supports it.
struct VocabularyTerm: Codable, Hashable, Sendable {
    let text: String
    let source: String
    let weight: Double

    init(text: String, source: String, weight: Double = 1) {
        self.text = text
        self.source = source
        self.weight = min(max(weight, 0), 2)
    }
}

struct TranscriptionContext: Sendable {
    let qualityMode: QualityMode
    let vocabulary: [VocabularyTerm]

    static let standard = TranscriptionContext(qualityMode: .standard, vocabulary: [])
}

/// One engine-native word, relative to the beginning of its audio track.
/// `confidence` stays raw here; calibration belongs to the cross-engine
/// pipeline because scores from different model families are not comparable.
struct TimedWord: Codable, Equatable, Sendable {
    let text: String
    let startMs: Int
    let endMs: Int
    let confidence: Double?

    init(text: String, startMs: Int, endMs: Int, confidence: Double? = nil) {
        self.text = text
        self.startMs = max(0, startMs)
        self.endMs = max(max(0, startMs), endMs)
        self.confidence = confidence.map { min(max($0, 0), 1) }
    }
}

/// One readable span, still relative to the source track. Timed words remain
/// attached so echo removal and consensus never have to compare whole strings.
struct TranscriptSegment: Codable, Equatable, Sendable {
    let startMs: Int
    let endMs: Int
    let text: String
    let confidence: Double?
    let words: [TimedWord]
}

struct EngineContextEvidence: Codable, Equatable, Sendable {
    let requestedTerms: [String]
    let detectedTerms: [String]
    let appliedTerms: [String]
}

/// The common Swift/C# engine boundary. The serialized representation is
/// pinned by schemas/engine-transcript-v1.schema.json and one shared fixture.
struct EngineTranscript: Codable, Equatable, Sendable {
    let engine: String
    let model: String
    let version: String
    let settings: [String: String]
    let text: String
    let language: String?
    let audioDurationMs: Int
    let processingDurationMs: Int
    let words: [TimedWord]
    let segments: [TranscriptSegment]
    let diagnostics: [String: String]
    let context: EngineContextEvidence
}

/// A speech-to-text engine patchthrough can run locally. Engines are prepared
/// lazily and released when the queue drains, so idle Patchthrough never holds
/// gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    var name: String { get }
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL, context: TranscriptionContext) async throws -> EngineTranscript
    func release() async
}

enum TranscriptSegmentation {
    static let pauseSeconds = 0.8
    static let maximumDurationSeconds = 30.0
    static let confidenceChange = 0.35

    /// Natural boundaries first: punctuation, pauses, material confidence
    /// changes, then a duration safety bound for genuinely run-on speech.
    static func segments(from words: [TimedWord]) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let scores = current.compactMap(\.confidence)
            output.append(TranscriptSegment(
                startMs: first.startMs,
                endMs: last.endMs,
                text: normalizedText(current.map(\.text).joined(separator: " ")),
                confidence: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
                words: current
            ))
            current = []
        }

        for word in words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = current.last {
                let gap = Double(word.startMs - last.endMs) / 1000
                let duration = Double(word.endMs - (current.first?.startMs ?? word.startMs)) / 1000
                let confidenceShift: Bool
                if current.count >= 4, let previous = last.confidence, let next = word.confidence {
                    confidenceShift = abs(previous - next) >= confidenceChange
                } else {
                    confidenceShift = false
                }
                if gap > pauseSeconds || duration > maximumDurationSeconds || confidenceShift {
                    flush()
                }
            }
            current.append(word)
            if word.text.last.map({ ".?!".contains($0) }) == true { flush() }
        }
        flush()
        return output
    }

    static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
