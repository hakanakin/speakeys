import AppKit
import Speech

/// User preferences, persisted in UserDefaults.
final class Settings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var language: String {
        get { defaults.string(forKey: Key.language) ?? Language.systemDefault }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    var corner: Corner {
        get { Corner(stored: defaults.string(forKey: Key.corner)) ?? .bottomRight }
        set { defaults.set(newValue.rawValue, forKey: Key.corner) }
    }

    var size: OrbSize {
        get { OrbSize(stored: defaults.string(forKey: Key.size)) ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.size) }
    }

    var motion: Motion {
        get { Motion(stored: defaults.string(forKey: Key.motion)) ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: Key.motion) }
    }

    /// A preset, or `.custom` to use `customColor`.
    var color: OrbColor {
        get { OrbColor(stored: defaults.string(forKey: Key.color)) ?? .pink }
        set { defaults.set(newValue.rawValue, forKey: Key.color) }
    }

    var customColor: NSColor {
        get { defaults.string(forKey: Key.customColor).flatMap(NSColor.init(hex:)) ?? OrbColor.pink.nsColor }
        set { defaults.set(newValue.hexString, forKey: Key.customColor) }
    }

    /// The color the orb is drawn in.
    var orbColor: NSColor { color == .custom ? customColor : color.nsColor }

    /// On by default.
    var checksForUpdates: Bool {
        get { defaults.object(forKey: Key.checksForUpdates) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.checksForUpdates) }
    }

    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    /// The newest version the user was already notified about, so we only tell them once.
    var lastNotifiedVersion: String? {
        get { defaults.string(forKey: Key.lastNotifiedVersion) }
        set { defaults.set(newValue, forKey: Key.lastNotifiedVersion) }
    }

    var playsSounds: Bool {
        get { defaults.bool(forKey: Key.sounds) }
        set { defaults.set(newValue, forKey: Key.sounds) }
    }

    var trigger: Trigger {
        get {
            defaults.data(forKey: Key.trigger)
                .flatMap { try? JSONDecoder().decode(Trigger.self, from: $0) } ?? .rightCommand
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.trigger) }
    }

    private enum Key {
        static let language = "language"
        static let corner = "corner"
        static let size = "size"
        static let sounds = "sounds"
        static let trigger = "trigger"
        static let motion = "motion"
        static let color = "color"
        static let customColor = "customColor"
        static let checksForUpdates = "checksForUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let lastNotifiedVersion = "lastNotifiedVersion"
    }
}

// MARK: - Options

/// A preference stored by `rawValue`. Older builds stored the display title, so both are accepted.
protocol StoredOption: RawRepresentable, CaseIterable where RawValue == String {
    var title: String { get }
}

extension StoredOption {
    init?(stored: String?) {
        guard let stored,
              let match = Self.allCases.first(where: {
                  $0.rawValue == stored || $0.title.caseInsensitiveCompare(stored) == .orderedSame
              })
        else { return nil }
        self = match
    }
}

enum Corner: String, StoredOption {
    case bottomRight, topRight, bottomLeft, topLeft

    var title: String {
        switch self {
        case .bottomRight: "Bottom Right"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .topLeft: "Top Left"
        }
    }

    var isRight: Bool { self == .bottomRight || self == .topRight }
    var isTop: Bool { self == .topRight || self == .topLeft }
}

enum OrbSize: String, StoredOption {
    case small, medium, large

    var title: String { rawValue.capitalized }

    /// Side length of the orb's window, in points.
    var side: CGFloat {
        switch self {
        case .small: 130
        case .medium: 170
        case .large: 240
        }
    }
}

enum OrbColor: String, StoredOption {
    case pink, violet, blue, teal, green, amber, white, custom

    static let presets = allCases.filter { $0 != .custom }

