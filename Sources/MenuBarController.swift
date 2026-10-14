import AppKit
import ServiceManagement

/// The menu bar icon and its menu. The menu is rebuilt each time it opens, so it always
/// reflects the current settings, permissions and login-item state.
final class MenuBarController: NSObject, NSMenuDelegate {
    var onLanguageChange: ((String) -> Void)?
    var onLayoutChange: (() -> Void)?
    /// Motion or color changed.
    var onAppearanceChange: (() -> Void)?
    var onShortcutChange: (() -> Void)?
    var onRecordShortcut: (() -> Void)?
    var onToggleOrb: (() -> Void)?
    /// Whether the orb is currently shown, for the Hide/Show item.
    var isOrbVisible: () -> Bool = { true }

    private let settings: Settings
    weak var updates: UpdateChecker?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    init(settings: Settings) {
        self.settings = settings
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        menuNeedsUpdate(menu)
        setListening(false)
    }

    /// The icon fills in while Speakeys is listening.
    func setListening(_ listening: Bool) {
        let symbol = listening ? "circle.hexagongrid.fill" : "circle.hexagongrid"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Speakeys")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hint = NSMenuItem(title: "Tap \(settings.trigger.name) to dictate · hold to push-to-talk",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠︎ Allow Accessibility to type text…") { Self.openAccessibilitySettings() })
        }
        if let release = updates?.available {
            menu.addItem(item("⬆︎ Download Speakeys \(release.version)…") { [unowned self] in updates?.openDownload() })
        }
        menu.addItem(.separator())

        menu.addItem(submenu("Shortcut", shortcutItems()))
        menu.addItem(submenu("Language", Language.supported.map { language in
            item(language.name, checked: language.id == settings.language) { [unowned self] in
                settings.language = language.id
                onLanguageChange?(language.id)
            }
        }))
        menu.addItem(submenu("Size", OrbSize.allCases.map { size in
            item(size.title, checked: size == settings.size) { [unowned self] in
                settings.size = size
                onLayoutChange?()
            }
        }))
        menu.addItem(submenu("Position", Corner.allCases.map { corner in
            item(corner.title, checked: corner == settings.corner) { [unowned self] in
                settings.corner = corner
                onLayoutChange?()
            }
        }))
        menu.addItem(submenu("Motion", Motion.allCases.map { motion in
            item(motion.title, checked: motion == settings.motion) { [unowned self] in
                settings.motion = motion
                onAppearanceChange?()
            }
        }))
        menu.addItem(submenu("Color", colorItems()))
        menu.addItem(.separator())

        menu.addItem(item("Play Sounds", checked: settings.playsSounds) { [unowned self] in
            settings.playsSounds.toggle()
        })
        menu.addItem(item("Launch at Login", checked: SMAppService.mainApp.status == .enabled) {
            Self.toggleLaunchAtLogin()
        })
        menu.addItem(item("Check for Updates Automatically", checked: settings.checksForUpdates) { [unowned self] in
            settings.checksForUpdates.toggle()
        })
        menu.addItem(.separator())

        menu.addItem(item(isOrbVisible() ? "Hide Speakeys" : "Show Speakeys", key: "h") { [unowned self] in
            onToggleOrb?()
        })
        menu.addItem(item("Check for Updates…") { [unowned self] in updates?.checkNow() })
        menu.addItem(item("About Speakeys") { Self.showAbout() })
        menu.addItem(NSMenuItem(title: "Quit Speakeys", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Items

    private func shortcutItems() -> [NSMenuItem] {
        let current = settings.trigger
        let options = Trigger.presets.contains(current) ? Trigger.presets : Trigger.presets + [current]
        var items = options.map { trigger in
            item(trigger.name, checked: trigger == current) { [unowned self] in
                settings.trigger = trigger
                onShortcutChange?()
            }
        }
        items.append(.separator())
        items.append(item("Record Shortcut…") { [unowned self] in onRecordShortcut?() })
        return items
    }

    private func colorItems() -> [NSMenuItem] {
        var items = OrbColor.presets.map { color in
            let entry = item(color.title, checked: color == settings.color) { [unowned self] in
                settings.color = color
                onAppearanceChange?()
            }
            entry.image = Self.swatch(color.nsColor)
            return entry
        }
        items.append(.separator())
        let custom = item(OrbColor.custom.title, checked: settings.color == .custom) { [unowned self] in
            showColorPanel()
        }
        custom.image = Self.swatch(settings.customColor)
        items.append(custom)
        return items
    }

    /// The system color picker; the orb follows it live.
    private func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = settings.customColor
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        settings.color = .custom
        onAppearanceChange?()
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFront(nil)
    }

    @objc private func customColorChanged(_ panel: NSColorPanel) {
        settings.customColor = panel.color
        settings.color = .custom
        onAppearanceChange?()
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
    }

    private func item(_ title: String, checked: Bool = false, key: String = "",
                      action: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: title, keyEquivalent: key, action: action)
        item.state = checked ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu()
        items.forEach(item.submenu!.addItem)
        return item
    }

    // MARK: Actions

    private static func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            Log.error("launch at login: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "A tiny dictation app with a floating wireframe orb.\nOpen source under the MIT License.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }
}

/// A menu item that runs a closure, which keeps menu construction declarative.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
