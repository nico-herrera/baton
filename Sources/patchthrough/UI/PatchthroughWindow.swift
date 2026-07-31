import AppKit
import SwiftUI

/// Observable model behind the main window: the session list, the current
/// recording state, the target project folder, and the dispatch actions.
/// All UI state lives here; the views are dumb.
@MainActor
final class SessionStore: ObservableObject {

    struct Item: Identifiable {
        let id: String            // folder name, e.g. 2026.07.30-2145
        let dir: URL
        let date: Date?
        let duration: String
        let words: Int
        let segments: [Segment]
        let status: Status
        let cleanStop: Bool

        enum Status { case ready, pending, broken }

        var statusSymbol: String {
            switch status {
            case .ready:   return cleanStop ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            case .pending: return "clock.arrow.circlepath"
            case .broken:  return "exclamationmark.triangle.fill"
            }
        }
        var statusColor: Color {
            switch status {
            case .ready:   return cleanStop ? .secondary : .orange
            case .pending: return .orange
            case .broken:  return .red
            }
        }
        var subtitle: String {
            switch status {
            case .ready:   return "\(duration) · \(words) words" + (cleanStop ? "" : " · truncated")
            case .pending: return "transcribing…"
            case .broken:  return "interrupted — no meta.json"
            }
        }
    }

    struct Segment: Identifiable {
        let id: Int
        let time: String
        let speaker: String
        let text: String
    }

    /// A place a transcript can be sent. Unifies terminal agents and GUI
    /// targets so the window renders them as one concept in two groups.
    struct Destination: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let isTerminal: Bool
        let needsRepo: Bool

        /// Menu-length labels ("Copilot — VS Code") don't fit a button grid;
        /// the full label stays available as a tooltip.
        var shortLabel: String { label.components(separatedBy: " — ").first ?? label }
    }

    @Published var items: [Item] = []
    @Published var selection: String?
    @Published var isRecording = false
    @Published var elapsed = ""
    @Published var lastAction: String?
    @Published var search = ""
    @Published var showSettings = false
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

    /// Sessions matching the search box, by name or transcript content.
    var visibleItems: [Item] {
        guard !search.isEmpty else { return items }
        let q = search.lowercased()
        return items.filter { item in
            item.id.lowercased().contains(q)
                || item.segments.contains { $0.text.lowercased().contains(q) }
        }
    }

    /// Sessions bucketed into Today / Yesterday / older, for section headers.
    var groupedItems: [(title: String, items: [Item])] {
        let cal = Calendar.current
        var buckets: [(String, [Item])] = []
        for item in visibleItems {
            let title: String
            if let d = item.date {
                if cal.isDateInToday(d) { title = "Today" }
                else if cal.isDateInYesterday(d) { title = "Yesterday" }
                else if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
                    title = d.formatted(.dateTime.weekday(.wide))
                } else {
                    title = d.formatted(.dateTime.month(.abbreviated).day().year())
                }
            } else {
                title = "Undated"
            }
            if let i = buckets.firstIndex(where: { $0.0 == title }) {
                buckets[i].1.append(item)
            } else {
                buckets.append((title, [item]))
            }
        }
        return buckets.map { (title: $0.0, items: $0.1) }
    }

    var destinations: [Destination] {
        let terminal = Handoff.installedAgents().map {
            Destination(id: "cli:\($0.agent.name)", label: $0.agent.name,
                        symbol: $0.agent.symbol, isTerminal: true, needsRepo: true)
        }
        let gui = Handoff.installedGuiTargets().map { t in
            Destination(id: "gui:\(t.id)", label: t.label, symbol: Handoff.symbol(for: t.id),
                        isTerminal: false, needsRepo: t.needsRepo)
        }
        return terminal + gui
    }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func refresh() {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        items = dirs.map { dir in
            let name = dir.lastPathComponent
            // Folder names carry the timestamp; strip any "-2" collision suffix.
            let stamp = name.split(separator: "-").prefix(2).joined(separator: "-")
            let date = Self.folderFormat.date(from: stamp)

            if let sess = try? Handoff.resolveSession(named: name, root: root) {
                return Item(id: name, dir: dir, date: date, duration: sess.duration,
                            words: sess.words, segments: Self.parseSegments(dir),
                            status: .ready, cleanStop: sess.cleanStop)
            }
            let hasMeta = fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path)
            return Item(id: name, dir: dir, date: date, duration: "", words: 0, segments: [],
                        status: hasMeta ? .pending : .broken, cleanStop: true)
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
                    ? "\(dest.shortLabel) opened — pasting into a new chat…"
                    : "\(dest.shortLabel) opened — prompt + transcript on your clipboard (⌘V)"
            case .fileOpen:
                lastAction = "\(dest.shortLabel) opened with the transcript attached — instructions on your clipboard (⌘V)"
            case .folderOpen:
                lastAction = "session folder opened in \(dest.shortLabel) — instructions on your clipboard (⌘V)"
            default:
                lastAction = "opened \(dest.shortLabel) in \(repo?.lastPathComponent ?? "?")"
            }
        }
    }

    /// The file used for drag-out: the self-describing handoff document.
    func dragFile(for item: Item) -> URL? {
        guard let sess = try? Handoff.resolveSession(named: item.id, root: root) else { return nil }
        return Handoff.exportHandoffFile(for: sess)
    }

    func copyTranscript(_ item: Item) {
        guard let sess = try? Handoff.resolveSession(named: item.id, root: root) else { return }
        Handoff.pbcopy(Handoff.handoffDocument(for: sess))
        lastAction = "transcript copied to the clipboard"
    }

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

