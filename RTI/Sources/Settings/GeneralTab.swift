import AppKit
import SwiftUI

// MARK: - General

/// Settings → General. Composed of independent section views so each section
/// re-renders only when its own bindings change — previously every toggle on
/// this tab invalidated every other section.
struct GeneralTab: View {
    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard { LaunchAtLoginSection() }
                SettingsCard { AudioInputSection() }
                SettingsCard { RealTimeAnalysisSection() }
                SettingsCard { OverlayAppearanceSection() }
                SettingsCard { HotkeysSection() }
                SettingsCard { DataAndSupportSection() }
                SettingsCard { DiagnosticsSection() }
            }
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
            Text("Pick BlackHole or an aggregate device to capture system audio from calls. Applies on the next session.")
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
            Text("Keeps Bluetooth headphones at full volume by using the built-in mic while recording, then restores your original mic on stop.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 6)
            Text("Live levels")
                .font(.system(size: 13, weight: .medium))
            Text("During a session, confirm both sides are being captured. The same monitor is available from the menubar.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AudioMonitorContent()
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.06))
                )
                .padding(.top, 6)
        }
        .onAppear {
            inputDevices = AudioInputDeviceStore.availableInputDevices()
        }
    }
}

// MARK: - Real-Time Analysis

private struct RealTimeAnalysisSection: View {
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled: Bool = AnalysisSettingsDefaults.defaultNotesEnabled
    @AppStorage(AnalysisSettingsDefaults.notesIntervalKey) private var notesInterval: Double = AnalysisSettingsDefaults.defaultInterval
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled: Bool = AnalysisSettingsDefaults.defaultGuideEnabled
    @AppStorage(AnalysisSettingsDefaults.findingsEnabledKey) private var findingsEnabled: Bool = AnalysisSettingsDefaults.defaultFindingsEnabled
    @AppStorage(AnalysisSettingsDefaults.autoAssistEnabledKey) private var autoAssistEnabled: Bool = AnalysisSettingsDefaults.defaultAutoAssistEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Real-Time Analysis")
                .font(.system(size: 13, weight: .medium))

            Toggle("Enable notes generation", isOn: $notesEnabled)
            Toggle("Enable discussion guide matching", isOn: $guideEnabled)
            Toggle("Enable live intelligence ledger", isOn: $findingsEnabled)
            Toggle("Enable auto next-move cards", isOn: $autoAssistEnabled)

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

            Text("Runs automatically while recording.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    notesEnabled = AnalysisSettingsDefaults.defaultNotesEnabled
                    guideEnabled = AnalysisSettingsDefaults.defaultGuideEnabled
                    findingsEnabled = AnalysisSettingsDefaults.defaultFindingsEnabled
                    autoAssistEnabled = AnalysisSettingsDefaults.defaultAutoAssistEnabled
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
    @AppStorage(OverlayAppearanceDefaults.appearanceModeKey) private var appearanceMode: String = OverlayAppearanceDefaults.defaultAppearanceMode
    @AppStorage(OverlayAppearanceDefaults.accentColorKey) private var accentColorHex: String = OverlayAppearanceDefaults.defaultAccentColor
    @AppStorage(OverlayAppearanceDefaults.contrastKey) private var contrast: Double = OverlayAppearanceDefaults.defaultContrast
    @AppStorage(OverlayAppearanceDefaults.translucentPanelKey) private var translucentPanel: Bool = OverlayAppearanceDefaults.defaultTranslucentPanel
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize
    @AppStorage(OverlayAppearanceDefaults.reduceMotionKey) private var reduceMotion: String = OverlayAppearanceDefaults.defaultReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Overlay Appearance")
                .font(.system(size: 13, weight: .medium))

            Picker("Theme", selection: $appearanceMode) {
                ForEach(RTIAppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: appearanceMode) { _, _ in postAppearanceChanged() }

            HStack {
                ColorPicker("Accent", selection: accentBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 36)
                Text("Accent")
                    .font(.system(size: 12))
                Spacer()
                Text(accentColorHex.uppercased())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .onChange(of: accentColorHex) { _, _ in postAppearanceChanged() }

            Toggle("Translucent panel", isOn: $translucentPanel)
                .onChange(of: translucentPanel) { _, _ in postAppearanceChanged() }
            Text("A softer live surface for meetings. Turn it off for a flatter, higher-contrast panel.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            sliderRow(
                label: "Contrast",
                value: $contrast,
                range: OverlayAppearanceDefaults.contrastRange,
                step: 1,
                format: "%.0f",
                postsResize: false,
                postsAppearance: true
            )

            sliderRow(
                label: "UI font size",
                value: $uiFontSize,
                range: OverlayAppearanceDefaults.uiFontSizeRange,
                step: 1,
                format: "%.0f pt",
                postsResize: false,
                postsAppearance: true
            )

            Picker("Reduce motion", selection: $reduceMotion) {
                ForEach(RTIReduceMotionMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: reduceMotion) { _, _ in postAppearanceChanged() }

            Divider().padding(.vertical, 4)

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
                    appearanceMode = OverlayAppearanceDefaults.defaultAppearanceMode
                    accentColorHex = OverlayAppearanceDefaults.defaultAccentColor
                    contrast = OverlayAppearanceDefaults.defaultContrast
                    translucentPanel = OverlayAppearanceDefaults.defaultTranslucentPanel
                    uiFontSize = OverlayAppearanceDefaults.defaultUIFontSize
                    reduceMotion = OverlayAppearanceDefaults.defaultReduceMotion
                    overlayWidth = OverlayAppearanceDefaults.defaultWidth
                    overlayHeight = OverlayAppearanceDefaults.defaultHeight
                    overlayOpacity = OverlayAppearanceDefaults.defaultOpacity
                    UserDefaults.standard.removeObject(forKey: OverlayAppearanceDefaults.lightModeKey)
                    NotificationCenter.default.post(name: .rtiOverlaySizeChanged, object: nil)
                    postAppearanceChanged()
                }
                .controlSize(.small)
            }
        }
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor.rtiColor(hex: accentColorHex) ?? NSColor.systemBlue)
            },
            set: { newValue in
                accentColorHex = NSColor(newValue).rtiHexString
            }
        )
    }

    private func postAppearanceChanged() {
        NotificationCenter.default.post(name: .rtiOverlayAppearanceChanged, object: nil)
    }

    @ViewBuilder
    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        postsResize: Bool,
        postsAppearance: Bool = false,
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
                if !editing && postsAppearance {
                    postAppearanceChanged()
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
                hotkeyRow("Pause / resume", "⌘ ⇧ P")
                hotkeyRow("Primary action (remappable)", "⌘ ↵")
                hotkeyRow("Note mode (type into transcript)", "⌘ ⌥ N")
                hotkeyRow("Attach screenshot", "⌘ ⇧ H")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Text("⌘⏎ is the remappable primary action. Quick AI actions are also available from the command palette.")
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
            Text("Audio is streamed to your transcription provider. Transcripts and prompts are sent to your configured LLM provider. Session records are written to your vault on stop and checkpointed every 5 minutes while recording.")
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
            diagRow("Assistant", "\(LLMProviders.active.displayName) · \(LLMProviders.active.model)")
            diagRow("Transcribe", STTProviders.active.displayName)
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
            "Assistant: \(provider.displayName) · \(provider.model) · \(provider.baseURL.absoluteString)",
            "Transcription: \(STTProviders.active.displayName)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
