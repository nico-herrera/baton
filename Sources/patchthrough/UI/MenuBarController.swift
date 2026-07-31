import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem

    private let handoffItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenWindow: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Called with the agent name when the user picks one from "Hand off →".
    var onHandoff: ((String) -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        // Hand off → [detected agents]. Rebuilt whenever a transcript lands,
        // disabled until there's something to hand off.
        handoffItem = NSMenuItem(title: "Hand off to", action: nil, keyEquivalent: "")
        handoffItem.submenu = NSMenu()
        handoffItem.isEnabled = false
        menu.addItem(handoffItem)

        let openWindow = NSMenuItem(
            title: "Open Patchthrough…",
            action: #selector(openWindowClicked),
            keyEquivalent: "b"
        )
        menu.addItem(openWindow)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Patchthrough",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openWindow, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.markImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the feather (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    /// Populate "Hand off to →": terminal agents first, then GUI targets.
    /// `representedObject` carries "cli:<name>" or "gui:<id>" so the handler
    /// knows which door to use. Pass nil session when nothing is transcribed.
    func updateHandoff(agents: [String], guiTargets: [(id: String, label: String)], latestSession: String?) {
        let sub = handoffItem.submenu ?? NSMenu()
        sub.removeAllItems()

        guard let session = latestSession, !(agents.isEmpty && guiTargets.isEmpty) else {
            handoffItem.isEnabled = false
            handoffItem.title = latestSession != nil
                ? "Hand off to (no agents found)"
                : "Hand off to"
            return
        }

        handoffItem.title = "Hand off \(session) to"
        handoffItem.isEnabled = true

        for name in agents {
            let item = NSMenuItem(title: "\(name) — terminal", action: #selector(handoffClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "cli:\(name)"
            sub.addItem(item)
        }
        if !agents.isEmpty && !guiTargets.isEmpty { sub.addItem(.separator()) }
        for target in guiTargets {
            let item = NSMenuItem(title: target.label, action: #selector(handoffClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "gui:\(target.id)"
            sub.addItem(item)
        }
        handoffItem.submenu = sub
    }

    // The patch cable in flight — diagonal line with signal ticks. Same mark
    // scaled up for the Dock icon in AppIcon.swift.
    // Inlined SVG so the executable has no separate resource bundle to
    // install alongside it — true single-binary.
    private static let markSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M8.5 15.5 19 5"/>\
    <path d="M5 12l-2 2"/>\
    <path d="M9 16l-2 2"/>\
    <path d="M13 20l-1.5 1.5"/>\
    </svg>
    """

    private static func markImage() -> NSImage? {
        guard let data = markSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openWindowClicked() { onOpenWindow?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func handoffClicked(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { onHandoff?(name) }
    }
}
