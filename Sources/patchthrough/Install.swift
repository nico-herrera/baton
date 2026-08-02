import ArgumentParser
import Foundation

enum LaunchAtLoginError: Error, LocalizedError {
    case appBundleNotFound
    case launchctl(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .appBundleNotFound:
            return "Launch at login requires Patchthrough.app in ~/Applications or /Applications."
        case .launchctl(let status, let message):
            return "launchctl exited \(status): \(message)"
        }
    }
}

/// The native app owns its background lifecycle. The npm package is a
/// standalone transcript client and never installs or launches the app.
enum LaunchAtLogin {
    static let label = "com.nicoherrera.patchthrough"

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try enable() } else { try disable() }
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    private static func enable() throws {
        let binary = try resolveAppBinary()
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/patchthrough.out.log",
            "StandardErrorPath": "/tmp/patchthrough.err.log",
        ]

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)

        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        let result = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: plistURL)
            throw LaunchAtLoginError.launchctl(
                status: result.status,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func disable() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        // Removing the plist first is deliberate: bootout can terminate the
        // calling app when it was itself launched by this job.
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    private static func resolveAppBinary() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Applications/patchthrough.app/Contents/MacOS/patchthrough",
            "/Applications/patchthrough.app/Contents/MacOS/patchthrough",
        ]
        if let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return binary
        }
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app",
           let binary = Bundle.main.executableURL?.path,
           FileManager.default.isExecutableFile(atPath: binary) {
            return binary
        }
        throw LaunchAtLoginError.appBundleNotFound
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        task.waitUntilExit()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return (task.terminationStatus, String(data: errorData, encoding: .utf8) ?? "")
    }
}

/// Retained for source builds and diagnostics when invoking the executable
/// inside Patchthrough.app directly. Normal users manage this in Settings.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register Patchthrough.app to start at login.")
    var launchAtLogin = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }
        try LaunchAtLogin.setEnabled(launchAtLogin)
        print(launchAtLogin ? "✓ launch at login enabled" : "✓ launch at login disabled")
    }
}
