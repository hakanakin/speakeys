import AppKit
import Carbon.HIToolbox

/// Types text into the frontmost app by pasting it, then puts the user's clipboard back.
enum TextInserter {
    /// How long the target app gets to read the clipboard before it is restored.
    private static let restoreDelay: TimeInterval = 0.5

    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            // Pasting needs Accessibility; until then leave the text on the clipboard for ⌘V
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            Log.error("accessibility not granted: text left on clipboard")
            return
        }

        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChange = pasteboard.changeCount
        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // If the user copied something in the meantime, keep theirs
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
    }

    /// Copies every item and type, so images and rich text survive too.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: isDown)
            event?.flags = .maskCommand   // replaces any modifiers still held from the shortcut
            event?.post(tap: .cghidEventTap)
        }
    }
}
