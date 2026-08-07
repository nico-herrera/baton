import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate so every engine receives clean single-source audio and the
/// product retains reliable two-party diarization.
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
        // power loss) orphans the audio on disk forever. The tracks are there,
        // but nothing ever picks them up. A clean stop overwrites this file
        // with the real end time and the offsets.
        writeMeta(ended: nil)
    }

    /// Stop both tracks and write the final meta.json.
    func stop() {
        mic.stop()
        system.stop()
        writeMeta(ended: Date())
    }

    /// `audio_start` needs sub-second resolution: it is the zero point notes are
    /// measured against, and a note is only as accurate as the anchor it is
    /// subtracted from. `started` and `ended` stay on the plain second-precision
    /// formatter because three implementations already parse them.
    ///
    /// A fresh instance per call rather than a shared one: `ISO8601DateFormatter`
    /// is not `Sendable`, and this runs at most three times per recording.
    /// `SessionNotes` parses with the same options; the two must agree.
    static func isoMillisFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
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
            // `earliest` is what every transcript timestamp is measured from,
            // and until now it was computed here and thrown away. Without it on
            // disk nothing can convert a wall-clock instant into transcript
            // time, because `started` is stamped before the audio devices are
            // even touched — process tap, aggregate device, AudioDeviceStart and
            // the first callback all land after it. Notes anchor to this key, so
            // they share the transcript's zero rather than the ticker's.
            //
            // Write it even when it degenerates to `startedAt` (a track that
            // never delivered a buffer). Being consistent with the transcript
            // matters more than being right in the absolute: both are wrong by
            // the same amount, so a note still points at the correct line.
            "audio_start": Self.isoMillisFormatter().string(from: earliest),
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
