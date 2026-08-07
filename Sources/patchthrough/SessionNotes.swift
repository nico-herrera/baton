import Foundation

/// Notes the user typed while a meeting was recording, stored beside the audio
/// as `notes.json`.
///
/// These are the user's own words. Nothing generates, rewrites, or summarizes
/// them — they ride into `handoff.md` verbatim, above the transcript, so the
/// receiving agent knows which minutes a human thought mattered. That is the
/// whole feature: the transcript says what was said, the notes say what landed.
///
/// **Timestamps are absolute wall clock, never offsets.** The transcript's zero
/// is `audio_start`, and that value is not final until the recording stops:
/// `MicRecorder.fallBackToRaw` can discard the mic track a second in and move
/// the session's zero forward. A note that stored "2:14" at typing time would
/// bake in whichever zero happened to be current and silently point at the wrong
/// line afterwards. Storing the instant instead lets every note re-resolve
/// against the final anchor, however many times that anchor moves.
struct SessionNotes: Equatable, Sendable {
    struct Note: Equatable, Sendable {
        /// When the user committed the note, on the same wall clock as
        /// `audio_start` in meta.json.
        let at: Date
        let text: String
    }

    static let schemaVersion = 1
    static let fileName = "notes.json"

    var notes: [Note]

    // MARK: - Disk

    /// Read `notes.json`. Nil when the file is absent, which is the normal state
    /// for every session recorded before this shipped and every session where
    /// the user typed nothing. A malformed file reads as nil rather than
    /// throwing: notes are an enhancement, and losing the handoff because a
    /// side file got corrupted would be a worse failure than losing the notes.
    static func read(from dir: URL) -> SessionNotes? {
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["notes"] as? [[String: Any]]
        else { return nil }

        let iso = RecordingSession.isoMillisFormatter()
        let notes = raw.compactMap { entry -> Note? in
            guard let text = entry["text"] as? String,
                  let stamp = entry["at"] as? String,
                  let at = iso.date(from: stamp)
            else { return nil }
            return Note(at: at, text: text)
        }
        return notes.isEmpty ? nil : SessionNotes(notes: notes)
    }

    /// Append one note and flush. Read-modify-write is safe here in a way it is
    /// not for meta.json: `notes.json` has exactly one writer, the main actor,
    /// and `RecordingSession.writeMeta` never touches this file.
    ///
    /// Flushing on every note rather than at stop() is deliberate. A recording
    /// can run for an hour and a crash in that hour should not take the user's
    /// typing with it.
    @MainActor
    static func append(_ text: String, at date: Date = Date(), to dir: URL) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var notes = read(from: dir)?.notes ?? []
        notes.append(Note(at: date, text: trimmed))
        try SessionNotes(notes: notes).write(to: dir)
    }

    func write(to dir: URL) throws {
        let iso = RecordingSession.isoMillisFormatter()
        let payload: [String: Any] = [
            "schema_version": Self.schemaVersion,
            "notes": notes.map { ["at": iso.string(from: $0.at), "text": $0.text] },
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        // .atomic for the same reason every other session file uses it: a reader
        // can arrive at any moment, and truncated JSON is worse than no file.
        try data.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    // MARK: - Resolving against the transcript clock

    /// One note, placed on the transcript's clock.
    struct Resolved: Equatable, Sendable {
        /// Milliseconds from the transcript's zero, or nil when the session
        /// carries no usable anchor. Nil means "render this note without a
        /// timestamp", never "render it at zero" — a note claiming 0:00 when we
        /// do not know where it belongs would send an agent to the wrong line.
        let offsetMs: Int?
        let text: String
    }

    /// Read the notes and place them on the same clock `transcript.md` uses.
    ///
    /// The anchor is `audio_start` — the first audio buffer of whichever track
    /// delivered one first, which is exactly what every transcript timestamp is
    /// measured from. `started` is the fallback for sessions written before that
    /// key existed; it is stamped before the audio devices are opened, so those
    /// offsets land early by the device startup latency.
    static func resolved(in dir: URL) -> [Resolved] {
        guard let notes = read(from: dir)?.notes else { return [] }
        let anchor = audioStart(in: dir)

        return notes
            .map { note in
                guard let anchor else { return Resolved(offsetMs: nil, text: note.text) }
                // Clamp: a note typed in the window before the first buffer
                // arrived belongs at the start of the transcript, not before it.
                let ms = Int((note.at.timeIntervalSince(anchor) * 1000).rounded())
                return Resolved(offsetMs: max(0, ms), text: note.text)
            }
            .sorted { ($0.offsetMs ?? 0) < ($1.offsetMs ?? 0) }
    }

    /// The transcript's zero, read from meta.json.
    private static func audioStart(in dir: URL) -> Date? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let stamp = json["audio_start"] as? String,
           let date = RecordingSession.isoMillisFormatter().date(from: stamp) {
            return date
        }
        // Pre-audio_start sessions. Second precision and early by however long
        // the audio devices took to open, but far better than dropping the
        // timestamps entirely.
        if let stamp = json["started"] as? String {
            return ISO8601DateFormatter().date(from: stamp)
        }
        return nil
    }
}
