import AppKit

/// Confirmations for actions that change what is on disk. Separate from
/// `HandoffAlert`, which is about the paste flows: these guard user data.
@MainActor
enum SessionAlert {
    /// Ask before a session leaves the sidebar.
    ///
    /// Deliberately not suppressible, unlike the two handoff alerts. Those
    /// silence workflow friction; this one is the last thing standing between a
    /// click and a meeting nobody can record again. The alert names the session
    /// so the answer is to a specific question rather than a general one.
    ///
    /// Returns false on cancel.
    static func confirmTrash(name: String, hasTranscript: Bool, noteCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move “\(name)” to the Trash?"

        // Say what is actually being lost. "Deletes the session" is true and
        // useless; the audio is the part that cannot be reconstructed.
        var parts = ["Both audio tracks"]
        if hasTranscript { parts.append("the transcript") }
        if noteCount > 0 { parts.append("your \(noteCount) note\(noteCount == 1 ? "" : "s")") }
        let contents = parts.count == 1
            ? parts[0]
            : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]

        alert.informativeText = """
        \(contents) go to the Trash together. The recording cannot be made \
        again, so recover it from the Trash rather than emptying it if you are \
        not sure.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        // Return cancels. macOS makes the first button the default, which for a
        // destructive action means a stray Return deletes a meeting.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Shown when the move itself fails — a locked volume, a permissions
    /// change, a folder already gone from under us.
    static func trashFailed(name: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not move “\(name)” to the Trash"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
