import AppKit
import Foundation

/// Which terminal a CLI handoff opens in.
///
/// This is a real preference, not a cosmetic one: your shell profile, colours
/// and startup files come from whichever terminal runs the command, so a
/// session started in Terminal.app doesn't see the setup you built in iTerm.
struct TerminalApp: Identifiable, Equatable {

    /// How a command gets into the app. Terminal and iTerm expose scripting
    /// dictionaries that take a command directly; everything else is opened
    /// with an executable `.command` file, which every terminal that registers
    /// as a shell-script handler will run.
    enum Driver {
        case appleScriptDoScript   // Terminal.app
        case iTerm                 // iTerm2
        case commandFile           // generic
    }

    /// Bundle identifier. The config file stores this same value.
    let id: String
    /// Shown in Settings.
    let name: String
    /// The name AppleScript addresses the app by.
    let scriptName: String
    let driver: Driver

    /// Terminals worth offering. Adding one is a single entry here; prefer
    /// `.commandFile` unless the app has a scripting dictionary that takes a
    /// command, because that route needs no per-app AppleScript.
    static let known: [TerminalApp] = [
        .init(id: "com.apple.Terminal", name: "Terminal",
              scriptName: "Terminal", driver: .appleScriptDoScript),
        .init(id: "com.googlecode.iterm2", name: "iTerm",
              scriptName: "iTerm", driver: .iTerm),
        .init(id: "com.mitchellh.ghostty", name: "Ghostty",
              scriptName: "Ghostty", driver: .commandFile),
        .init(id: "com.github.wez.wezterm", name: "WezTerm",
              scriptName: "WezTerm", driver: .commandFile),
        .init(id: "net.kovidgoyal.kitty", name: "kitty",
              scriptName: "kitty", driver: .commandFile),
        .init(id: "org.alacritty", name: "Alacritty",
              scriptName: "Alacritty", driver: .commandFile),
        .init(id: "dev.warp.Warp-Stable", name: "Warp",
              scriptName: "Warp", driver: .commandFile),
        .init(id: "co.zeit.hyper", name: "Hyper",
              scriptName: "Hyper", driver: .commandFile),
    ]

    /// Whether this app is actually on the machine.
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    /// Installed terminals, in `known` order. Terminal.app ships with macOS so
    /// this is never empty.
    static func installed() -> [TerminalApp] {
        known.filter(\.isInstalled)
    }

    /// The configured terminal, falling back to Terminal.app when the config
    /// names an app that is absent. A handoff that silently does nothing after
    /// someone uninstalls the chosen app is worse than opening the stock app.
    static func current() -> TerminalApp {
        let fallback = known[0]
        guard let id = Config.terminal(),
              let match = known.first(where: { $0.id == id }), match.isInstalled
        else { return fallback }
        return match
    }

    // MARK: - Launching

    /// Run `command` in this terminal, in a new window/tab.
    func run(_ command: String) {
        switch driver {
        case .appleScriptDoScript:
            osascript("""
            tell application "\(scriptName)"
                activate
                do script \(Self.asQuote(command))
            end tell
            """)
        case .iTerm:
            // iTerm's `do script` equivalent: make a window from the default
            // profile so the user's profile (shell, theme, startup) applies,
            // then write into its session.
            osascript("""
            tell application "\(scriptName)"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text \(Self.asQuote(command))
                end tell
            end tell
            """)
        case .commandFile:
            runViaCommandFile(command)
        }
    }

    /// Generic route: an executable script opened with the chosen app. Used for
    /// terminals with no usable scripting dictionary.
    private func runViaCommandFile(_ command: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("patchthrough-\(UUID().uuidString).command")
        // The script removes itself, so temp doesn't accumulate launchers.
        let body = "#!/bin/sh\nrm -f \(Self.shq(file.path))\n\(command)\n"
        guard (try? body.write(to: file, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes(
                  [.posixPermissions: 0o755], ofItemAtPath: file.path)) != nil,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config)
    }

    private func osascript(_ script: String) {
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        try? osa.run()
    }

    /// Quote for an AppleScript string literal.
    private static func asQuote(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        + "\""
    }

    /// Single-quote for POSIX shell.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
