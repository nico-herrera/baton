import AppKit
import ArgumentParser
import Foundation

@main
struct Baton: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baton",
        abstract: "Record a meeting, transcribe it on-device, hand the transcript to your coding agent.",
        subcommands: [Run.self, Hand.self, Transcripts.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

/// `baton hand [agent]` — stage the newest (or a chosen) transcript in the
/// current repo and start an agent session primed with it.
struct Hand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hand",
        abstract: "Hand a meeting transcript to a coding agent in this repo.",
        discussion: """
        Writes the transcript to .meeting/<session>.md (kept out of commits via
        the repo's local git excludes) and launches the agent with a prompt
        pointing at it. With no agent named, lists what's installed.

          baton hand claude              newest transcript → claude, here
          baton hand kimi -s 2026.07.30-2145
          baton hand claude -d ~/Developer/foo
          baton hand claude -n           stage + print prompt, don't launch
        """
    )

    @Argument(help: "Which agent (claude, copilot, codex, kimi, opencode, cursor-agent). Omit to list.")
    var agent: String?

    @Option(name: .shortAndLong, help: "A specific session (default: newest transcribed).")
    var session: String?

    @Option(name: .shortAndLong, help: "The repo to work in (default: current directory).")
    var dir: String?

    @Flag(name: .shortAndLong, help: "Stage the file and print the prompt without launching.")
    var noLaunch = false

    @Flag(name: .shortAndLong, help: "Open the GUI instead of a terminal session (VS Code chat for copilot, Cursor, or the Claude/ChatGPT/Kimi app).")
    var gui = false

    func run() throws {
        let root = Config.resolveRoot(cliOverride: nil)
        let installed = Handoff.installedAgents()
        let guiTargets = Handoff.installedGuiTargets()

        guard let agentName = agent else {
            print("terminal agents installed here:")
            if installed.isEmpty {
                print("  (none found — looked in \(Handoff.searchDirs.joined(separator: ", ")))")
            }
            for (a, path) in installed { print("  \(a.name)  →  \(path)") }
            print("\nGUI targets (use --gui):")
            for t in guiTargets { print("  \(t.id)  →  \(t.label)") }
            print("\nusage: baton hand <agent> [--gui]   (from inside the repo you want to work in)")
            return
        }

        let sess = try Handoff.resolveSession(named: session, root: root)
        if sess.words < 40 {
            FileHandle.standardError.write(Data(
                "⚠ '\(sess.name)' is only ~\(sess.words) words — thin context, likely a test recording or a quiet mic\n".utf8
            ))
        }

        let repo = URL(fileURLWithPath: dir ?? FileManager.default.currentDirectoryPath)

        if gui {
            guard let target = guiTargets.first(where: { $0.id == agentName }) else {
                throw Handoff.HandoffError.unknownAgent(
                    "\(agentName) (gui)", available: guiTargets.map(\.id)
                )
            }
            if noLaunch {
                _ = try Handoff.stage(session: sess, inRepo: repo)
                print("staged; would open \(target.label)")
                return
            }
            Handoff.launchGui(target: target, session: sess, repo: repo)
            FileHandle.standardError.write(Data("→ \(target.label)\n".utf8))
            return
        }

        let staged = try Handoff.stage(session: sess, inRepo: repo)
        FileHandle.standardError.write(Data(
            "staged \(staged.path)  (\(sess.words) words, \(sess.segments) segments, \(sess.duration))\n".utf8
        ))

        let prompt = Handoff.prompt(for: sess)
        if noLaunch {
            print("\n\(prompt)")
            return
        }

        guard let match = installed.first(where: { $0.agent.name == agentName }) else {
            throw Handoff.HandoffError.unknownAgent(agentName, available: installed.map(\.agent.name))
        }
        Handoff.exec(agent: match.agent, at: match.path, prompt: prompt, cwd: repo)
    }
}

