import Accelerate
import AVFoundation
import os
import Speech

/// Captures audio only while dictation runs. Publishes a 0…1 loudness level and
/// forwards every buffer to the active speech request.
final class Microphone {
    private struct Shared {
        var level: Float = 0
        var sink: SFSpeechAudioBufferRecognitionRequest?
    }

    /// Written on the audio thread, read on the main thread.
    private let shared = OSAllocatedUnfairLock(uncheckedState: Shared())
    private var engine: AVAudioEngine?

    var level: Float { shared.withLockUnchecked { $0.level } }

    static func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { Log.error("microphone permission denied") }
        }
    }

    /// Starts capturing into `request`. Returns false if no microphone could be started.
    func start(feeding request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        shared.withLockUnchecked { $0.sink = request }
        if engine != nil { return true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            Log.error("no audio input device")
            return false
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [shared] buffer, _ in
            let level = Self.loudness(of: buffer)
            let sink = shared.withLockUnchecked { state in
                state.level = level
                return state.sink
            }
            sink?.append(buffer)
        }

        do {
            try engine.start()
            self.engine = engine
            return true
        } catch {
            Log.error("could not start microphone: \(error)")
            input.removeTap(onBus: 0)
            shared.withLockUnchecked { $0 = Shared() }
            return false
        }
    }

    /// Releases the microphone so the orange privacy indicator goes away.
    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        shared.withLockUnchecked { $0 = Shared() }
    }

    /// RMS loudness mapped from roughly -55 dB (quiet room) … -15 dB (speech) to 0…1.
    private static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 55) / 40, 0), 1)
    }
}
