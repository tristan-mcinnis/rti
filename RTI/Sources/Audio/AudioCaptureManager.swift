import AVFoundation
import CoreAudio
import Foundation

enum AudioCaptureError: Error {
    case permissionDenied
    case engineStartFailed(Error)
    case converterCreationFailed
    case deviceSelectionFailed(OSStatus)
}

final class AudioCaptureManager {
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

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
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
                NSLog("[RTI] audio: failed to bind input device (status=\(setStatus)) — falling back to system default")
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

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        guard status != .error, output.frameLength > 0 else {
            if let error = error { NSLog("[RTI] audio converter error: \(error)") }
            return
        }

        onPCMBuffer?(output)
    }
}
