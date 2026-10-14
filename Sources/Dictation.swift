import Foundation
import Speech

/// Runs one speech-to-text session at a time: start, stream partial text, then hand back the final text.
final class Dictation {
    enum Ending { case insert, cancel }

    var onListeningChange: ((Bool) -> Void)?
    var onPartial: ((String) -> Void)?
    /// Called with the final, non-empty text once a session ends with `.insert`.
    var onFinish: ((String) -> Void)?

    private(set) var isListening = false

    private enum Timing {
        static let silenceToFinish: TimeInterval = 2
        static let nothingSaidTimeout: TimeInterval = 8
        static let finalResultGrace: TimeInterval = 0.6
        static let silencePollInterval: TimeInterval = 0.2
        static let speakingLevel: Float = 0.5
    }

    /// State of one recognition. Results that arrive for an older session are ignored.
    private final class Session {
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var transcript = ""
        var isFinal = false
        let startedAt = Date()
        var lastActivity = Date()
    }

    private let mic: Microphone
    private var recognizer: SFSpeechRecognizer?
    private var session: Session?
    private var silenceTimer: Timer?
    private var pendingDelivery: DispatchWorkItem?

    init(mic: Microphone, language: String) {
        self.mic = mic
        setLanguage(language)
    }

    func setLanguage(_ id: String) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: id))
    }

    static func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized { Log.error("speech recognition not authorized (\(status.rawValue))") }
        }
    }

    // MARK: Session lifecycle

    func start() {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            Log.error("speech recognition unavailable for \(recognizer?.locale.identifier ?? "?")")
            return
        }
        // A previous session may still be waiting for its final result; finish it first
        deliver()

        let session = Session()
        session.request.shouldReportPartialResults = true
        session.request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { session.request.requiresOnDeviceRecognition = true }

        session.task = recognizer.recognitionTask(with: session.request) { [weak self, weak session] result, error in
            DispatchQueue.main.async {
                guard let self, let session else { return }
                self.handle(result: result, error: error, in: session)
            }
        }
        guard mic.start(feeding: session.request) else {
            session.task?.cancel()
            return
        }
        self.session = session
        setListening(true)
    }

    /// Keeps listening until the speaker goes quiet, like macOS Dictation.
    func finishWhenQuiet() {
        guard isListening else { return }
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: Timing.silencePollInterval, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    func finish(_ ending: Ending) {
        guard isListening, let session else { return }
        setListening(false)
        mic.stop()
        session.request.endAudio()

        switch ending {
        case .cancel:
            session.task?.cancel()
            self.session = nil
        case .insert where session.isFinal:
            deliver()
        case .insert:
            // The final pass usually lands within a few hundred milliseconds; don't wait longer than that
            let work = DispatchWorkItem { [weak self] in self?.deliver() }
            pendingDelivery = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.finalResultGrace, execute: work)
        }
    }

    // MARK: Private

    private func setListening(_ listening: Bool) {
        isListening = listening
        if !listening {
            silenceTimer?.invalidate()
            silenceTimer = nil
        }
        onListeningChange?(listening)
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, in session: Session) {
        guard session === self.session else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if text != session.transcript { session.lastActivity = Date() }
            session.transcript = text
            if isListening { onPartial?(text) }
        }
        if error != nil || result?.isFinal == true {
            session.isFinal = true
            if !isListening { deliver() }   // we were only waiting for this
        }
    }

    private func checkSilence() {
        guard isListening, let session else { return }
        let now = Date()
        // Recognition can lag behind the voice, so loudness also counts as activity
        if mic.level > Timing.speakingLevel { session.lastActivity = now }

        if session.transcript.isEmpty {
            if now.timeIntervalSince(session.startedAt) > Timing.nothingSaidTimeout { finish(.cancel) }
        } else if now.timeIntervalSince(session.lastActivity) > Timing.silenceToFinish {
            finish(.insert)
        }
    }

    /// Hands the session's text to `onFinish` and clears it.
    private func deliver() {
        pendingDelivery?.cancel()
        pendingDelivery = nil
        guard !isListening, let session else { return }
        self.session = nil
        session.task = nil
        let text = session.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onFinish?(text) }
    }
}
