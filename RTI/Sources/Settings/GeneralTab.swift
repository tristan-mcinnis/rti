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
                SettingsCard { CaptureAccessSection() }
                SettingsCard { ScreenPrivacySection() }
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

// MARK: - Screen Privacy

/// Deny-list of apps whose windows are removed from every screen capture at
/// the ScreenCaptureKit filter — their pixels never reach OCR, frames, notes,
/// summaries, or the vault meeting note.
private struct ScreenPrivacySection: View {
    @State private var listText: String = ScreenPrivacy.excludedBundleIds.joined(separator: "\n")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SlateSectionLabel(text: "Screen Privacy")
            Text("Windows of these apps are cut out of every screen capture — ambient context, attached screenshots, and the assistant's capture tool. Their content can never reach OCR text, kept frames, notes, or meeting summaries. One bundle id per line.")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $listText)
                .font(.system(size: House.TypeToken.Size.caption, design: .monospaced))
                .frame(minHeight: 120, maxHeight: 160)
                .settingsEditorBorder()
                .onChange(of: listText) { _, newValue in
                    ScreenPrivacy.excludedBundleIds = newValue
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            HStack {
                let count = ScreenPrivacy.excludedBundleIds.count
                SettingsStatusLabel(
                    text: count == 0
                        ? "No apps excluded — everything visible on screen can be captured."
                        : "\(count) app\(count == 1 ? "" : "s") never captured. Applies immediately.",
                    systemImage: count == 0 ? "exclamationmark.triangle.fill" : "eye.slash.fill",
                    color: count == 0 ? .orange : .green
                )
                Spacer()
                Button("Reset to Defaults") {
                    ScreenPrivacy.resetToDefaults()
                    listText = ScreenPrivacy.excludedBundleIds.joined(separator: "\n")
                }
                .controlSize(.small)
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
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(RTIDesign.Color.danger)
            }
        }
    }
}

// MARK: - Capture Access

private struct CaptureAccessSection: View {
    @State private var microphonePermission = AppPermissions.microphone
    @State private var screenPermission = AppPermissions.screenRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SlateSectionLabel(text: "Capture Setup")
            accessRow(
                title: "Microphone",
                detail: "Required for live transcription.",
                state: microphonePermission,
                grant: { AppPermissions.requestMicrophone { _ in refreshPermissions() } },
                openSettings: AppPermissions.openMicrophoneSettings
            )
            Divider()
            accessRow(
                title: "Screen & OCR",
                detail: "Optional — reads the active screen and attached images. With the local vision lane on, session frames are kept in the session archive; otherwise images are discarded.",
                state: screenPermission,
                grant: {
                    _ = AppPermissions.requestScreenRecording()
                    refreshPermissions()
                },
                openSettings: AppPermissions.openScreenRecordingSettings
            )
        }
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func accessRow(
        title: String,
        detail: String,
        state: AppPermissions.State,
        grant: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: House.TypeToken.Size.meta, weight: .medium))
                Text(detail)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(RTIDesign.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            switch state {
            case .granted:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.system(size: House.TypeToken.Size.caption, weight: .medium))
                    .foregroundStyle(RTIDesign.Color.success)
            case .notDetermined:
                Button("Allow", action: grant)
                    .controlSize(.small)
            case .denied:
                Button("Open Settings", action: openSettings)
                    .controlSize(.small)
            }
        }
    }

    private func refreshPermissions() {
        microphonePermission = AppPermissions.microphone
        screenPermission = AppPermissions.screenRecording
    }
}

// MARK: - Audio Input

