import Foundation

enum VocabularyEvidence {
    static func acousticallySupported(
        _ requested: [String],
        in words: [TimedWord],
        minimumConfidence: Double = 0.72
    ) -> [String] {
        let normalizedWords = words.map { normalize($0.text) }
        return requested.filter { term in
            let parts = term.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
            guard !parts.isEmpty, normalizedWords.count >= parts.count else { return false }
            for start in 0...(normalizedWords.count - parts.count) {
                guard Array(normalizedWords[start..<(start + parts.count)]) == parts else { continue }
                let confidence = words[start..<(start + parts.count)].compactMap(\.confidence)
                if confidence.count == parts.count && confidence.reduce(0, +) / Double(confidence.count) >= minimumConfidence {
                    return true
                }
            }
            return false
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
