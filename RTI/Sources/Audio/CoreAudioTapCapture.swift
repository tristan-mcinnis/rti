@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os
import RTICore

/// Captures system audio via a CoreAudio process tap + aggregate device
/// (macOS 14.2+). Preferred over the ScreenCaptureKit backend because:
///
/// - It doesn't touch the screen-capture subsystem, so RTI's invisible
///   overlay and on-demand screenshot OCR keep working during a meeting.
/// - It needs only `NSAudioCaptureUsageDescription` ("record audio from
///   other applications"), not the heavier Screen Recording permission.
/// - It follows the default output device, so switching to AirPods/Bluetooth
///   mid-call keeps the other party's audio flowing (we rebuild the tap on
///   default-output-device changes).
///
/// Emits 16 kHz mono Int16 `AVAudioPCMBuffer`s on `onPCMBuffer`, matching the
/// SCK backend and what `AudioPipeline` feeds to Soniox.
@available(macOS 14.2, *)
final class CoreAudioTapCapture: SystemAudioCapturing, @unchecked Sendable {
    static let targetFormat: AVAudioFormat = AudioCaptureManager.targetFormat

    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var deviceIOProcID: AudioDeviceIOProcID?
    private let deviceIOQueue = DispatchQueue(label: "com.tristan.rti.system-audio-tap.io", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "com.tristan.rti.system-audio-tap")
    private var defaultOutputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var tappedProcessObjects: Set<AudioObjectID> = []

    private let recordingFlag = OSAllocatedUnfairLock(initialState: false)
    private var isRecording: Bool {
        get { recordingFlag.withLock { $0 } }
        set { recordingFlag.withLock { $0 = newValue } }
    }

    private static let targetSampleRate = Double(AudioFormat.sampleRateHz)

    // Tap source format + resampler. Touched only on `processingQueue`
    // (setup runs there or before the IOProc starts; teardown syncs onto it).
    private var sourceFormat = AudioStreamBasicDescription()
    private var activeCaptureGeneration: UInt64 = 0
    private var resampler: AVAudioConverter?
    private var resamplerInputFormat: AVAudioFormat?
    private var resamplerOutputFormat: AVAudioFormat?
    private var framesCaptured: AVAudioFramePosition = 0
    private var audibleFramesCaptured: AVAudioFramePosition = 0
    private var captureSampleRate: Double = CoreAudioTapCapture.targetFormat.sampleRate
    private var lastBufferAt: Date?
    private var lastAudibleBufferAt: Date?
    private var lastRMSLevel: Float = 0
    private var peakRMSLevel: Float = 0
    private static let audibleRMSThreshold: Float = 0.0005

    deinit {
        if isRecording || aggregateDeviceID != kAudioObjectUnknown || tapID != kAudioObjectUnknown {
            stop()
        }
    }

    func start() async throws {
        guard !isRecording else { return }
        isRecording = true
        processingQueue.sync { resetCaptureHealth() }
        do {
            try createTapAndAggregateDevice()
            try setupAndStartAudioDevice()
            installDefaultOutputDeviceListener()
            RTILog.log("CoreAudio tap capture started", category: .audio)
        } catch {
            cleanupFailedStart()
            throw error
        }
    }

    func stop() {
        guard isRecording || aggregateDeviceID != kAudioObjectUnknown || tapID != kAudioObjectUnknown else { return }
        isRecording = false
        removeDefaultOutputDeviceListener()
        processingQueue.sync {
            teardownTapAndAudioDevice()
            onPCMBuffer = nil
        }
        RTILog.log("CoreAudio tap capture stopped", category: .audio)
    }

    func captureHealth() -> SystemAudioCaptureHealth {
        processingQueue.sync {
            SystemAudioCaptureHealth(
                duration: captureSampleRate > 0 ? Double(framesCaptured) / captureSampleRate : 0,
                audibleDuration: captureSampleRate > 0 ? Double(audibleFramesCaptured) / captureSampleRate : 0,
                lastBufferAt: lastBufferAt,
                lastAudibleBufferAt: lastAudibleBufferAt,
                lastRMSLevel: lastRMSLevel,
                peakRMSLevel: peakRMSLevel
            )
        }
    }

