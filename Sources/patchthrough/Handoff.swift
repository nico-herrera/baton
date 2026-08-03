import AppKit
import ApplicationServices
import Foundation

/// The handoff: take a finished transcript and put it in front of a coding
/// agent. The prompt tells the agent to treat the transcript as messy
/// speech-to-text rather than gospel. Patchthrough passes the transcript
/// verbatim and adds no summary step. A lossy summary is where requirements
/// get dropped quietly.
enum Handoff {

    // MARK: - Agents

    /// A coding agent we know how to launch. `positionalPrompt` means
    /// `<binary> "<prompt>"` starts an interactive session with the prompt
    /// loaded; the exceptions get their own launch style.
    struct Agent {
        let name: String
        let launch: LaunchStyle

        /// SF Symbol for the UI. Chosen to say something about the target
        /// rather than decorate it: a moon for Kimi (Moonshot), braces for
        /// opencode, a cursor for Cursor.
        var symbol: String { Handoff.symbol(for: name) }

        /// Menu label. The `claude` binary ships as the product "Claude
        /// Code", and the label must say what users look for, especially
        /// next to the separate "Claude app" destination. Every other agent
        /// keeps its binary name.
        var displayName: String { name == "claude" ? "Claude Code" : name }

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
    /// prompt API at all, so they get the self-contained handoff file on the
    /// clipboard and a single paste attaches it.
    struct GuiTarget {
        let id: String        // stable identifier for CLI/menu
        let label: String     // human-readable menu title
        let kind: Kind

        enum Kind {
            case vscodeChat                      // code chat -n -a <file> "<prompt>"
            case cursorDeeplink                  // open repo, prompt via cursor:// deeplink + clipboard
            case appClipboard(appName: String)   // open -a <App>, handoff file on the clipboard
            case claudeChat                      // claude://claude.ai/new deeplink + handoff file on the clipboard
            case claudeCode                      // claude://code/new deeplink, repo mounted, transcript staged
        }

        /// The M365 Copilot composer (WebView2) swallows synthetic clicks
        /// and keystrokes, and drops pasted file references even from a
        /// human ⌘V (verified against 1.2607). Text is the only payload
        /// that pastes, so this target stages the full handoff document as
        /// text and leaves the paste to the user. A very long transcript
        /// can exceed the composer's input limit; that is the app's
        /// ceiling, not ours.
        var manualTextPaste: Bool { id == "m365-copilot" }

        /// Whether launching this target needs a project folder.
        var needsRepo: Bool {
            switch kind {
            case .vscodeChat, .cursorDeeplink, .claudeCode: return true
            case .appClipboard, .claudeChat: return false
            }
        }
    }

    static let knownGuiTargets: [GuiTarget] = [
        GuiTarget(id: "copilot", label: "VS Code (Copilot)", kind: .vscodeChat),
        GuiTarget(id: "cursor", label: "Cursor", kind: .cursorDeeplink),
        // Claude.app registers the claude:// scheme. Its handler routes
        // claude.ai/new?q= to a fresh chat composer, and code/new?q=&folder=
        // to a new Claude Code session with the folders mounted. Verified
        // against the 1.24012.9 bundle; the scheme is undocumented, so a
        // future app version could change it. The chat entry still attaches
        // handoff.md from the clipboard (the composer only takes text). The
        // code entry mounts the project the meeting was about and reads the
        // transcript staged into it, the same as the terminal agents.
        GuiTarget(id: "claude", label: "Claude Chat/Cowork", kind: .claudeChat),
        GuiTarget(id: "claude-code", label: "Claude Code (app)", kind: .claudeCode),
        GuiTarget(id: "codex", label: "Codex (ChatGPT app)", kind: .appClipboard(appName: "ChatGPT")),
        GuiTarget(id: "kimi", label: "Kimi app", kind: .appClipboard(appName: "Kimi")),
        // The work app ("Microsoft 365 Copilot.app", com.microsoft.m365copilot).
        // Microsoft's consumer chat app is a different bundle (plain
        // "Copilot.app", com.copilot.production); add it here if it ever
        // needs a door.
        GuiTarget(id: "m365-copilot", label: "Microsoft 365 Copilot",
                  kind: .appClipboard(appName: "Microsoft 365 Copilot")),
    ]

