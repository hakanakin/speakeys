import AppKit
import AVFoundation
import Speech
import Carbon.HIToolbox
import ServiceManagement

// Problems are written to ~/Library/Logs/Speakeys.log
func debugLog(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Speakeys.log")
    let line = "\(Date()) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Microphone (runs only while dictating)

final class Microphone {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var current: Float = 0
    private var sink: SFSpeechAudioBufferRecognitionRequest?

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { debugLog("microphone permission denied") }
        }
    }

    /// Starts the mic and feeds every buffer to `request`. Returns false if the mic could not start.
    func start(feeding request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        lock.lock(); sink = request; lock.unlock()
        guard engine == nil else { return true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { debugLog("no input device"); return false }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let db = 20 * log10(max(rms, 1e-7))
            // Map roughly -55 dB (quiet room) ... -15 dB (speaking) to 0...1
            let norm = min(max((db + 55) / 40, 0), 1)
            self.lock.lock()
            self.current = norm
            let sink = self.sink
            self.lock.unlock()
            sink?.append(buffer)
        }
        do {
            try engine.start()
            self.engine = engine
            return true
        } catch {
            debugLog("could not start microphone: \(error)")
            input.removeTap(onBus: 0)
            return false
        }
    }

    /// Stops the mic so the orange privacy dot goes away.
    func stop() {
        lock.lock(); sink = nil; current = 0; lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

// MARK: - Dictation (speech → text typed at the cursor)

struct Language {
    let id: String
    let name: String
}

let allLanguages = [
    Language(id: "tr-TR", name: "Türkçe"),
    Language(id: "en-US", name: "English (US)"),
    Language(id: "en-GB", name: "English (UK)"),
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

final class Dictation {
    private let mic: Microphone
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var finished = false
    private var silenceTimer: Timer?
    private var startedAt = Date()
    private var lastActivity = Date()

    private(set) var isListening = false
    var onStateChange: ((Bool) -> Void)?
    var onPartial: ((String) -> Void)?   // live transcript while speaking

    init(mic: Microphone, language: String) {
        self.mic = mic
        setLanguage(language)
    }

    func setLanguage(_ id: String) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: id))
    }

    func requestPermissions() {
        mic.requestPermission()
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized { debugLog("speech recognition not authorized (\(status.rawValue))") }
        }
        // Needed to watch the hotkey and to paste into other apps
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { debugLog("accessibility not granted yet") }
    }

    func begin() {
        guard !isListening, let recognizer, recognizer.isAvailable else {
            debugLog("dictation unavailable for \(recognizer?.locale.identifier ?? "?")")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        transcript = ""
        finished = false
        startedAt = Date()
        lastActivity = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript { self.lastActivity = Date() }
                    self.transcript = text
                    self.onPartial?(self.transcript)
                }
                if error != nil || result?.isFinal == true { self.finished = true }
            }
        }
        guard mic.start(feeding: request) else {
            task?.cancel()
            task = nil
            return
        }
        self.request = request
        isListening = true
        onStateChange?(true)
    }

    /// Keeps listening until the speaker goes quiet, then types the text (like macOS Dictation).
    func stopWhenQuiet() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.checkSilence() }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func checkSilence() {
        guard isListening else { return }
        let now = Date()
        if mic.level > 0.5 { lastActivity = now }   // still talking, even if recognition lags
        if transcript.isEmpty {
            if now.timeIntervalSince(startedAt) > 8 { end(cancel: true) }   // nothing said at all
        } else if now.timeIntervalSince(lastActivity) > 2 {
            end()
        }
    }

    /// Stops listening; types the text unless `cancel` is set.
    func end(cancel: Bool = false) {
        guard isListening else { return }
        silenceTimer?.invalidate()
        silenceTimer = nil
        isListening = false
        onStateChange?(false)
        mic.stop()
        request?.endAudio()
        request = nil

        if cancel {
            task?.cancel()
            task = nil
            return
        }
        // Don't wait long for the final pass; the live transcript is usually already complete
        waitForFinal(deadline: Date().addingTimeInterval(0.6))
    }

    private func waitForFinal(deadline: Date) {
        if finished || Date() >= deadline {
            task = nil
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if AXIsProcessTrusted() {
                Self.type(text)
            } else {
                // Can't paste without Accessibility; leave the text on the clipboard instead
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                debugLog("not trusted: text left on clipboard")
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.waitForFinal(deadline: deadline) }
    }

    /// Pastes text at the cursor via the clipboard, then restores the clipboard.
    private static func type(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
    }
}