    func recoverFromSilentAudio() async -> Bool {
        await withCheckedContinuation { continuation in
            processingQueue.async { [weak self] in
                guard let self, self.isRecording else {
                    continuation.resume(returning: false)
                    return
                }
                guard self.shouldRebuildForSilentAudio() else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    try self.rebuildTap(reason: "system audio silent")
                    continuation.resume(returning: true)
                } catch {
                    let msg = "System audio tap rebuild failed after silence: \(error.localizedDescription)"
                    RTILog.log(msg, category: .audio)
                    self.onError?(msg)
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Tap + Aggregate Device Setup

    private func createTapAndAggregateDevice() throws {
        // Per-app capture when the user picked one (and it's resolvable right
        // now); otherwise the global stereo mix excluding RTI itself. The
        // fallback rule is "capture everything rather than capture nothing" —
        // a missing app must never silently lose the other party's audio.
        let tapDesc: CATapDescription
        let selectedApp = AudioInputDeviceStore.captureAppBundleID
        if !selectedApp.isEmpty {
            let objects = AudioInputDeviceStore.processObjects(forAppBundleID: selectedApp)
            if objects.isEmpty {
                tappedProcessObjects = []
                RTILog.log("per-app capture: '\(selectedApp)' has no audio processes — falling back to all apps", category: .audio)
                tapDesc = Self.makeGlobalTapDescription(
                    excludingProcessID: Self.currentProcessAudioObjectID(),
                    name: "RTI System Audio Tap"
                )
            } else {
                tappedProcessObjects = Set(objects)
                tapDesc = CATapDescription(stereoMixdownOfProcesses: objects)
                tapDesc.name = "RTI App Audio Tap (\(selectedApp))"
                tapDesc.isPrivate = true
                tapDesc.muteBehavior = .unmuted
                RTILog.log("per-app capture: tapping \(objects.count) process(es) of \(selectedApp)", category: .audio)
            }
        } else {
            tappedProcessObjects = []
            tapDesc = Self.makeGlobalTapDescription(
                excludingProcessID: Self.currentProcessAudioObjectID(),
                name: "RTI System Audio Tap"
            )
        }

        // Registering the tap triggers the first-run permission dialog
        // ("RTI would like to record audio from other applications").
        var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(status)
        }

        // The tap list must contain UID strings, never CATapDescription
        // objects (passing objects crashes CoreAudio).
        let tapUIDString = tapDesc.uuid.uuidString
        let aggUID = "com.tristan.rti.system-audio-tap-\(UUID().uuidString)"
        let aggDesc = Self.makeAggregateDeviceDescription(tapUID: tapUIDString, aggregateUID: aggUID)

        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateDeviceID)
        guard status == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw TapError.aggregateDeviceCreationFailed(status)
        }

        sourceFormat = try Self.audioTapStreamFormat(for: tapID)
        RTILog.log("tap format: \(sourceFormat.mSampleRate)Hz \(sourceFormat.mChannelsPerFrame)ch", category: .audio)
    }

