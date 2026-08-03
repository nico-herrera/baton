import AppKit
import ArgumentParser
import CoreFoundation
import Foundation

@main
struct Patchthrough: ParsableCommand {
    private static var releaseVersion: String {
        let key = "CFBundleShortVersionString"
        if let version = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            return version
        }

        // Direct diagnostic invocations can still arrive through a symlink.
        // Resolve it back into the app bundle so `--version` reports the same
        // value Finder exposes.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let app = executable
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // patchthrough.app
        if let bundle = Bundle(url: app),
           let version = bundle.object(forInfoDictionaryKey: key) as? String {
            return version
        }
        return "development"
    }

    static let configuration = CommandConfiguration(
        commandName: "patchthrough",
        abstract: "Record a meeting, transcribe it on-device, hand the transcript to your coding agent.",
        version: releaseVersion,
        subcommands: [Run.self, Hand.self, Transcripts.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

/// `patchthrough hand [agent]` stages the newest transcript, or a chosen
/// transcript, in the current repo. It then starts a primed agent session.
struct Hand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hand",
        abstract: "Hand a meeting transcript to a coding agent in this repo.",
        discussion: """
        Writes the transcript to .meeting/<session>.md (kept out of commits via
        the repo's local git excludes) and launches the agent with a prompt
        pointing at it. With no agent named, lists what's installed.

          patchthrough hand claude              newest transcript → claude, here
          patchthrough hand kimi -s 2026.07.30-2145
          patchthrough hand claude -d ~/Developer/foo
          patchthrough hand claude -n           stage + print prompt, don't launch
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
                print("  (none found. Looked in \(Handoff.searchDirs.joined(separator: ", ")))")
            }
            for (a, path) in installed { print("  \(a.name)  →  \(path)") }
            print("\nGUI targets (use --gui):")
            for t in guiTargets { print("  \(t.id)  →  \(t.label)") }
            print("\nusage: patchthrough hand <agent> [--gui]   (from inside the repo you want to work in)")
            return
        }

        let sess = try Handoff.resolveSession(named: session, root: root)
        if sess.words < 40 {
            FileHandle.standardError.write(Data(
                "⚠ '\(sess.name)' is only ~\(sess.words) words. The context is thin. This is probably a test recording or a quiet mic\n".utf8
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

/// `patchthrough transcripts` lists what is on disk, newest first.
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
                print(row(name, "-", "⏳ not transcribed yet"))
            } else {
                print(row(name, "-", "⚠ no meta.json. Interrupted?"))
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

    @Flag(name: .long, help: "Open the patchthrough window at launch.")
    var window = false

    func run() throws {
        // ArgumentParser invokes run() on the main thread; promote that fact
        // to the type system so AppKit calls are cleanly isolated.
        try MainActor.assumeIsolated { try runMain() }
    }

    @MainActor
    private func runMain() throws {
        // Finder/Dock launches the bundle with only argv[0]. The LaunchAgent
        // explicitly passes `run`, so it stays menu-bar-only; `--window`
        // remains available for a direct CLI preview.
        let launchedFromAppBundle = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
            && CommandLine.arguments.count == 1
        if launchedFromAppBundle, signalExistingAppToOpen() {
            return
        }

        let root = Config.resolveRoot(cliOverride: out)
        let opensWindowAtLaunch = window || launchedFromAppBundle

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
        // Runtime Dock icon. A bare binary has no bundle for the system to read
        // an icon from, and the window promotes us to .regular.
        AppIcon.apply()

        let controller = AppController(root: root)
        app.delegate = controller
        if opensWindowAtLaunch {
            // Defer until the run loop is pumping. An accessory app silently
            // ignores a window order-front call made before app.run().
            DispatchQueue.main.async { controller.openWindow() }
        }
        if ProcessInfo.processInfo.environment["PATCHTHROUGH_DEBUG_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                controller.openMenuForDebug()
            }
        }

        // Ignore the default disposition *before* arming the sources, so there
        // is no window where an early signal kills us outright.
        //
        // SIGTERM matters as much as SIGINT here: `launchctl bootout`, logout,
        // and reboot all send SIGTERM, and without a handler a recording in
        // progress never gets stop(): no finalized files and no final meta.json.
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
            "patchthrough up · recordings → \(root.path) · ^C to quit\n".utf8
        ))

        // The sources MUST outlive the run loop. A plain local (or a trailing
        // `_ = sources`) is not enough: its last use is above, so ARC is free to
        // release the sources before app.run(). The disposition is already
        // SIG_IGN, so the signals then become silently ignored instead of
        // default-terminate. Verified: SIGTERM was a no-op
        // until this was wrapped.
        withExtendedLifetime(controller) {
            withExtendedLifetime(signalSources) {
                app.run()
            }
        }
    }

    /// A LaunchAgent-started app is not reopened reliably by LaunchServices.
    /// Let the short-lived Finder/Dock launch signal that existing process and
    /// exit; if there is no existing process, normal startup continues below.
    @MainActor
    private func signalExistingAppToOpen() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.nicoherrera.patchthrough"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != getpid() })
        else { return false }

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            AppController.openWindowNotification,
            nil,
            nil,
            true
        )
        return true
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
final class AppController: NSObject, NSApplicationDelegate {
    static let openWindowNotification = CFNotificationName(
        "com.nicoherrera.patchthrough.openWindow" as CFString
    )

    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?
    private let store: SessionStore
    private let windowController: PatchthroughWindowController
    private var rootWatcher: DispatchSourceFileSystemObject?

    init(root: URL) {
        Self.removeLegacyCLISymlink()
        self.root = root
        let store = SessionStore(root: root)
        self.store = store
        self.windowController = PatchthroughWindowController(store: store)
        super.init()
        store.onToggleRecording = { [weak self] in self?.toggle() }
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onOpenWindow = { [weak self] in self?.openWindow() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onHandoff = { [weak self] agent in self?.handOff(to: agent) }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<AppController>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async { controller.openWindow() }
            },
            Self.openWindowNotification.rawValue,
            nil,
            .deliverImmediately
        )
        let appleEvents = NSAppleEventManager.shared()
        appleEvents.setEventHandler(
            self,
            andSelector: #selector(openWindowFromAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenApplication)
        )
        appleEvents.setEventHandler(
            self,
            andSelector: #selector(openWindowFromAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
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

        watchRecordingsRoot()
    }

    /// Source builds before the standalone npm CLI created this symlink. Only
    /// remove it when it resolves to this exact app executable; a real npm
    /// command, or a symlink the user owns for another purpose, is untouched.
    private static func removeLegacyCLISymlink() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = home
            .appendingPathComponent(".local/bin/patchthrough")
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: legacy.path)
        else { return }
        let oldAppTarget = home
            .appendingPathComponent("Applications/patchthrough.app/Contents/MacOS/patchthrough")
            .path
        let currentTarget = Bundle.main.executableURL?.path
        guard target == oldAppTarget || target == currentTarget else { return }
        try? FileManager.default.removeItem(at: legacy)
    }

    @objc private func openWindowFromAppleEvent(_ event: NSAppleEventDescriptor,
                                                withReplyEvent reply: NSAppleEventDescriptor) {
        openWindow()
    }

    /// Finder and Dock deliver a reopen event to the existing LaunchAgent
    /// process. Promote it from accessory mode and bring the GUI forward.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }

    /// LaunchServices activates the LaunchAgent process when the bundle is
    /// clicked, but does not consistently send it a reopen Apple event.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !windowController.hasPresentableWindow else { return }
        openWindow()
    }

    /// The redesign removed the Refresh button: the list reloads itself when
    /// the recordings folder changes (new session directories appearing or
    /// vanishing). Transcript completion inside a session is already covered
    /// by the transcription status handler.
    private func watchRecordingsRoot() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.refreshHandoffMenu()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        rootWatcher = source
    }

    /// Show the main window (session list + transcript + dispatch).
    func openWindow() {
        windowController.show()
    }

    /// See `MenuBarController.openMenuForDebug()`.
    func openMenuForDebug() {
        menuBar.openMenuForDebug()
    }

    /// Rebuild the patch-through menu from the ranked destinations and
    /// what's on disk. Cheap enough to call whenever state changes.
    private func refreshHandoffMenu() {
        store.refresh()
        let counts = DestinationRanking.counts()
        let ranked = store.rankedDestinations
        func entry(_ d: SessionStore.Destination) -> MenuBarController.HandoffMenuModel.Entry {
            .init(id: d.id, label: d.shortLabel, symbol: d.symbol, count: counts[d.id] ?? 0)
        }
        let top3 = ranked.prefix(3)
        let rest = ranked.dropFirst(3)
        let latest = store.items.first { $0.status == .ready }
        menuBar.apply(.init(
            mostUsed: top3.map(entry),
            terminal: rest.filter(\.isTerminal).map(entry),
            app: rest.filter { !$0.isTerminal }.map(entry),
            top: top3.first.map(entry),
            latestTimeLabel: latest?.date.map { $0.formatted(date: .omitted, time: .shortened) }
                ?? latest?.id,
            sessionCount: store.items.count
        ))
    }

    /// Menu-bar handoff. `choice` is "cli:<agent>" (Terminal session) or
    /// "gui:<target>" (VS Code chat, Cursor, or a chat app). Repo-based
    /// targets get a folder picker first. Chat apps need no folder, because the
    /// transcript rides along on the clipboard.
    private func handOff(to choice: String) {
        guard let session = try? Handoff.resolveSession(named: nil, root: root) else { return }

        let isGui = choice.hasPrefix("gui:")
        let name = String(choice.dropFirst(4))

        if isGui {
            guard let target = Handoff.installedGuiTargets().first(where: { $0.id == name }) else { return }
            if !target.needsRepo {
                Handoff.launchGui(target: target, session: session, repo: nil)
                switch target.kind {
                case .appClipboard(let appName):
                    notifyUser(
                        title: "Patchthrough: handed to \(appName)",
                        body: Config.autoPaste()
                            ? "Pasting into a new chat…"
                            : "Prompt + transcript are on your clipboard. Paste (⌘V) into a new chat."
                    )
                case .fileOpen(let appName):
                    notifyUser(
                        title: "Patchthrough: handed to \(appName)",
                        body: "Transcript attached. Instructions are on your clipboard. Paste (⌘V) and send."
                    )
                case .folderOpen(let appName):
                    notifyUser(
                        title: "Patchthrough: session folder → \(appName)",
                        body: "Instructions are on your clipboard. Paste (⌘V) once the workspace opens."
                    )
                default: break
                }
                DestinationRanking.record(choice)
                refreshHandoffMenu()
                return
            }
            guard let repo = pickRepo(session: session.name, destination: target.label) else { return }
            Handoff.launchGui(target: target, session: session, repo: repo)
            DestinationRanking.record(choice)
            refreshHandoffMenu()
            return
        }

        guard let match = Handoff.installedAgents().first(where: { $0.agent.name == name }),
              let repo = pickRepo(session: session.name, destination: name)
        else { return }

        do {
            try Handoff.stage(session: session, inRepo: repo)
        } catch {
            notifyUser(title: "Patchthrough: handoff failed", body: "\(error)")
            return
        }
        Handoff.launchInTerminal(
            agent: match.agent,
            at: match.path,
            prompt: Handoff.prompt(for: session),
            cwd: repo
        )
        DestinationRanking.record(choice)
        refreshHandoffMenu()
    }

    private func pickRepo(session: String, destination: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Hand \(session) to \(destination)"
        panel.message = "Choose the project this meeting was about. The session starts in that folder."
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
            notifyUser(title: "Patchthrough: recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        store.isRecording = true
        store.elapsed = "0:00"
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
        store.isRecording = false
        store.refresh()

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
            // A drain just finished, so new transcripts may exist.
            refreshHandoffMenu()
            store.refresh()
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
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        menuBar.update(recording: true, elapsed: elapsed)
        store.elapsed = elapsed
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
