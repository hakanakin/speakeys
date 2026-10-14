import AppKit
import Carbon.HIToolbox

/// A small window that captures the next shortcut the user presses.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var monitor: Any?
    private var completion: ((Trigger?) -> Void)?
    /// A modifier that went down with no other key yet; if it comes back up alone, it's the trigger.
    private var lastModifier: UInt16?
    private let titleLabel = NSTextField(labelWithString: "")

    /// Shows the recorder. `completion` gets the new trigger, or nil if the user cancelled.
    func record(completion: @escaping (Trigger?) -> Void) {
        guard window == nil else { return }
        self.completion = completion
        lastModifier = nil

        let window = makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil   // swallow keys while recording
        }
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            guard let isDown = ModifierKey.isDown(event.keyCode, in: event.modifierFlags) else { return }
            if isDown {
                lastModifier = event.keyCode
                titleLabel.stringValue = ModifierKey.name(for: event.keyCode) ?? ""
            } else if lastModifier == event.keyCode {
                finish(Trigger.modifier(event.keyCode))
            }
            return
        }

        lastModifier = nil
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]) {
            finish(nil)
        } else if let trigger = Trigger.combo(from: event) {
            finish(trigger)
        } else {
            titleLabel.stringValue = "Add ⌘, ⌃ or ⌥, or use an F-key"
        }
    }

    private func finish(_ trigger: Trigger?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let completion = self.completion
        self.completion = nil
        window?.orderOut(nil)
        window = nil
        completion?(trigger)
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Speakeys Shortcut"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self

        titleLabel.stringValue = "Press the new shortcut"
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .center

        let detail = NSTextField(wrappingLabelWithString:
            "A single key like Right ⌥, a combo like ⌃⌥Space, or an F-key.\nPress Esc to cancel.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center

        let stack = NSStackView(views: [titleLabel, detail])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 22, right: 20)
        window.contentView = stack
        window.center()
        return window
    }
}
