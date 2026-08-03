import AppKit

/// Alerts for the handoff paste flows. These are NSAlerts rather than
/// notifications on purpose: macOS silently drops `display notification` for
/// an accessory app often enough that the message would never arrive.
@MainActor
enum HandoffAlert {
    private static let accessibilitySettings =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let manualPasteSuppressKey = "handoff.manualPasteExplainerSuppressed"
    /// Per destination, because the checkbox says "for this destination".
    /// A single flag would silence the warning for every future one.
    private static func cloudUploadSuppressKey(_ site: String) -> String {
        "handoff.cloudUploadWarningSuppressed.\(site)"
    }

    /// Shown when a clipboard handoff opened the app but the ⌘N+⌘V paste
    /// failed, which almost always means patchthrough has no Accessibility
    /// grant.
    static func showPasteFailed(app: String) {
        let alert = NSAlert()
        alert.messageText = "The handoff file is on your clipboard"
        alert.informativeText = """
        Patchthrough could not paste into \(app). Press ⌘N then ⌘V in \(app) to \
        attach the transcript.

        Grant Accessibility to Patchthrough to have it paste for you next time.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: accessibilitySettings) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shown before a handoff to a target that accepts no automation
    /// (`manualTextPaste`), so the user knows the one manual step before the
    /// app takes focus. A suppression checkbox silences it permanently.
    /// Returns false when the user cancels the handoff.
    static func confirmManualPaste(app: String) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: manualPasteSuppressKey) { return true }

        let alert = NSAlert()
        alert.messageText = "\(app) needs one manual paste"
        alert.informativeText = """
        Patchthrough puts the prompt and the full transcript on your clipboard \
        as text. In \(app), click the message box, press ⌘V, then send.

        Patchthrough pastes into other apps for you, but \(app) accepts no \
        automation: it has no prompt link, and it ignores synthesized \
        keystrokes and pasted files. A very long transcript can also exceed \
        the message box's own size limit.
        """
        alert.alertStyle = .informational
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this again"
        alert.addButton(withTitle: "Open \(app)")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: manualPasteSuppressKey)
        }
        return response == .alertFirstButtonReturn
    }

    /// Shown before a handoff to a site that copies the attachment into cloud
    /// storage. Patchthrough keeps recordings on the machine, so the one door
    /// that breaks that has to say so first. Returns false when the user
    /// cancels.
    static func confirmCloudUpload(site: String) -> Bool {
        let defaults = UserDefaults.standard
        let suppressKey = cloudUploadSuppressKey(site)
        if defaults.bool(forKey: suppressKey) { return true }

        let alert = NSAlert()
        alert.messageText = "\(site) copies the transcript to the cloud"
        alert.informativeText = """
        Microsoft puts a file that you attach in your work OneDrive, so this \
        transcript leaves your Mac. Every other destination keeps it here.

        The recording and the audio stay on this machine either way. Only the \
        attached transcript is copied.
        """
        alert.alertStyle = .warning
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again for this destination"
        alert.addButton(withTitle: "Attach and Continue")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: suppressKey)
        }
        return response == .alertFirstButtonReturn
    }
}