private struct AudioInputSection: View {
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedInputUID: String = AudioInputDeviceStore.preferredUID
    @AppStorage(AudioSettingsDefaults.echoCancellationKey) private var echoCancellation: Bool = false
    @AppStorage(AudioSettingsDefaults.protectBluetoothVolumeKey) private var protectBluetoothVolume: Bool = true
    private let session = SessionCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SlateSectionLabel(text: "Audio Input")
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
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Echo cancellation", isOn: $echoCancellation)
                .padding(.top, 4)
            Text("Cancels the other party's voice bleeding from your speakers into the mic. Off by default: on some Macs Apple's voice-processing silences the mic entirely (no transcript). Only enable if you're on speakers and transcription still works. Applies on the next session.")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Protect Bluetooth headphone volume", isOn: $protectBluetoothVolume)
                .padding(.top, 4)
            Text("Keeps Bluetooth headphones at full volume by using the built-in mic while recording, then restores your original mic on stop.")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 6)
            SlateSectionLabel(text: "Live levels")
            Text(session.isRunning
                ? "Confirm both sides are being captured. The same monitor is available from the menubar."
                : "Levels are available only while a session is recording.")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if session.isRunning {
                AudioMonitorContent()
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.sm)
                            .fill(RTIDesign.Color.chipFill)
                    )
                    .padding(.top, 6)
            }
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
            SlateSectionLabel(text: "Real-Time Analysis")

            Toggle("Enable notes generation", isOn: $notesEnabled)
            Toggle("Enable discussion guide matching", isOn: $guideEnabled)
            Toggle("Enable live intelligence ledger", isOn: $findingsEnabled)
            Toggle("Enable auto next-move cards", isOn: $autoAssistEnabled)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Notes interval")
                        .font(RTIDesign.Font.meta)
                    Spacer()
                    Text("\(Int(notesInterval / 60)) min")
                        .font(.system(size: House.TypeToken.Size.caption, design: .monospaced))
                        .foregroundStyle(RTIDesign.Color.textSecondary)
                }
                Slider(value: $notesInterval, in: AnalysisSettingsDefaults.intervalRange, step: 60) {}
            }
            .disabled(!notesEnabled)
            .opacity(notesEnabled ? 1 : 0.5)

            Text("Runs automatically while recording.")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
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
    @AppStorage(OverlayAppearanceDefaults.appearanceModeKey) private var appearanceMode: String = OverlayAppearanceDefaults.defaultAppearanceMode
    @AppStorage(OverlayAppearanceDefaults.accentColorKey) private var accentColorHex: String = OverlayAppearanceDefaults.defaultAccentColor
    @AppStorage(OverlayAppearanceDefaults.contrastKey) private var contrast: Double = OverlayAppearanceDefaults.defaultContrast
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize
    @AppStorage(OverlayAppearanceDefaults.reduceMotionKey) private var reduceMotion: String = OverlayAppearanceDefaults.defaultReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SlateSectionLabel(text: "Overlay Appearance")

            HStack(spacing: RTIDesign.Spacing.sm) {
                Text("Appearance")
                    .font(RTIDesign.Font.label)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                Spacer(minLength: RTIDesign.Spacing.xs)
                Picker("Appearance", selection: $appearanceMode) {
                    ForEach(RTIAppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: appearanceMode) { _, _ in postAppearanceChanged() }
            }
            .frame(height: RTIDesign.Control.heightMd)

            // The accent no longer paints chrome (DESIGN.md: focus rings and
            // links only), so the old accent picker is gone. What is left of
            // the palette is the six-colour SPEAKER palette, which is data
            // colour and stays local to RTI.
            HStack(spacing: RTIDesign.Spacing.sm) {
                Text("Speaker palette")
                    .font(RTIDesign.Font.label)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                Spacer(minLength: RTIDesign.Spacing.xs)
                HStack(spacing: RTIDesign.Spacing.xxs + 2) {
                    ForEach(Array(RTIDesign.Color.speakerPalette.enumerated()), id: \.offset) { index, colour in
                        Circle()
                            .fill(colour)
                            .frame(width: 10, height: 10)
                            .accessibilityLabel("Speaker \(index + 1)")
                    }
                }
            }
            .frame(height: RTIDesign.Control.heightMd)
            .help("Transcript speaker chips use these six colours so speakers stay distinct.")

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

            HStack(spacing: RTIDesign.Spacing.sm) {
                Text("Reduce motion")
                    .font(RTIDesign.Font.label)
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                Spacer(minLength: RTIDesign.Spacing.xs)
                Picker("Reduce motion", selection: $reduceMotion) {
                    ForEach(RTIReduceMotionMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: reduceMotion) { _, _ in postAppearanceChanged() }
            }
            .frame(height: RTIDesign.Control.heightMd)

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

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    appearanceMode = OverlayAppearanceDefaults.defaultAppearanceMode
                    accentColorHex = OverlayAppearanceDefaults.defaultAccentColor
                    contrast = OverlayAppearanceDefaults.defaultContrast
                    uiFontSize = OverlayAppearanceDefaults.defaultUIFontSize
                    reduceMotion = OverlayAppearanceDefaults.defaultReduceMotion
                    overlayWidth = OverlayAppearanceDefaults.defaultWidth
                    overlayHeight = OverlayAppearanceDefaults.defaultHeight
                    UserDefaults.standard.removeObject(forKey: OverlayAppearanceDefaults.lightModeKey)
                    NotificationCenter.default.post(name: .rtiOverlaySizeChanged, object: nil)
                    postAppearanceChanged()
                }
                .controlSize(.small)
            }
        }
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
                    .font(RTIDesign.Font.meta)
                Spacer()
                Text(String(format: format, displayTransform?(value.wrappedValue) ?? value.wrappedValue))
                    .font(.system(size: House.TypeToken.Size.caption, design: .monospaced))
                    .foregroundStyle(RTIDesign.Color.textSecondary)
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
            SlateSectionLabel(text: "Hotkeys")
            VStack(alignment: .leading, spacing: 4) {
                hotkeyRow("Toggle overlay", "⌘ \\")
                hotkeyRow("Start / stop session", "⌘ ⇧ R")
                hotkeyRow("Pause / resume", "⌘ ⇧ P")
                hotkeyRow("Primary action (remappable)", "⌘ ↵")
                hotkeyRow("Note mode (type into transcript)", "⌘ ⌥ N")
                hotkeyRow("Attach screenshot", "⌘ ⇧ H")
            }
            .font(RTIDesign.Font.meta)
            .foregroundStyle(RTIDesign.Color.textSecondary)

            Text("⌘⏎ is the remappable primary action. Quick AI actions are also available from the command palette.")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
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
            SlateSectionLabel(text: "Data & Support")
            Text("Audio is streamed to your transcription provider. Transcripts and prompts are sent to your configured LLM provider. Session records are written to your vault on stop and checkpointed every 5 minutes while recording.")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
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
        guard let rti = AppSupportPaths.rtiDirectory() else { return }
        NSWorkspace.shared.open(rti)
    }

    private func crashLogURL() -> URL? {
        CrashLog.logURL
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
            SlateSectionLabel(text: "Diagnostics")
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
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: House.TypeToken.Size.caption, design: .monospaced))
                .foregroundStyle(RTIDesign.Color.textPrimary)
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
