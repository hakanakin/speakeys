import AppKit

/// Wires the pieces together: shortcut → dictation → orb, caption and text insertion.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let mic = Microphone()
    private lazy var dictation = Dictation(mic: mic, language: settings.language)
    private let shortcut = ShortcutMonitor()
    private let recorder = ShortcutRecorder()
    private lazy var menuBar = MenuBarController(settings: settings)
    private let orbPanel = NSPanel.overlay()
    private let orb = OrbView()
    private let caption = CaptionPanel()
    private lazy var updates = UpdateChecker(settings: settings)

    /// Set when a press stops a running dictation, so its release doesn't start anything.
    private var pressStoppedDictation = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestPermissions()
        setUpOrb()
        setUpDictation()
        setUpShortcut()
        setUpMenuBar()
        observeSystem()
        updates.start()
        layoutOrb()
        showOrb()
    }

    // MARK: Setup

    private func requestPermissions() {
        Microphone.requestPermission()
        Dictation.requestPermission()
        // Needed to see the shortcut in other apps and to paste. Prompts only if not yet granted.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { Log.error("accessibility not granted yet") }
    }

    private func setUpOrb() {
        orb.autoresizingMask = [.width, .height]
        orb.voiceLevel = { [mic] in mic.level }
        applyAppearance()
        orbPanel.contentView = orb
    }

    private func setUpDictation() {
        dictation.onListeningChange = { [unowned self] listening in
            orb.isDictating = listening
            menuBar.setListening(listening)
            listening ? caption.show("", beside: orbPanel.frame) : caption.hide()
            if settings.playsSounds { NSSound(named: listening ? "Tink" : "Pop")?.play() }
        }
        dictation.onPartial = { [unowned self] text in
            caption.show(text, beside: orbPanel.frame)
        }
        dictation.onFinish = TextInserter.insert
    }

    /// Tap: start, then stop on silence or the next tap. Hold: push-to-talk.
    private func setUpShortcut() {
        shortcut.onPress = { [unowned self] in
            guard orbPanel.isVisible else { return }
            pressStoppedDictation = dictation.isListening
            pressStoppedDictation ? dictation.finish(.insert) : dictation.start()
        }
        shortcut.onRelease = { [unowned self] held in
            if pressStoppedDictation {
                pressStoppedDictation = false
            } else if held {
                dictation.finish(.insert)
            } else {
                dictation.finishWhenQuiet()
            }
        }
        shortcut.onUsedAsShortcut = { [unowned self] in
            if !pressStoppedDictation { dictation.finish(.cancel) }
        }
        shortcut.onEscape = { [unowned self] in dictation.finish(.cancel) }
        shortcut.start()
        shortcut.use(settings.trigger)
    }

    private func setUpMenuBar() {
        menuBar.isOrbVisible = { [unowned self] in orbPanel.isVisible }
        menuBar.onLanguageChange = { [unowned self] id in dictation.setLanguage(id) }
        menuBar.onLayoutChange = { [unowned self] in layoutOrb() }
        menuBar.onAppearanceChange = { [unowned self] in applyAppearance() }
        menuBar.updates = updates
        menuBar.onShortcutChange = { [unowned self] in shortcut.use(settings.trigger) }
        menuBar.onToggleOrb = { [unowned self] in orbPanel.isVisible ? hideOrb() : showOrb() }
        menuBar.onRecordShortcut = { [unowned self] in
            dictation.finish(.cancel)
            shortcut.use(nil)   // so the current shortcut can be recorded too
            recorder.record { [unowned self] trigger in
                if let trigger { settings.trigger = trigger }
                shortcut.use(settings.trigger)
            }
        }
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [unowned self] _ in layoutOrb()
        }
        // No drawing or listening while the displays sleep
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
            [unowned self] _ in
            dictation.finish(.cancel)
            orb.stopAnimating()
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
            [unowned self] _ in
            if orbPanel.isVisible { orb.startAnimating() }
        }
    }

    // MARK: Orb window

    private func applyAppearance() {
        orb.motion = settings.motion
        orb.tint = settings.orbColor
    }

    private func layoutOrb() {
        guard let screen = NSScreen.menuBarScreen?.visibleFrame else { return }
        let side = settings.size.side
        let margin: CGFloat = 12
        let corner = settings.corner
        let x = corner.isRight ? screen.maxX - side - margin : screen.minX + margin
        let y = corner.isTop ? screen.maxY - side - margin : screen.minY + margin
        orbPanel.setFrame(NSRect(x: x, y: y, width: side, height: side), display: true)
    }

    private func showOrb() {
        orbPanel.orderFrontRegardless()
        orb.startAnimating()
    }

    private func hideOrb() {
        dictation.finish(.cancel)
        orbPanel.orderOut(nil)
        orb.stopAnimating()
    }
}
