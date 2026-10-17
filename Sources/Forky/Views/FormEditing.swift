import AppKit

/// Composed/marked text is not necessarily in SwiftUI's bound model yet.
/// Never execute an older reviewed value while a different IME candidate is visible.
@MainActor enum FormEditing {
    static func finish() -> Bool {
        guard let window = NSApp.keyWindow else { return true }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() {
            editor.unmarkText()
            editor.didChangeText()
            _ = window.makeFirstResponder(nil)
            return false // binding/approval must be reviewed after composition ends
        }
        return window.makeFirstResponder(nil)
    }
    static let reviewMessage = "Input composition was completed. Review the committed text and approve again; no operation ran."
}