// MARK: - Shortcut

/// The key that starts dictation: either a lone modifier (e.g. Right ⌘) or a key combo (e.g. ⌃⌥Space).
struct Trigger: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt        // ⌘⌃⌥⇧ for key combos; unused for lone modifiers
    var modifierOnly: Bool
    var name: String

    static let rightCommand = Trigger(keyCode: 54, modifiers: 0, modifierOnly: true, name: "Right ⌘")
    static let presets: [Trigger] = [
        .rightCommand,
        Trigger(keyCode: 61, modifiers: 0, modifierOnly: true, name: "Right ⌥"),
        Trigger(keyCode: 62, modifiers: 0, modifierOnly: true, name: "Right ⌃"),
        Trigger(keyCode: 60, modifiers: 0, modifierOnly: true, name: "Right ⇧"),
        Trigger(keyCode: 63, modifiers: 0, modifierOnly: true, name: "Fn"),
    ]

    private static let modifierKeys: [UInt16: (name: String, mask: UInt)] = [
        54: ("Right ⌘", 0x10), 55: ("Left ⌘", 0x08),
        60: ("Right ⇧", 0x04), 56: ("Left ⇧", 0x02),
        61: ("Right ⌥", 0x40), 58: ("Left ⌥", 0x20),
        62: ("Right ⌃", 0x2000), 59: ("Left ⌃", 0x01),
        63: ("Fn", NSEvent.ModifierFlags.function.rawValue),
    ]

    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                            105, 107, 113, 106, 64, 79, 80, 90]

    /// Device-specific flag bit that is set while this exact modifier key is down.
    static func deviceMask(for keyCode: UInt16) -> UInt? { modifierKeys[keyCode]?.mask }
    static func modifierName(for keyCode: UInt16) -> String? { modifierKeys[keyCode]?.name }

    static func symbols(_ f: NSEvent.ModifierFlags) -> String {
        (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "")
            + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
    }

    static func keyName(_ event: NSEvent) -> String {
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        return special[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    var carbonModifiers: UInt32 {
        let f = NSEvent.ModifierFlags(rawValue: modifiers)
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }
}

/// Watches the chosen shortcut. A quick tap and a long hold are reported separately.
final class PushToTalk {
    private static let escape: UInt16 = 53
    private static let holdThreshold: TimeInterval = 0.4
    private var monitors: [Any] = []
    private var trigger: Trigger?
    private var downAt: Date?
    private var usedAsShortcut = false
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var onPress: (() -> Void)?
    /// `held` is true when the key was held long enough to mean push-to-talk.
    var onRelease: ((_ held: Bool) -> Void)?
    var onShortcut: (() -> Void)?   // a lone-modifier trigger used with another key is a normal shortcut
    var onEscape: (() -> Void)?

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] in self?.flags($0) }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] in self?.otherKey($0) }) {
            monitors.append(m)
        }
        installHotKeyHandler()
    }

    /// Switches to a new trigger; nil pauses the shortcut (used while recording a new one).
    func use(_ trigger: Trigger?) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        downAt = nil
        self.trigger = trigger
        guard let trigger, !trigger.modifierOnly else { return }

        // Key combos go through a system hot key so the keystroke doesn't also reach the front app
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5350_4B59), id: 1)   // "SPKY"
        let status = RegisterEventHotKey(UInt32(trigger.keyCode), trigger.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotKeyRef = ref } else { debugLog("could not register \(trigger.name): \(status)") }
    }

    private func installHotKeyHandler() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let me = Unmanaged<PushToTalk>.fromOpaque(userData).takeUnretainedValue()
            GetEventKind(event) == UInt32(kEventHotKeyPressed) ? me.keyDown() : me.keyUp()
            return noErr
        }, 2, &types, me, &handlerRef)
    }

    private func keyDown() {
        guard downAt == nil else { return }
        downAt = Date()
        usedAsShortcut = false
        onPress?()
    }

    private func keyUp() {
        guard let start = downAt else { return }
        downAt = nil
        guard !usedAsShortcut else { return }
        onRelease?(Date().timeIntervalSince(start) >= Self.holdThreshold)
    }

    private func flags(_ event: NSEvent) {
        guard let trigger, trigger.modifierOnly, event.keyCode == trigger.keyCode,
              let mask = Trigger.deviceMask(for: trigger.keyCode) else { return }
        event.modifierFlags.rawValue & mask != 0 ? keyDown() : keyUp()
    }

    private func otherKey(_ event: NSEvent) {
        if downAt != nil, trigger?.modifierOnly == true {
            guard !usedAsShortcut else { return }
            usedAsShortcut = true
            onShortcut?()
        } else if event.keyCode == Self.escape {
            onEscape?()
        }
    }
}

