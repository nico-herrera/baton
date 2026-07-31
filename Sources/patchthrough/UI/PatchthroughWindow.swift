import AppKit
import SwiftUI

/// Observable model behind the main window. All UI state lives here; the
/// views are dumb. Layout and behaviour follow APP_REDESIGN_HANDOFF.md
/// (round 11a window, 10d settings) — deviations are bugs.
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

        /// First thing said — the only human-readable identifier a session has.
        var firstLine: String { segments.first?.text ?? "" }

        var statusSymbol: String {
            switch status {
            case .ready:   return cleanStop ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            case .pending: return "clock.arrow.circlepath"
            case .broken:  return "exclamationmark.triangle.fill"
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

    /// Consecutive same-speaker segments, grouped. The transcript's only
    /// structure is who's talking; the layout leans entirely on it.
    struct Turn: Identifiable {
        let id: Int
        let speaker: String
        let time: String          // time of the first utterance in the turn
        let lines: [String]
    }

    struct Destination: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let isTerminal: Bool
        let needsRepo: Bool

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

    var visibleItems: [Item] {
        guard !search.isEmpty else { return items }
        let q = search.lowercased()
        return items.filter { item in
            item.id.lowercased().contains(q)
                || item.segments.contains { $0.text.lowercased().contains(q) }
        }
    }

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

    /// Most-used first. Cold start falls back to discovery order, whose first
    /// entry is the first installed terminal agent.
    var rankedDestinations: [Destination] { DestinationRanking.rank(destinations) }
    var topDestination: Destination? { rankedDestinations.first }

    /// The repo chip's display name — just the folder, full path in tooltip.
    var repoDisplayName: String? {
        let trimmed = repoPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath).lastPathComponent
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

    static func groupedTurns(_ segments: [Segment]) -> [Turn] {
        var turns: [Turn] = []
        for seg in segments {
            if let last = turns.last, last.speaker == seg.speaker {
                turns[turns.count - 1] = Turn(
                    id: last.id, speaker: last.speaker, time: last.time,
                    lines: last.lines + [seg.text]
                )
            } else {
                turns.append(Turn(id: seg.id, speaker: seg.speaker, time: seg.time, lines: [seg.text]))
            }
        }
        return turns
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
            lastAction = "patched through to \(name) in \(repo.lastPathComponent)"
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
                lastAction = "\(dest.shortLabel) opened with the transcript attached (⌘V for instructions)"
            case .folderOpen:
                lastAction = "session folder opened in \(dest.shortLabel) (⌘V for instructions)"
            default:
                lastAction = "patched through to \(dest.shortLabel) in \(repo?.lastPathComponent ?? "?")"
            }
        }
        DestinationRanking.record(dest.id)
    }

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
            .appendingPathComponent("coding", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        repoPath = url.path
        return url
    }
}

// MARK: - Root view (round 11a)

