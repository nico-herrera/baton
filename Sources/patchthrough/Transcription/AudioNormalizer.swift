import AVFoundation
import FluidAudio
import Foundation

enum AudioNormalizer {
    static let sampleRate = 16_000

    enum NormalizationError: Error {
        case empty(URL)
    }

    /// Writes a derived, validated PCM track and leaves the original capture
    /// untouched. All engines therefore see identical samples.
    static func normalize(_ source: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory
            .appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("16k.wav")
        if isValid(output) { return output }

        let samples = try AudioConverter().resampleAudioFile(source).map { sample in
            sample.isFinite ? min(max(sample, -1), 1) : 0
        }
        guard !samples.isEmpty else { throw NormalizationError.empty(source) }
        let partial = output.appendingPathExtension("partial")
        try writePCM16(samples, to: partial)
        guard isValid(partial) else { throw NormalizationError.empty(source) }
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: partial, to: output)
        return output
    }

    private static func isValid(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
            && file.processingFormat.channelCount == 1
            && Int(file.processingFormat.sampleRate.rounded()) == sampleRate
    }

    private static func writePCM16(_ samples: [Float], to url: URL) throws {
        let dataBytes = UInt32(samples.count * MemoryLayout<Int16>.size)
        var header = Data()
        header.append(Data("RIFF".utf8)); append(UInt32(36) + dataBytes, to: &header)
        header.append(Data("WAVEfmt ".utf8)); append(UInt32(16), to: &header)
        append(UInt16(1), to: &header); append(UInt16(1), to: &header)
        append(UInt32(sampleRate), to: &header); append(UInt32(sampleRate * 2), to: &header)
        append(UInt16(2), to: &header); append(UInt16(16), to: &header)
        header.append(Data("data".utf8)); append(dataBytes, to: &header)
        try header.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for start in stride(from: 0, to: samples.count, by: 16_384) {
            var chunk = Data(capacity: min(16_384, samples.count - start) * 2)
            for sample in samples[start..<min(start + 16_384, samples.count)] {
                let scaled = Int16((sample * Float(Int16.max)).rounded())
                append(UInt16(bitPattern: scaled), to: &chunk)
            }
            try handle.write(contentsOf: chunk)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
