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
