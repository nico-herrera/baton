import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
///
/// The mark and its rules come from packaging/design/DESIGN.md: a socket ring
/// and patch cord on a 24×24 grid, regular weight (1.6) at rest, heavy (2.1)
/// while patching (transcribing). The recording dot (#D2371B) is the only
/// colour in the product and is composited as a separate non-template layer —
/// baking it into the template art would get it flattened to black.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem

    private let handoffItem: NSMenuItem

    private var recordingDot: NSView?

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
            let image = Self.markImage(weight: .regular)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state: the mark stays template (macOS handles
    /// light/dark), and the Signal dot appears at the lower right, pulsing.
    /// The elapsed counter lives in the menu's state label.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        setRecordingDot(visible: recording)
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. While transcribing, the mark goes heavy — the
    /// design system's "patching" state.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil

        let image = Self.markImage(weight: text == nil ? .regular : .heavy)
        image?.isTemplate = true
        statusItem.button?.image = image
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
            item.image = NSImage(systemSymbolName: Handoff.symbol(for: name), accessibilityDescription: nil)
            sub.addItem(item)
        }
        if !agents.isEmpty && !guiTargets.isEmpty { sub.addItem(.separator()) }
        for target in guiTargets {
            let item = NSMenuItem(title: target.label, action: #selector(handoffClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = "gui:\(target.id)"
            item.image = NSImage(systemSymbolName: Handoff.symbol(for: target.id), accessibilityDescription: nil)
            sub.addItem(item)
        }
        handoffItem.submenu = sub
    }

    // MARK: - The mark

    enum MarkWeight { case regular, heavy }

    /// The Patchthrough mark: socket ring + patch cord, 24×24 grid, inlined
    /// from packaging/design (single binary, no resource bundle). Rules that
    /// matter: ring and cord always share one weight, the cord never crosses
    /// the ring's centre, and nothing here gets rotated or mirrored.
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
        image.size = NSSize(width: 18, height: 18)   // spec: 18pt in the menu bar
        return image
    }

    /// The Signal dot: 7px at 18pt, lower right, pulsing at 1.6s ease-in-out.
    /// A subview rather than part of the image, so the mark stays a template.
    private func setRecordingDot(visible: Bool) {
        guard let button = statusItem.button else { return }

        if !visible {
            recordingDot?.removeFromSuperview()
            recordingDot = nil
            return
        }
        guard recordingDot == nil else { return }

        let dot = NSView(frame: NSRect(x: button.bounds.maxX - 10, y: 2, width: 7, height: 7))
        dot.autoresizingMask = [.minXMargin, .maxYMargin]
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(
            calibratedRed: 0xD2 / 255, green: 0x37 / 255, blue: 0x1B / 255, alpha: 1
        ).cgColor
        dot.layer?.cornerRadius = 3.5

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(pulse, forKey: "pulse")

        button.addSubview(dot)
        recordingDot = dot
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openWindowClicked() { onOpenWindow?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func handoffClicked(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { onHandoff?(name) }
    }
}
