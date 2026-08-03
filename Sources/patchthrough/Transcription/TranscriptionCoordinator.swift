import Foundation

enum TranscriptionError: Error, CustomStringConvertible {
    case allTracksFailed(attempted: Int)

    var description: String {
        switch self {
        case .allTracksFailed(let n):
            return "all \(n) track(s) failed to transcribe. See the lines above for the per-track cause"
        }
    }
}

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue.
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires. The hook then gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        // handoff.md became part of the public session contract after the
        // first releases. Backfill it for older completed sessions so the npm
        // CLI consumes the same canonical document as the app.
        let missingHandoffs = entries.filter {
            fm.fileExists(atPath: $0.appendingPathComponent("transcript.md").path)
                && !fm.fileExists(atPath: $0.appendingPathComponent("handoff.md").path)
        }
        for dir in missingHandoffs {
            do {
                let session = try Handoff.resolveSession(
                    named: dir.lastPathComponent,
                    root: root
                )
                try Handoff.writeHandoffFile(for: session)
            } catch {
                log(dir, "could not create handoff.md: \(error)")
            }
        }

        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                notifyUser(title: "Patchthrough: transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "Patchthrough: transcription failed",
                    body: "\(dir.lastPathComponent). See transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        var rawTracks: [RawTrack] = []
        var attempted = 0
        var succeeded = 0
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            attempted += 1
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript. Log the failure and keep going.
            let result: EngineTranscript
            do {
                result = try await engine.transcribe(audio, context: .standard)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            succeeded += 1
            let offset = TimeInterval(track.offsetMs) / 1000
            rawTracks.append(RawTrack(
                sourceTrack: track.key,
                speaker: track.speaker,
                offsetMs: track.offsetMs,
                audioFile: track.file,
                hypotheses: [result],
                selectedHypothesis: 0,
                optionalStageFailures: []
            ))
            merged += result.segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    source_track: track.key,
                    start_ms: $0.startMs + Int(offset * 1000),
                    end_ms: $0.endMs + Int(offset * 1000),
                    text: $0.text,
                    confidence: $0.confidence,
                    applied_vocabulary: result.context.appliedTerms,
                    words: $0.words.map { word in
                        TimedWord(
                            text: word.text,
                            startMs: word.startMs + track.offsetMs,
                            endMs: word.endMs + track.offsetMs,
                            confidence: word.confidence
                        )
                    }
                )
            }
        }
        // Every track we tried failed. Writing transcript.json here would be
        // actively harmful: it's the completion marker resumePending() keys on,
        // so a valid-looking 0-segment file permanently buries the session and
        // fires a "transcript ready" notification for nothing. Throw instead.
        // The caller logs to transcribe.log and reports .failed, and the
        // session stays eligible for a retry on next launch.
        if attempted > 0 && succeeded == 0 {
            throw TranscriptionError.allTracksFailed(attempted: attempted)
        }

        try RawTranscript(
            schemaVersion: 1,
            pipelineVersion: 2,
            qualityMode: .standard,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            tracks: rawTracks
        ).write(to: dir)

        // Stable ordering: Swift's sort isn't stable, so mic/system segments
        // sharing a start_ms would otherwise swap places between runs. Break
        // ties on speaker to keep transcripts diffable.
        merged.sort {
            $0.start_ms != $1.start_ms
                ? $0.start_ms < $1.start_ms
                : $0.speaker < $1.speaker
        }

        if Config.dedupMicEcho() {
            let before = merged.count
            merged = EchoDedup.dropMicEcho(from: merged)
            if merged.count < before {
                log(dir, "dropped \(before - merged.count) mic segment(s) that echo the system track")
            }
        }

        let transcript = Transcript(
            pipeline_version: 2,
            engine: engine.name,
            model: engine.model,
            quality_mode: .standard,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        do {
            let session = try Handoff.resolveSession(
                named: dir.lastPathComponent,
                root: dir.deletingLastPathComponent()
            )
            try Handoff.writeHandoffFile(for: session)
        } catch {
            // transcript.json is the durable completion marker. A secondary
            // handoff-file failure should be visible but must not turn a good
            // transcription into a permanently non-retryable failure.
            log(dir, "could not create handoff.md: \(error)")
        }
        log(dir, "done: \(merged.count) segments")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\". Using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let key: String
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0. The
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(key: "mic", file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(key: "system", file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Speech from the speakers reaches the mic, so the other side of a call is
/// transcribed twice: once from system.caf as "them" and again from mic.caf
/// as "me". The second copy is worse than noise, because it credits the user
/// with words another person said. This filter drops a mic segment when a
/// system segment nearby says the same thing.
///
/// The mic copy is the one to drop: the system track is a process tap of
/// other apps' output, so the local user's live voice cannot appear on it.
/// The one path that direction is far-end echo, and conferencing apps cancel
/// that on their side.
///
/// Thresholds were tuned against a real 9.5-minute call recorded over
/// speakers (293 segments, 90 echoes): similarity 0.7 reproduced a
/// difflib-0.8 reference to within one segment either way, and the
/// containment rule catches echo fragments that length-ratio misses. The
/// minimum-length floor keeps a genuine simultaneous "yeah" from both
/// speakers alive.
private enum EchoDedup {
    /// How far apart (ms) the two copies of one utterance can start. Echo is
    /// near-simultaneous; 5s absorbs the engines segmenting the tracks
    /// differently.
    private static let windowMs = 5000
    /// Segments whose normalized text is shorter never drop: "yeah" from
    /// both speakers is agreement, not echo.
    private static let minLength = 12
    /// Minimum Levenshtein similarity for two texts to count as one
    /// utterance.
    private static let threshold = 0.7

    static func dropMicEcho(from segments: [Transcript.Segment]) -> [Transcript.Segment] {
        let system = segments.filter { $0.speaker == "them" }
            .map { (start: $0.start_ms, text: normalize($0.text)) }
        guard !system.isEmpty else { return segments }

        return segments.filter { seg in
            guard seg.speaker == "me" else { return true }
            let text = normalize(seg.text)
            guard text.count >= minLength else { return true }
            return !system.contains { candidate in
                abs(candidate.start - seg.start_ms) <= windowMs
                    && isEcho(text, candidate.text)
            }
        }
    }

    /// Lowercase, punctuation stripped, whitespace collapsed. ASR renders the
    /// same audio with different casing and punctuation per track; the words
    /// are what repeat.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func isEcho(_ a: String, _ b: String) -> Bool {
        // Containment: the mic often catches a fragment of an utterance the
        // system track has whole (or the reverse). A shared run this long is
        // not coincidence.
        if a.count >= minLength, b.count >= minLength, a.contains(b) || b.contains(a) {
            return true
        }
        let longest = max(a.count, b.count)
        guard longest > 0 else { return false }
        // Cheap pre-check: a length gap alone can rule the pair out, and
        // Levenshtein is quadratic.
        guard Double(longest - min(a.count, b.count)) / Double(longest) <= 1 - threshold else {
            return false
        }
        return 1 - Double(levenshtein(a, b)) / Double(longest) >= threshold
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a.unicodeScalars), t = Array(b.unicodeScalars)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            for j in 1...t.count {
                current[j] = Swift.min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (s[i - 1] == t[j - 1] ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }
        return previous[t.count]
    }
}

/// Canonical transcript. Property names are the JSON schema. This struct
/// exists to be serialized.
private struct Transcript: Encodable {
    struct Segment: Encodable {
        let speaker: String
        let source_track: String
        let start_ms: Int
        let end_ms: Int
        let text: String
        let confidence: Double?
        let applied_vocabulary: [String]
        /// Retained in memory for word-level echo comparison, but the full
        /// timing data lives in transcript.raw.json rather than duplicating it.
        let words: [TimedWord]

        private enum CodingKeys: String, CodingKey {
            case speaker, source_track, start_ms, end_ms, text, confidence, applied_vocabulary
        }
    }

    let pipeline_version: Int
    let engine: String
    let model: String
    let quality_mode: QualityMode
    let created_at: String
    let segments: [Segment]

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk. resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

private struct RawTrack: Codable {
    let sourceTrack: String
    let speaker: String
    let offsetMs: Int
    let audioFile: String
    let hypotheses: [EngineTranscript]
    let selectedHypothesis: Int
    let optionalStageFailures: [String]
}

private struct RawTranscript: Codable {
    let schemaVersion: Int
    let pipelineVersion: Int
    let qualityMode: QualityMode
    let createdAt: String
    let tracks: [RawTrack]

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(self).write(
            to: directory.appendingPathComponent("transcript.raw.json"),
            options: .atomic
        )
    }
}
