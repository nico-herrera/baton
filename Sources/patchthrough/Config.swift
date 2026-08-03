import Foundation

/// Optional user config at ~/.config/patchthrough/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument. It runs after Patchthrough writes the transcript,
/// or right after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/patchthrough/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off, because the live voice unit ducks all other
    /// playback, and on headphones there is no echo to cancel. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// After a clipboard handoff to a chat app, synthesize ⌘N+⌘V so the paste
    /// happens without a hand touching the keyboard. Off by default: it
    /// requires an Accessibility grant and injects keystrokes, which is the
    /// kind of thing that should be a deliberate opt-in.
    static func autoPaste() -> Bool {
        load()?["auto_paste"] as? Bool ?? false
    }

    /// Whether transcription runs at all.
    static func transcriptionEnabledValue() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Bundle identifier of the terminal that CLI handoffs open in, or nil for
    /// the default (Terminal.app). Your shell profile comes from whichever
    /// terminal runs the command, so this is not cosmetic.
    static func terminal() -> String? {
        guard let id = load()?["terminal"] as? String, !id.isEmpty else { return nil }
        return id
    }

    // MARK: - Writing

    /// Merge a set of values into the config file, creating it if needed.
    /// Keys mapped to nil are removed, so the file only ever contains
    /// deliberate overrides rather than a full dump of defaults.
    ///
    /// Written atomically: a half-written config would be read as malformed
    /// on next launch and silently drop every setting.
    static func update(_ changes: [String: Any?]) throws {
        var root = load() ?? [:]

        for (key, value) in changes {
            // Dotted keys address nested objects ("transcription.enabled").
            let parts = key.split(separator: ".").map(String.init)
            if parts.count == 2 {
                var nested = root[parts[0]] as? [String: Any] ?? [:]
                if let value { nested[parts[1]] = value } else { nested.removeValue(forKey: parts[1]) }
                root[parts[0]] = nested.isEmpty ? nil : nested
            } else if let value {
                root[key] = value
            } else {
                root.removeValue(forKey: key)
            }
        }
        root = root.compactMapValues { $0 }

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: path, options: .atomic)
    }

    /// Where the config lives, for showing in the UI.
    static var configPath: URL { path }

    /// The most specific path that actually exists, for revealing in Finder.
    /// The config file is only written once a setting has been saved, and
    /// `activateFileViewerSelecting` silently does nothing for a path that
    /// isn't there. Fall back to the containing directory, and create that
    /// directory so there is always something to show.
    static func revealTarget() -> URL {
        if FileManager.default.fileExists(atPath: path.path) { return path }
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored. A recording that lands in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON. Ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
