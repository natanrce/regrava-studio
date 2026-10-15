import AppKit

/// Native message boxes: confirm is the default button, cancel is the cancel button.
@MainActor
enum Dialogs {
    @discardableResult
    static func confirm(title: String, message: String, confirm: String = "Confirm", cancel: String = "Cancel", destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        let confirmButton = alert.addButton(withTitle: confirm)
        confirmButton.hasDestructiveAction = destructive
        alert.addButton(withTitle: cancel).keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func info(title: String, message: String, button: String = "OK") {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.runModal()
    }

    static func error(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Error"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