    var title: String { self == .custom ? "Custom…" : rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .pink, .custom: NSColor(srgbRed: 1.00, green: 0.55, blue: 0.78, alpha: 1)
        case .violet: NSColor(srgbRed: 0.72, green: 0.58, blue: 1.00, alpha: 1)
        case .blue: NSColor(srgbRed: 0.45, green: 0.70, blue: 1.00, alpha: 1)
        case .teal: NSColor(srgbRed: 0.35, green: 0.90, blue: 0.85, alpha: 1)
        case .green: NSColor(srgbRed: 0.55, green: 0.92, blue: 0.55, alpha: 1)
        case .amber: NSColor(srgbRed: 1.00, green: 0.75, blue: 0.40, alpha: 1)
        case .white: NSColor(srgbRed: 0.92, green: 0.92, blue: 0.95, alpha: 1)
        }
    }
}

extension NSColor {
    /// Parses "#RRGGBB".
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// How strongly the orb reacts to the voice while dictating. Resting motion is the same for all.
enum Motion: String, StoredOption {
    case calm, balanced, lively

    var title: String { rawValue.capitalized }

    struct Profile {
        /// Easing rates per 1/60 s: following a louder voice, settling after it, waking up.
        let attack, release, wake: Double
        /// Extra rotation and surface flow while dictating, and per unit of voice.
        let spin, flowFocus, flowVoice: Double
        /// Size, surface displacement and glow added by dictating and by the voice.
        let swell, wobbleFocus, wobbleVoice, glow: Double
    }

    var profile: Profile {
        switch self {
        case .calm:
            Profile(attack: 0.15, release: 0.04, wake: 0.12, spin: 0.35, flowFocus: 0.7, flowVoice: 1.4,
                    swell: 0.04, wobbleFocus: 0.04, wobbleVoice: 0.14, glow: 4)
        case .balanced:
            Profile(attack: 0.25, release: 0.07, wake: 0.16, spin: 0.55, flowFocus: 1.2, flowVoice: 2.8,
                    swell: 0.06, wobbleFocus: 0.05, wobbleVoice: 0.22, glow: 6)
        case .lively:
            Profile(attack: 0.4, release: 0.1, wake: 0.2, spin: 0.8, flowFocus: 1.8, flowVoice: 4.2,
                    swell: 0.07, wobbleFocus: 0.06, wobbleVoice: 0.3, glow: 7)
        }
    }
}

struct Language {
    let id: String
    let name: String

    static let all = [
        Language(id: "en-US", name: "English (US)"),
        Language(id: "en-GB", name: "English (UK)"),
        Language(id: "tr-TR", name: "Türkçe"),
        Language(id: "de-DE", name: "Deutsch"),
        Language(id: "fr-FR", name: "Français"),
        Language(id: "es-ES", name: "Español"),
        Language(id: "it-IT", name: "Italiano"),
        Language(id: "pt-BR", name: "Português (Brasil)"),
        Language(id: "nl-NL", name: "Nederlands"),
        Language(id: "ru-RU", name: "Русский"),
        Language(id: "ar-SA", name: "العربية"),
        Language(id: "ja-JP", name: "日本語"),
        Language(id: "ko-KR", name: "한국어"),
        Language(id: "zh-CN", name: "中文 (简体)"),
    ]

    /// The languages this Mac can recognize.
    static var supported: [Language] {
        let ids = Set(SFSpeechRecognizer.supportedLocales().map {
            $0.identifier.replacingOccurrences(of: "_", with: "-")
        })
        return all.filter { ids.contains($0.id) }
    }

    /// The system language if Speakeys offers it, otherwise US English.
    static var systemDefault: String {
        let preferred = Locale.preferredLanguages.first ?? "en-US"
        if all.contains(where: { $0.id == preferred }) { return preferred }
        let base = preferred.split(separator: "-").first.map(String.init) ?? "en"
        return all.first(where: { $0.id.hasPrefix(base + "-") })?.id ?? "en-US"
    }
}
