@preconcurrency import AVFoundation
import CoreAudio
import Foundation

enum AudioCaptureError: Error {
    case permissionDenied
    case engineStartFailed(Error)
    case converterCreationFailed
    case deviceSelectionFailed(OSStatus)
}

final class AudioCaptureManager: @unchecked Sendable {
    static let targetFormat: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("RTI: Failed to create 16 kHz mono Int16 PCM format — AVAudioFormat initializer returned nil")
        }
        return fmt
    }()

    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

    // Last time the input tap delivered a buffer. The tap fires continuously
    // while the engine runs — even during silence the buffers carry silent
    // samples — so a gap means the device/tap actually died (disconnect, mute,
    // revoked permission), not just a quiet room. Read by the pipeline's
    // watchdog. Touched on the audio thread + main, so it's lock-guarded.
    private let bufferLock = NSLock()
    private var lastBufferAt: TimeInterval = 0
    /// True mute: input buffers are dropped BEFORE conversion/transmission, so
    /// nothing from the mic leaves the machine. The tap keeps running (health
    /// watchdog still sees buffers) and unmute is instant. Audio-thread read,
    /// main-thread write — lock-guarded.
    private var muted = false

    var micMuted: Bool {
        get { bufferLock.lock(); defer { bufferLock.unlock() }; return muted }
        set { bufferLock.lock(); muted = newValue; bufferLock.unlock() }
    }

    /// Seconds since the last delivered input buffer, or nil if none has
    /// arrived yet this session (so the watchdog ignores the startup window).
    func secondsSinceLastBuffer() -> TimeInterval? {
        bufferLock.lock()
        let t = lastBufferAt
        bufferLock.unlock()
        guard t > 0 else { return nil }
        return Date().timeIntervalSinceReferenceDate - t
    }

    private func markBufferReceived() {
        bufferLock.lock()
        lastBufferAt = Date().timeIntervalSinceReferenceDate
        bufferLock.unlock()
    }

    func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func start() throws {
        guard !isRunning else { return }
        bufferLock.lock(); lastBufferAt = 0; bufferLock.unlock()

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            throw AudioCaptureError.permissionDenied
        }

        // If the user picked a non-default input device (e.g. BlackHole or an
        // aggregate that combines mic + system audio), point the AVAudioEngine
        // input AUHAL at that device before installing the tap. The AUHAL only
        // surfaces after `engine.inputNode` is touched, so do this in order.
        let input = engine.inputNode

        // Acoustic echo cancellation. Apple's Voice-Processing I/O cancels
        // the speaker output (the other party's voice) from the mic input,
        // so a meeting on speakers doesn't double-transcribe. Best-effort:
        // some devices (e.g. aggregates / BlackHole) reject VPIO, in which
        // case we fall back to the raw input. Must be set before the format
        // is read and the tap installed — VPIO changes the node format.
        // Default OFF: Apple's Voice-Processing I/O, enabled on an input node
        // that we only *tap* (no running output graph), delivers SILENT buffers
        // on some Macs — which kills transcription entirely. Verified 2026-06-09.
        // Leave AEC opt-in until VPIO is wired so it doesn't zero the mic; the
        // system-audio tap already captures the other party separately.
        let echoSetting = UserDefaults.standard.object(forKey: AudioSettingsDefaults.echoCancellationKey) as? Bool ?? false
        // Skip Voice-Processing I/O when listening on Bluetooth: there's no
        // speaker bleed to cancel on headphones, and VPIO can itself force the
        // headset into low-quality HFP mode (the volume-drop culprit).
        let onBluetoothOutput = AudioInputDeviceStore.defaultOutputIsBluetooth()
        let echoCancellation = echoSetting && !onBluetoothOutput
        do {
            try input.setVoiceProcessingEnabled(echoCancellation)
            RTILog.log("voice processing (echo cancellation) = \(echoCancellation)\(onBluetoothOutput && echoSetting ? " [forced off: Bluetooth output]" : "")", category: "audio")
        } catch {
            RTILog.log("voice processing unavailable on this device — using raw input: \(error)", category: "audio")
        }

        if let preferred = AudioInputDeviceStore.resolvePreferredDeviceID(),
           let unit = input.audioUnit {
            var deviceID = preferred
            let setStatus = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout.size(ofValue: deviceID))
            )
            if setStatus != noErr {
                RTILog.log("failed to bind input device (status=\(setStatus)) — using system default", category: "audio")
            } else {
                RTILog.log("bound to input device id=\(deviceID)", category: "audio")
            }
        } else {
            RTILog.log("using system default input device", category: "audio")
        }
        let nativeFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: nativeFormat, to: Self.targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error)
        }
    }

    func stop() {
        guard isRunning else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        // Voice-Processing I/O (acoustic echo cancellation) keeps the
        // microphone claimed even after `engine.stop()` — the orange mic
        // indicator stays lit and the input device stays held, which blocks
        // other apps (e.g. Zoom) from using the mic between sessions. The
        // engine is a long-lived instance reused across sessions, so it never
        // deallocates to release the device on its own. Explicitly disable
        // voice processing to fully hand the mic back to the system.
        if input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(false)
            } catch {
                RTILog.log("failed to disable voice processing on stop: \(error)", category: "audio")
            }
        }
        converter = nil
        isRunning = false
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        markBufferReceived()
        guard !micMuted else { return }
        guard let converter = converter else { return }

        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        final class MutableBool: @unchecked Sendable { var value: Bool = false }
        let consumed = MutableBool()
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        guard status != .error, output.frameLength > 0 else {
            if let error = error {
                RTILog.log("converter error: \(error)", category: "audio")
            }
            return
        }

        onPCMBuffer?(output)
    }
}
