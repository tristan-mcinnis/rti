@preconcurrency import AVFoundation
import Foundation
import ScreenCaptureKit

enum SystemAudioError: Error {
    case noDisplay
    case permissionDenied
    case alreadyRunning
}

final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    static let targetFormat: AVAudioFormat = AudioCaptureManager.targetFormat

    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private var isRunning = false
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func start() async throws {
        guard !isRunning else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw SystemAudioError.permissionDenied
        }

        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.width = 1
        config.height = 1

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .main)
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
        RTILog.log("started — capturing system audio", category: "audio")
    }

    func stop() {
        guard isRunning, let stream = stream else { return }
        isRunning = false
        do {
            try stream.removeStreamOutput(self, type: .audio)
        } catch {
            NSLog("[RTI] system audio: removeStreamOutput error: \(error)")
        }
        stream.stopCapture { [weak self] error in
            if let error {
                NSLog("[RTI] system audio: stopCapture error: \(error)")
            }
            self?.stopContinuation?.resume()
            self?.stopContinuation = nil
        }
        self.stream = nil
        converter = nil
        sourceFormat = nil
        RTILog.log("stopped", category: "audio")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        processSampleBuffer(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard isRunning else { return }
        isRunning = false
        self.stream = nil
        converter = nil
        sourceFormat = nil
        let msg = error.localizedDescription
        NSLog("[RTI] system audio: stream stopped with error: \(msg)")
        RTILog.log("stream error — \(msg)", category: "audio")
        onError?(msg)
    }

    // MARK: - Audio Processing

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return
        }

        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return }

        let srcSampleRate = asbd.mSampleRate
        let srcChannels = Int(asbd.mChannelsPerFrame)

        // Lazy-create or recreate the source format + converter when the format changes
        if converter == nil || sourceFormat?.sampleRate != srcSampleRate || Int(sourceFormat?.channelCount ?? 0) != srcChannels {
            guard let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: srcSampleRate,
                channels: AVAudioChannelCount(srcChannels),
                interleaved: false
            ) else { return }
            sourceFormat = fmt
            converter = AVAudioConverter(from: fmt, to: Self.targetFormat)
        }

        guard let converter = converter, let sourceFormat = sourceFormat else { return }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(numFrames)) else {
            return
        }
        inputBuffer.frameLength = AVAudioFrameCount(numFrames)

        let copyResult = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numFrames),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyResult == noErr else { return }

        let ratio = Self.targetFormat.sampleRate / srcSampleRate
        let outputFrames = AVAudioFrameCount(Double(numFrames) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: outputFrames) else {
            return
        }

        // Mutable box so the Sendable block can flip the flag. The converter
        // calls the block synchronously before returning, so no concurrent
        // access occurs despite the lack of synchronisation.
        final class MutableBool: @unchecked Sendable { var value: Bool = false }
        let consumed = MutableBool()
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, outputBuffer.frameLength > 0 else {
            if let error { NSLog("[RTI] system audio: converter error: \(error)") }
            return
        }

        onPCMBuffer?(outputBuffer)
    }
}