struct PatchthroughRootView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        NavigationSplitView {
            sessionList
                .navigationSplitViewColumnWidth(252)
        } detail: {
            detail
        }
        .frame(minWidth: 860, minHeight: 660)
        .background(Color.ptWindow)
        .tint(.ptSignal)
        .preferredColorScheme(.dark)
        .toolbar { toolbarContent }
        .searchable(text: $store.search, placement: .sidebar, prompt: "Search transcripts")
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
        .background(  // ⌘⇧C stays as a command with no toolbar slot
            Button("") { if let i = store.selected { store.copyTranscript(i) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .onAppear { store.refresh() }
    }

    // MARK: Toolbar — mark + title left; Drag, split button, gear right.

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                PatchthroughMarkView(weight: 1.6)
                    .frame(width: 17, height: 17)
                    .foregroundStyle(Color.ptText2)
                Text("Patchthrough")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ptText2)
            }
        }
        ToolbarItemGroup {
            if let item = store.selected, item.status == .ready {
                Label("Drag", systemImage: "arrow.up.doc.on.clipboard")
                    .labelStyle(.titleAndIcon)
                    .onDrag {
                        guard let url = store.dragFile(for: item) else { return NSItemProvider() }
                        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                    }
                    .help("Drag the transcript into any chat")
            }

            Menu {
                let ranked = store.rankedDestinations
                let counts = DestinationRanking.counts()
                let top3 = Array(ranked.prefix(3))
                Section("Most used") {
                    ForEach(top3) { dest in
                        destItem(dest, count: counts[dest.id] ?? 0)
                    }
                }
                let rest = ranked.dropFirst(3)
                Section("Terminal") {
                    ForEach(rest.filter(\.isTerminal)) { dest in destItem(dest, count: 0) }
                }
                Section("App") {
                    ForEach(rest.filter { !$0.isTerminal }) { dest in destItem(dest, count: 0) }
                }
            } label: {
                Label("Patch through to \(store.topDestination?.shortLabel ?? "…")",
                      systemImage: "arrow.right")
                    .labelStyle(.titleAndIcon)
            } primaryAction: {
                if let item = store.selected, let d = store.topDestination {
                    store.send(item, to: d)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.selected?.status != .ready)

            Button { store.showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    @ViewBuilder
    private func destItem(_ dest: SessionStore.Destination, count: Int) -> some View {
        Button {
            if let item = store.selected { store.send(item, to: dest) }
        } label: {
            // Never show a count of 0 — omit the suffix instead.
            if count > 0 {
                Label("\(dest.shortLabel)   \(count)×", systemImage: dest.symbol)
            } else {
                Label(dest.shortLabel, systemImage: dest.symbol)
            }
        }
    }

    // MARK: Sidebar — time + first transcript line.

    private var sessionList: some View {
        List(selection: $store.selection) {
            ForEach(store.groupedItems, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        sidebarRow(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(.ptSignal)
        .scrollContentBackground(.hidden)
        .background(Color.ptSidebar)
        .overlay {
            if store.visibleItems.isEmpty { emptySidebar }
        }
    }

    @ViewBuilder
    private func sidebarRow(_ item: SessionStore.Item) -> some View {
        if item.status == .ready {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(timeLabel(item)).font(.system(size: 13, weight: .semibold))
                    Text(item.duration).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(item.firstLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 3)
            .tag(item.id)
        } else {
            // Pending/broken keep their status glyph and subtitle.
            HStack(spacing: 8) {
                Image(systemName: item.statusSymbol)
                    .foregroundStyle(item.status == .broken ? Color.ptSignal : Color.ptText3)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeLabel(item)).font(.system(size: 13, weight: .semibold))
                    Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
            .tag(item.id)
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
                .foregroundStyle(Color.ptText4)
            Text(store.search.isEmpty ? "No recordings" : "No matches")
                .font(.callout)
                .foregroundStyle(Color.ptText3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let item = store.selected, item.status == .ready {
            VStack(spacing: 0) {
                detailHeader(item)
                Divider().overlay(Color.ptHairline)
                transcriptView(item)
                if let action = store.lastAction {
                    Divider().overlay(Color.ptHairline)
                    Label(action, systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(Color.ptText3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
            }
            .background(Color.ptWindow)
        } else if let item = store.selected, item.status == .pending {
            placeholder(symbol: "clock.arrow.circlepath",
                        title: "Transcribing \(item.id)",
                        detail: "About 20 seconds per hour of audio. The list updates when it lands.")
        } else if let item = store.selected, item.status == .broken {
            placeholder(symbol: "exclamationmark.triangle",
                        title: "\(item.id) was interrupted",
                        detail: "No meta.json, so nothing will pick it up. The audio files are still in the session folder.")
        } else {
            placeholder(symbol: "waveform.badge.mic",
                        title: store.items.isEmpty ? "No recordings yet" : "Nothing selected",
                        detail: store.items.isEmpty
                            ? "Start a recording from the menu bar. Your mic and everything your Mac plays are captured as two tracks, then transcribed on-device."
                            : "Pick a session on the left.")
        }
    }

    private func placeholder(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.ptText4)
            Text(title).font(.title3).foregroundStyle(Color.ptText)
            Text(detail)
                .font(.callout)
                .foregroundStyle(Color.ptText3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ptWindow)
    }

    /// One row: session id (mono), stats, and the target repo as just the
    /// folder name on the trailing edge — full path in the tooltip.
    private func detailHeader(_ item: SessionStore.Item) -> some View {
        HStack(spacing: 10) {
            Text(item.id).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.ptText3)
            Text("\(item.duration) · \(item.words) words · \(item.segments.count) segments")
                .font(.system(size: 12))
                .foregroundStyle(Color.ptText4)
            Spacer()
            Button {
                _ = store.pickRepo()
            } label: {
                Label(store.repoDisplayName ?? "choose project", systemImage: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ptText3)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.ptRaised, in: RoundedRectangle(cornerRadius: 6))
            .help(store.repoPath.isEmpty ? "Choose the project repo-based handoffs start in" : store.repoPath)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Transcript — me right on a ground, them left and bare.

    private func transcriptView(_ item: SessionStore.Item) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(SessionStore.groupedTurns(item.segments)) { turn in
                        let isMe = turn.speaker == "me"
                        VStack(alignment: isMe ? .trailing : .leading, spacing: isMe ? 7 : 8) {
                            HStack(spacing: 8) {
                                if isMe { Text(turn.time).monoCaption() }
                                Text(turn.speaker.uppercased())
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .tracking(0.9)
                                    .foregroundStyle(isMe ? Color.ptSignalLit : Color(hex: 0x8C887E))
                                if !isMe { Text(turn.time).monoCaption() }
                            }
                            ForEach(turn.lines, id: \.self) { line in
                                Text(highlighted(line))
                                    .font(.system(size: 14.5))
                                    .lineSpacing(4)
                                    .foregroundStyle(isMe ? Color.ptText : Color.ptText2)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.leading)
                                    .padding(isMe
                                        ? EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
                                        : EdgeInsets())
                                    .background(isMe ? Color.ptSurface : .clear,
                                                in: RoundedRectangle(cornerRadius: 11))
                            }
                        }
                        // 78% cap: trailing alignment can only offset an item
                        // narrower than the line — a larger cap makes both
                        // speakers span the column and the left/right rule
                        // vanishes.
                        .frame(maxWidth: geo.size.width * 0.78,
                               alignment: isMe ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
                        .padding(isMe ? .leading : .trailing, 22)
                    }
                }
                .padding(16)
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard !store.search.isEmpty else { return out }
        var cursor = out.startIndex
        while let r = out[cursor...].range(of: store.search, options: .caseInsensitive) {
            out[r].inlinePresentationIntent = .stronglyEmphasized
            out[r].backgroundColor = Color.ptSignal.opacity(0.3)
            cursor = r.upperBound
            if cursor >= out.endIndex { break }
        }
        return out
    }
}

// MARK: - Settings (round 10d)

/// Fixed frame, no scrolling. Four groups: Recordings, Transcription,
/// Patch through, After each transcript. Every toggle carries a one-line
/// subtitle stating its tradeoff.
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
            header
            Divider().overlay(Color.ptHairline)

            VStack(alignment: .leading, spacing: 18) {
                section("Recordings") {
                    HStack {
                        TextField("", text: $recordingsDir, prompt: Text("~/Recordings"))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Button("Choose…") { chooseFolder() }
                    }
                }

                section("Transcription") {
                    toggleRow("Transcribe automatically after each recording",
                              subtitle: "On-device, ~20s per hour of audio",
                              isOn: $transcribe)
                    toggleRow("Echo cancellation on the mic",
                              subtitle: "Cleaner on speakers, thinner on headphones",
                              isOn: $voiceProcessing)
                }

                section("Patch through") {
                    toggleRow("Paste automatically after a clipboard handoff",
                              subtitle: "Types ⌘N then ⌘V. Never presses send.",
                              isOn: $autoPaste)
                    // Accessibility requirement, attached to the row it gates.
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.ptSignalLit)
                        Text("Requires the Accessibility permission")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.ptText2)
                        Spacer()
                        Button("Grant now") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.ptSignal.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                }

                section("After each transcript") {
                    TextField("", text: $onStop, prompt: Text("my-hook"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Text("Runs with the session folder as its only argument. Leave empty for none.")
                        .font(.system(size: 11.5)).foregroundStyle(Color.ptText4)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.ptSignalLit).font(.caption)
                }
            }
            .padding(18)

            Divider().overlay(Color.ptHairline)
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
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.ptWindow)
        .tint(.ptSignal)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    /// Header carries the mark and the config path — the file being edited is
    /// never a mystery.
    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                PatchthroughMarkView(weight: 1.6)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Color.ptText2)
                Text("Settings").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.ptText)
            }
            Spacer()
            Text("~/.config/patchthrough/config.json")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.ptText4)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.ptText4)
                .textCase(.uppercase)
            content()
        }
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Color.ptText)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Color.ptText4)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
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
            store.lastAction = "settings saved"
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
            // The toolbar carries the mark + wordmark; a second title is noise.
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: PatchthroughRootView(store: store))

            w.representedURL = Bundle.main.bundleURL
            w.standardWindowButton(.documentIconButton)?.image = AppIcon.titlebarImage()

            if let saved = UserDefaults.standard.string(forKey: Self.frameKey), !saved.isEmpty {
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

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        NSApp.setActivationPolicy(.accessory)
    }
}
