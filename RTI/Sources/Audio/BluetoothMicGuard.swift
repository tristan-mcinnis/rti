import CoreAudio
import Foundation

/// Keeps Bluetooth headphones at full volume while RTI records.
///
/// Opening a Bluetooth headset's microphone forces it out of rich stereo (A2DP)
/// into low-quality mono "call mode" (HFP), which audibly halves the user's
/// listening volume. When recording starts and the **default mic is a Bluetooth
/// device**, this switches the *system default input* to the built-in mic — the
/// one route AVAudioEngine accepts without an input≠output device conflict — and
/// restores the user's original choice on stop. It is a no-op when the default
/// mic isn't Bluetooth, when no built-in mic exists, or when the user disables
/// it in Settings.
@MainActor
final class BluetoothMicGuard {
    static let shared = BluetoothMicGuard()

    private var savedDefaultInput: AudioDeviceID?
    private var routedTo: AudioDeviceID?

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AudioSettingsDefaults.protectBluetoothVolumeKey) as? Bool ?? true
    }

    private init() {}

    /// Call right before the capture engine starts.
    func engage() {
        guard isEnabled, savedDefaultInput == nil else { return }
        guard let current = AudioInputDeviceStore.defaultInputDeviceID(),
              AudioInputDeviceStore.defaultInputIsBluetooth(),
              let builtIn = AudioInputDeviceStore.builtInInputDeviceID(),
              builtIn != current
        else { return }

        guard AudioInputDeviceStore.setDefaultInputDevice(builtIn) else {
            RTILog.log("bluetooth mic guard: failed to switch default input", category: "audio")
            return
        }
        savedDefaultInput = current
        routedTo = builtIn
        RTILog.log("bluetooth mic guard: default input → built-in mic (headphones stay in A2DP)", category: "audio")
    }

    /// Call after the capture engine has stopped. Restores the user's original
    /// default input unless they changed it themselves while recording.
    func release() {
        guard let saved = savedDefaultInput else { return }
        defer { savedDefaultInput = nil; routedTo = nil }
        if let now = AudioInputDeviceStore.defaultInputDeviceID(), now != routedTo { return }
        AudioInputDeviceStore.setDefaultInputDevice(saved)
        RTILog.log("bluetooth mic guard: restored default input", category: "audio")
    }
}