/// A small window that captures the next shortcut the user presses.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var monitor: Any?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var pendingModifier: UInt16?
    private var completion: ((Trigger?) -> Void)?

    func record(completion: @escaping (Trigger?) -> Void) {
        guard window == nil else { return }
        self.completion = completion
        pendingModifier = nil

        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 130),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Speakeys Shortcut"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self

        title.stringValue = "Press the new shortcut"
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        detail.stringValue = "A single key like Right ⌥, a combo like ⌃⌥Space, or an F-key.\nPress Esc to cancel."
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 22, right: 20)
        window.contentView = stack
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            guard let mask = Trigger.deviceMask(for: event.keyCode),
                  let name = Trigger.modifierName(for: event.keyCode) else { return }
            if event.modifierFlags.rawValue & mask != 0 {
                pendingModifier = event.keyCode
                title.stringValue = name
            } else if pendingModifier == event.keyCode {
                // Pressed and released on its own: a lone-modifier trigger
                finish(Trigger(keyCode: event.keyCode, modifiers: 0, modifierOnly: true, name: name))
            }
            return
        }

        pendingModifier = nil
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, mods.isEmpty { finish(nil); return }   // Esc

        // Plain letters would hijack normal typing, so require a modifier unless it's an F-key
        guard Trigger.functionKeys.contains(event.keyCode)
                || !mods.intersection([.command, .control, .option]).isEmpty else {
            title.stringValue = "Add ⌘, ⌃ or ⌥, or use an F-key"
            return
        }
        let name = Trigger.symbols(mods) + Trigger.keyName(event)
        finish(Trigger(keyCode: event.keyCode, modifiers: mods.rawValue, modifierOnly: false, name: name))
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

    func windowWillClose(_ notification: Notification) { finish(nil) }
}

// MARK: - Geometry

struct Vec3 {
    var x, y, z: Double
    var normalized: Vec3 {
        let l = (x * x + y * y + z * z).squareRoot()
        return Vec3(x: x / l, y: y / l, z: z / l)
    }
}

