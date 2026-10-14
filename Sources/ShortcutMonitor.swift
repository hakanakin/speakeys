import AppKit
import Carbon.HIToolbox

/// Watches the chosen trigger system-wide and reports presses, distinguishing a tap from a hold.
///
/// Lone modifiers are seen through global flag-change events. Key combos are registered as
/// Carbon hot keys, which also stops the keystroke from reaching the frontmost app.
final class ShortcutMonitor {
    var onPress: (() -> Void)?
    /// `held` is true when the key stayed down long enough to mean push-to-talk.
    var onRelease: ((_ held: Bool) -> Void)?
    /// A lone-modifier trigger was combined with another key, so it's a normal shortcut.
    var onUsedAsShortcut: (() -> Void)?
    var onEscape: (() -> Void)?

    private static let holdThreshold: TimeInterval = 0.4
    private static let hotKeyID = EventHotKeyID(signature: OSType(0x5350_4B59), id: 1)   // "SPKY"

    private var trigger: Trigger?
    private var pressedAt: Date?
    private var usedAsShortcut = false
    private var monitors: [Any] = []
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func start() {
        guard monitors.isEmpty else { return }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flagsChanged($0) },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.keyDown($0) },
        ].compactMap { $0 }
        installHotKeyHandler()
    }

    /// Switches to `trigger`; nil pauses the monitor (e.g. while recording a new shortcut).
    func use(_ trigger: Trigger?) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        pressedAt = nil
        self.trigger = trigger
        guard let trigger, !trigger.modifierOnly else { return }

        let status = RegisterEventHotKey(UInt32(trigger.keyCode), trigger.carbonModifiers, Self.hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { Log.error("could not register shortcut \(trigger.name): \(status)") }
    }

    // MARK: Events

    private func press() {
        guard pressedAt == nil else { return }
        pressedAt = Date()
        usedAsShortcut = false
        onPress?()
    }

    private func release() {
        guard let start = pressedAt else { return }
        pressedAt = nil
        guard !usedAsShortcut else { return }
        onRelease?(Date().timeIntervalSince(start) >= Self.holdThreshold)
    }

    private func flagsChanged(_ event: NSEvent) {
        guard let trigger, trigger.modifierOnly, event.keyCode == trigger.keyCode,
              let isDown = ModifierKey.isDown(trigger.keyCode, in: event.modifierFlags) else { return }
        isDown ? press() : release()
    }

    private func keyDown(_ event: NSEvent) {
        if pressedAt != nil, trigger?.modifierOnly == true {
            guard !usedAsShortcut else { return }
            usedAsShortcut = true
            onUsedAsShortcut?()
        } else if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
        }
    }

    private func installHotKeyHandler() {
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
            GetEventKind(event) == UInt32(kEventHotKeyPressed) ? monitor.press() : monitor.release()
            return noErr
        }, events.count, &events, context, &hotKeyHandler)
    }
}
