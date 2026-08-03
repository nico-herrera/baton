import Foundation

/// Optional user config at ~/.config/patchthrough/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook",
///       "custom_destinations": [
///         { "id": "nucleus", "label": "Nucleus",
///           "url": "https://nucleus.example.com/chat",
///           "prefills_prompt": true, "uploads_to_cloud": false }
///       ]
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
    /// happens without a hand touching the keyboard. On by default: without
    /// it, opening an app that is already open looks like nothing happened.
    /// The first paste asks for Accessibility, and patchthrough explains the
    /// manual fallback when the grant is missing. Set `"auto_paste": false`
    /// to keep the paste manual.
    static func autoPaste() -> Bool {
        load()?["auto_paste"] as? Bool ?? true
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

    /// A chat destination the user defined for themselves. These never ship:
    /// an internal tool belongs in one person's config file, not in a public
    /// build's menu.
    struct CustomDestination {
        let id: String
        let label: String
        let url: URL
        let prefillsPrompt: Bool
        let uploadsToCloud: Bool
    }

    /// Destinations from the `custom_destinations` array:
    ///
    ///     "custom_destinations": [
    ///       { "id": "nucleus", "label": "Nucleus",
    ///         "url": "https://nucleus.example.com/chat",
    ///         "prefills_prompt": true, "uploads_to_cloud": false }
    ///     ]
    ///
    /// Validation happens here rather than at launch, because the URL reaches
    /// `/usr/bin/open`, which hands any scheme to whatever app claims it. A
    /// `file://` or third-party scheme in a config file would otherwise become
    /// an app invocation with values this code never checked. A rejected entry
    /// is reported and skipped; one bad row must not cost the others.
    static func customDestinations() -> [CustomDestination] {
        guard let rows = load()?["custom_destinations"] as? [[String: Any]] else { return [] }

        return rows.compactMap { row in
            func reject(_ reason: String) -> CustomDestination? {
                FileHandle.standardError.write(Data(
                    "warning: ignoring a custom_destinations entry: \(reason)\n".utf8
                ))
                return nil
            }

            guard let id = row["id"] as? String, !id.isEmpty else {
                return reject("no \"id\"")
            }
            // The id becomes a UserDefaults ranking key and a CLI argument.
            guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
                return reject("id \"\(id)\" has characters outside A-Z a-z 0-9 . _ -")
            }
            guard let urlString = row["url"] as? String,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                return reject("\"\(id)\" needs a \"url\" that starts with http:// or https://")
            }
            return CustomDestination(
                id: id,
                label: (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                url: url,
                prefillsPrompt: row["prefills_prompt"] as? Bool ?? true,
                uploadsToCloud: row["uploads_to_cloud"] as? Bool ?? false
            )
        }
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