func makeIcosphere(subdivisions: Int) -> (verts: [Vec3], edges: [(Int, Int)]) {
    let t = (1 + 5.0.squareRoot()) / 2
    var verts = [
        Vec3(x: -1, y: t, z: 0), Vec3(x: 1, y: t, z: 0), Vec3(x: -1, y: -t, z: 0), Vec3(x: 1, y: -t, z: 0),
        Vec3(x: 0, y: -1, z: t), Vec3(x: 0, y: 1, z: t), Vec3(x: 0, y: -1, z: -t), Vec3(x: 0, y: 1, z: -t),
        Vec3(x: t, y: 0, z: -1), Vec3(x: t, y: 0, z: 1), Vec3(x: -t, y: 0, z: -1), Vec3(x: -t, y: 0, z: 1),
    ].map(\.normalized)
    var faces: [(Int, Int, Int)] = [
        (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
        (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
        (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
        (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
    ]

    for _ in 0..<subdivisions {
        var cache: [Int: Int] = [:]
        func midpoint(_ a: Int, _ b: Int) -> Int {
            let key = min(a, b) * 1_000_000 + max(a, b)
            if let i = cache[key] { return i }
            let p = verts[a], q = verts[b]
            verts.append(Vec3(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2, z: (p.z + q.z) / 2).normalized)
            cache[key] = verts.count - 1
            return verts.count - 1
        }
        faces = faces.flatMap { f -> [(Int, Int, Int)] in
            let a = midpoint(f.0, f.1), b = midpoint(f.1, f.2), c = midpoint(f.2, f.0)
            return [(f.0, a, c), (f.1, b, a), (f.2, c, b), (a, b, c)]
        }
    }

    var seen = Set<Int>()
    var edges: [(Int, Int)] = []
    for f in faces {
        for (a, b) in [(f.0, f.1), (f.1, f.2), (f.2, f.0)] {
            if seen.insert(min(a, b) * 1_000_000 + max(a, b)).inserted { edges.append((a, b)) }
        }
    }
    return (verts, edges)
}

// MARK: - Orb view

final class OrbView: NSView {
    private let mic: Microphone
    private let mesh = makeIcosphere(subdivisions: 3)
    private var time = 0.0      // wall clock, drives breathing
    private var spin = 0.0      // rotation angle; turns faster while dictating
    private var phase = 0.0     // surface wobble; speeds up with the voice
    private var smooth = 0.0    // smoothed mic level
    private var focus = 0.0     // 0 resting ... 1 dictating, eased
    private var timer: Timer?

    var isDictating = false

    private let pink = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.78, alpha: 1)
    private let hot = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.93, alpha: 1)

    init(frame: NSRect, mic: Microphone) {
        self.mic = mic
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    func startAnimating() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let dt = 1.0 / 60.0
        let target = Double(mic.level)
        // Fast attack, slow release so the orb swells quickly and settles gently
        smooth += (target - smooth) * (target > smooth ? 0.5 : 0.12)
        focus += ((isDictating ? 1 : 0) - focus) * 0.2
        time += dt
        // Calm at rest, lively while speaking
        spin += dt * (0.10 + 0.9 * focus)
        phase += dt * (0.22 + 2.2 * focus + 5.5 * smooth)
        needsDisplay = true
    }

    private func wobble(_ v: Vec3) -> Double {
        let p = phase
        let a = sin(3.1 * v.x + 1.3 * p) * sin(2.7 * v.y + 1.1 * p + 1.7) * sin(2.3 * v.z + 0.9 * p + 0.6)
        let b = sin(4.3 * v.x + 3.7 * v.y - 1.5 * p) * 0.5
        let c = sin(5.9 * v.z - 2.3 * v.x + 2.1 * p) * 0.3
        return a + b + c
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let size = Double(min(bounds.width, bounds.height))
        let breath = sin(time * 0.9) * 0.012 * (1 - focus)   // slow breathing while resting
        let radius = (0.21 + breath + 0.04 * focus + 0.08 * smooth) * size
        let cx = Double(bounds.midX), cy = Double(bounds.midY)
        let amp = 0.06 + 0.06 * focus + 0.38 * smooth

        let ay = spin
        let ax = 0.35 + sin(time * 0.15) * 0.15
        let (sy, cyr) = (sin(ay), cos(ay))
        let (sx, cxr) = (sin(ax), cos(ax))

        // Displace, rotate, and project every vertex
        var points = [CGPoint](repeating: .zero, count: mesh.verts.count)
        var depth = [Double](repeating: 0, count: mesh.verts.count)
        for (i, v) in mesh.verts.enumerated() {
            let r = 1 + amp * wobble(v)
            var x = v.x * r, y = v.y * r, z = v.z * r
            (x, z) = (x * cyr + z * sy, -x * sy + z * cyr)
            (y, z) = (y * cxr - z * sx, y * sx + z * cxr)
            let persp = 3.2 / (3.2 + z)
            points[i] = CGPoint(x: cx + x * radius * persp, y: cy + y * radius * persp)
            depth[i] = z
        }

        // Group edges by depth so the back of the orb is fainter than the front
        let buckets = 5
        let paths = (0..<buckets).map { _ in CGMutablePath() }
        for (a, b) in mesh.edges {
            let z = (depth[a] + depth[b]) / 2
            let k = min(max(Int((z + 1.5) / 3.0 * Double(buckets)), 0), buckets - 1)
            paths[k].move(to: points[a])
            paths[k].addLine(to: points[b])
        }

        // Resting: soft and dim. Dictating: brighter, whiter, glowing.
        let color = pink.blended(withFraction: CGFloat(focus * 0.6), of: hot) ?? pink
        let brightness = 0.55 + 0.45 * focus
        ctx.setLineWidth(CGFloat(0.8 + 0.6 * focus))
        ctx.setLineCap(.round)
        ctx.setShadow(offset: .zero, blur: CGFloat(1.5 + 5 * focus + 8 * smooth),
                      color: color.withAlphaComponent(0.35 + 0.5 * focus).cgColor)
        for k in (0..<buckets).reversed() {   // draw back first, front last
            let alpha = (0.95 - Double(k) / Double(buckets - 1) * 0.75) * brightness
            ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
            ctx.addPath(paths[k])
            ctx.strokePath()
        }
    }
}

// MARK: - Live caption bubble

final class CaptionPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let maxWidth: CGFloat = 420
    private let pad: CGFloat = 14

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingHead   // keep the newest words visible
        label.cell?.truncatesLastVisibleLine = true
        background.addSubview(label)
    }

    /// Shows `text` beside the orb frame, on the side that faces the screen center.
    func show(_ text: String, beside orbFrame: NSRect) {
        let placeholder = text.isEmpty
        label.stringValue = placeholder ? "Listening…" : text
        label.textColor = placeholder ? .secondaryLabelColor : .labelColor

        label.preferredMaxLayoutWidth = maxWidth - 2 * pad
        let fit = label.sizeThatFits(NSSize(width: maxWidth - 2 * pad, height: .greatestFiniteMagnitude))
        let width = min(maxWidth, max(120, ceil(fit.width) + 2 * pad))
        let height = min(ceil(fit.height), 3 * 18) + 2 * (pad - 4)
        label.frame = NSRect(x: pad, y: pad - 4, width: width - 2 * pad, height: height - 2 * (pad - 4))

        let screen = NSScreen.main?.visibleFrame ?? orbFrame
        let onRight = orbFrame.midX > screen.midX
        let x = onRight ? orbFrame.minX - width + 8 : orbFrame.maxX - 8
        let y = orbFrame.midY - height / 2
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }
}

