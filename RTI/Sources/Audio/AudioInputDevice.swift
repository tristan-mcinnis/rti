import AppKit
import CoreAudio
import Foundation

/// Lightweight wrapper around CoreAudio HAL device enumeration so the user can
/// pick a non-default input (typically BlackHole or an aggregate device that
/// blends mic + system audio for full-conversation capture).
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    /// Sentinel value meaning "follow the system default input device" — keeps
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
    ///
    /// Thin wrapper kept for callers that only care about the raw UID pick
    /// (unfiltered). `preferredRealInputDeviceID()` is the one that filters
    /// out virtual devices and should be used to actually bind capture.
    static func resolvePreferredDeviceID() -> AudioDeviceID? {
        let uid = preferredUID
        guard uid != AudioInputDevice.systemDefaultUID else { return nil }
        return availableInputDevices().first(where: { $0.uid == uid })?.id
    }

    // MARK: - Virtual device filtering
    //
    // Virtual/loopback devices (BlackHole, aggregates, etc.) show up as valid
    // input devices to CoreAudio, so nothing stops the app from silently
    // recording a loopback device instead of a real microphone. These
    // helpers filter them out.

    /// Name substrings (case-insensitive) known to belong to virtual/loopback
    /// audio devices rather than physical microphones.
    private static let virtualDeviceNameDenylist = [
        "blackhole", "loopback", "soundflower", "vb-cable", "vb-audio",
        "aggregate", "multi-output", "zoomaudiodevice", "teams audio", "krisp",
    ]

    /// True when `deviceID` is a virtual, aggregate, or otherwise
    /// known-loopback device rather than a physical microphone.
    static func isVirtual(_ deviceID: AudioDeviceID) -> Bool {
        let transport = transportType(deviceID)
        if transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate {
            return true
        }
        guard let name = stringProperty(deviceID, kAudioObjectPropertyName) else { return false }
        return isVirtualName(name)
    }

    /// Pure name-based check against the virtual/loopback device denylist,
    /// split out from `isVirtual(_:)` so it's testable without a real
    /// `AudioDeviceID`.
    static func isVirtualName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return virtualDeviceNameDenylist.contains { lowered.contains($0) }
    }

    /// All input-capable devices, minus virtual/loopback ones.
    static func physicalInputDevices() -> [AudioInputDevice] {
        availableInputDevices().filter { !isVirtual($0.id) }
    }

    /// Name + UID for an arbitrary device ID, for logging which device was
    /// actually bound.
    static func nameAndUID(for deviceID: AudioDeviceID) -> (name: String, uid: String) {
        let name = stringProperty(deviceID, kAudioObjectPropertyName) ?? "unknown"
        let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? "unknown"
        return (name, uid)
    }

    /// The device capture should actually bind to, in priority order:
    /// 1. the user's explicit pick, if it's not virtual
    /// 2. the current system default input, if it's not virtual
    /// 3. the built-in microphone
    /// 4. the first physical input device
    /// 5. `nil` if there is no physical input device at all
    static func preferredRealInputDeviceID() -> AudioDeviceID? {
        if let picked = resolvePreferredDeviceID(), !isVirtual(picked) {
            return picked
        }
        if let defaultID = defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice), !isVirtual(defaultID) {
            return defaultID
        }
        if let builtIn = builtInInputDeviceID() {
            return builtIn
        }
        return physicalInputDevices().first?.id
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

    // MARK: - Per-app system-audio capture

    /// Bundle ID of the app whose audio the system tap should capture, or ""
    /// for the default global tap (everything except RTI). Helper processes
    /// (e.g. browser renderers) are matched by bundle-ID prefix.
    private static let captureAppKey = "rti.audio.captureAppBundleID"
    static var captureAppBundleID: String {
        get { UserDefaults.standard.string(forKey: captureAppKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: captureAppKey) }
    }

    struct CaptureApp: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
    }

    /// Every HAL audio process object with its PID and bundle ID. These are
    /// the processes a CATapDescription can target.
    static func audioProcessObjects() -> [(object: AudioObjectID, pid: pid_t, bundleID: String)] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr else { return [] }

        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return objects.compactMap { obj in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &pid) == noErr else { return nil }
            var unmanaged: Unmanaged<CFString>?
            var strSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
            let bundle: String
            if AudioObjectGetPropertyData(obj, &bundleAddr, 0, nil, &strSize, &unmanaged) == noErr, let v = unmanaged {
                bundle = v.takeRetainedValue() as String
            } else {
                bundle = ""
            }
            return (obj, pid, bundle)
        }
    }

    /// Apps the user can pick as a capture target: running applications that
    /// own at least one HAL audio process (matched by bundle-ID prefix so
    /// browser/Electron helper processes count toward their parent app).
    static func capturableApps() -> [CaptureApp] {
        let processBundles = audioProcessObjects().map(\.bundleID).filter { !$0.isEmpty }
        guard !processBundles.isEmpty else { return [] }
        let myBundle = Bundle.main.bundleIdentifier ?? ""
        var seen = Set<String>()
        var apps: [CaptureApp] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, bid != myBundle, !seen.contains(bid),
                  let name = app.localizedName,
                  processBundles.contains(where: { $0 == bid || $0.hasPrefix(bid + ".") }) else { continue }
            seen.insert(bid)
            apps.append(CaptureApp(bundleID: bid, name: name))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// HAL process objects belonging to `bundleID` (prefix match covers
    /// helper processes). Empty when the app isn't producing audio objects.
    static func processObjects(forAppBundleID bundleID: String) -> [AudioObjectID] {
        audioProcessObjects()
            .filter { $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".") }
            .map(\.object)
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
