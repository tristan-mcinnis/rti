@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import RTICore

enum AudioCaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case engineStartFailed(Error)
    case converterCreationFailed
    /// CoreAudio did not answer the start probe (2026-11-15: a wedged audio
    /// service froze RTI's window at Start).
    case audioSystemNotResponding

    var description: String {
        switch self {
        case .permissionDenied: "microphone permission denied"
        case let .engineStartFailed(error): "the audio engine did not start (\(error))"
        case .converterCreationFailed: "the microphone format could not be converted"
        case .audioSystemNotResponding:
            "macOS audio is not responding. Quit and reopen RTI; if it still fails, run `sudo killall coreaudiod` in Terminal, then start again"
        }
    }
}

/// Asks CoreAudio one cheap question on a background thread and waits a
/// bounded time. AVAudioEngine's first touch of the input node blocks with
/// no timeout when the audio service is wedged, and on the main thread that
/// froze the whole window. The probe thread may stay stuck; RTI does not.
enum AudioServiceProbe {
    static func responds(within timeout: TimeInterval = 3) -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            if let device = AudioInputDeviceStore.defaultInputDeviceID() {
                var rate = Float64(0)
                var size = UInt32(MemoryLayout<Float64>.size)
                var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
                _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
                var streams = UInt32(0)
                var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                                mScope: kAudioDevicePropertyScopeInput,
                                                                mElement: kAudioObjectPropertyElementMain)
                _ = AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streams)
            }
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }
}

/// The capture lifecycle consumed by AudioPipeline. Tests deliver synthetic PCM
/// through the same callback as the engine tap, without opening a real device.
protocol MicrophoneCapturing: AnyObject, Sendable {
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onRestarted: (() -> Void)? { get set }
    var micMuted: Bool { get set }
    func start() throws
    func stop()
    func restart() throws
    func secondsSinceLastBuffer() -> TimeInterval?
    func secondsAllZero() -> TimeInterval?
}

