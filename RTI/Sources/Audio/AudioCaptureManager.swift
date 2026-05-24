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

    func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func start() throws {
        guard !isRunning else { return }

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
        let echoCancellation = UserDefaults.standard.object(forKey: AudioSettingsDefaults.echoCancellationKey) as? Bool ?? true
        do {
            try input.setVoiceProcessingEnabled(echoCancellation)
            RTILog.log("voice processing (echo cancellation) = \(echoCancellation)", category: "audio")
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
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