/// `baton transcripts` — what's on disk, newest first.
struct Transcripts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcripts",
        abstract: "List recorded sessions and their transcripts."
    )

    func run() throws {
        let root = Config.resolveRoot(cliOverride: nil)
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        guard !dirs.isEmpty else {
            print("no sessions in \(root.path) yet")
            return
        }

        func row(_ a: String, _ b: String, _ c: String) -> String {
            a.padding(toLength: 22, withPad: " ", startingAt: 0)
                + b.padding(toLength: 9, withPad: " ", startingAt: 0) + c
        }
        print(row("SESSION", "LENGTH", "OPENS WITH"))
        for d in dirs {
            let name = d.lastPathComponent
            if let sess = try? Handoff.resolveSession(named: name, root: root) {
                let transcript = (try? String(contentsOf: d.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
                let first = transcript.components(separatedBy: "\n")
                    .first { $0.hasPrefix("**[") }?
                    .replacingOccurrences(of: "**", with: "")
                    .prefix(50) ?? "(empty)"
                print(row(name, sess.duration, String(first)))
            } else if fm.fileExists(atPath: d.appendingPathComponent("meta.json").path) {
                print(row(name, "—", "⏳ not transcribed yet"))
            } else {
                print(row(name, "—", "⚠ no meta.json — interrupted?"))
            }
        }
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        let root = Config.resolveRoot(cliOverride: out)

        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            // Deliberately non-fatal, matching the comment above: exiting here
            // fights the LaunchAgent's KeepAlive{SuccessfulExit:false} and
            // respawn-loops at launchd's ~10s throttle, spamming the log
            // forever. Permissions can be granted while we're running, so
            // surface the problem and stay up.
            FileHandle.standardError.write(Data("startup checks failed (continuing):\n".utf8))
            DoctorReport.print(checks)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        // Ignore the default disposition *before* arming the sources, so there
        // is no window where an early signal kills us outright.
        //
        // SIGTERM matters as much as SIGINT here: `launchctl bootout`, logout,
        // and reboot all send SIGTERM, and without a handler a recording in
        // progress never gets stop() — no finalized files, no final meta.json.
        let signalSources = [SIGINT, SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                FileHandle.standardError.write(Data("\nshutting down\n".utf8))
                MainActor.assumeIsolated { controller.shutdown() }
            }
            source.resume()
            return source
        }

        FileHandle.standardError.write(Data(
            "baton up · recordings → \(root.path) · ^C to quit\n".utf8
        ))

        // The sources MUST outlive the run loop. A plain local (or a trailing
        // `_ = sources`) is not enough: its last use is above, so ARC is free to
        // release the sources before app.run() — and because the disposition is
        // already SIG_IGN, the signals then become silently ignored rather than
        // falling back to default-terminate. Verified: SIGTERM was a no-op
        // until this was wrapped.
        withExtendedLifetime(signalSources) {
            app.run()
        }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onHandoff = { [weak self] agent in self?.handOff(to: agent) }
        menuBar.update(recording: false, elapsed: nil)
        refreshHandoffMenu()

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Rebuild "Hand off to →" from what's on disk and what's installed.
    /// Cheap enough to call whenever state changes.
    private func refreshHandoffMenu() {
        let agents = Handoff.installedAgents().map(\.agent.name)
        let gui = Handoff.installedGuiTargets().map { (id: $0.id, label: $0.label) }
        let latest = try? Handoff.resolveSession(named: nil, root: root)
        menuBar.updateHandoff(agents: agents, guiTargets: gui, latestSession: latest?.name)
    }

    /// Menu-bar handoff. `choice` is "cli:<agent>" (Terminal session) or
    /// "gui:<target>" (VS Code chat, Cursor, or a chat app). Repo-based
    /// targets get a folder picker first; chat apps don't need one — the
    /// transcript rides along on the clipboard.
    private func handOff(to choice: String) {
        guard let session = try? Handoff.resolveSession(named: nil, root: root) else { return }

        let isGui = choice.hasPrefix("gui:")
        let name = String(choice.dropFirst(4))

        if isGui {
            guard let target = Handoff.installedGuiTargets().first(where: { $0.id == name }) else { return }
            if case .appClipboard(let appName) = target.kind {
                Handoff.launchGui(target: target, session: session, repo: nil)
                notifyUser(
                    title: "baton — handed to \(appName)",
                    body: "Prompt + transcript are on your clipboard. Paste (⌘V) into a new chat."
                )
                return
            }
            guard let repo = pickRepo(session: session.name, destination: target.label) else { return }
            Handoff.launchGui(target: target, session: session, repo: repo)
            return
        }

        guard let match = Handoff.installedAgents().first(where: { $0.agent.name == name }),
              let repo = pickRepo(session: session.name, destination: name)
        else { return }

        do {
            try Handoff.stage(session: session, inRepo: repo)
        } catch {
            notifyUser(title: "baton — handoff failed", body: "\(error)")
            return
        }
        Handoff.launchInTerminal(
            agent: match.agent,
            prompt: Handoff.prompt(for: session),
            cwd: repo
        )
    }

    private func pickRepo(session: String, destination: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Hand \(session) to \(destination)"
        panel.message = "Choose the project this meeting was about — the session starts there."
        panel.prompt = "Start session"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer", isDirectory: true)

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let repo = panel.url else { return nil }
        return repo
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "baton — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
            // A drain just finished — new transcript(s) may exist.
            refreshHandoffMenu()
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