    /// SF Symbols per destination. Keyed by id so terminal agents and GUI
    /// targets stay visually consistent. `claude` looks like `claude`
    /// whichever door the handoff uses.
    static func symbol(for id: String) -> String {
        switch id {
        case "claude":        return "sparkle"
        case "copilot":       return "chevron.left.forwardslash.chevron.right"
        case "codex":         return "bubble.left.and.text.bubble.right"
        case "cursor", "cursor-agent": return "cursorarrow.rays"
        case "kimi":          return "moon.stars"       // Moonshot AI
        case "opencode":      return "curlybraces"
        default:              return "terminal"
        }
    }

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
            case .appClipboard(let app):
                return appInstalled(app)
            case .claudeChat, .claudeCode:
                return appInstalled("Claude")
            }
        }
    }

    /// Open the handoff in a GUI. For vscode/cursor the transcript is staged
    /// in `repo`; for the chat apps the handoff file rides along on the
    /// clipboard so no file access is needed.
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
            // No prompt API. The clipboard carries handoff.md as a file
            // reference: pasting attaches the file, the same as dragging it
            // in. The file is self-contained (instructions, then the verbatim
            // transcript), and an attachment scales to any transcript length
            // where inline text would flood the app's input box. Targets
            // whose composer drops file pastes get the document as text
            // instead; text is the only payload that reaches them.
            if target.manualTextPaste {
                pbcopy(handoffDocument(for: session))
            } else {
                copyFileReference(exportHandoffFile(for: session))
            }
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", appName]
            try? open.run()
            open.waitUntilExit()

        case .claudeChat:
            // The deeplink opens a guaranteed-fresh chat with the
            // instructions prefilled, so the follow-up paste is ⌘V only. A
            // synthesized ⌘N lands wherever focus happens to be; the
            // deeplink does not.
            copyFileReference(exportHandoffFile(for: session))
            openClaudeDeeplink(host: "claude.ai", query: [("q", chatPrompt(for: session))])

        case .claudeCode:
            // The workspace is the project the meeting was about, not the
            // recording folder. The transcript stages into the repo the same
            // way the terminal agents get it (.meeting/<session>.md, kept
            // out of commits), and the deeplink prompt points at it. The app
            // slices q at 1024 characters, which the shared prompt fits. No
            // clipboard, no keystrokes.
            guard let repo else { return }
            _ = try? stage(session: session, inRepo: repo)
            openClaudeDeeplink(host: "code", query: [
                ("q", prompt(for: session)),
                ("folder", repo.path),
            ])
        }
    }

    /// `claude://<host>/new?<query>`. Values are percent-encoded down to
    /// alphanumerics: the app parses the query with URLSearchParams, which
    /// also decodes `+` as a space, so anything milder corrupts the prompt.
    private static func openClaudeDeeplink(host: String, query: [(String, String)]) {
        let qs = query.compactMap { key, value in
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                .map { "\(key)=\($0)" }
        }.joined(separator: "&")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["claude://\(host)/new?\(qs)"]
        try? open.run()
        open.waitUntilExit()
    }

    /// Write the self-describing handoff document next to the session's other
    /// files. Stable location, survives reboots, and is what gets dragged or
    /// attached. Idempotent.
    static func writeHandoffFile(for session: Session) throws -> URL {
        let out = session.dir.appendingPathComponent("handoff.md")
        try handoffDocument(for: session).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// UI actions should remain available even if a session folder becomes
    /// unwritable between refresh and click. The transcription pipeline uses
    /// the throwing variant above so it can record a useful warning.
    @discardableResult
    static func exportHandoffFile(for session: Session) -> URL {
        let out = session.dir.appendingPathComponent("handoff.md")
        _ = try? writeHandoffFile(for: session)
        return out
    }

    /// Finish a clipboard handoff: give the app a beat to open, then
    /// synthesize ⌘N (new chat) and ⌘V (paste). Pass `newChat: false` when a
    /// deeplink already opened the fresh chat, so only the ⌘V fires. The
    /// script's delays block for about two seconds, so UI callers run this
    /// off the main thread. Returns false when the paste did not happen, and
    /// callers own that messaging.
    ///
    /// The Accessibility check is not redundant. Without the grant, System
    /// Events accepts the keystrokes and osascript still exits 0, so the exit
    /// status alone reports success for a paste that never landed. Checking
    /// first also means no keystrokes get injected into whatever window is
    /// frontmost when the paste cannot work anyway.
    static func autoPaste(app: String, newChat: Bool) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        var lines = [
            "delay 1.2",
            "tell application \"\(app)\" to activate",
            "delay 0.4",
            "tell application \"System Events\"",
        ]
        if newChat {
            lines += ["    keystroke \"n\" using command down", "    delay 0.5"]
        }
        lines += ["    keystroke \"v\" using command down", "end tell"]
        let script = lines.joined(separator: "\n")
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        do { try osa.run() } catch { return false }
        osa.waitUntilExit()
        return osa.terminationStatus == 0
    }

    /// Prompt the chat deeplink prefills in the composer. The transcript
    /// arrives separately, as an attached handoff.md.
    static func chatPrompt(for session: Session) -> String {
        """
        The attached handoff.md is the transcript of a meeting I just had \
        (\(session.duration), machine-transcribed on-device). Read it, work \
        out what it asks of me, then give me:

        1. Concrete work items it implies, ordered by what should happen first.
        2. Anything stated as a decision or constraint I shouldn't relitigate.
        3. Anything ambiguous or contradictory, and anything that reads like a transcription error. Ask me rather than guess.

        It's speech-to-text, so it's messy: unreliable punctuation, garbled \
        technical terms, 'me' and 'them' instead of names. Read for intent, \
        not literal wording.
        """
    }

    /// Instructions that travel inside every handoff document. Keeping them
    /// with the transcript means attachments, dragged files, folder handoffs,
    /// and clipboard handoffs all tell the receiving agent what to do.
    static func taskInstructions(for session: Session) -> String {
        """
        Read the transcript below and work out what this meeting asks of me. \
        Before changing anything, give me:

        1. Concrete work items it implies, ordered by what should happen first.
        2. Anything stated as a decision or constraint I shouldn't relitigate.
        3. Anything ambiguous or contradictory, and anything that reads like a transcription error. Ask me rather than guess.
        4. Anything discussed that the current project may already do or contradict.

        It's speech-to-text, so it's messy: unreliable punctuation, garbled \
        technical terms, 'me'/'them' instead of names. Read for intent, not \
        literal wording. Don't edit anything until we've agreed the list.
        """
    }

    /// Put a file reference on the clipboard: the file itself, not its path
    /// as text. Pasting into a chat input then attaches the file, the same
    /// as dragging it in.
    static func copyFileReference(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
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
                return "no transcribed sessions in \(root.path) yet. Record one from the menu bar first"
            case .sessionNotFound(let name, let root):
                return "no session '\(name)' in \(root.path)"
            case .notTranscribed(let name):
                return "session '\(name)' has no transcript yet; if it's still processing, check its transcribe.log"
            case .emptyTranscript(let name):
                return "session '\(name)' has a transcript file but no segments. Both tracks probably failed. Check its transcribe.log"
            case .unknownAgent(let name, let available):
                return "'\(name)' isn't installed or isn't an agent patchthrough knows. Found here: \(available.isEmpty ? "none" : available.joined(separator: ", "))"
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

        let truncationNote = session.cleanStop ? "" : " (recording ended uncleanly, so the transcript may be truncated)"
        return """
        # Meeting handoff: \(session.name)

        ## Instructions

        \(taskInstructions(for: session))

        ## Recording

        - Duration: \(session.duration)\(truncationNote)
        - Speakers: `me` = this machine's microphone. `them` = everything the Mac \
        played, i.e. the other side of the call. Not real names.
        - Transcribed on-device. **Expect transcription errors**, especially in \
        proper nouns, identifiers and technical terms. If a term looks wrong but is \
        phonetically close to something plausible, it probably is that.
        - Source: `\(session.dir.path)`

        ## Transcript

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
                let addition = "\n# patchthrough meeting transcripts: local only, never commit\n.meeting/\n"
                try? (existing + addition).write(to: exclude, atomically: true, encoding: .utf8)
            }
        }
        return out
    }

    // MARK: - The prompt

    static func prompt(for session: Session) -> String {
        """
        Read .meeting/\(session.name).md. That file is the transcript of a meeting I just had in this repo.

        Work out what it asks of this codebase, then tell me before changing anything:

        1. Concrete work items it implies, ordered by what should happen first, with the files or areas involved.
        2. Anything stated as a decision or constraint I shouldn't relitigate.
        3. Anything ambiguous or contradictory, and anything that reads like a transcription error. Ask me rather than guess.
        4. Anything discussed that the code already does, or already contradicts.

        It's speech-to-text, so it's messy: unreliable punctuation, garbled technical \
        terms, 'me'/'them' instead of names. Read for intent, not literal wording. \
        Don't edit anything until we've agreed the list.
        """
    }

    // MARK: - Launching (CLI path: replace this process with the agent)

    /// Launch the agent in the current terminal, replacing the patchthrough process
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
            FileHandle.standardError.write(Data("prompt on your clipboard. Paste it (⌘V) once \(agent.name) is up\n\n".utf8))
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
    static func launchInTerminal(agent: Agent, at path: String, prompt: String, cwd: URL) {
        // The prompt goes through a temp file → environment, never through
        // shell interpolation: transcript-derived text must not reach a shell.
        let stagedPrompt = FileManager.default.temporaryDirectory
            .appendingPathComponent("patchthrough-prompt-\(UUID().uuidString).txt")
        try? prompt.write(to: stagedPrompt, atomically: true, encoding: .utf8)

        let launcher: String
        switch agent.launch {
        case .positionalPrompt:
            launcher = "\(shq(path)) \"$(cat \(shq(stagedPrompt.path)))\"; rm -f \(shq(stagedPrompt.path))"
        case .runSubcommand:
            launcher = "\(shq(path)) run \"$(cat \(shq(stagedPrompt.path)))\"; rm -f \(shq(stagedPrompt.path))"
        case .clipboardThenPlain:
            launcher = "cat \(shq(stagedPrompt.path)) | pbcopy; rm -f \(shq(stagedPrompt.path)); echo 'prompt on clipboard. Press ⌘V once \(agent.name) is up'; \(shq(path))"
        }
        let command = "cd \(shq(cwd.path)) && PATH=\(shq(searchDirs.joined(separator: ":"))):\"$PATH\" \(launcher)"

        // The user picks the terminal. That app supplies the shell profile, and
        // therefore the agent's environment, instead of Terminal.app.
        TerminalApp.current().run(command)
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
