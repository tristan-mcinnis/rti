import SwiftUI

// MARK: - General

/// Settings → General. Composed of independent section views so each section
/// re-renders only when its own bindings change — previously every toggle on
/// this tab invalidated every other section.
struct GeneralTab: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                Text("General")
                    .font(.system(size: 16, weight: .semibold))

                LaunchAtLoginSection()

                Divider().padding(.vertical, 8)
                AssistantSection()

                Divider().padding(.vertical, 8)
                TranscriptionSection()

                Divider().padding(.vertical, 8)
                AudioInputSection()

                Divider().padding(.vertical, 8)
                RealTimeAnalysisSection()

                Divider().padding(.vertical, 8)
                OverlayAppearanceSection()

                Divider().padding(.vertical, 8)
                HotkeysSection()

                Divider().padding(.vertical, 8)
                DataAndSupportSection()

                Divider().padding(.vertical, 8)
                DiagnosticsSection()

                Spacer()
            }
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Launch at Login

private struct LaunchAtLoginSection: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch RTI at login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    if let err = LaunchAtLogin.setEnabled(newValue) {
                        launchError = err
                        launchAtLogin = LaunchAtLogin.isEnabled
                    } else {
                        launchError = nil
                        launchAtLogin = newValue
                    }
                }
            ))
            if let launchError {
                Text(launchError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Assistant

private struct AssistantSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Assistant")
                .font(.system(size: 13, weight: .medium))
            llmProviderRow
            Text("Provider is selected in code (`LLMProviders.activeId`). All providers must speak OpenAI-compatible streaming chat. Add your API key in the Keys tab.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var llmProviderRow: some View {
        let active = LLMProviders.active
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(active.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(active.model)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(active.baseURL.host ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06))
        )
    }
}

// MARK: - Transcription (speech-to-text provider)

