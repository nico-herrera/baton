import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
        // Write a provisional meta.json immediately. resumePending() keys on
        // meta.json existing, so without this an unclean exit (SIGKILL, panic,
        // power loss) orphans the audio on disk forever — the tracks are there
        // but nothing will ever pick them up. Overwritten on clean stop with
        // real end time and offsets.
        writeMeta(ended: nil)
    }

    /// Stop both tracks and write the final meta.json.
    func stop() {
        mic.stop()
        system.stop()
        writeMeta(ended: Date())
    }

    /// Serialize meta.json. `ended == nil` means the session is still live, so
    /// the file is a crash-recovery marker rather than a completion record.
    private func writeMeta(ended: Date?) {
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        var meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
            "clean_stop": ended != nil,
        ]
        let end = ended ?? Date()
        meta["ended"] = iso.string(from: end)
        meta["duration_seconds"] = Int(end.timeIntervalSince(startedAt))

        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            // .atomic so a kill mid-write can't leave truncated JSON that
            // SessionMeta.read would choke on.
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
    }
}