// MARK: - App

enum Corner: String, CaseIterable {
    case bottomRight = "Bottom Right", topRight = "Top Right", bottomLeft = "Bottom Left", topLeft = "Top Left"
}

enum OrbSize: String, CaseIterable {
    case small = "Small", medium = "Medium", large = "Large"
    var side: CGFloat {
        switch self {
        case .small: return 130
        case .medium: return 170
        case .large: return 240
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let mic = Microphone()
    private lazy var dictation = Dictation(mic: mic, language: language)
    private let hotkey = PushToTalk()
    private let recorder = ShortcutRecorder()
    private var tappedToStop = false
    private var panel: NSPanel!
    private var orb: OrbView!
    private let caption = CaptionPanel()
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var hintItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var soundsItem: NSMenuItem!
    private var shortcutMenu = NSMenu()
    private var shortcutOptions: [Trigger] = []
    private var languageMenu = NSMenu()
    private var cornerMenu = NSMenu()
    private var sizeMenu = NSMenu()

    private var language: String {
        get { defaults.string(forKey: "language") ?? Self.defaultLanguage }
        set { defaults.set(newValue, forKey: "language") }
    }
    /// The system language if Speakeys offers it, otherwise US English.
    private static var defaultLanguage: String {
        let preferred = Locale.preferredLanguages.first ?? "en-US"
        if let exact = allLanguages.first(where: { $0.id == preferred }) { return exact.id }
        let base = preferred.split(separator: "-").first.map(String.init) ?? "en"
        return allLanguages.first(where: { $0.id.hasPrefix(base + "-") })?.id ?? "en-US"
    }

    private var trigger: Trigger {
        get {
            guard let data = defaults.data(forKey: "trigger"),
                  let t = try? JSONDecoder().decode(Trigger.self, from: data) else { return .rightCommand }
            return t
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "trigger") }
    }
    private var playsSounds: Bool {
        get { defaults.bool(forKey: "sounds") }
        set { defaults.set(newValue, forKey: "sounds") }
    }

    private var corner: Corner {
        get { Corner(rawValue: defaults.string(forKey: "corner") ?? "") ?? .bottomRight }
        set { defaults.set(newValue.rawValue, forKey: "corner") }
    }
    private var orbSize: OrbSize {
        get { OrbSize(rawValue: defaults.string(forKey: "size") ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "size") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: orbSize.side, height: orbSize.side),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        orb = OrbView(frame: panel.contentRect(forFrameRect: panel.frame), mic: mic)
        orb.autoresizingMask = [.width, .height]
        panel.contentView = orb

        dictation.onStateChange = { [weak self] on in
            guard let self else { return }
            self.orb.isDictating = on
            on ? self.caption.show("", beside: self.panel.frame) : self.caption.hide()
            let symbol = on ? "circle.hexagongrid.fill" : "circle.hexagongrid"
            self.statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Speakeys")
            if self.playsSounds { NSSound(named: on ? "Tink" : "Pop")?.play() }
        }
        dictation.onPartial = { [weak self] text in
            guard let self, self.dictation.isListening else { return }
            self.caption.show(text, beside: self.panel.frame)
        }
        dictation.requestPermissions()
        // Tap: start, then stop on silence or on the next tap. Hold: push-to-talk.
        hotkey.onPress = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if self.dictation.isListening {
                self.tappedToStop = true
                self.dictation.end()
            } else {
                self.tappedToStop = false
                self.dictation.begin()
            }
        }
        hotkey.onRelease = { [weak self] held in
            guard let self else { return }
            if self.tappedToStop { self.tappedToStop = false; return }
            guard self.dictation.isListening else { return }
            held ? self.dictation.end() : self.dictation.stopWhenQuiet()
        }
        hotkey.onShortcut = { [weak self] in
            guard let self, !self.tappedToStop else { return }
            self.dictation.end(cancel: true)
        }
        hotkey.onEscape = { [weak self] in self?.dictation.end(cancel: true) }
        hotkey.start()
        hotkey.use(trigger)

        setUpMenu()
        layoutPanel()
        show()
    }

