import CoreAudio
import Foundation

/// Lightweight wrapper around CoreAudio HAL device enumeration so the user can
/// pick a non-default input (typically BlackHole or an aggregate device that
/// blends mic + system audio for full-conversation capture).
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    /// Sentinel UID meaning "follow the system default input device" — keeps
    /// users who never touch the picker on the existing behavior.
    static let systemDefaultUID = "__system_default__"
}

enum AudioInputDeviceStore {
    private static let preferredUIDKey = "rti.audio.preferredInputUID"

    /// UID currently chosen by the user, or `systemDefaultUID` if untouched.
    static var preferredUID: String {
        get { UserDefaults.standard.string(forKey: preferredUIDKey) ?? AudioInputDevice.systemDefaultUID }
        set { UserDefaults.standard.set(newValue, forKey: preferredUIDKey) }
    }

    /// True when the user explicitly picked a device other than the system
    /// default — used to decide whether to assume "this is probably system
    /// audio + mic, expect multiple speakers" downstream.
    static var isCustomDevice: Bool {
        preferredUID != AudioInputDevice.systemDefaultUID
    }

    /// Enumerate all input-capable devices on the system.
    static func availableInputDevices() -> [AudioInputDevice] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs)
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { id -> AudioInputDevice? in
            guard hasInputChannels(deviceID: id) else { return nil }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// Resolve the user's preferred device to an `AudioDeviceID` we can hand to
    /// CoreAudio. Returns `nil` when "system default" is selected so the caller
    /// can fall back to the existing AVAudioEngine behavior.
    static func resolvePreferredDeviceID() -> AudioDeviceID? {
        let uid = preferredUID
        guard uid != AudioInputDevice.systemDefaultUID else { return nil }
        return availableInputDevices().first(where: { $0.uid == uid })?.id
    }

    /// Human-readable name of the input device actually in use — the picked
    /// device if the user chose one, otherwise the live system default.
    static func currentInputName() -> String {
        if isCustomDevice, let id = resolvePreferredDeviceID(),
           let name = stringProperty(id, kAudioObjectPropertyName) {
            return name
        }
        return defaultDeviceName(kAudioHardwarePropertyDefaultInputDevice) ?? "System default input"
    }

    /// Name of the default **output** device — what the system-audio tap
    /// follows to capture the other party.
    static func currentOutputName() -> String {
        defaultDeviceName(kAudioHardwarePropertyDefaultOutputDevice) ?? "System default output"
    }

    // MARK: - Bluetooth volume protection
    //
    // Opening a Bluetooth headset's mic flips it from rich stereo (A2DP) into
    // low-quality mono "call mode" (HFP), which halves the user's listening
    // volume. These helpers let `BluetoothMicGuard` detect that situation and
    // route capture to the built-in mic instead.

    static func defaultInputDeviceID() -> AudioDeviceID? {
        defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputIsBluetooth() -> Bool {
        guard let id = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) else { return false }
        return isBluetooth(id)
    }

    static func defaultInputIsBluetooth() -> Bool {
        guard let id = defaultInputDeviceID() else { return false }
        return isBluetooth(id)
    }

    /// The built-in microphone's device ID, if the Mac has one.
    static func builtInInputDeviceID() -> AudioDeviceID? {
        availableInputDevices().first { transportType($0.id) == kAudioDeviceTransportTypeBuiltIn }?.id
    }

    /// Enumerate all output-capable devices on the system.
    static func availableOutputDevices() -> [AudioInputDevice] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs)
        guard status == noErr else { return [] }
        return deviceIDs.compactMap { id -> AudioInputDevice? in
            guard hasOutputChannels(deviceID: id) else { return nil }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// UID of the current system default output device (what playback uses and
    /// what the system-audio tap follows).
    static func defaultOutputUID() -> String? {
        guard let id = defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// Set the system default OUTPUT device (Zoom-style speaker picker). The
    /// running system-audio tap auto-follows via its default-output listener.
    @discardableResult
    static func setDefaultOutputDevice(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device
        )
        return status == noErr
    }

    private static func hasOutputChannels(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size > 0 else { return false }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, bufferList) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buf in buffers where buf.mNumberChannels > 0 { return true }
        return false
    }

    /// Set the system default input device. Returns true on success.
    @discardableResult
    static func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device
        )
        return status == noErr
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }

    private static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        let t = transportType(deviceID)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func defaultDeviceName(_ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return stringProperty(deviceID, kAudioObjectPropertyName)
    }

    // MARK: - HAL helpers

    private static func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size > 0 else { return false }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, bufferList) == noErr else { return false }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buf in buffers where buf.mNumberChannels > 0 { return true }
        return false
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &unmanaged)
        guard status == noErr, let value = unmanaged else { return nil }
        return value.takeRetainedValue() as String
    }
}
