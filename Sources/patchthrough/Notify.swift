import Foundation
import UserNotifications

/// True when this process runs from a .app bundle rather than a bare
/// `swift build` binary. UserNotifications needs bundle identity, and a bare
/// binary has none.
var runsFromAppBundle: Bool {
    Bundle.main.bundleURL.pathExtension.lowercased() == "app"
}

/// Best-effort user-visible notification. The bundled app posts through
/// UserNotifications, so the banner belongs to Patchthrough and a click
/// activates it. The osascript path stays for bare binaries: it needs no
/// bundle, but macOS attributes its banner to Script Editor, so a click
/// opens Script Editor.
func notifyUser(title: String, body: String) {
    if runsFromAppBundle {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        return
    }

    func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let script = "display notification \(quoted(body)) with title \(quoted(title))"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    try? task.run()
}