final class AudioCaptureManager: MicrophoneCapturing, @unchecked Sendable {
    static let targetFormat: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AudioFormat.sampleRateHz),
            channels: 1,
            interleaved: true
        ) else {
            fatalError("RTI: Failed to create 16 kHz mono Int16 PCM format — AVAudioFormat initializer returned nil")
        }
        return fmt
    }()

    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    /// Configuration-change rebinds, merged and paced (main thread only).
    private var rebindPacer = MicRebindPacer()
    private var rebindWork: DispatchWorkItem?
    /// Fired (on main) after the engine was rebound following a configuration
    /// change or a restart request; the pipeline resets its watchdogs.
    var onRestarted: (() -> Void)?
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

    /// Start of the current run of exact-zero input (pre-mute), or 0 when the
    /// last buffer carried signal. A tap can keep delivering buffers that are
    /// all zeros (another app's voice-processing unit owning the built-in mic),
    /// which the liveness check alone cannot see.
    private var zeroSince: TimeInterval = 0

    /// Seconds the mic has delivered nothing but exact-zero samples, or nil
    /// when it is currently carrying signal / has not started.
    func secondsAllZero() -> TimeInterval? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard zeroSince > 0 else { return nil }
        return Date().timeIntervalSinceReferenceDate - zeroSince
    }

    private func recordZeroState(_ buffer: AVAudioPCMBuffer) {
        var silent = true
        if let data = buffer.int16ChannelData {
            let p = data[0]
            for i in 0..<Int(buffer.frameLength) where p[i] != 0 { silent = false; break }
        }
        bufferLock.lock()
        if !silent { zeroSince = 0 }
        else if zeroSince == 0 { zeroSince = Date().timeIntervalSinceReferenceDate }
        bufferLock.unlock()
    }

    /// Tear down and rebuild the engine on a fresh AVAudioEngine, rebinding to
    /// the current input device. Throws if the new engine cannot start.
    func restart() throws {
        stop()
        try start()
        onRestarted?()
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
        bufferLock.lock(); lastBufferAt = 0; zeroSince = 0; bufferLock.unlock()

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            throw AudioCaptureError.permissionDenied
        }

        // A fresh engine per start: the input AUHAL of a reused engine keeps
        // the device it first saw. The -10868 start failure of 2026-11-14
        // (Bose QC45 in call mode) was the client rate, fixed in
        // `matchInputClientRate`; no retry here, and nothing on this path
        // sleeps, because `restart()` runs on the main actor (2026-11-15
        // concurrency review). A failure throws to the caller, whose outage
        // backoff retries.
        guard AudioServiceProbe.responds() else {
            RTILog.log("CoreAudio did not answer the start probe within 3 s — start refused", category: .audio)
            throw AudioCaptureError.audioSystemNotResponding
        }
        engine = AVAudioEngine()
        try startEngine()
    }

    private func startEngine() throws {

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
            RTILog.log("voice processing (echo cancellation) = \(echoCancellation)\(onBluetoothOutput && echoSetting ? " [forced off: Bluetooth output]" : "")", category: .audio)
        } catch {
            RTILog.log("voice processing unavailable on this device — using raw input: \(error)", category: .audio)
        }

        if let preferred = AudioInputDeviceStore.resolvePreferredDeviceID(),
           AudioInputDeviceStore.isBluetooth(preferred) {
            // A Bluetooth mic can never work here: BluetoothMicGuard keeps the
            // headset in A2DP (its mic OFF) to protect audio quality, so an
            // AUHAL bound to it runs but delivers zero buffers — the mic leg
            // records nothing and its STT stream starves (whole-day incident,
            // 2026-08-31: preferred input was AirPods; the user's side of a
            // meeting was silently lost). Fall through to the system default,
            // which the guard has already steered to the built-in mic.
            RTILog.log("preferred input is a Bluetooth mic — ignoring it (A2DP guard keeps its mic off); using system default input", category: .audio)
        } else if let preferred = AudioInputDeviceStore.resolvePreferredDeviceID(),
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
                RTILog.log("failed to bind input device (status=\(setStatus)) — using system default", category: .audio)
            } else {
                RTILog.log("bound to input device id=\(deviceID)", category: .audio)
            }
        } else if let current = AudioInputDeviceStore.defaultInputDeviceID(),
                  let unit = input.audioUnit, Self.boundDevice(unit) != current {
            // Bind the current default explicitly when the AUHAL is not on it
            // yet (a default switch made a moment ago). Only when it differs:
            // a needless set could post a configuration change, and the
            // change observer restarts the engine.
            var deviceID = current
            let setStatus = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout.size(ofValue: deviceID))
            )
            RTILog.log("using system default input device id=\(current)\(setStatus == noErr ? "" : " (bind status=\(setStatus))")", category: .audio)
        } else {
            RTILog.log("using system default input device", category: .audio)
        }
        if !input.isVoiceProcessingEnabled {
            Self.matchInputClientRate(input)
        }
        let nativeFormat = input.outputFormat(forBus: 0)

        // Each engine run owns its converter inside its own tap block, so the
        // audio thread never reads state that `stop()`/`restart()` replace on
        // main (AUD-7: a strong-reference race during a device switch).
        guard let converter = MicTapConverter(inputFormat: nativeFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        Self.installInputTap(on: input) { [weak self] buffer in
            self?.handleInputBuffer(buffer, converter: converter)
        }

        do {
            try engine.start()
            isRunning = true
            observeConfigurationChanges()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error)
        }
    }

    /// A default-input switch (AirPods, Continuity mic) or another app
    /// reconfiguring the device stops the engine and silences the tap.
    private func observeConfigurationChanges() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, isRunning else { return }
            scheduleRebind()
        }
    }

    /// One rebind for a burst of configuration changes, paced: each fresh
    /// engine re-sets the mic's client rate, which can post another change,
    /// and on 2026-11-15 that fed a loop of rebinds every 150 ms (133 in a
    /// row at one start). Changes in the settle window after RTI's own
    /// restart are its echo and are dropped; repeated rebinds back off.
    private func scheduleRebind() {
        let now = Date().timeIntervalSinceReferenceDate
        guard let delay = rebindPacer.delay(now: now), rebindWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            rebindWork = nil
            guard isRunning else { return }
            rebindPacer.didRebind(at: Date().timeIntervalSinceReferenceDate)
            RTILog.log("audio engine configuration changed — rebinding mic", category: .audio)
            do {
                try restart()
            } catch {
                RTILog.log("mic rebind after configuration change failed: \(error)", category: .audio)
            }
        }
        rebindWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stop() {
        rebindWork?.cancel()
        rebindWork = nil
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
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
                RTILog.log("failed to disable voice processing on stop: \(error)", category: .audio)
            }
        }
        isRunning = false
    }

    /// The input node's client side (output scope, bus 1) runs at the OUTPUT
    /// device's sample rate, and the input AUHAL cannot convert rates. With a
    /// 48 kHz mic and a 16 kHz output (a Bluetooth headset in call mode,
    /// because another app holds its mic) engine.start() fails with -10868
    /// in InitializeActiveNodesInInputChain (2026-11-14). Setting the client
    /// rate to the device's own rate lets the engine start; MicTapConverter
    /// resamples to 16 kHz anyway.
    /// The device an input AUHAL is bound to, or nil when unreadable.
    static func boundDevice(_ unit: AudioUnit) -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        return status == noErr ? device : nil
    }

    static func matchInputClientRate(_ input: AVAudioInputNode) {
        guard let unit = input.audioUnit else { return }
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var device = AudioStreamBasicDescription()
        var client = AudioStreamBasicDescription()
        var deviceSize = size, clientSize = size
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &device, &deviceSize) == noErr,
              AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, &clientSize) == noErr,
              device.mSampleRate > 0, client.mSampleRate != device.mSampleRate
        else { return }
        let from = client.mSampleRate
        client.mSampleRate = device.mSampleRate
        let status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, clientSize)
        RTILog.log("mic client rate \(Int(from)) Hz → \(Int(device.mSampleRate)) Hz to match the input device\(status == noErr ? "" : " (failed, status=\(status))")", category: .audio)
    }

    /// Install the mic tap with no format: the tap then takes the bus's own
    /// format when it is installed. Passing the format read a moment earlier
    /// raised an uncatchable AVAudioEngine exception ("format.sampleRate ==
    /// hwFormat.sampleRate") when the device changed in between, which is
    /// exactly when `restart()` runs (AUD-7). `MicTapConverter` follows any
    /// format the buffers arrive in.
    static func installInputTap(on node: AVAudioNode, block: @escaping (AVAudioPCMBuffer) -> Void) {
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            block(buffer)
        }
    }

    func handleInputBuffer(_ buffer: AVAudioPCMBuffer, converter: MicTapConverter) {
        markBufferReceived()
        // Mute = SILENCE, not absence: Soniox 408-times-out a stream that
        // stops receiving audio (observed 2026-06-11, killed the session).
        // So while muted we keep the exact buffer cadence but zero the
        // samples after conversion — the stream stays alive, hears nothing.
        let muted = micMuted
        guard let output = converter.convert(buffer) else { return }

        recordZeroState(output)
        if muted, let channelData = output.int16ChannelData {
            let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
            memset(channelData[0], 0, byteCount)
        }
        onPCMBuffer?(output)
    }
}

/// One engine run's converter to 16 kHz mono Int16. Owned by that run's tap
/// block and used only there; a tap delivers its blocks one at a time, so no
/// lock is needed. A buffer in a new format (the device changed under a
/// running tap) gets a new converter instead of a crash or a dropped leg.
final class MicTapConverter: @unchecked Sendable {
    private var converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: AudioCaptureManager.targetFormat) else { return nil }
        self.converter = converter
    }

    /// The converted buffer, or nil when this buffer cannot be converted
    /// (it is dropped and logged; the next buffer is tried again).
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format != converter.inputFormat {
            guard let rebuilt = AVAudioConverter(from: buffer.format, to: AudioCaptureManager.targetFormat) else {
                RTILog.log("mic format \(buffer.format) cannot be converted — buffer dropped", category: .audio)
                return nil
            }
            RTILog.log("mic format changed to \(buffer.format) — converter rebuilt", category: .audio)
            converter = rebuilt
        }
        let target = AudioCaptureManager.targetFormat
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputFrameCapacity) else { return nil }

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
            if let error {
                RTILog.log("converter error: \(error)", category: .audio)
            }
            return nil
        }
        return output
    }
}