private struct TranscriptionSection: View {
    @AppStorage(STTProviders.activeIdKey) private var providerId = "soniox"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcription")
                .font(.system(size: 13, weight: .medium))
            Picker("Speech-to-text", selection: $providerId) {
                ForEach(STTProviders.all, id: \.id) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .pickerStyle(.menu)
            Text("Which engine transcribes live audio. Soniox is the default (best multilingual + diarization). AssemblyAI uses Universal-Streaming v3 — add its key in the Keys tab first. Falls back to Soniox if the selected provider has no key. Applies on the next session.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Audio Input

private struct AudioInputSection: View {
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedInputUID: String = AudioInputDeviceStore.preferredUID
    @AppStorage(AudioSettingsDefaults.echoCancellationKey) private var echoCancellation: Bool = false
    @AppStorage(AudioSettingsDefaults.protectBluetoothVolumeKey) private var protectBluetoothVolume: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio Input")
                .font(.system(size: 13, weight: .medium))
            Picker("Capture from", selection: $selectedInputUID) {
                Text("System default microphone").tag(AudioInputDevice.systemDefaultUID)
                if !inputDevices.isEmpty { Divider() }
                ForEach(inputDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedInputUID) { _, newValue in
                AudioInputDeviceStore.preferredUID = newValue
            }
            Text("Pick BlackHole (or an aggregate device that combines mic + BlackHole) to capture system audio from calls. The change applies the next time you start a session.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Echo cancellation", isOn: $echoCancellation)
                .padding(.top, 4)
            Text("Cancels the other party's voice bleeding from your speakers into the mic. Off by default: on some Macs Apple's voice-processing silences the mic entirely (no transcript). Only enable if you're on speakers and transcription still works. Applies on the next session.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Protect Bluetooth headphone volume", isOn: $protectBluetoothVolume)
                .padding(.top, 4)
            Text("While recording, if your mic is a Bluetooth headset, RTI captures from the built-in mic instead so the headphones stay at full volume. Your original mic is restored when recording stops.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 6)
            Text("Live levels")
                .font(.system(size: 13, weight: .medium))
            Text("During a session, confirm both sides are being captured. Also a floating panel: menubar → Toggle Audio I/O Monitor.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AudioMonitorContent()
                .padding(.top, 4)
        }
        .onAppear {
            inputDevices = AudioInputDeviceStore.availableInputDevices()
        }
    }
}

// MARK: - Real-Time Analysis

private struct RealTimeAnalysisSection: View {
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled: Bool = false
    @AppStorage(AnalysisSettingsDefaults.notesIntervalKey) private var notesInterval: Double = AnalysisSettingsDefaults.defaultInterval
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Real-Time Analysis")
                .font(.system(size: 13, weight: .medium))

            Toggle("Enable notes generation", isOn: $notesEnabled)
            Toggle("Enable discussion guide matching", isOn: $guideEnabled)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Notes interval")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(Int(notesInterval / 60)) min")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $notesInterval, in: AnalysisSettingsDefaults.intervalRange, step: 60) {}
            }
            .disabled(!notesEnabled)
            .opacity(notesEnabled ? 1 : 0.5)

            Text("Notes and discussion-guide matching run automatically while recording.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    notesEnabled = false
                    guideEnabled = false
                    notesInterval = AnalysisSettingsDefaults.defaultInterval
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Overlay Appearance

private struct OverlayAppearanceSection: View {
    @AppStorage(OverlayAppearanceDefaults.widthKey) private var overlayWidth: Double = OverlayAppearanceDefaults.defaultWidth
    @AppStorage(OverlayAppearanceDefaults.heightKey) private var overlayHeight: Double = OverlayAppearanceDefaults.defaultHeight
    @AppStorage(OverlayAppearanceDefaults.opacityKey) private var overlayOpacity: Double = OverlayAppearanceDefaults.defaultOpacity
    @AppStorage(OverlayAppearanceDefaults.lightModeKey) private var lightMode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Overlay Appearance")
                .font(.system(size: 13, weight: .medium))

            Toggle("Light mode", isOn: $lightMode)
                .onChange(of: lightMode) { _, _ in
                    NotificationCenter.default.post(name: .rtiOverlayAppearanceChanged, object: nil)
                }
            Text("White panel, dark text. Off keeps the dark glass overlay.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            sliderRow(
                label: "Width",
                value: $overlayWidth,
                range: OverlayAppearanceDefaults.widthRange,
                step: 10,
                format: "%.0f px",
                postsResize: true
            )

            sliderRow(
                label: "Height",
                value: $overlayHeight,
                range: OverlayAppearanceDefaults.heightRange,
                step: 10,
                format: "%.0f px",
                postsResize: true
            )

            sliderRow(
                label: "Background opacity",
                value: $overlayOpacity,
                range: OverlayAppearanceDefaults.opacityRange,
                step: 0.05,
                format: "%.0f%%",
                postsResize: false,
                displayTransform: { $0 * 100 }
            )

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    overlayWidth = OverlayAppearanceDefaults.defaultWidth
                    overlayHeight = OverlayAppearanceDefaults.defaultHeight
                    overlayOpacity = OverlayAppearanceDefaults.defaultOpacity
                    NotificationCenter.default.post(name: .rtiOverlaySizeChanged, object: nil)
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        postsResize: Bool,
        displayTransform: ((Double) -> Double)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                Spacer()
                Text(String(format: format, displayTransform?(value.wrappedValue) ?? value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step) { editing in
                if !editing && postsResize {
                    NotificationCenter.default.post(name: .rtiOverlaySizeChanged, object: nil)
                }
            }
        }
    }
}

// MARK: - Hotkeys

private struct HotkeysSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hotkeys")
                .font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: 4) {
                hotkeyRow("Toggle overlay", "⌘ \\")
                hotkeyRow("Start / stop session", "⌘ ⇧ R")
                hotkeyRow("Assist (from any app)", "⌘ ↵")
                hotkeyRow("Attach screenshot", "⌘ ⇧ H")
                hotkeyRow("Show / hide live transcript", "⌘ ⌥ T")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Text("⌘⏎ is remappable to any quick action (✦ menu → \"⌘⏎ runs\"). Other hotkeys are fixed: ⌘⇧R record, ⌘⌥R recap, ⌘⌥M summary, ⌘⌥S say-next, ⌘⌥F follow-ups, ⌘⇧H screenshot, ⌘\\ overlay.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func hotkeyRow(_ label: String, _ key: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(key).font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Data & Support

private struct DataAndSupportSection: View {
    @State private var crashLogAvailable: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Data & Support")
                .font(.system(size: 13, weight: .medium))
            Text("Live audio is streamed to your transcription provider (Soniox by default, or AssemblyAI) for transcription. Transcripts and prompts are sent to your configured LLM provider (DeepSeek by default) to generate answers. The full meeting is saved as m4a in your vault recordings folder (kept for backup and high-quality re-transcription); the working 16 kHz WAV is still deleted on stop. The session record (transcript, notes, chat, auto-summary) is written to your vault on stop — and checkpointed every 5 minutes during recording — where it syncs and becomes searchable. API keys stay in an owner-only file on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Show RTI Folder") { revealRTIFolder() }
                Button("Show Crash Log") { revealCrashLog() }
                    .disabled(!crashLogAvailable)
                Button("View Logs…") { showLogs() }
            }
        }
        .onAppear {
            crashLogAvailable = crashLogURL().map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    private func revealRTIFolder() {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let rti = dir.appendingPathComponent("RTI", isDirectory: true)
        try? FileManager.default.createDirectory(at: rti, withIntermediateDirectories: true)
        NSWorkspace.shared.open(rti)
    }

    private func crashLogURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("RTI/crash.log")
    }

    private func revealCrashLog() {
        guard let url = crashLogURL(), FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func showLogs() {
        NotificationCenter.default.post(name: .rtiShowLogs, object: nil)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSection: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics")
                .font(.system(size: 13, weight: .medium))
            diagRow("Version", "RTI \(version) (\(build))")
            diagRow("Provider", "\(LLMProviders.active.displayName) · \(LLMProviders.active.model)")
            HStack {
                Spacer()
                Button("Copy diagnostics") { copyDiagnostics() }
                    .controlSize(.small)
            }
        }
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private func copyDiagnostics() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let provider = LLMProviders.active
        let lines = [
            "RTI \(version) (\(build))",
            "Platform: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Provider: \(provider.displayName) · \(provider.model) · \(provider.baseURL.absoluteString)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
