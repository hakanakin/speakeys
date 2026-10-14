import AppKit
import Carbon.HIToolbox

/// The key that starts dictation: either a lone modifier (Right ⌘) or a key combo (⌃⌥Space).
struct Trigger: Codable, Equatable {
    var keyCode: UInt16
    /// ⌘⌃⌥⇧ flags for key combos; unused for lone modifiers.
    var modifiers: UInt
    var modifierOnly: Bool
    var name: String

    static let rightCommand = Trigger.modifier(54)!
    static let presets: [Trigger] = [54, 61, 62, 60, 63].compactMap(Trigger.modifier)

    /// A lone-modifier trigger, if `keyCode` is a modifier key.
    static func modifier(_ keyCode: UInt16) -> Trigger? {
        guard let name = ModifierKey.name(for: keyCode) else { return nil }
        return Trigger(keyCode: keyCode, modifiers: 0, modifierOnly: true, name: name)
    }

    /// A key-combo trigger from a key press, or nil if it would get in the way of normal typing.
    static func combo(from event: NSEvent) -> Trigger? {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isFunctionKey = KeyName.functionKeys.contains(event.keyCode)
        guard isFunctionKey || !mods.isDisjoint(with: [.command, .control, .option]) else { return nil }
        return Trigger(keyCode: event.keyCode, modifiers: mods.rawValue, modifierOnly: false,
                       name: KeyName.symbols(for: mods) + KeyName.name(for: event))
    }

    /// Modifier flags in the form Carbon's RegisterEventHotKey expects.
    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        let pairs: [(NSEvent.ModifierFlags, Int)] = [
            (.command, cmdKey), (.shift, shiftKey), (.option, optionKey), (.control, controlKey),
        ]
        return pairs.reduce(0) { flags.contains($1.0) ? $0 | UInt32($1.1) : $0 }
    }
}

/// Left/right-specific modifier keys. macOS reports each side as its own device flag bit.
enum ModifierKey {
    private static let keys: [UInt16: (name: String, mask: UInt)] = [
        54: ("Right ⌘", 0x10), 55: ("Left ⌘", 0x08),
        61: ("Right ⌥", 0x40), 58: ("Left ⌥", 0x20),
        62: ("Right ⌃", 0x2000), 59: ("Left ⌃", 0x01),
        60: ("Right ⇧", 0x04), 56: ("Left ⇧", 0x02),
        63: ("Fn", NSEvent.ModifierFlags.function.rawValue),
    ]

    static func name(for keyCode: UInt16) -> String? { keys[keyCode]?.name }

    /// Whether this exact modifier key (not just "any ⌘") is down in `flags`.
    static func isDown(_ keyCode: UInt16, in flags: NSEvent.ModifierFlags) -> Bool? {
        keys[keyCode].map { flags.rawValue & $0.mask != 0 }
    }
}

/// Display names for keys, e.g. "⌃⌥Space".
enum KeyName {
    static let functionKeys: Set<UInt16> = Set(names.compactMap { $0.value.hasPrefix("F") ? $0.key : nil })

    private static let names: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static func name(for event: NSEvent) -> String {
        names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }
            .map(\.1)
            .joined()
    }
}
