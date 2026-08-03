import AppKit
import SwiftUI

/// Observable model behind the main window. All UI state lives here, and the
/// views are dumb. Layout and behaviour follow APP_REDESIGN_HANDOFF.md
/// (round 11a window, 10d settings). Any deviation is a bug.
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

        /// The first thing said. A session has no other human-readable identifier.
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
            case .broken:  return "interrupted: no meta.json"
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

        var shortLabel: String { label.components(separatedBy: " (").first ?? label }

        /// The menu keeps meaningful product context ("Copilot (VS Code)") but
        /// drops launch-mechanism notes that are not destination names.
        var menuLabel: String {
            for suffix in [" (ChatGPT app)"] where label.hasSuffix(suffix) {
                return String(label.dropLast(suffix.count))
            }
            return label
        }
    }

    @Published var items: [Item] = []
    @Published var selection: String?
    @Published var isRecording = false
    @Published var elapsed = ""
    @Published var lastAction: String?
    @Published var search = ""
    @Published var showSettings = false
    @Published private(set) var lastDestinationID: String?
    @Published var repoPath: String {
        didSet { UserDefaults.standard.set(repoPath, forKey: "handoff.repo") }
    }

    let root: URL
    var onToggleRecording: (() -> Void)?

    init(root: URL) {
        self.root = root
        self.repoPath = UserDefaults.standard.string(forKey: "handoff.repo") ?? ""
        self.lastDestinationID = DestinationRanking.lastUsedID()
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
        // One glyph per kind, not per agent: the design's menu uses the mock's
        // `#i-term` for every CLI row and `#i-app` for every GUI row
        // (swift/PatchThroughButton.swift). Per-agent SF Symbols read as noise
        // next to section headers that already say Terminal and App.
        let terminal = Handoff.installedAgents().map {
            Destination(id: "cli:\($0.agent.name)", label: $0.agent.displayName,
                        symbol: "terminal", isTerminal: true, needsRepo: true)
        }
        let gui = Handoff.installedGuiTargets().map { t in
            Destination(id: "gui:\(t.id)", label: t.label, symbol: "app",
                        isTerminal: false, needsRepo: t.needsRepo)
        }
        return terminal + gui
    }

    /// Most-used first. Cold start falls back to discovery order, whose first
    /// entry is the first installed terminal agent.
    var rankedDestinations: [Destination] { DestinationRanking.rank(destinations) }
    /// The split button repeats the last successful destination. If that
    /// destination is no longer installed, fall back to the ranked list.
    var topDestination: Destination? {
        if let lastDestinationID,
           let lastUsed = destinations.first(where: { $0.id == lastDestinationID }) {
            return lastUsed
        }
        return rankedDestinations.first
    }

    /// The repo chip's display name: the folder only. The tooltip has the path.
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

    /// Consecutive same-speaker segments collapse into one turn, per
    /// swift/TranscriptView.swift. There is deliberately no silence threshold:
    /// the design shows one speaker's run under a single header.
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
            Handoff.launchInTerminal(
                agent: match.agent,
                at: match.path,
                prompt: Handoff.prompt(for: sess),
                cwd: repo
            )
            lastAction = "patched through to \(name) in \(repo.lastPathComponent)"
        } else {
            let id = String(dest.id.dropFirst(4))
            guard let target = Handoff.installedGuiTargets().first(where: { $0.id == id }) else { return }
            // Targets that accept no automation get an explainer first, so
            // the one manual step is clear before the app takes focus.
            if case .appClipboard(let appName) = target.kind, target.manualTextPaste,
               !HandoffAlert.confirmManualPaste(app: appName) {
                lastAction = "handoff to \(dest.shortLabel) cancelled"
                return
            }
            Handoff.launchGui(target: target, session: sess, repo: repo)
            switch target.kind {
            case .appClipboard(let appName):
                if Config.autoPaste() && !target.manualTextPaste {
                    lastAction = "\(dest.shortLabel) opened. Attaching the transcript to a new chat…"
                    finishPaste(app: appName, label: dest.shortLabel, newChat: true)
                } else if target.manualTextPaste {
                    lastAction = "\(dest.shortLabel) opened. Prompt and transcript are on your clipboard (⌘V)"
                } else {
                    lastAction = "\(dest.shortLabel) opened. The handoff file is on your clipboard (⌘V attaches it)"
                }
            case .claudeChat:
                if Config.autoPaste() {
                    lastAction = "Claude opened a new chat. Attaching the transcript…"
                    finishPaste(app: "Claude", label: dest.shortLabel, newChat: false)
                } else {
                    lastAction = "Claude opened a new chat. The handoff file is on your clipboard (⌘V attaches it)"
                }
            case .claudeCode:
                lastAction = "new Claude Code session in \(repo?.lastPathComponent ?? "?") (transcript staged)"
            default:
                lastAction = "patched through to \(dest.shortLabel) in \(repo?.lastPathComponent ?? "?")"
            }
        }
        DestinationRanking.record(dest.id)
        lastDestinationID = dest.id
    }

    /// The paste script sleeps about two seconds while the app comes up, so it
    /// runs off the main actor. Otherwise every clipboard handoff freezes the
    /// window for the duration.
    private func finishPaste(app: String, label: String, newChat: Bool) {
        Task {
            let pasted = await Task.detached { Handoff.autoPaste(app: app, newChat: newChat) }.value
            guard !pasted else { return }
            lastAction = "\(label) opened. The handoff file is on your clipboard (⌘V attaches it)"
            HandoffAlert.showPasteFailed(app: app)
        }
    }

    /// Point the split button at a destination without sending anything.
    /// The window menu calls this: rows select, the Signal button fires.
    func choose(_ dest: Destination) {
        lastDestinationID = dest.id
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
        panel.message = "Choose the project this meeting was about. The session starts in that folder."
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
    /// The sidebar search field is hand-built (see `searchField`), so ⌘F has
    /// to be wired up by hand too. `.searchable` used to supply ⌘F.
    @FocusState private var searchFocused: Bool
    @State private var showDestinationMenu = false
    /// The hover/keyboard highlight in the destination menu. It persists when
    /// the pointer leaves a row: falling back to the default highlight made
    /// the selection bounce on every gap the pointer crossed.
    @State private var highlightedDestination: String?
    @FocusState private var destinationMenuFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                titleBar
                Rectangle().fill(PT.C.hairline).frame(height: 1)
                // 11a is a fixed `252px 1fr` grid, not a collapsible split view.
                // NavigationSplitView insisted on a collapse control (which drags
                // a second titlebar in with it) and would not honour a pinned
                // column width once that control was removed.
                HStack(spacing: 0) {
                    sessionList
                        .frame(width: PT.M.sidebarWidth)
                    Rectangle().fill(PT.C.hairline).frame(width: 1)
                    detail
                }
            }

            if showDestinationMenu {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { closeDestinationMenu() }

                destinationMenuPanel
                    .padding(.top, PT.M.menuTop)
                    .padding(.trailing, PT.M.menuTrailing)
            }
        }
        // The strip below is the titlebar, so the content must not be inset
        // for the system titlebar. An inset opens the window 28pt taller than
        // 11a, and everything sits a titlebar's height too low.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: PT.M.windowMin.width, minHeight: PT.M.windowMin.height)
        .background(PT.C.window)
        .tint(PT.C.signal)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
        .background(  // ⌘⇧C and ⌘F stay as commands with no toolbar slot
            ZStack {
                Button("") { if let i = store.selected { store.copyTranscript(i) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .onAppear { store.refresh() }
        .onExitCommand { closeDestinationMenu() }
        .onChange(of: store.showSettings) { _, isShowing in
            if isShowing { closeDestinationMenu() }
        }
    }

    // MARK: Titlebar: mark and wordmark left; Drag, split button, gear right.
    //
    // Drawn in SwiftUI rather than as an NSToolbar on purpose. 11a's titlebar
    // is a flat #201F1A strip with a two-tone red split button and unbordered
    // chips; NSToolbar re-styles whatever it hosts, so `.borderedProminent`
    // came out grey and the chips picked up system borders. The window uses
    // .fullSizeContentView with a transparent titlebar, so this strip sits
    // where the toolbar would be and the traffic lights float over its inset.

    private var titleBar: some View {
        HStack(spacing: 9) {
            PatchthroughMarkView(weight: 1.6)
                .frame(width: 17, height: 17)
                .foregroundStyle(PT.C.text)
            Text("Patchthrough")
                .font(PT.F.button)
                .foregroundStyle(PT.C.text)

            Spacer(minLength: 12)

            if let item = store.selected, item.status == .ready {
                dragChip
                    .onDrag {
                        guard let url = store.dragFile(for: item) else { return NSItemProvider() }
                        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                    }
                    .help("Drag the transcript into any chat")
            }

            patchSplitButton

            // SF `gearshape`, not the mock's own `#i-gear` glyph: that one is a
            // ring with eight radial spokes, which reads as a sun. A sun reads
            // as a light/dark toggle. This app is dark-only, so that reading is a
            // dead end and Settings needs to be unmistakable. Deliberate
            // deviation from 11a; don't "fix" it back.
            Button { store.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(PT.F.gear)
                    .foregroundStyle(PT.C.text3)
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.leading, PT.M.titleBarLeading)   // clears the traffic lights
        .padding(.trailing, PT.M.titleBarTrailing)
        .frame(height: PT.M.titleBarHeight)
        .background(PT.C.chrome)
    }

    /// Mock: bg #24231D, 1px #3A3730, radius 7, padding 8/11. The glyph is the
    /// mock's `#i-drag`, a page with an up arrow, which is `arrow.up.doc`.
    private var dragChip: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.up.doc")
                .font(PT.F.icon)
                .foregroundStyle(PT.C.text3)
            Text("Drag")
                .font(PT.F.control)
                .foregroundStyle(PT.C.text2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(PT.C.raised, in: RoundedRectangle(cornerRadius: PT.M.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PT.M.controlRadius)
                .strokeBorder(PT.C.border, lineWidth: 1)
        )
    }

    /// Two segments in one radius-7 clip: Signal primary repeats the last-used
    /// destination, while the darker chevron opens the ranked menu.
    private var patchSplitButton: some View {
        let ready = store.selected?.status == .ready
        return HStack(spacing: 0) {
            Button {
                if let item = store.selected, let d = store.topDestination {
                    store.send(item, to: d)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right")
                        .font(PT.F.buttonGlyph)
                    Text("Patch through to \(store.topDestination?.shortLabel ?? "…")")
                        .font(PT.F.button)
                }
                .foregroundStyle(PT.C.onSignal)
                .padding(.horizontal, 14)
                .frame(height: PT.M.splitButtonHeight)
                .background(PT.C.signal)
            }
            .buttonStyle(.plain)

            Button {
                showDestinationMenu.toggle()
                highlightedDestination = showDestinationMenu ? store.topDestination?.id : nil
            } label: {
                Image(systemName: "chevron.down")
                    .font(PT.F.chevron)
                    .foregroundStyle(PT.C.onSignal)
                    .frame(width: PT.M.splitChevronWidth,
                           height: PT.M.splitButtonHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(PT.C.signalDim)
            // The mock's divider is a border-left on this half, so the 22% white
            // sits over red. As a sibling in the HStack it composited over the
            // titlebar instead and read as a dark grey line.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(PT.C.onSignalRule)
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("Choose patch-through destination")
            .help("Choose where to patch this session through")
        }
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: PT.M.controlRadius))
        .opacity(ready ? 1 : 0.45)
        .disabled(!ready)
    }

    /// Menu order: three most-used, then terminals, then apps. Keyboard
    /// navigation walks the same flattened order the rows render in.
    private var menuSections: (top: [SessionStore.Destination],
                               terminal: [SessionStore.Destination],
                               app: [SessionStore.Destination]) {
        let ranked = store.rankedDestinations
        let rest = Array(ranked.dropFirst(3))
        return (Array(ranked.prefix(3)), rest.filter(\.isTerminal), rest.filter { !$0.isTerminal })
    }

    private var destinationMenuPanel: some View {
        let sections = menuSections
        let counts = DestinationRanking.counts()

        return VStack(alignment: .leading, spacing: PT.M.menuGap) {
            menuSectionHeader("Most used")
            ForEach(sections.top) { dest in
                destinationMenuRow(dest, count: counts[dest.id] ?? 0, isMostUsed: true)
            }

            if !sections.terminal.isEmpty {
                menuDivider
                menuSectionHeader("Terminal")
                ForEach(sections.terminal) { dest in
                    destinationMenuRow(dest, count: 0, isMostUsed: false)
                }
            }

            if !sections.app.isEmpty {
                menuSectionHeader("App")
                ForEach(sections.app) { dest in
                    destinationMenuRow(dest, count: 0, isMostUsed: false)
                }
            }
        }
        .padding(PT.M.menuPadding)
        .frame(width: PT.M.menuWidth)
        .background(PT.C.raised, in: RoundedRectangle(cornerRadius: PT.M.menuRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PT.M.menuRadius)
                .strokeBorder(PT.C.menuEdge, lineWidth: PT.M.menuBorderWidth)
        }
        .shadow(color: PT.C.menuShadow,
                radius: PT.M.menuShadowRadius,
                x: 0,
                y: PT.M.menuShadowY)
        .focusable()
        .focusEffectDisabled()
        .focused($destinationMenuFocused)
        .onAppear { destinationMenuFocused = true }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.return) { commitHighlight(); return .handled }
        .onKeyPress(.escape) { closeDestinationMenu(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Patch through destinations")
    }

    private func moveHighlight(_ delta: Int) {
        let sections = menuSections
        let items = sections.top + sections.terminal + sections.app
        guard !items.isEmpty else { return }
        guard let current = items.firstIndex(where: { $0.id == highlightedDestination }) else {
            highlightedDestination = (delta > 0 ? items.first : items.last)?.id
            return
        }
        highlightedDestination = items[(current + delta + items.count) % items.count].id
    }

    /// Return picks the highlighted destination, exactly like a click: the
    /// menu only selects. The Signal half of the split button sends.
    private func commitHighlight() {
        if let id = highlightedDestination,
           let dest = store.destinations.first(where: { $0.id == id }) {
            store.choose(dest)
        }
        closeDestinationMenu()
    }

    private func menuSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(PT.F.sectionHead)
            .tracking(PT.F.labelTracking)
            .foregroundStyle(PT.C.text4)
            .padding(.horizontal, PT.M.menuTextInset)
            .padding(.top, PT.M.menuSectionTopPad)
            .padding(.bottom, PT.M.menuSectionBottomPad)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(PT.C.menuRule)
            .frame(height: PT.M.menuRuleWidth)
            .padding(.horizontal, PT.M.menuRuleInset)
            .padding(.vertical, PT.M.menuRulePadV)
    }

    private func destinationMenuRow(_ dest: SessionStore.Destination,
                                    count: Int,
                                    isMostUsed: Bool) -> some View {
        let isActive = highlightedDestination == dest.id
        // A row click selects the destination as the split button's primary
        // action; it never sends. Sending stays behind the explicit click on
        // the Signal half, so browsing the menu can't launch anything.
        return Button {
            store.choose(dest)
            closeDestinationMenu()
        } label: {
            HStack(spacing: PT.M.menuRowGap) {
                Image(systemName: dest.symbol)
                    .font(PT.F.icon)
                    .foregroundStyle(isActive ? PT.C.signalLit : PT.C.speakerThem)
                    .frame(width: PT.M.menuIconSize, height: PT.M.menuIconSize)

                Text(dest.menuLabel)
                    .font(isActive ? PT.F.menuItemStrong : PT.F.menuItem)
                    .foregroundStyle(isActive ? PT.C.text : (isMostUsed ? PT.C.text2 : PT.C.text3))

                Spacer(minLength: 0)

                // Never show a count of 0. Omit the suffix instead.
                if count > 0 {
                    Text("\(count)×")
                        .font(PT.F.monoTiny)
                        .foregroundStyle(isActive ? PT.C.speakerThem : PT.C.text4)
                }
            }
            .padding(.horizontal, PT.M.menuTextInset)
            .padding(.vertical, isMostUsed ? PT.M.menuFrequentRowPadV : PT.M.menuRowPadV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isActive ? PT.C.menuSelectFill : Color.clear,
                in: RoundedRectangle(cornerRadius: PT.M.menuRowRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: PT.M.menuRowRadius))
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering { highlightedDestination = dest.id }
        }
        .accessibilityLabel(dest.menuLabel)
        .accessibilityValue(count > 0 ? "Used \(count) times" : "")
    }

    private func closeDestinationMenu() {
        showDestinationMenu = false
        highlightedDestination = nil
    }

    // MARK: Sidebar: time and first transcript line.

    /// A ScrollView, not a List: `.listStyle(.sidebar)` adds ~16pt of its own
    /// horizontal inset on top of any `listRowInsets`, which pushes the row fill
    /// in from the 8pt the mock specifies. Nothing here needs List behaviour.
    /// Selection draws its own fill and ring (rule 4).
    private var sessionList: some View {
        VStack(spacing: 0) {
            searchField
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PT.M.rowGap) {
                    ForEach(store.groupedItems, id: \.title) { group in
                        Text(group.title)
                            .font(PT.F.sectionHead)
                            .tracking(PT.F.labelTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(PT.C.text4)
                            .padding(.horizontal, PT.M.rowInset)
                            .padding(.top, 8)
                            .padding(.bottom, 3)
                        ForEach(group.items) { item in
                            sidebarRow(item, selected: store.selection == item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { store.selection = item.id }
                        }
                    }
                }
                .padding(.horizontal, PT.M.rowInset)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if store.visibleItems.isEmpty { emptySidebar }
            }
            sidebarFooter
        }
        .background(PT.C.sidebar)
    }

    /// Mock: the search field lives at the top of the sidebar, with bg #24231D
    /// on #302E27, radius 6, and padding 6/9. A native `.searchable` would put
    /// the field in the toolbar instead.
    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(PT.F.icon)
                .foregroundStyle(PT.C.text4)
            TextField("", text: $store.search,
                      prompt: Text("Search transcripts").foregroundColor(PT.C.text4))
                .textFieldStyle(.plain)
                .font(PT.F.field)
                .foregroundStyle(PT.C.text)
                .focused($searchFocused)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(PT.C.raised, in: RoundedRectangle(cornerRadius: PT.M.fieldRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PT.M.fieldRadius)
                .strokeBorder(PT.C.border2, lineWidth: 1)
        )
        .padding(.horizontal, PT.M.sidebarPad)
        .padding(.top, PT.M.sidebarPad)
        .padding(.bottom, 10)
        .background(PT.C.sidebar)
    }

    /// Mock: the sidebar ends in the recordings path, hairline above.
    private var sidebarFooter: some View {
        Button {
            NSWorkspace.shared.open(store.root)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(PT.F.icon)
                    .foregroundStyle(PT.C.glyphDim)
                Text(displayPath(store.root))
                    .font(PT.F.monoSmall)
                    .foregroundStyle(PT.C.text4)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(PT.C.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(PT.C.raised).frame(height: 1) }
        .help("Open the recordings folder")
    }

    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
        )
    }

    /// Two lines, padding 9, own fill + ring. Follows swift/SessionRow.swift.
    @ViewBuilder
    private func sidebarRow(_ item: SessionStore.Item, selected: Bool) -> some View {
        Group {
            if item.status == .ready {
                // Selection brightens both lines and warms the duration. That
                // warm tone is the only place the accent reaches text.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(timeLabel(item))
                            .font(selected ? PT.F.sessionTime : PT.F.sessionTime2)
                            .foregroundStyle(selected ? PT.C.text : PT.C.text2)
                        Text(item.duration)
                            .font(PT.F.monoSmall)
                            .foregroundStyle(selected ? PT.C.signalInk : PT.C.text4)
                    }
                    Text(item.firstLine)
                        .font(PT.F.sessionLine)
                        .foregroundStyle(selected ? PT.C.textSel : PT.C.text4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                // Pending/broken keep their status glyph and subtitle.
                HStack(spacing: 8) {
                    Image(systemName: item.statusSymbol)
                        .foregroundStyle(item.status == .broken ? PT.C.signalLit : PT.C.text3)
                        .font(PT.F.iconSmall)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(timeLabel(item))
                            .font(PT.F.sessionTime2)
                            .foregroundStyle(PT.C.text2)
                        Text(item.subtitle)
                            .font(PT.F.sessionLine)
                            .foregroundStyle(PT.C.text4)
                    }
                }
            }
        }
        .padding(PT.M.rowPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PT.M.controlRadius)
                .fill(selected ? PT.C.signal.opacity(0.15) : .clear)
                .strokeBorder(selected ? PT.C.signal.opacity(0.32) : .clear, lineWidth: 1)
        )
    }

    private func timeLabel(_ item: SessionStore.Item) -> String {
        guard let d = item.date else { return item.id }
        return d.formatted(date: .omitted, time: .shortened)
    }

    private var emptySidebar: some View {
        VStack(spacing: 6) {
            Image(systemName: store.search.isEmpty ? "waveform" : "magnifyingglass")
                .font(PT.F.placeholder)
                .foregroundStyle(PT.C.text4)
            Text(store.search.isEmpty ? "No recordings" : "No matches")
                .font(.callout)
                .foregroundStyle(PT.C.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let item = store.selected, item.status == .ready {
            VStack(spacing: 0) {
                detailHeader(item)
                Divider().overlay(PT.C.hairline)
                transcriptView(item)
                if let action = store.lastAction {
                    Divider().overlay(PT.C.hairline)
                    Label(action, systemImage: "checkmark.circle")
                        .font(PT.F.iconSmall).foregroundStyle(PT.C.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
            }
            .background(PT.C.window)
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
                .font(PT.F.placeholder)
                .foregroundStyle(PT.C.text4)
            Text(title).font(.title3).foregroundStyle(PT.C.text)
            Text(detail)
                .font(.callout)
                .foregroundStyle(PT.C.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PT.C.window)
    }

    /// One row: session id (mono), stats, and the target repo as just the
    /// folder name on the trailing edge. The tooltip carries the full path.
    private func detailHeader(_ item: SessionStore.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.id).font(PT.F.mono)
                .foregroundStyle(PT.C.text)
            Text("\(item.duration) · \(item.words) words · \(item.segments.count) segments")
                .font(PT.F.caption)
                .foregroundStyle(PT.C.label)
            Spacer()
            Button {
                _ = store.pickRepo()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(PT.F.iconSmall)
                        .foregroundStyle(PT.C.text4)
                    Text(store.repoDisplayName ?? "choose project")
                        .font(PT.F.monoRepo)
                        .foregroundStyle(PT.C.speakerThem)
                }
            }
            .buttonStyle(.plain)
            .help(store.repoPath.isEmpty ? "Choose the project repo-based handoffs start in" : store.repoPath)
        }
        .padding(.horizontal, PT.M.transcriptPad)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Transcript: me on the right on a ground, them on the left and bare.

    private func transcriptView(_ item: SessionStore.Item) -> some View {
        GeometryReader { geo in
            // 78% of the padded content box. See PT.M.turnMaxWidthFraction.
            let cap = (geo.size.width - PT.M.transcriptPad * 2)
                * PT.M.turnMaxWidthFraction
            ScrollView {
                VStack(spacing: PT.M.turnGap) {
                    ForEach(SessionStore.groupedTurns(item.segments)) { turn in
                        let isMe = turn.speaker == "me"
                        VStack(alignment: isMe ? .trailing : .leading, spacing: isMe ? 7 : 8) {
                            HStack(spacing: 8) {
                                if isMe { Text(turn.time).monoCaption() }
                                Text(turn.speaker.uppercased())
                                    .font(PT.F.speaker)
                                    .tracking(PT.F.labelTracking)
                                    .foregroundStyle(isMe ? PT.C.signalLit : PT.C.speakerThem)
                                if !isMe { Text(turn.time).monoCaption() }
                            }
                            ForEach(turn.lines, id: \.self) { line in
                                Text(highlighted(line))
                                    .font(PT.F.transcript)
                                    .lineSpacing(PT.F.transcriptLineSpacing)
                                    .foregroundStyle(isMe ? PT.C.text : PT.C.text2)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(isMe
                                        ? EdgeInsets(top: PT.M.bubblePadV, leading: PT.M.bubblePadH,
                                                     bottom: PT.M.bubblePadV, trailing: PT.M.bubblePadH)
                                        : EdgeInsets())
                                    .background(isMe ? PT.C.surface : .clear,
                                                in: RoundedRectangle(cornerRadius: PT.M.bubbleRadius))
                            }
                        }
                        .frame(maxWidth: cap, alignment: isMe ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
                    }
                }
                .padding(PT.M.transcriptPad)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard !store.search.isEmpty else { return out }
        var cursor = out.startIndex
        while let r = out[cursor...].range(of: store.search, options: .caseInsensitive) {
            out[r].inlinePresentationIntent = .stronglyEmphasized
            out[r].backgroundColor = PT.C.signal.opacity(0.3)
            cursor = r.upperBound
            if cursor >= out.endIndex { break }
        }
        return out
    }
}

// MARK: - Settings (round 10d)

/// Fixed frame, no scrolling. Every toggle carries a one-line subtitle
/// stating its tradeoff.
struct SettingsView: View {
    @ObservedObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var recordingsDir = ""
    @State private var transcribe = true
    @State private var voiceProcessing = false
    @State private var autoPaste = false
    @State private var launchAtLogin = false
    @State private var onStop = ""
    @State private var terminalID = TerminalApp.known[0].id
    @State private var error: String?
    @FocusState private var focused: Field?

    /// Only terminals that are on this Mac. An absent terminal produces a
    /// handoff that silently does nothing.
    private let terminals = TerminalApp.installed()

    private enum Field { case recordingsDir, hook }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(PT.C.hairline)

            VStack(alignment: .leading, spacing: 22) {
                section("Recordings") {
                    HStack(spacing: 9) {
                        well(text: $recordingsDir, placeholder: "~/Recordings")
                            .focused($focused, equals: .recordingsDir)
                        chip("Choose…", hPad: 12) { chooseFolder() }
                    }
                    caption("Applies to the next recording. Existing sessions stay where they are.")
                    card {
                        toggleRow("Open Patchthrough at login",
                                  subtitle: "Keeps the menu-bar recorder ready in the background",
                                  isOn: $launchAtLogin)
                    }
                }

                section("Transcription") {
                    card {
                        toggleRow("Transcribe after each recording",
                                  subtitle: "On-device, ~20s per hour of audio",
                                  isOn: $transcribe)
                    }
                    card {
                        toggleRow("Echo cancellation on the mic",
                                  subtitle: "Cleaner on speakers, thinner on headphones",
                                  isOn: $voiceProcessing)
                    }
                }

                section("Patch through") {
                    card {
                        chooserRow(
                            "Terminal for CLI agents",
                            subtitle: "Your shell profile comes from this app, not the system default.",
                            selection: terminals.first { $0.id == terminalID }?.name
                                ?? TerminalApp.current().name
                        ) {
                            ForEach(terminals) { term in
                                Button(term.name) { terminalID = term.id }
                            }
                        }
                    }
                    // The Accessibility strip lives inside the card, directly
                    // under the switch that it gates. In small print elsewhere,
                    // nobody connects the strip to the switch.
                    card {
                        VStack(spacing: 0) {
                            toggleRow("Paste automatically after a clipboard handoff",
                                      subtitle: "Types ⌘N then ⌘V. Never presses send.",
                                      isOn: $autoPaste)
                            Rectangle().fill(PT.C.border2).frame(height: 1)
                            HStack(spacing: 8) {
                                Text("Requires Accessibility permission. macOS asks once.")
                                    .font(PT.F.caption)
                                    .foregroundStyle(PT.C.signalWarn)
                                Spacer()
                                Button("Grant now") {
                                    NSWorkspace.shared.open(URL(string:
                                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                                }
                                .buttonStyle(.plain)
                                .font(PT.F.caption.weight(.medium))
                                .foregroundStyle(PT.C.signalLit)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(PT.C.signal.opacity(0.10))
                        }
                    }
                }

                section("After each transcript") {
                    well(text: $onStop, placeholder: "my-hook")
                        .focused($focused, equals: .hook)
                    caption("Runs with the session folder as its only argument. Empty for none.")
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(PT.C.signalLit).font(PT.F.iconSmall)
                }
            }
            .padding(.horizontal, PT.M.sheetPadH)
            .padding(.vertical, 18)

            Rectangle().fill(PT.C.hairline).frame(height: 1)
            HStack(spacing: 10) {
                Button("Reveal config file") {
                    NSWorkspace.shared.activateFileViewerSelecting([Config.revealTarget()])
                }
                .buttonStyle(.plain)
                .font(PT.F.sessionLine)
                .foregroundStyle(PT.C.label)
                Spacer()
                chip("Cancel", hPad: 15) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button { save() } label: {
                    Text("Save")
                        .font(PT.F.control.weight(.semibold))
                        .foregroundStyle(PT.C.onSignal)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 9)
                        .background(PT.C.signal, in: RoundedRectangle(cornerRadius: PT.M.fieldRadius))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, PT.M.sheetPadH)
            .padding(.vertical, 13)
            .background(PT.C.window)
        }
        .frame(width: PT.M.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(PT.C.chrome)
        .tint(PT.C.signal)
        .preferredColorScheme(.dark)
        .onAppear {
            load()
            focused = nil
            // AppKit gives first responder to the first text field just after
            // onAppear, which selects its whole value; 10d opens with nothing
            // focused, so hand the responder back to the sheet.
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    /// Sunken monospaced input. Mock: #17160F on a #35322A border, radius 6.
    private func well(text: Binding<String>, placeholder: String) -> some View {
        TextField("", text: text, prompt:
            Text(placeholder).foregroundColor(PT.C.text5))
            .textFieldStyle(.plain)
            .font(PT.F.monoField)
            .foregroundStyle(PT.C.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(PT.C.sunken, in: RoundedRectangle(cornerRadius: PT.M.fieldRadius))
            .overlay(
                RoundedRectangle(cornerRadius: PT.M.fieldRadius)
                    .strokeBorder(PT.C.border, lineWidth: 1)
            )
    }

    /// Neutral chip. Mock: #2A2822 on #3A3730, radius 6. Drawn rather than
    /// styled, because the sheet's Signal tint colours native buttons red and
    /// red is reserved for Save.
    private func chip(_ title: String, hPad: CGFloat,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(PT.F.control)
                .foregroundStyle(PT.C.text2)
                .padding(.horizontal, hPad)
                .padding(.vertical, 8)
                .background(PT.C.chip, in: RoundedRectangle(cornerRadius: PT.M.fieldRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: PT.M.fieldRadius)
                        .strokeBorder(PT.C.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(PT.F.caption)
            .foregroundStyle(PT.C.text4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Toggle ground. Mock: #24231D on #302E27, radius 8.
    private func card(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .background(PT.C.raised, in: RoundedRectangle(cornerRadius: PT.M.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: PT.M.cardRadius)
                    .strokeBorder(PT.C.border2, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: PT.M.cardRadius))
    }

    /// Header carries the mark and the config path, so you always know which
    /// file you edit.
    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                PatchthroughMarkView(weight: 1.6)
                    .frame(width: 17, height: 17)
                    .foregroundStyle(PT.C.text)
                Text("Settings").font(PT.F.sheetTitle)
                    .foregroundStyle(PT.C.text)
            }
            Spacer()
            Text("~/.config/patchthrough/config.json")
                .font(PT.F.monoSmall)
                .foregroundStyle(PT.C.text5)
        }
        .padding(.horizontal, PT.M.sheetPadH)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(PT.F.speaker)
                .tracking(PT.F.labelTracking)
                .foregroundStyle(PT.C.label)
                .textCase(.uppercase)
            content()
        }
    }

    /// A card row whose trailing control picks one of several values. Same
    /// shape as `toggleRow`, and the control reuses the neutral chip look so
    /// the sheet gains no new visual language (rules 11 and 12).
    private func chooserRow(_ title: String, subtitle: String, selection: String,
                            @ViewBuilder options: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PT.F.settingRow).foregroundStyle(PT.C.text)
                Text(subtitle).font(PT.F.caption).foregroundStyle(PT.C.text4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu(content: options) {
                HStack(spacing: 6) {
                    Text(selection)
                        .font(PT.F.control)
                        .foregroundStyle(PT.C.text2)
                    Image(systemName: "chevron.down")
                        .font(PT.F.chevron)
                        .foregroundStyle(PT.C.text3)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(PT.C.chip, in: RoundedRectangle(cornerRadius: PT.M.fieldRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: PT.M.fieldRadius)
                        .strokeBorder(PT.C.border, lineWidth: 1)
                )
            }
            // `.button`, not `.borderlessButton`: the borderless style discards a
            // custom label and draws its own (leading indicator, no chip).
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PT.F.settingRow).foregroundStyle(PT.C.text)
                Text(subtitle).font(PT.F.caption).foregroundStyle(PT.C.text4)
            }
            // Without this the label hugs its text, the card shrinks to fit,
            // and the switch stops being right-aligned.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(PTSwitchStyle())
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    /// 10d's switch: a 38×22 Signal pill with an 18pt knob inset 2pt, muted
    /// track and grey knob when off. The system switch has its own size and
    /// its own greys, which is exactly the drift the mock calls out.
    private struct PTSwitchStyle: ToggleStyle {
        func makeBody(configuration: Configuration) -> some View {
            // Knob travel from center: half the track minus half the knob,
            // minus the inset.
            let travel = (PT.M.switchTrackWidth - PT.M.switchKnobSize) / 2 - PT.M.switchKnobInset
            return Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 12) {
                    configuration.label
                    RoundedRectangle(cornerRadius: PT.M.switchTrackHeight / 2)
                        .fill(configuration.isOn ? PT.C.signal : PT.C.switchOffTrack)
                        .frame(width: PT.M.switchTrackWidth, height: PT.M.switchTrackHeight)
                        .overlay {
                            Circle()
                                .fill(configuration.isOn ? PT.C.onSignal : PT.C.switchOffKnob)
                                .frame(width: PT.M.switchKnobSize, height: PT.M.switchKnobSize)
                                .offset(x: configuration.isOn ? travel : -travel)
                        }
                        .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isOn ? "on" : "off")
        }
    }

    private func load() {
        let resolved = Config.resolveRoot(cliOverride: nil).path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        recordingsDir = resolved.replacingOccurrences(of: home, with: "~")
        transcribe = Config.transcriptionEnabledValue()
        voiceProcessing = Config.micVoiceProcessing()
        autoPaste = Config.autoPaste()
        launchAtLogin = LaunchAtLogin.isEnabled
        onStop = Config.onStop() ?? ""
        terminalID = TerminalApp.current().id
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
                "auto_paste": autoPaste ? nil : false,
                "on_stop": trimmedHook.isEmpty ? nil : trimmedHook,
                // Only written when it isn't the default, so the config keeps
                // holding deliberate overrides only.
                "terminal": terminalID == TerminalApp.known[0].id ? nil : terminalID,
            ])
            if launchAtLogin != LaunchAtLogin.isEnabled {
                try LaunchAtLogin.setEnabled(launchAtLogin)
            }
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

    var hasPresentableWindow: Bool {
        window?.isVisible == true && window?.isMiniaturized == false
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
            // Dark by decision, not by system setting. The palette is dark-only.
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(PT.C.window)
            // The root view draws its own titlebar strip; the system one only
            // needs to supply the traffic lights.
            w.titlebarAppearsTransparent = true
            // Reopening from Finder or the Dock should bring the review window
            // to the Space the user is currently looking at.
            w.collectionBehavior.insert(.moveToActiveSpace)
            w.contentView = NSHostingView(rootView: PatchthroughRootView(store: store))

            if let saved = UserDefaults.standard.string(forKey: Self.frameKey), !saved.isEmpty {
                w.setFrame(NSRectFromString(saved), display: false)
            } else {
                center(w, on: preferredScreen())
            }
            window = w
        }
        if let window {
            keepOnscreen(window)
            saveFrame()
        }
        store.refresh()
        if ProcessInfo.processInfo.environment["PATCHTHROUGH_DEBUG_SETTINGS"] != nil {
            store.showSettings = true
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()

        alignTrafficLights()

        if ProcessInfo.processInfo.environment["PATCHTHROUGH_DEBUG_WINDOW"] != nil, let w = window {
            FileHandle.standardError.write(Data("""
            window: visible=\(w.isVisible) frame=\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)) \
            \(Int(w.frame.width))x\(Int(w.frame.height)) \
            screen=\(w.screen?.localizedName ?? "none") sessions=\(store.items.count)\n
            """.utf8))
        }
    }

    /// Saved frames can point at a display that is no longer connected. A
    /// window only counts as present when its centre is on a current display;
    /// otherwise move it to the display under the pointer before ordering it.
    private func keepOnscreen(_ window: NSWindow) {
        let centre = NSPoint(x: window.frame.midX, y: window.frame.midY)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(centre) }) {
            let constrained = window.constrainFrameRect(window.frame, to: screen)
            if constrained != window.frame {
                window.setFrame(constrained, display: false)
            }
        } else {
            center(window, on: preferredScreen())
        }
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main
    }

    private func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        let centered = NSRect(
            x: visible.midX - window.frame.width / 2,
            y: visible.midY - window.frame.height / 2,
            width: window.frame.width,
            height: window.frame.height
        )
        window.setFrame(window.constrainFrameRect(centered, to: screen), display: false)
    }

    /// 11a's titlebar strip is 52pt and the traffic lights sit level with the
    /// wordmark. macOS parks them near the top of a standard 28pt titlebar, so
    /// nudge them to the strip's centre line. Re-applied on resize, which is
    /// when AppKit re-lays them out.
    private func alignTrafficLights() {
        guard let w = window else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = w.standardWindowButton(kind),
                  let container = button.superview else { continue }
            var f = button.frame
            let centre = Self.titleBarHeight / 2
            f.origin.y = container.isFlipped
                ? centre - f.height / 2
                : container.frame.height - centre - f.height / 2
            guard abs(f.origin.y - button.frame.origin.y) > 0.5 else { continue }
            button.frame = f
        }
    }

    /// Matches `PatchthroughRootView.titleBar`'s height.
    static let titleBarHeight: CGFloat = 52

    func windowDidResize(_ notification: Notification) {
        saveFrame()
        alignTrafficLights()
    }
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