    // MARK: Menu

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "Speakeys")

        let menu = NSMenu()
        menu.delegate = self
        hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        accessibilityItem = NSMenuItem(title: "⚠︎ Allow Accessibility to type text…",
                                       action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())

        menu.addItem(submenu("Shortcut", shortcutMenu))

        // Only offer languages this Mac can actually recognize
        let supported = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier.replacingOccurrences(of: "_", with: "-") })
        for lang in allLanguages where supported.contains(lang.id) {
            languageMenu.addItem(choice(lang.name, value: lang.id, action: #selector(pickLanguage(_:))))
        }
        menu.addItem(submenu("Language", languageMenu))

        for s in OrbSize.allCases {
            sizeMenu.addItem(choice(s.rawValue, value: s.rawValue, action: #selector(pickSize(_:))))
        }
        menu.addItem(submenu("Size", sizeMenu))

        for c in Corner.allCases {
            cornerMenu.addItem(choice(c.rawValue, value: c.rawValue, action: #selector(pickCorner(_:))))
        }
        menu.addItem(submenu("Position", cornerMenu))

        menu.addItem(.separator())
        soundsItem = NSMenuItem(title: "Play Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        soundsItem.target = self
        menu.addItem(soundsItem)
        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: "Hide Speakeys", action: #selector(toggle), keyEquivalent: "h")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let about = NSMenuItem(title: "About Speakeys", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit Speakeys", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        rebuildShortcutMenu()
        refreshChecks()
    }

    private func rebuildShortcutMenu() {
        shortcutMenu.removeAllItems()
        shortcutOptions = Trigger.presets
        if !shortcutOptions.contains(trigger) { shortcutOptions.append(trigger) }
        for (i, option) in shortcutOptions.enumerated() {
            let item = NSMenuItem(title: option.name, action: #selector(pickShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = option == trigger ? .on : .off
            shortcutMenu.addItem(item)
        }
        shortcutMenu.addItem(.separator())
        let record = NSMenuItem(title: "Record Shortcut…", action: #selector(recordShortcut), keyEquivalent: "")
        record.target = self
        shortcutMenu.addItem(record)
        hintItem.title = "Tap \(trigger.name) to dictate · hold to push-to-talk"
    }

    @objc private func pickShortcut(_ sender: NSMenuItem) {
        guard shortcutOptions.indices.contains(sender.tag) else { return }
        trigger = shortcutOptions[sender.tag]
        hotkey.use(trigger)
        rebuildShortcutMenu()
    }

    @objc private func recordShortcut() {
        dictation.end(cancel: true)
        hotkey.use(nil)   // so the current shortcut can be pressed in the recorder too
        recorder.record { [weak self] newTrigger in
            guard let self else { return }
            if let newTrigger { self.trigger = newTrigger }
            self.hotkey.use(self.trigger)
            self.rebuildShortcutMenu()
        }
    }

    @objc private func toggleSounds() {
        playsSounds.toggle()
        refreshChecks()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            debugLog("launch at login: \(error)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refreshChecks()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "A tiny dictation app with a floating wireframe orb.\nOpen source under the MIT License.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    private func choice(_ title: String, value: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        return item
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private func refreshChecks() {
        soundsItem.state = playsSounds ? .on : .off
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        accessibilityItem.isHidden = AXIsProcessTrusted()
        let marks: [(NSMenu, String)] = [(languageMenu, language), (sizeMenu, orbSize.rawValue), (cornerMenu, corner.rawValue)]
        for (menu, current) in marks {
            for item in menu.items {
                item.state = (item.representedObject as? String) == current ? .on : .off
            }
        }
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        language = id
        dictation.setLanguage(id)
        refreshChecks()
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = OrbSize(rawValue: raw) else { return }
        orbSize = s
        layoutPanel()
        refreshChecks()
    }

    @objc private func pickCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = Corner(rawValue: raw) else { return }
        corner = c
        layoutPanel()
        refreshChecks()
    }

    // MARK: Window

    private func layoutPanel() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let side = orbSize.side
        let m: CGFloat = 12
        let x = (corner == .bottomRight || corner == .topRight) ? screen.maxX - side - m : screen.minX + m
        let y = (corner == .topRight || corner == .topLeft) ? screen.maxY - side - m : screen.minY + m
        panel.setFrame(NSRect(x: x, y: y, width: side, height: side), display: true)
    }

    private func show() {
        panel.orderFrontRegardless()
        orb.startAnimating()
        toggleItem.title = "Hide Speakeys"
    }

    private func hide() {
        dictation.end(cancel: true)
        panel.orderOut(nil)
        orb.stopAnimating()
        toggleItem.title = "Show Speakeys"
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : show()
    }
}

extension AppDelegate: NSMenuDelegate {
    // Permissions and login items can change in System Settings while Speakeys runs
    func menuWillOpen(_ menu: NSMenu) { refreshChecks() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
