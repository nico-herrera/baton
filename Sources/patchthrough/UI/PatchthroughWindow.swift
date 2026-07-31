import AppKit
import SwiftUI

/// Observable model behind the main window: the session list, the current
/// recording state, the target project folder, and the dispatch actions.
/// All UI state lives here; the window itself is dumb.
@MainActor
final class SessionStore: ObservableObject {

    struct Item: Identifiable {
        let id: String            // folder name, e.g. 2026.07.30-2145
        let dir: URL
        let duration: String
        let words: Int
        let segments: [Segment]
        let status: Status

        enum Status { case ready, pending, broken }
    }

    struct Segment: Identifiable {
        let id: Int
        let time: String
        let speaker: String
        let text: String
    }

    /// A place a transcript can be sent. Unifies terminal agents and GUI
    /// targets so the window renders them as one concept with two groups.
    struct Destination: Identifiable {
        let id: String
        let label: String
        let isTerminal: Bool
        let needsRepo: Bool

        /// Menu-length labels ("Copilot — VS Code") don't fit a button grid;
        /// the full label stays available as a tooltip.
        var shortLabel: String {
            label.components(separatedBy: " — ").first ?? label
        }
    }

    @Published var items: [Item] = []
    @Published var selection: String?
    @Published var isRecording = false
    @Published var elapsed = ""
    @Published var lastAction: String?
    @Published var repoPath: String {
        didSet { UserDefaults.standard.set(repoPath, forKey: "handoff.repo") }
    }

    let root: URL
    var onToggleRecording: (() -> Void)?

    init(root: URL) {
        self.root = root
        self.repoPath = UserDefaults.standard.string(forKey: "handoff.repo") ?? ""
    }

    var selected: Item? { items.first { $0.id == selection } }

    var destinations: [Destination] {
        let terminal = Handoff.installedAgents().map {
            Destination(id: "cli:\($0.agent.name)", label: $0.agent.name, isTerminal: true, needsRepo: true)
        }
        let gui = Handoff.installedGuiTargets().map { target in
            Destination(id: "gui:\(target.id)", label: target.label, isTerminal: false, needsRepo: target.needsRepo)
        }
        return terminal + gui
    }

    func refresh() {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        items = dirs.map { dir in
            let name = dir.lastPathComponent
            if let sess = try? Handoff.resolveSession(named: name, root: root) {
                return Item(id: name, dir: dir, duration: sess.duration, words: sess.words,
                            segments: Self.parseSegments(dir), status: .ready)
            }
            if fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) {
                return Item(id: name, dir: dir, duration: "", words: 0, segments: [], status: .pending)
            }
            return Item(id: name, dir: dir, duration: "", words: 0, segments: [], status: .broken)
        }

        if selection == nil || !items.contains(where: { $0.id == selection }) {
            selection = items.first(where: { $0.status == .ready })?.id
        }
    }

    /// Parse transcript.md lines of the form `**[0:00] me:** text` into rows.
    static func parseSegments(_ dir: URL) -> [Segment] {
        guard let text = try? String(
            contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8
        ) else { return [] }

        var out: [Segment] = []
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            guard line.hasPrefix("**["),
                  let close = line.range(of: "] "),
                  let colon = line.range(of: ":** ", range: close.upperBound..<line.endIndex)
            else { continue }
            out.append(Segment(
                id: n,
                time: String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound]),
                speaker: String(line[close.upperBound..<colon.lowerBound]),
                text: String(line[colon.upperBound...])
            ))
        }
        return out
    }

    // MARK: - Dispatch

    func send(_ item: Item, to dest: Destination) {
        guard let sess = try? Handoff.resolveSession(named: item.id, root: root) else {
            lastAction = "couldn't load \(item.id)"
            return
        }

        var repo: URL?
        if dest.needsRepo {
            guard let picked = resolveRepo() else { return }
            repo = picked
        }

        if dest.isTerminal {
            let name = String(dest.id.dropFirst(4))
            guard let match = Handoff.installedAgents().first(where: { $0.agent.name == name }),
                  let repo else { return }
            do { try Handoff.stage(session: sess, inRepo: repo) } catch {
                lastAction = "staging failed: \(error)"
                return
            }
            Handoff.launchInTerminal(agent: match.agent, prompt: Handoff.prompt(for: sess), cwd: repo)
            lastAction = "opened Terminal in \(repo.lastPathComponent) → \(name)"
        } else {
            let id = String(dest.id.dropFirst(4))
            guard let target = Handoff.installedGuiTargets().first(where: { $0.id == id }) else { return }
            Handoff.launchGui(target: target, session: sess, repo: repo)
            switch target.kind {
            case .appClipboard:
                lastAction = Config.autoPaste()
                    ? "\(dest.label) opened — pasting into a new chat…"
                    : "\(dest.label) opened — prompt + transcript on your clipboard, paste with ⌘V"
            case .fileOpen:
                lastAction = "\(dest.label) opened with the transcript attached — instructions on your clipboard (⌘V)"
            case .folderOpen:
                lastAction = "session folder opened in \(dest.label) — instructions on your clipboard (⌘V)"
            default:
                lastAction = "opened \(dest.label) in \(repo?.lastPathComponent ?? "?")"
            }
        }
    }

    /// The file used for drag-out: the self-describing handoff document,
    /// exported into the session folder.
    func dragFile(for item: Item) -> URL? {
        guard let sess = try? Handoff.resolveSession(named: item.id, root: root) else { return nil }
        return Handoff.exportHandoffFile(for: sess)
    }

    /// The project folder for repo-based destinations: the remembered path if
    /// it still exists, otherwise ask.
    private func resolveRepo() -> URL? {
        let expanded = NSString(string: repoPath).expandingTildeInPath
        var isDir: ObjCBool = false
        if !expanded.isEmpty,
           FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: expanded)
        }
        return pickRepo()
    }

    func pickRepo() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose the project this meeting was about — the session starts there."
        panel.prompt = "Use this folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Developer", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        repoPath = url.path
        return url
    }
}