// MARK: - Root view

struct PatchthroughRootView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        NavigationSplitView {
            sessionList
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 860, minHeight: 660)
        .toolbar { toolbarContent }
        .searchable(text: $store.search, placement: .sidebar, prompt: "Search transcripts")
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
        .onAppear { store.refresh() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                store.onToggleRecording?()
            } label: {
                Label(
                    store.isRecording ? "Stop recording · \(store.elapsed)" : "Record",
                    systemImage: store.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .monospacedDigit()
            }
            .help(store.isRecording ? "Stop and transcribe" : "Start recording mic + system audio")
            .keyboardShortcut("r", modifiers: .command)
            .tint(store.isRecording ? .red : nil)
        }
        ToolbarItemGroup {
            if let item = store.selected, item.status == .ready {
                Button { store.copyTranscript(item) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the transcript to the clipboard")
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            Button { store.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button { NSWorkspace.shared.open(store.root) } label: {
                Label("Recordings folder", systemImage: "folder")
            }
            Button { store.showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    // MARK: Sidebar

    private var sessionList: some View {
        List(selection: $store.selection) {
            ForEach(store.groupedItems, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.statusSymbol)
                                .foregroundStyle(item.statusColor)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(timeLabel(item))
                                    .font(.system(.body, design: .rounded))
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(item.status == .ready ? .secondary : item.statusColor)
                            }
                        }
                        .padding(.vertical, 1)
                        .tag(item.id)
                        .help(item.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.visibleItems.isEmpty {
                emptySidebar
            }
        }
    }

    private func timeLabel(_ item: SessionStore.Item) -> String {
        guard let d = item.date else { return item.id }
        return d.formatted(date: .omitted, time: .shortened)
    }

    private var emptySidebar: some View {
        VStack(spacing: 6) {
            Image(systemName: store.search.isEmpty ? "waveform" : "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(store.search.isEmpty ? "No recordings" : "No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
    }

    // MARK: Detail

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
        } else if let item = store.selected, item.status == .pending {
            placeholder(
                symbol: "clock.arrow.circlepath",
                title: "Transcribing \(item.id)",
                detail: "This usually takes about 20 seconds per hour of audio. The list updates when it lands."
            )
        } else if let item = store.selected, item.status == .broken {
            placeholder(
                symbol: "exclamationmark.triangle",
                title: "\(item.id) was interrupted",
                detail: "No meta.json, so nothing will pick it up. The audio files are still in the session folder."
            )
        } else {
            placeholder(
                symbol: "waveform.badge.mic",
                title: store.items.isEmpty ? "No recordings yet" : "Nothing selected",
                detail: store.items.isEmpty
                    ? "Press ⌘R or click Record. Your mic and everything your Mac plays are captured as two tracks, then transcribed on-device."
                    : "Pick a session on the left."
            )
        }
    }

    private func placeholder(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The universal handoff: a draggable chip. Every chat app accepts a file
    /// dropped on its input, so drag works even for apps with no button.
    private func dragHeader(_ item: SessionStore.Item) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.id).font(.system(.callout, design: .monospaced))
                Text("\(item.duration) · \(item.words) words · \(item.segments.count) segments")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label("drag into any chat", systemImage: "arrow.up.doc.on.clipboard")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .onDrag {
                    guard let url = store.dragFile(for: item) else { return NSItemProvider() }
                    return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                }
                .help("Drag the transcript file into Claude, ChatGPT, Kimi, or anything else that takes a file")
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
                            .frame(width: 42, alignment: .trailing)
                        Label {
                            Text(seg.speaker).font(.caption.weight(.semibold))
                        } icon: {
                            Image(systemName: seg.speaker == "me" ? "mic.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(seg.speaker == "me" ? Color.accentColor : Color.purple)
                        .frame(width: 58, alignment: .leading)
                        Text(highlighted(seg.text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(14)
        }
    }

    /// Bold the search term inside transcript lines so hits are findable.
    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard !store.search.isEmpty else { return out }
        var cursor = out.startIndex
        while let r = out[cursor...].range(of: store.search, options: .caseInsensitive) {
            out[r].inlinePresentationIntent = .stronglyEmphasized
            out[r].backgroundColor = .yellow.opacity(0.25)
            cursor = r.upperBound
            if cursor >= out.endIndex { break }
        }
        return out
    }

    private func handoffBar(_ item: SessionStore.Item) -> some View {
        let dests = store.destinations
        let terminal = dests.filter(\.isTerminal)
        let gui = dests.filter { !$0.isTerminal }
        let columns = [GridItem(.adaptive(minimum: 132), spacing: 6)]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Project", systemImage: "folder.badge.gearshape")
                    .font(.caption).foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                TextField("~/Developer/your-project", text: $store.repoPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Button("Choose…") { _ = store.pickRepo() }
            }

            if !terminal.isEmpty {
                destinationGroup("Terminal session", terminal, columns: columns, item: item)
            }
            if !gui.isEmpty {
                destinationGroup("App", gui, columns: columns, item: item)
            }

            if let action = store.lastAction {
                Label(action, systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private func destinationGroup(
        _ title: String, _ dests: [SessionStore.Destination],
        columns: [GridItem], item: SessionStore.Item
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(dests) { dest in
                    Button {
                        store.send(item, to: dest)
                    } label: {
                        Label(dest.shortLabel, systemImage: dest.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help(dest.label)
                }
            }
        }
    }
}

// MARK: - Settings

/// The config file, as a form. Every knob here was previously only reachable
/// by hand-editing ~/.config/patchthrough/config.json, which nobody you hand
/// this to is going to do.
struct SettingsView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var recordingsDir = ""
    @State private var transcribe = true
    @State private var voiceProcessing = false
    @State private var autoPaste = false
    @State private var onStop = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    HStack {
                        TextField("Recordings folder", text: $recordingsDir, prompt: Text("~/Recordings"))
                            .font(.system(.body, design: .monospaced))
                        Button("Choose…") { chooseFolder() }
                    }
                } header: {
                    Text("Where recordings go")
                } footer: {
                    Text("Takes effect for the next recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Transcription") {
                    Toggle("Transcribe automatically after each recording", isOn: $transcribe)
                    Toggle("Echo cancellation on the mic", isOn: $voiceProcessing)
                }

                Section {
                    Toggle("Paste automatically after a clipboard handoff", isOn: $autoPaste)
                } header: {
                    Text("Handoff")
                } footer: {
                    Text("Synthesizes ⌘N then ⌘V once the app opens. Needs Accessibility permission; it never presses send.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    TextField("Command", text: $onStop, prompt: Text("my-hook"))
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Run after each transcript")
                } footer: {
                    Text("Runs with the session folder as its only argument. Leave empty for none.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.caption)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Reveal config file") {
                    NSWorkspace.shared.activateFileViewerSelecting([Config.configPath])
                }
                .font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 540, height: 560)
        .onAppear(perform: load)
    }

    private func load() {
        let resolved = Config.resolveRoot(cliOverride: nil).path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        recordingsDir = resolved.replacingOccurrences(of: home, with: "~")
        transcribe = Config.transcriptionEnabledValue()
        voiceProcessing = Config.micVoiceProcessing()
        autoPaste = Config.autoPaste()
        onStop = Config.onStop() ?? ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            recordingsDir = url.path.replacingOccurrences(of: home, with: "~")
        }
    }

    private func save() {
        // Only write keys that differ from the default, so the config stays a
        // list of deliberate choices rather than a dump of everything.
        let trimmedDir = recordingsDir.trimmingCharacters(in: .whitespaces)
        let trimmedHook = onStop.trimmingCharacters(in: .whitespaces)
        do {
            try Config.update([
                "recordings_dir": (trimmedDir.isEmpty || trimmedDir == "~/Recordings") ? nil : trimmedDir,
                "transcription.enabled": transcribe ? nil : false,
                "mic_voice_processing": voiceProcessing ? true : nil,
                "auto_paste": autoPaste ? true : nil,
                "on_stop": trimmedHook.isEmpty ? nil : trimmedHook,
            ])
            store.lastAction = "settings saved to \(Config.configPath.lastPathComponent)"
            dismiss()
        } catch {
            self.error = "Couldn't write the config: \(error.localizedDescription)"
        }
    }
}

// MARK: - Window plumbing

@MainActor
final class PatchthroughWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: SessionStore
    private static let frameKey = "window.frame"

    init(store: SessionStore) {
        self.store = store
        super.init()
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Patchthrough"
            w.titlebarAppearsTransparent = false
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: PatchthroughRootView(store: store))

            // Restore the last frame; otherwise open on whichever screen has
            // the pointer — with several displays, centering on the "main"
            // screen puts the window somewhere the user isn't looking.
            if let saved = UserDefaults.standard.string(forKey: Self.frameKey),
               !saved.isEmpty {
                w.setFrame(NSRectFromString(saved), display: false)
            } else if let screen = NSScreen.screens.first(where: {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            }) ?? NSScreen.main {
                let f = screen.visibleFrame
                w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2,
                                         y: f.midY - w.frame.height / 2))
            }
            window = w
        }
        store.refresh()
        if ProcessInfo.processInfo.environment["PATCHTHROUGH_DEBUG_SETTINGS"] != nil {
            store.showSettings = true
        }

        // An .accessory app can show a window but can't properly own focus or
        // a menu bar. Promote to .regular while the window is up and drop back
        // when it closes, so it behaves like a normal app while visible and
        // stays out of the Dock the rest of the time.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()

        if ProcessInfo.processInfo.environment["PATCHTHROUGH_DEBUG_WINDOW"] != nil, let w = window {
            FileHandle.standardError.write(Data("""
            window: visible=\(w.isVisible) frame=\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)) \
            \(Int(w.frame.width))x\(Int(w.frame.height)) \
            screen=\(w.screen?.localizedName ?? "none") sessions=\(store.items.count)\n
            """.utf8))
        }
    }

    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let w = window else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: Self.frameKey)
    }

    /// Back to accessory when the window closes: no Dock icon, menu bar only.
    /// The daemon keeps running either way — closing the window never stops a
    /// recording.
    func windowWillClose(_ notification: Notification) {
        saveFrame()
        NSApp.setActivationPolicy(.accessory)
    }
}
