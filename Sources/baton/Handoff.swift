import Foundation

/// The handoff: take a finished transcript and put it in front of a coding
/// agent, primed with a prompt that treats it as messy speech-to-text rather
/// than gospel. The transcript is passed verbatim — no summarizing step,
/// because a lossy summary is exactly where requirements get quietly dropped.
enum Handoff {

    // MARK: - Agents

    /// A coding agent we know how to launch. `positionalPrompt` means
    /// `<binary> "<prompt>"` starts an interactive session with the prompt
    /// loaded; the exceptions get their own launch style.
    struct Agent {
        let name: String
        let launch: LaunchStyle

        enum LaunchStyle {
            case positionalPrompt          // claude, codex, cursor-agent, copilot
            case runSubcommand             // opencode run "<prompt>"
            case clipboardThenPlain        // kimi: no initial-prompt flag; stage on clipboard
        }
    }

    static let knownAgents: [Agent] = [
        Agent(name: "claude", launch: .positionalPrompt),
        Agent(name: "copilot", launch: .positionalPrompt),
        Agent(name: "codex", launch: .positionalPrompt),
        Agent(name: "cursor-agent", launch: .positionalPrompt),
        Agent(name: "opencode", launch: .runSubcommand),
        Agent(name: "kimi", launch: .clipboardThenPlain),
    ]

