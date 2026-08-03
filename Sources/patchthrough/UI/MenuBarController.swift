import AppKit

/// Status bar item. Art per the logo handoff (regular at rest, heavy while
/// patching, Signal dot while recording); menu per APP_REDESIGN_HANDOFF.md
/// round 10e. The menu leads with the verb and promotes the top-ranked
/// destination to a one-click item. The state header carries the session count.
@MainActor
final class MenuBarController {

    /// Everything the menu needs to render handoff state, built by the
    /// controller so this class never touches the store directly.
    struct HandoffMenuModel {
        struct Entry {
            let id: String        // "cli:claude" / "gui:claude-cowork"
            let label: String
            let symbol: String
            let count: Int
        }
        let mostUsed: [Entry]     // top 3 by use
        let terminal: [Entry]     // remainder, CLI
        let app: [Entry]          // remainder, installed apps
        let web: [Entry]          // remainder, browser doors
        let custom: [Entry]       // remainder, the user's own config
        let top: Entry?
        let latestTimeLabel: String?   // "9:45 PM"
        let sessionCount: Int
    }

    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let patchNowItem: NSMenuItem
    private let handoffItem: NSMenuItem
    private let transcriptionLabel: NSMenuItem

    private var recordingDot: NSView?
    private var isRecording = false
    private var model = HandoffMenuModel(
        mostUsed: [], terminal: [], app: [], web: [], custom: [], top: nil, latestTimeLabel: nil, sessionCount: 0
    )

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenWindow: (() -> Void)?
    var onQuit: (() -> Void)?
    var onHandoff: ((String) -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "● Idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "Start recording", action: #selector(toggleClicked), keyEquivalent: "r")
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        patchNowItem = NSMenuItem(title: "Patch through", action: #selector(patchNowClicked), keyEquivalent: "")
        patchNowItem.isEnabled = false
        menu.addItem(patchNowItem)

        handoffItem = NSMenuItem(title: "Patch through to", action: nil, keyEquivalent: "")
        handoffItem.submenu = NSMenu()
        handoffItem.isEnabled = false
        menu.addItem(handoffItem)

        menu.addItem(.separator())

        let openWindow = NSMenuItem(title: "Open Patchthrough…", action: #selector(openWindowClicked), keyEquivalent: "b")
        menu.addItem(openWindow)
        let openFolder = NSMenuItem(title: "Recordings folder", action: #selector(openFolderClicked), keyEquivalent: "o")
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        menu.addItem(quit)

        for item in [toggleItem, patchNowItem, openWindow, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.markImage(weight: .regular)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
        render()
    }

    // MARK: - State

    func update(recording: Bool, elapsed: String?) {
        isRecording = recording
        renderState(elapsed: elapsed)
        setRecordingDot(visible: recording)
        renderPatchItems()
    }

    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
        let image = Self.markImage(weight: text == nil ? .regular : .heavy)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func apply(_ newModel: HandoffMenuModel) {
        model = newModel
        render()
    }

    private func render() {
        renderState(elapsed: nil)
        renderPatchItems()
    }

    private func renderState(elapsed: String?) {
        if isRecording {
            // ● Recording  1:04 in Signal, with monospaced digits.
            let s = NSMutableAttributedString(
                string: "● Recording",
                attributes: [.foregroundColor: PT.NS.signal]
            )
            if let elapsed {
                s.append(NSAttributedString(
                    string: "  \(elapsed)",
                    attributes: [.font: NSFont.monospacedDigitSystemFont(
                        ofSize: NSFont.systemFontSize(for: .small), weight: .regular)]
                ))
            }
            stateLabel.attributedTitle = s
            toggleItem.title = "Stop & transcribe"
            toggleItem.subtitle = "mic + system audio · 2 tracks"
            toggleItem.image = Self.dotImage(square: true)
        } else {
            // The idle header is a dim status line, not a peer of the actions.
            let n = model.sessionCount
            stateLabel.attributedTitle = NSAttributedString(
                string: "● Idle · \(n) session\(n == 1 ? "" : "s")",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                             .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))]
            )
            toggleItem.title = "Start recording"
            toggleItem.subtitle = nil
            toggleItem.image = Self.dotImage(square: false)
        }
    }

    /// The record/stop glyph beside the toggle: a Signal disc at rest, a
    /// Signal square while recording. Non-template so it keeps its colour.
    private static func dotImage(square: Bool) -> NSImage {
        let side = PT.M.menuGlyphSize
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            PT.NS.signal.setFill()
            let path = square
                ? NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
                : NSBezierPath(ovalIn: rect)
            path.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func renderPatchItems() {
        // Promoted one-click item: top-ranked destination, latest session.
        if let top = model.top, let time = model.latestTimeLabel {
            patchNowItem.title = "Patch \(time) to \(top.label)"
            patchNowItem.image = NSImage(systemSymbolName: top.symbol, accessibilityDescription: nil)
            patchNowItem.representedObject = top.id
            patchNowItem.isEnabled = !isRecording   // nothing finished to patch while recording
            patchNowItem.isHidden = false
        } else {
            patchNowItem.isHidden = true
        }

        let sub = handoffItem.submenu ?? NSMenu()
        sub.removeAllItems()
        let hasAny = !(model.mostUsed.isEmpty && model.terminal.isEmpty
                       && model.app.isEmpty && model.web.isEmpty && model.custom.isEmpty)
        handoffItem.isEnabled = hasAny && model.latestTimeLabel != nil && !isRecording

        func add(_ entries: [HandoffMenuModel.Entry], header: String) {
            guard !entries.isEmpty else { return }
            sub.addItem(NSMenuItem.sectionHeader(title: header))
            for e in entries {
                // Never show a count of 0. Omit the suffix instead.
                let title = e.count > 0 ? "\(e.label)   \(e.count)×" : e.label
                let item = NSMenuItem(title: title, action: #selector(handoffClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = e.id
                item.image = NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil)
                item.isEnabled = !isRecording
                sub.addItem(item)
            }
        }
        add(model.mostUsed, header: "Most used")
        add(model.terminal, header: "Terminal")
        add(model.app, header: "App")
        add(model.web, header: "Web")
        add(model.custom, header: "Custom")
        handoffItem.submenu = sub
    }

    // MARK: - The mark (the redesign did not change it; the logo handoff rules)

    enum MarkWeight { case regular, heavy }

    private static func markSVG(weight: CGFloat) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">\
        <g transform="translate(0,-0.45)" fill="none" stroke="#000000" stroke-linecap="round">\
        <circle cx="12" cy="12" r="6.3" stroke-width="\(weight)"></circle>\
        <path d="M2.8 19.2 C 5.2 14.8 7.8 10.9 10.3 9.6 C 12.8 8.3 16.8 7.2 21.2 6.4" stroke-width="\(weight)"></path>\
        </g>\
        </svg>
        """
    }

    private static func markImage(weight: MarkWeight) -> NSImage? {
        let svg = markSVG(weight: weight == .regular ? 1.6 : 2.1)
        guard let data = svg.data(using: .utf8), let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: PT.M.statusItemSize, height: PT.M.statusItemSize)
        return image
    }

    /// The Signal dot: 7px at 18pt, lower right, pulsing 1.6s ease-in-out.
    /// A subview rather than part of the image, so the mark stays a template.
    private func setRecordingDot(visible: Bool) {
        guard let button = statusItem.button else { return }

        if !visible {
            recordingDot?.removeFromSuperview()
            recordingDot = nil
            return
        }
        guard recordingDot == nil else { return }

        let dot = NSView(frame: NSRect(x: button.bounds.maxX - PT.M.recordDotSize - 3, y: 2,
                                        width: PT.M.recordDotSize, height: PT.M.recordDotSize))
        dot.autoresizingMask = [.minXMargin, .maxYMargin]
        dot.wantsLayer = true
        dot.layer?.backgroundColor = PT.NS.signal.cgColor
        dot.layer?.cornerRadius = PT.M.recordDotSize / 2

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = PT.M.pulseHalfPeriod
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(pulse, forKey: "pulse")

        button.addSubview(dot)
        recordingDot = dot
    }

    /// Open the menu from code. A screenshot harness can't click the status
    /// item without Accessibility permission, but the app can click its own.
    func openMenuForDebug() {
        statusItem.button?.performClick(nil)
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openWindowClicked() { onOpenWindow?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func patchNowClicked() {
        if let id = patchNowItem.representedObject as? String { onHandoff?(id) }
    }
    @objc private func handoffClicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onHandoff?(id) }
    }
}