    static func makeGlobalTapDescription(excludingProcessID: AudioObjectID?, name: String) -> CATapDescription {
        let excludeList = excludingProcessID.map { [$0] } ?? []
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeList)
        tapDesc.name = name
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted
        return tapDesc
    }

    static func makeAggregateDeviceDescription(tapUID: String, aggregateUID: String) -> NSDictionary {
        [
            kAudioAggregateDeviceNameKey: "RTI System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
    }

    private func setupAndStartAudioDevice() throws {
        let format = sourceFormat
        configureResampler(for: format)
        activeCaptureGeneration &+= 1
        let generation = activeCaptureGeneration

        let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            guard let self, self.isRecording else { return }
            let buffers = Self.copyAudioBuffers(from: inputData)
            guard !buffers.isEmpty else { return }
            self.processingQueue.async { [weak self] in
                guard let self, self.isRecording else { return }
                guard self.activeCaptureGeneration == generation else { return }
                self.processAudioBuffers(buffers, format: format)
            }
        }

        var procID: AudioDeviceIOProcID?
        try osCheck(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, deviceIOQueue, block),
                    "create aggregate IOProc")
        guard let procID else { throw TapError.deviceIOProcCreationFailed }
        deviceIOProcID = procID

        do {
            try osCheck(AudioDeviceStart(aggregateDeviceID, procID), "start aggregate device")
        } catch {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceIOProcID = nil
            throw error
        }
    }

    // MARK: - Audio Processing (processing queue)

    private struct CapturedAudioBuffer {
        let numberChannels: UInt32
        let data: Data
    }

    private static func copyAudioBuffers(from inputData: UnsafePointer<AudioBufferList>) -> [CapturedAudioBuffer] {
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        var buffers: [CapturedAudioBuffer] = []
        buffers.reserveCapacity(bufferList.count)
        for buffer in bufferList {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            buffers.append(CapturedAudioBuffer(
                numberChannels: buffer.mNumberChannels,
                data: Data(bytes: data, count: Int(buffer.mDataByteSize))
            ))
        }
        return buffers
    }

    private func processAudioBuffers(_ buffers: [CapturedAudioBuffer], format: AudioStreamBasicDescription) {
        guard isRecording else { return }
        guard let mono = mixToMonoFloat(buffers: buffers, format: format), !mono.isEmpty else { return }
        guard let int16Samples = resampleMonoFloatToInt16(mono, sourceSampleRate: format.mSampleRate),
              !int16Samples.isEmpty else { return }

        guard let out = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: AVAudioFrameCount(int16Samples.count)
        ), let channel = out.int16ChannelData else { return }
        out.frameLength = AVAudioFrameCount(int16Samples.count)
        int16Samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: src.count)
        }
        noteCaptured(out)
        onPCMBuffer?(out)
    }

    private func noteCaptured(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let rms = Self.rmsLevel(of: buffer)
        let now = Date()
        captureSampleRate = buffer.format.sampleRate
        framesCaptured += AVAudioFramePosition(buffer.frameLength)
        lastBufferAt = now
        lastRMSLevel = rms
        peakRMSLevel = max(peakRMSLevel, rms)
        if rms >= Self.audibleRMSThreshold {
            audibleFramesCaptured += AVAudioFramePosition(buffer.frameLength)
            lastAudibleBufferAt = now
        }
    }

    private func resetCaptureHealth() {
        framesCaptured = 0
        audibleFramesCaptured = 0
        captureSampleRate = Self.targetFormat.sampleRate
        lastBufferAt = nil
        lastAudibleBufferAt = nil
        lastRMSLevel = 0
        peakRMSLevel = 0
    }

    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.int16ChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sumSquares: Float = 0
        for index in 0..<count {
            let sample = Float(channel[0][index]) / 32768.0
            sumSquares += sample * sample
        }
        return (sumSquares / Float(count)).squareRoot()
    }

    private func resampleMonoFloatToInt16(_ samples: [Float], sourceSampleRate: Double) -> [Int16]? {
        guard !samples.isEmpty, sourceSampleRate > 0 else { return nil }

        // Already at target rate — quantise directly.
        if abs(sourceSampleRate - Self.targetSampleRate) < 1.0 {
            return samples.map { Int16(max(-1.0, min(1.0, $0)) * 32767.0) }
        }

        guard let converter = resampler,
              let inputFormat = resamplerInputFormat,
              let outputFormat = resamplerOutputFormat,
              abs(inputFormat.sampleRate - sourceSampleRate) < 1.0 else {
            return nil
        }

        let inputFrameCount = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount),
              let inputChannel = inputBuffer.floatChannelData?[0] else {
            return nil
        }
        inputBuffer.frameLength = inputFrameCount
        inputChannel.update(from: samples, count: samples.count)

        let ratio = Self.targetSampleRate / sourceSampleRate
        let outputFrameCapacity = AVAudioFrameCount(max(1, Int(ceil(Double(samples.count) * ratio)) + 32))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        final class MutableBool: @unchecked Sendable { var value = false }
        let provided = MutableBool()
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if provided.value {
                status.pointee = .noDataNow
                return nil
            }
            provided.value = true
            status.pointee = .haveData
            return inputBuffer
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        guard status != .error, conversionError == nil, let outputChannel = outputBuffer.floatChannelData?[0] else {
            if let conversionError { RTILog.log("system audio converter failed: \(conversionError)", category: .audio) }
            return nil
        }

        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else { return nil }
        return (0..<frameLength).map { Int16(max(-1.0, min(1.0, outputChannel[$0])) * 32767.0) }
    }

    private func configureResampler(for format: AudioStreamBasicDescription) {
        resampler = nil
        resamplerInputFormat = nil
        resamplerOutputFormat = nil

        guard abs(format.mSampleRate - Self.targetSampleRate) >= 1.0 else { return }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: format.mSampleRate, channels: 1, interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            RTILog.log("failed to configure resampler for \(format.mSampleRate)Hz", category: .audio)
            return
        }
        resampler = converter
        resamplerInputFormat = inputFormat
        resamplerOutputFormat = outputFormat
    }

    private func mixToMonoFloat(buffers: [CapturedAudioBuffer], format: AudioStreamBasicDescription) -> [Float]? {
        guard format.mFormatID == kAudioFormatLinearPCM else { return nil }
        let flags = format.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(format.mBitsPerChannel)
        let channelCount = max(Int(format.mChannelsPerFrame), 1)

        if isFloat, bitsPerChannel == 32 {
            return mixBuffers(buffers, channelCount: channelCount, isNonInterleaved: isNonInterleaved) { data in
                data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
        if !isFloat, bitsPerChannel == 16 {
            return mixBuffers(buffers, channelCount: channelCount, isNonInterleaved: isNonInterleaved) { data in
                data.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { Float($0) / 32768.0 } }
            }
        }
        RTILog.log("unsupported tap PCM format flags=\(flags) bits=\(bitsPerChannel)", category: .audio)
        return nil
    }

    private func mixBuffers(
        _ buffers: [CapturedAudioBuffer],
        channelCount: Int,
        isNonInterleaved: Bool,
        decode: (Data) -> [Float]
    ) -> [Float]? {
        var mono: [Float] = []
        var channelsMixed = 0
        for buffer in buffers {
            let channels = isNonInterleaved ? max(Int(buffer.numberChannels), 1) : max(Int(buffer.numberChannels), channelCount)
            let samples = decode(buffer.data)
            guard !samples.isEmpty else { continue }
            let frames = samples.count / channels
            if mono.isEmpty { mono = [Float](repeating: 0, count: frames) }
            let framesToMix = min(mono.count, frames)
            for frame in 0..<framesToMix {
                for channel in 0..<channels {
                    mono[frame] += samples[frame * channels + channel]
                }
            }
            channelsMixed += channels
        }
        guard channelsMixed > 0, !mono.isEmpty else { return nil }
        let scale = 1.0 / Float(channelsMixed)
        for index in mono.indices { mono[index] *= scale }
        return mono
    }

    // MARK: - Process / format lookups

    /// Our process's AudioObjectID from the HAL process list. `CATapDescription`
    /// expects these IDs, not raw PIDs.
    private static func currentProcessAudioObjectID() -> AudioObjectID? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize) == noErr else {
            return nil
        }
        let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &objects) == noErr else {
            return nil
        }
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for obj in objects {
            var objPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &objPID) == noErr, objPID == myPID {
                return obj
            }
        }
        return nil
    }

    private static func audioTapStreamFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { throw TapError.tapFormatUnavailable(status) }
        return format
    }

    // MARK: - Permission

    /// Whether system-audio capture (`kTCCServiceAudioCapture`) is granted —
    /// probed by trying to create a tap. Used by `AudioPipeline` to decide
    /// whether the tap path is viable before committing to it.
    static func isPermissionGranted() -> Bool {
        let tapDesc = makeGlobalTapDescription(excludingProcessID: currentProcessAudioObjectID(), name: "RTI Permission Check")
        var testTapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(tapDesc, &testTapID)
        if status == noErr, testTapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(testTapID)
            return true
        }
        return false
    }

    // MARK: - Stale Device Cleanup

    /// Remove phantom "RTI System Audio" aggregate devices left behind by a
    /// previous crash. Call once at launch before any recording.
    static func cleanupStaleDevices() {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize) == noErr else { return }
        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &devices) == noErr else { return }

        for deviceID in devices {
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name) == noErr, let name else { continue }
            if (name.takeRetainedValue() as String) == "RTI System Audio" {
                RTILog.log("cleaning up stale aggregate device \(deviceID)", category: .audio)
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }

    // MARK: - Default Output Device Tracking

    /// Switching the system output (e.g. to AirPods mid-call) invalidates the
    /// tap. Rebuild it so the other party's audio keeps flowing.
    private func installDefaultOutputDeviceListener() {
        guard defaultOutputDeviceListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.processingQueue.async { [weak self] in self?.restartTapForDefaultOutputDeviceChange() }
        }
        defaultOutputDeviceListenerBlock = block
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
    }

    private func removeDefaultOutputDeviceListener() {
        guard let block = defaultOutputDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        defaultOutputDeviceListenerBlock = nil
    }

    private func restartTapForDefaultOutputDeviceChange() {
        guard isRecording else { return }
        do {
            try rebuildTap(reason: "default output device changed")
        } catch {
            teardownTapAndAudioDevice()
            isRecording = false
            let msg = "System audio tap lost after output change: \(error.localizedDescription)"
            RTILog.log(msg, category: .audio)
            onError?(msg)
        }
    }

    private func shouldRebuildForSilentAudio() -> Bool {
        let selectedApp = AudioInputDeviceStore.captureAppBundleID
        if !selectedApp.isEmpty {
            let currentObjects = Set(AudioInputDeviceStore.processObjects(forAppBundleID: selectedApp))
            if currentObjects != tappedProcessObjects {
                RTILog.log("system audio target changed; old=\(tappedProcessObjects.count) new=\(currentObjects.count)", category: .audio)
                return true
            }
        }
        // If the tap has never produced audible samples, one rebuild can clear
        // a stale aggregate/tap setup even when the process set appears stable.
        return audibleFramesCaptured == 0
    }

    private func rebuildTap(reason: String) throws {
        guard isRecording else { return }
        RTILog.log("\(reason); rebuilding tap", category: .audio)
        teardownTapAndAudioDevice()
        guard isRecording else { return }
        resetCaptureHealth()
        try createTapAndAggregateDevice()
        try setupAndStartAudioDevice()
        RTILog.log("CoreAudio tap rebuilt", category: .audio)
    }

    // MARK: - Teardown

    private func teardownTapAndAudioDevice() {
        activeCaptureGeneration &+= 1
        resampler = nil
        resamplerInputFormat = nil
        resamplerOutputFormat = nil

        if let procID = deviceIOProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        deviceIOProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        tappedProcessObjects = []
    }

    private func cleanupFailedStart() {
        isRecording = false
        removeDefaultOutputDeviceListener()
        teardownTapAndAudioDevice()
    }

    private func osCheck(_ status: OSStatus, _ label: String) throws {
        guard status == noErr else { throw TapError.setupFailed(label, status) }
    }

    enum TapError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case deviceIOProcCreationFailed
        case tapFormatUnavailable(OSStatus)
        case setupFailed(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let s): return "Process tap creation failed (status \(s))"
            case .aggregateDeviceCreationFailed(let s): return "Aggregate device creation failed (status \(s))"
            case .deviceIOProcCreationFailed: return "Could not create aggregate device IOProc"
            case .tapFormatUnavailable(let s): return "Could not read tap stream format (status \(s))"
            case .setupFailed(let step, let s): return "CoreAudio setup failed at '\(step)' (status \(s))"
            }
        }
    }
}