    /// Where agent CLIs actually live. A menu-bar app (or LaunchAgent) gets a
    /// minimal PATH, so we search the usual install locations explicitly
    /// instead of trusting the environment.
    static var searchDirs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.kimi-code/bin",
            "\(home)/bin",
            "/usr/bin",
        ]
    }

    static func find(_ name: String) -> String? {
        for dir in searchDirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Agents present on this machine, in preference order.
    static func installedAgents() -> [(agent: Agent, path: String)] {
        knownAgents.compactMap { agent in
            find(agent.name).map { (agent, $0) }
        }
    }

    // MARK: - GUI targets

    /// A GUI destination for the handoff. Different apps expose very different
    /// doors: VS Code has a real `code chat` CLI that attaches files; Cursor
    /// has a prompt deeplink; the chat apps (Claude, ChatGPT, Kimi) expose no
    /// prompt API at all, so they get a self-contained prompt+transcript on
    /// the clipboard and a single paste finishes the handoff.
    struct GuiTarget {
        let id: String        // stable identifier for CLI/menu
        let label: String     // human-readable menu title
        let kind: Kind

        enum Kind {
            case vscodeChat                      // code chat -n -a <file> "<prompt>"
            case cursorDeeplink                  // open repo, prompt via cursor:// deeplink + clipboard
            case appClipboard(appName: String)   // open -a <App>, everything on the clipboard
            case fileOpen(appName: String)       // open -a <App> <transcript.md> — the file attaches
            case folderOpen(appName: String)     // open -a <App> <session dir> — Cowork-style workspace
        }

        /// Whether launching this target needs a project folder.
        var needsRepo: Bool {
            switch kind {
            case .vscodeChat, .cursorDeeplink: return true
            case .appClipboard, .fileOpen, .folderOpen: return false
            }
        }
    }

    static let knownGuiTargets: [GuiTarget] = [
        GuiTarget(id: "copilot", label: "Copilot — VS Code", kind: .vscodeChat),
        GuiTarget(id: "cursor", label: "Cursor", kind: .cursorDeeplink),
        // Claude.app declares public.data as an accepted document type, so an
        // `open -a Claude <file>` genuinely attaches the transcript — no
        // clipboard blob. It also takes public.folder with an Editor role,
        // which is the Cowork folder-mount path: hand it the whole session
        // directory and the agent can read the audio, meta and transcript.
        GuiTarget(id: "claude", label: "Claude app — attach transcript", kind: .fileOpen(appName: "Claude")),
        GuiTarget(id: "claude-cowork", label: "Claude Cowork — session folder", kind: .folderOpen(appName: "Claude")),
        GuiTarget(id: "codex", label: "Codex — ChatGPT app", kind: .appClipboard(appName: "ChatGPT")),
        GuiTarget(id: "kimi", label: "Kimi app", kind: .appClipboard(appName: "Kimi")),
    ]

    /// VS Code's CLI, wherever it lives (PATH, or bundled inside the app).
    static func vscodeCLI() -> String? {
        if let onPath = find("code") { return onPath }
        let bundled = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : nil
    }

    static func cursorCLI() -> String? {
        if let onPath = find("cursor") { return onPath }
        let bundled = "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : nil
    }

    private static func appInstalled(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/\(name).app")
    }

    /// GUI targets actually available on this machine.
    static func installedGuiTargets() -> [GuiTarget] {
        knownGuiTargets.filter { target in
            switch target.kind {
            case .vscodeChat: return vscodeCLI() != nil
            case .cursorDeeplink: return cursorCLI() != nil || appInstalled("Cursor")
            case .appClipboard(let app), .fileOpen(let app), .folderOpen(let app):
                return appInstalled(app)
            }
        }
    }

    /// Open the handoff in a GUI. For vscode/cursor the transcript is staged
    /// in `repo`; for the chat apps the transcript rides along inline so no
    /// file access is needed.
    static func launchGui(target: GuiTarget, session: Session, repo: URL?) {
        switch target.kind {
        case .vscodeChat:
            guard let code = vscodeCLI(), let repo else { return }
            let staged = try? stage(session: session, inRepo: repo)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: code)
            var args = ["chat", "--new-window", "--mode", "agent"]
            if let staged { args += ["--add-file", staged.path] }
            args.append(prompt(for: session))
            p.arguments = args
            p.currentDirectoryURL = repo
            try? p.run()

        case .cursorDeeplink:
            guard let repo else { return }
            _ = try? stage(session: session, inRepo: repo)
            if let cursor = cursorCLI() {
                let openRepo = Process()
                openRepo.executableURL = URL(fileURLWithPath: cursor)
                openRepo.arguments = [repo.path]
                try? openRepo.run()
                openRepo.waitUntilExit()
            }
            // Cursor's documented prompt deeplink. Belt and braces: the same
            // prompt goes on the clipboard in case the deeplink is ignored.
            let text = prompt(for: session)
            pbcopy(text)
            if let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = ["cursor://anysphere.cursor-deeplink/prompt?text=\(encoded)"]
                try? open.run()
            }

        case .appClipboard(let appName):
            // No prompt API — everything self-contained on the clipboard:
            // instructions first, verbatim transcript below. One paste.
            let payload = appPrompt(for: session) + "\n\n---\n\n" + handoffDocument(for: session)
            pbcopy(payload)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", appName]
            try? open.run()
            open.waitUntilExit()
            autoPasteIfEnabled(app: appName)

        case .fileOpen(let appName):
            // The app accepts arbitrary files (public.data), so hand it the
            // transcript as an actual attachment. Instructions go on the
            // clipboard — attach + ⌘V + send.
            let doc = exportHandoffFile(for: session)
            pbcopy(attachPrompt(for: session))
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", appName, doc.path]
            try? open.run()

        case .folderOpen(let appName):
            // The app takes folders with an Editor role (Cowork-style
            // workspace): hand it the whole session directory — audio,
            // meta.json, transcript — and the agent works with the originals.
            _ = exportHandoffFile(for: session)   // ensure handoff.md is in the folder too
            pbcopy(folderPrompt(for: session))
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", appName, session.dir.path]
            try? open.run()
        }
    }

    /// Prompt for the file-attach path — the transcript arrives as an
    /// attachment, not inline.
    static func attachPrompt(for session: Session) -> String {
        """
        The attached file is the transcript of a meeting I just had \
        (\(session.duration), machine-transcribed on-device). Read it, work \
        out what it asks of me, then give me:

        1. Concrete work items it implies, ordered by what should happen first.
        2. Anything stated as a decision or constraint I shouldn't relitigate.
        3. Anything ambiguous, contradictory, or that reads like a transcription error — ask rather than guess.

        It's speech-to-text, so it's messy: unreliable punctuation, garbled \
        technical terms, 'me' and 'them' instead of names. Read for intent, \
        not literal wording.
        """
    }

    /// Prompt for the folder-workspace path — the whole session directory is
    /// the workspace.
    static func folderPrompt(for session: Session) -> String {
        """
        This folder is a recorded meeting session (\(session.duration)). \
        handoff.md and transcript.md hold the machine transcript ('me' = my \
        mic, 'them' = the other side); meta.json has the timing; the .caf \
        files are the raw audio. Read the transcript, work out what the \
        meeting asks of me, then give me:

        1. Concrete work items it implies, ordered by what should happen first.
        2. Anything stated as a decision or constraint I shouldn't relitigate.
        3. Anything ambiguous, contradictory, or that reads like a transcription error — ask rather than guess.

        It's speech-to-text, so read for intent, not literal wording.
        """
    }

    /// Write the self-describing handoff document next to the session's other
    /// files. Stable location, survives reboots, and is what gets dragged or
    /// attached. Idempotent.
    @discardableResult
    static func exportHandoffFile(for session: Session) -> URL {
        let out = session.dir.appendingPathComponent("handoff.md")
        try? handoffDocument(for: session).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// With `"auto_paste": true` in the config, finish the clipboard handoff
    /// ourselves: give the app a beat to open, then synthesize ⌘N (new chat)
    /// and ⌘V (paste). Needs Accessibility for baton; without it the
    /// osascript fails and we fall back to telling the user to paste.
    static func autoPasteIfEnabled(app: String) {
        guard Config.autoPaste() else { return }
        let script = """
        delay 1.2
        tell application "\(app)" to activate
        delay 0.4
        tell application "System Events"
            keystroke "n" using command down
            delay 0.5
            keystroke "v" using command down
        end tell
        """
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        try? osa.run()
        osa.waitUntilExit()
        if osa.terminationStatus != 0 {
            FileHandle.standardError.write(Data(
                "auto_paste failed — grant Accessibility to baton in System Settings → Privacy & Security\n".utf8
            ))
        }
    }

    /// Prompt variant for chat apps, where the transcript is pasted inline
    /// rather than staged as a repo file.
    static func appPrompt(for session: Session) -> String {
        """
        Below is the transcript of a meeting I just had (\(session.duration), \
        machine-transcribed). Work out what it asks of me, then give me:

        1. Concrete work items it implies, ordered by what should happen first.
        2. Anything stated as a decision or constraint I shouldn't relitigate.
        3. Anything ambiguous, contradictory, or that reads like a transcription error — ask rather than guess.

        It's speech-to-text, so it's messy: unreliable punctuation, garbled \
        technical terms, 'me'/'them' instead of names. Read for intent, not \
        literal wording.
        """
    }

    static func pbcopy(_ text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        p.standardInput = pipe
        try? p.run()
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try? pipe.fileHandleForWriting.close()
        p.waitUntilExit()
    }

    // MARK: - Sessions

    struct Session {
        let dir: URL
        let name: String
        let words: Int
        let segments: Int
        let duration: String
        let cleanStop: Bool
    }

    enum HandoffError: Error, CustomStringConvertible {
        case noSessions(root: URL)
        case sessionNotFound(String, root: URL)
        case notTranscribed(String)
        case emptyTranscript(String)
        case unknownAgent(String, available: [String])

        var description: String {
            switch self {
            case .noSessions(let root):
                return "no transcribed sessions in \(root.path) yet — record one from the menu bar first"
            case .sessionNotFound(let name, let root):
                return "no session '\(name)' in \(root.path)"
            case .notTranscribed(let name):
                return "session '\(name)' has no transcript yet; if it's still processing, check its transcribe.log"
            case .emptyTranscript(let name):
                return "session '\(name)' has a transcript file but no segments — both tracks likely failed; check its transcribe.log"
            case .unknownAgent(let name, let available):
                return "'\(name)' isn't installed or isn't an agent baton knows. Found here: \(available.isEmpty ? "none" : available.joined(separator: ", "))"
            }
        }
    }

    /// Resolve a session by name, or the newest transcribed one when nil.
    static func resolveSession(named: String?, root: URL) throws -> Session {
        let fm = FileManager.default

        let dir: URL
        if let named {
            dir = root.appendingPathComponent(named, isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else {
                throw HandoffError.sessionNotFound(named, root: root)
            }
            guard fm.fileExists(atPath: dir.appendingPathComponent("transcript.md").path) else {
                throw HandoffError.notTranscribed(named)
            }
        } else {
            let all = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let candidates = all
                .filter { fm.fileExists(atPath: $0.appendingPathComponent("transcript.md").path) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }   // yyyy.MM.dd-HHmm sorts by time
            guard let newest = candidates.first else {
                throw HandoffError.noSessions(root: root)
            }
            dir = newest
        }

        let transcript = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        let segments = transcript.components(separatedBy: "\n").filter { $0.hasPrefix("**[") }.count
        guard segments > 0 else {
            throw HandoffError.emptyTranscript(dir.lastPathComponent)
        }

        // Word count of the spoken text only, tags stripped.
        let words = transcript
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("**[") }
            .map { line -> String in
                guard let range = line.range(of: ":** ") else { return line }
                return String(line[range.upperBound...])
            }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .count

        var duration = "unknown"
        var cleanStop = true
        if let metaData = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
           let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
            if let secs = meta["duration_seconds"] as? Int {
                duration = "\(secs / 60)m\(String(format: "%02d", secs % 60))s"
            }
            cleanStop = meta["clean_stop"] as? Bool ?? true
        }

        return Session(
            dir: dir, name: dir.lastPathComponent,
            words: words, segments: segments,
            duration: duration, cleanStop: cleanStop
        )
    }

    // MARK: - Staging

    /// The handoff file: the verbatim transcript with a header telling the
    /// reader what it is, who the speakers are, and to expect ASR errors.
    static func handoffDocument(for session: Session) -> String {
        let transcript = (try? String(
            contentsOf: session.dir.appendingPathComponent("transcript.md"),
            encoding: .utf8
        )) ?? ""
        // Drop the original "# <name>" + engine lines; we write our own header.
        let body = transcript
            .components(separatedBy: "\n")
            .drop(while: { !$0.hasPrefix("**[") })
            .joined(separator: "\n")

        let truncationNote = session.cleanStop ? "" : " (recording ended uncleanly — may be truncated)"
        return """
        # Meeting transcript — \(session.name)

        - Duration: \(session.duration)\(truncationNote)
        - Speakers: `me` = this machine's microphone. `them` = everything the Mac \
        played, i.e. the other side of the call. Not real names.
        - Transcribed on-device. **Expect transcription errors**, especially in \
        proper nouns, identifiers and technical terms. If a term looks wrong but is \
        phonetically close to something plausible, it probably is that.
        - Source: `\(session.dir.path)`

        ---

        \(body)
        """
    }

    /// Write the handoff file into `repo/.meeting/` and make sure that folder
    /// can never land in a commit by accident (local git excludes, so we're
    /// not editing a tracked .gitignore in someone's repo).
    @discardableResult
    static func stage(session: Session, inRepo repo: URL) throws -> URL {
        let meetingDir = repo.appendingPathComponent(".meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)
        let out = meetingDir.appendingPathComponent("\(session.name).md")
        try handoffDocument(for: session).write(to: out, atomically: true, encoding: .utf8)

        // Resolve the actual git dir (handles worktrees and submodules).
        let gitDir = shell("/usr/bin/git", ["-C", repo.path, "rev-parse", "--absolute-git-dir"])
        if let gitDir, !gitDir.isEmpty {
            let exclude = URL(fileURLWithPath: gitDir).appendingPathComponent("info/exclude")
            let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
            if !existing.components(separatedBy: "\n").contains(".meeting/") {
                let addition = "\n# baton meeting transcripts — local only, never commit\n.meeting/\n"
                try? (existing + addition).write(to: exclude, atomically: true, encoding: .utf8)
            }
        }
        return out
    }

    // MARK: - The prompt

    static func prompt(for session: Session) -> String {
        """
        Read .meeting/\(session.name).md — the transcript of a meeting I just had, in this repo.

        Work out what it asks of this codebase, then tell me before changing anything:

        1. Concrete work items it implies, ordered by what should happen first, with the files or areas involved.
        2. Anything stated as a decision or constraint I shouldn't relitigate.
        3. Anything ambiguous, contradictory, or that reads like a transcription error — ask rather than guess.
        4. Anything discussed that the code already does, or already contradicts.

        It's speech-to-text, so it's messy: unreliable punctuation, garbled technical \
        terms, 'me'/'them' instead of names. Read for intent, not literal wording. \
        Don't edit anything until we've agreed the list.
        """
    }

    // MARK: - Launching (CLI path: replace this process with the agent)

    /// Launch the agent in the current terminal, replacing the baton process
    /// so the agent owns the TTY. Only returns on failure.
    static func exec(agent: Agent, at path: String, prompt: String, cwd: URL) -> Never {
        FileManager.default.changeCurrentDirectoryPath(cwd.path)

        var argv: [String]
        switch agent.launch {
        case .positionalPrompt:
            argv = [path, prompt]
        case .runSubcommand:
            argv = [path, "run", prompt]
        case .clipboardThenPlain:
            // kimi's interactive mode takes no initial prompt (-p is one-shot
            // and exits), so stage the prompt on the clipboard for a paste.
            let pb = Process()
            pb.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
            let pipe = Pipe()
            pb.standardInput = pipe
            try? pb.run()
            pipe.fileHandleForWriting.write(Data(prompt.utf8))
            try? pipe.fileHandleForWriting.close()
            pb.waitUntilExit()
            FileHandle.standardError.write(Data("prompt on your clipboard — paste it (⌘V) once \(agent.name) is up\n\n".utf8))
            argv = [path]
        }

        // execv replaces this process; the agent inherits the terminal.
        let cArgs = argv.map { strdup($0) } + [nil]
        execv(path, cArgs)
        // Only reached if execv failed.
        FileHandle.standardError.write(Data("failed to exec \(path): \(String(cString: strerror(errno)))\n".utf8))
        exit(1)
    }

    /// Launch the agent in a fresh Terminal window (menu-bar path, where
    /// there's no TTY to inherit).
    static func launchInTerminal(agent: Agent, prompt: String, cwd: URL) {
        // The prompt goes through a temp file → environment, never through
        // shell interpolation: transcript-derived text must not reach a shell.
        let stagedPrompt = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-prompt-\(UUID().uuidString).txt")
        try? prompt.write(to: stagedPrompt, atomically: true, encoding: .utf8)

        let launcher: String
        switch agent.launch {
        case .positionalPrompt:
            launcher = "\(agent.name) \"$(cat \(shq(stagedPrompt.path)))\"; rm -f \(shq(stagedPrompt.path))"
        case .runSubcommand:
            launcher = "\(agent.name) run \"$(cat \(shq(stagedPrompt.path)))\"; rm -f \(shq(stagedPrompt.path))"
        case .clipboardThenPlain:
            launcher = "cat \(shq(stagedPrompt.path)) | pbcopy; rm -f \(shq(stagedPrompt.path)); echo 'prompt on clipboard — ⌘V once \(agent.name) is up'; \(agent.name)"
        }
        let command = "cd \(shq(cwd.path)) && PATH=\(shq(searchDirs.joined(separator: ":"))):\"$PATH\" \(launcher)"

        let script = """
        tell application "Terminal"
            activate
            do script \(asQuote(command))
        end tell
        """
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        try? osa.run()
    }

    // MARK: - helpers

    /// Single-quote for POSIX shell.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote for an AppleScript string literal.
    private static func asQuote(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        + "\""
    }

    private static func shell(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
