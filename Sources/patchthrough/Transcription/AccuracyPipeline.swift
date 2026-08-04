import Foundation

struct QualityProfile: Codable, Sendable {
    struct Calibration: Codable, Sendable {
        let scale: Double
        let offset: Double

        func apply(_ confidence: Double?) -> Double? {
            confidence.map { min(max($0 * scale + offset, 0), 1) }
        }
    }

    struct Evidence: Codable, Sendable {
        let releaseQualified: Bool
        let dualEngineRelativeWerImprovement: Double?
        let consensusNoCategoryRegression: Bool?
    }

    let standardEngine: String
    let maxAccuracyEngines: [String]
    let consensusQualified: Bool
    let calibration: [String: Calibration]
    let evidence: Evidence?

    static let safeDefault = QualityProfile(
        standardEngine: "parakeet",
        maxAccuracyEngines: ["parakeet"],
        consensusQualified: false,
        calibration: [:],
        evidence: nil
    )

    static func load() -> QualityProfile {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/patchthrough/quality-profile.json")
        guard let data = try? Data(contentsOf: url) else { return .safeDefault }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(QualityProfile.self, from: data)) ?? .safeDefault
    }

    func engines(configured: String, mode: QualityMode) -> [String] {
        if configured != "auto" { return [configured] }
        guard isReleaseQualified else { return ["parakeet"] }
        if mode == .maxAccuracy, canRunConsensus, maxAccuracyEngines.count >= 2 {
            return Array(maxAccuracyEngines.prefix(2))
        }
        return [mode == .standard ? standardEngine : (maxAccuracyEngines.first ?? standardEngine)]
    }

    /// Product UI may offer Max Accuracy only after corrected-corpus evidence
    /// qualifies the profile. Until then, selecting it would be a cosmetic
    /// switch over the same recoverable Parakeet baseline.
    var maxAccuracyAvailable: Bool {
        isReleaseQualified && !maxAccuracyEngines.isEmpty
    }

    var isReleaseQualified: Bool {
        evidence?.releaseQualified == true
    }

    var canRunConsensus: Bool {
        consensusQualified
            && (evidence?.dualEngineRelativeWerImprovement ?? 0) >= 0.10
            && evidence?.consensusNoCategoryRegression == true
    }
}

enum TranscriptConsensus {
    private enum Step { case both(Int, Int), left(Int), right(Int) }

    /// Two-engine ROVER: align words, retain agreements, and resolve real
    /// disagreements with calibrated confidence. Timing is never invented.
    static func combine(
        _ primary: EngineTranscript,
        _ secondary: EngineTranscript,
        calibration: [String: QualityProfile.Calibration] = [:]
    ) -> EngineTranscript {
        let aligned = align(primary.words, secondary.words)
        var words: [TimedWord] = []
        for step in aligned {
            switch step {
            case .both(let left, let right):
                let a = primary.words[left], b = secondary.words[right]
                let aScore = calibration[primary.engine]?.apply(a.confidence) ?? a.confidence ?? 0.5
                let bScore = calibration[secondary.engine]?.apply(b.confidence) ?? b.confidence ?? 0.5
                words.append(aScore >= bScore ? calibrated(a, aScore) : calibrated(b, bScore))
            case .left(let index):
                let word = primary.words[index]
                let score = calibration[primary.engine]?.apply(word.confidence) ?? word.confidence
                if score == nil || score! >= 0.65 { words.append(calibrated(word, score)) }
            case .right(let index):
                let word = secondary.words[index]
                let score = calibration[secondary.engine]?.apply(word.confidence) ?? word.confidence
                if let score, score >= 0.75 { words.append(calibrated(word, score)) }
            }
        }
        words.sort { $0.startMs != $1.startMs ? $0.startMs < $1.startMs : $0.endMs < $1.endMs }
        let text = TranscriptSegmentation.normalizedText(words.map(\.text).joined(separator: " "))
        let requested = orderedUnion(primary.context.requestedTerms, secondary.context.requestedTerms)
        let applied = VocabularyEvidence.acousticallySupported(requested, in: words)
        return EngineTranscript(
            engine: "rover",
            model: "\(primary.model)+\(secondary.model)",
            version: "1",
            settings: ["alignment": "timestamped-word-dp", "engines": "\(primary.engine),\(secondary.engine)"],
            text: text,
            language: primary.language ?? secondary.language,
            audioDurationMs: max(primary.audioDurationMs, secondary.audioDurationMs),
            processingDurationMs: primary.processingDurationMs + secondary.processingDurationMs,
            words: words,
            segments: TranscriptSegmentation.segments(from: words),
            diagnostics: ["hypotheses": "2"],
            context: EngineContextEvidence(
                requestedTerms: requested,
                detectedTerms: orderedUnion(primary.context.detectedTerms, secondary.context.detectedTerms),
                appliedTerms: applied
            )
        )
    }

    private static func align(_ left: [TimedWord], _ right: [TimedWord]) -> [Step] {
        let n = left.count, m = right.count
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let substitution = cost[i - 1][j - 1] + pairCost(left[i - 1], right[j - 1])
                    cost[i][j] = min(substitution, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                }
            }
        }
        var steps: [Step] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let substitution = pairCost(left[i - 1], right[j - 1])
                if substitution < 2, cost[i][j] == cost[i - 1][j - 1] + substitution {
                    steps.append(.both(i - 1, j - 1)); i -= 1; j -= 1; continue
                }
            }
            if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                steps.append(.left(i - 1)); i -= 1
            } else {
                steps.append(.right(j - 1)); j -= 1
            }
        }
        return steps.reversed()
    }

    private static func calibrated(_ word: TimedWord, _ confidence: Double?) -> TimedWord {
        TimedWord(text: word.text, startMs: word.startMs, endMs: word.endMs, confidence: confidence)
    }

    private static func sameWord(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }

    private static func pairCost(_ left: TimedWord, _ right: TimedWord) -> Int {
        let centers = abs((left.startMs + left.endMs) / 2 - (right.startMs + right.endMs) / 2)
        let separated = left.endMs + 500 < right.startMs || right.endMs + 500 < left.startMs
        guard centers <= 1_500 || !separated else { return 2 }
        return sameWord(left.text, right.text) ? 0 : 1
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func orderedUnion(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0.lowercased()).inserted }
    }
}

enum TranscriptCalibration {
    static func apply(
        _ transcript: EngineTranscript,
        calibration: [String: QualityProfile.Calibration]
    ) -> EngineTranscript {
        guard let curve = calibration[transcript.engine] else { return transcript }
        let words = transcript.words.map {
            TimedWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs, confidence: curve.apply($0.confidence))
        }
        let segments = transcript.segments.map { segment in
            TranscriptSegment(
                startMs: segment.startMs,
                endMs: segment.endMs,
                text: segment.text,
                confidence: curve.apply(segment.confidence),
                words: segment.words.map {
                    TimedWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs, confidence: curve.apply($0.confidence))
                }
            )
        }
        var diagnostics = transcript.diagnostics
        diagnostics["confidence_calibration"] = "held-out-linear-v1"
        return EngineTranscript(
            engine: transcript.engine, model: transcript.model, version: transcript.version,
            settings: transcript.settings, text: transcript.text, language: transcript.language,
            audioDurationMs: transcript.audioDurationMs,
            processingDurationMs: transcript.processingDurationMs,
            words: words, segments: segments, diagnostics: diagnostics, context: transcript.context)
    }
}
