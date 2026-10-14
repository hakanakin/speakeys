import AppKit

extension NSPanel {
    /// A borderless, transparent, click-through panel that floats above other apps on every Space.
    static func overlay(size: NSSize = NSSize(width: 100, height: 100)) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

extension NSScreen {
    /// The screen with the menu bar, which is where Speakeys lives.
    static var menuBarScreen: NSScreen? { screens.first }
}