// MARK: - Views

struct PatchthroughRootView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                sessionList
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)
                detail
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 600)
        .onAppear { store.refresh() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                store.onToggleRecording?()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.isRecording ? Color.red : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(store.isRecording ? "Stop recording · \(store.elapsed)" : "Start recording")
                        .monospacedDigit()
                }
            }
            Spacer()
            Button("Refresh") { store.refresh() }
            Button("Open folder") { NSWorkspace.shared.open(store.root) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sessionList: some View {
        List(selection: $store.selection) {
            ForEach(store.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.id).font(.system(.body, design: .monospaced))
                    switch item.status {
                    case .ready:
                        Text("\(item.duration) · \(item.words) words")
                            .font(.caption).foregroundStyle(.secondary)
                    case .pending:
                        Text("transcribing…").font(.caption).foregroundStyle(.orange)
                    case .broken:
                        Text("interrupted — no meta.json").font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 2)
                .tag(item.id)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let item = store.selected, item.status == .ready {
            VStack(spacing: 0) {
                dragHeader(item)
                Divider()
                transcriptView(item)
                Divider()
                handoffBar(item)
            }
        } else {
            VStack(spacing: 8) {
                Text(store.items.isEmpty ? "No recordings yet" : "Nothing selected")
                    .font(.title3).foregroundStyle(.secondary)
                Text(store.items.isEmpty
                     ? "Start a recording — sessions appear here when transcribed."
                     : "Pick a transcribed session on the left.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The universal handoff: a draggable chip. Every chat app accepts a file
    /// dropped on its input — Claude, ChatGPT, Kimi, Cursor's chat pane — so
    /// drag works even for apps patchthrough has no button for.
    private func dragHeader(_ item: SessionStore.Item) -> some View {
        HStack(spacing: 10) {
            Text(item.id).font(.system(.body, design: .monospaced))
            Text("\(item.duration) · \(item.words) words")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.caption)
                Text("drag into any chat")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .onDrag {
                guard let url = store.dragFile(for: item) else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
            .help("Drag the transcript file into Claude, ChatGPT, Kimi, or anywhere else that takes a file")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func transcriptView(_ item: SessionStore.Item) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(item.segments) { seg in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(seg.time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 44, alignment: .trailing)
                        Text(seg.speaker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(seg.speaker == "me" ? Color.blue : Color.purple)
                            .frame(width: 42, alignment: .leading)
                        Text(seg.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(14)
        }
    }

    private func handoffBar(_ item: SessionStore.Item) -> some View {
        let dests = store.destinations
        let terminal = dests.filter(\.isTerminal)
        let gui = dests.filter { !$0.isTerminal }
        let columns = [GridItem(.adaptive(minimum: 116), spacing: 6)]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Project").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                TextField("~/Developer/your-project", text: $store.repoPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Button("Choose…") { _ = store.pickRepo() }
            }

            if !terminal.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Terminal session").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(terminal) { dest in
                            Button(dest.label) { store.send(item, to: dest) }
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }

            if !gui.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("App").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(gui) { dest in
                            Button(dest.shortLabel) { store.send(item, to: dest) }
                                .frame(maxWidth: .infinity)
                                .help(dest.label)
                        }
                    }
                }
            }

            if let action = store.lastAction {
                Text(action)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }
}

// MARK: - Window plumbing

@MainActor
final class PatchthroughWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
        super.init()
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "patchthrough"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: PatchthroughRootView(store: store))
            // Open on whichever screen has the pointer — with several displays,
            // centering on the "main" screen puts the window somewhere the user
            // isn't looking.
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main {
                let f = screen.visibleFrame
                w.setFrameOrigin(NSPoint(
                    x: f.midX - w.frame.width / 2,
                    y: f.midY - w.frame.height / 2
                ))
            } else {
                w.center()
            }
            window = w
        }
        store.refresh()

        // An .accessory app can show a window but can't properly own focus or
        // a menu bar. Promote to .regular while the window is up, and drop back
        // when it closes, so it behaves like a normal app while visible and
        // stays out of the Dock the rest of the time.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()

        if ProcessInfo.processInfo.environment["PATCHTHROUGH_DEBUG_WINDOW"] != nil, let w = window {
            FileHandle.standardError.write(Data("""
            window: visible=\(w.isVisible) key=\(w.isKeyWindow) \
            frame=\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)) \
            \(Int(w.frame.width))x\(Int(w.frame.height)) \
            screen=\(w.screen?.localizedName ?? "none") \
            level=\(w.level.rawValue) sessions=\(store.items.count)\n
            """.utf8))
        }
    }

    /// Back to accessory when the window closes: no Dock icon, menu bar only.
    /// The daemon keeps running either way — closing the window never stops a
    /// recording.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
