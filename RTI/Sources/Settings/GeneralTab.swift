import AppKit
import SwiftUI

// MARK: - General

/// Settings → General. Composed of independent section views so each section
/// re-renders only when its own bindings change: one toggle never
/// invalidates every other card on the pane.
struct GeneralTab: View {
    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: House.Spacing.sm) {
                LaunchAtLoginSection()
                CaptureAccessSection()
                ScreenPrivacySection()
                AudioInputSection()
                RealTimeAnalysisSection()
                AppearanceSection()
                HotkeysSection()
                DataAndSupportSection()
            }
        }
    }
}

// MARK: - Launch at Login

private struct LaunchAtLoginSection: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        SettingsCard("Startup", rows: true) {
            SettingsToggleRow(title: "Launch RTI at login", isFirst: true, isOn: Binding(
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
                CardNote { CardText(launchError, tone: House.ColorToken.danger) }
            }
        }
    }
}

// MARK: - Capture Access

private struct CaptureAccessSection: View {
    @State private var microphonePermission = AppPermissions.microphone
    @State private var screenPermission = AppPermissions.screenRecording

    var body: some View {
        SettingsCard("Capture Access", rows: true) {
            SettingsRow(title: "Microphone", detail: "Needed for live transcription.", isFirst: true) {
                accessControl(
                    state: microphonePermission,
                    grant: { AppPermissions.requestMicrophone { _ in refreshPermissions() } },
                    openSettings: AppPermissions.openMicrophoneSettings
                )
            }
            SettingsRow(
                title: "Screen and OCR",
                detail: "Optional. Reads the screen and the images you attach. Frames are kept in the session only with the local vision lane on."
            ) {
                accessControl(
                    state: screenPermission,
                    grant: {
                        _ = AppPermissions.requestScreenRecording()
                        refreshPermissions()
                    },
                    openSettings: AppPermissions.openScreenRecordingSettings
                )
            }
        }
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    @ViewBuilder
    private func accessControl(
        state: AppPermissions.State,
        grant: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        switch state {
        case .granted:
            SettingsStatusLabel(text: "Allowed", systemImage: "checkmark.circle.fill", color: House.ColorToken.success)
                .fixedSize()
        case .notDetermined:
            Button("Allow", action: grant)
        case .denied:
            Button("Open System Settings", action: openSettings)
        }
    }

    private func refreshPermissions() {
        microphonePermission = AppPermissions.microphone
        screenPermission = AppPermissions.screenRecording
    }
}

// MARK: - Screen Privacy

/// Deny-list of apps whose windows are removed from every screen capture at
/// the ScreenCaptureKit filter: their pixels never reach OCR, frames, notes,
/// summaries, or the vault meeting note.
private struct ScreenPrivacySection: View {
    @State private var listText: String = ScreenPrivacy.excludedBundleIds.joined(separator: "\n")

    var body: some View {
        SettingsCard(
            "Screen Privacy",
            detail: "Windows of these apps are cut out of every screen capture: ambient context, attached screenshots, and the assistant's capture tool. Their content never reaches OCR text, kept frames, notes, or summaries. One bundle ID per line."
        ) {
            TextEditor(text: $listText)
                .font(House.TypeToken.code)
                .scrollContentBackground(.hidden)
                .padding(House.Spacing.xxs)
                .frame(minHeight: House.Control.hero * 2, maxHeight: House.Control.hero * 3)
                .settingsEditorBorder()
                .onChange(of: listText) { _, newValue in
                    ScreenPrivacy.excludedBundleIds = newValue
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            HStack(spacing: House.Spacing.sm) {
                let count = ScreenPrivacy.excludedBundleIds.count
                SettingsStatusLabel(
                    text: count == 0
                        ? "No apps excluded. Everything on screen can be captured."
                        : "\(count) app\(count == 1 ? "" : "s") never captured.",
                    systemImage: count == 0 ? "exclamationmark.triangle.fill" : "eye.slash.fill",
                    color: count == 0 ? House.ColorToken.warning : House.ColorToken.success
                )
                Spacer(minLength: House.Spacing.sm)
                Button("Reset to Defaults") {
                    ScreenPrivacy.resetToDefaults()
                    listText = ScreenPrivacy.excludedBundleIds.joined(separator: "\n")
                }
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
    private let session = SessionCoordinator.shared

    var body: some View {
        SettingsCard("Audio Input", rows: true) {
            SettingsRow(
                title: "Capture from",
                detail: "Pick BlackHole or an aggregate device to capture call audio. Applies on the next recording.",
                isFirst: true
            ) {
                Picker("Capture from", selection: $selectedInputUID) {
                    Text("System default microphone").tag(AudioInputDevice.systemDefaultUID)
                    if !inputDevices.isEmpty { Divider() }
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .onChange(of: selectedInputUID) { _, newValue in
                    AudioInputDeviceStore.preferredUID = newValue
                }
            }
            SettingsToggleRow(
                title: "Echo cancellation",
                detail: "Removes the other side's voice that your mic picks up from your speakers. Off by default: on some Macs it silences the mic. Turn it on only if you use speakers and transcription still works. Applies on the next recording.",
                isOn: $echoCancellation
            )
            SettingsToggleRow(
                title: "Protect Bluetooth headphone volume",
                detail: "Records from the built-in mic so Bluetooth headphones stay at full volume. Your mic comes back when you stop.",
                isOn: $protectBluetoothVolume
            )
            SettingsRow(
                title: "Live levels",
                detail: session.isRunning
                    ? "Check that both sides are heard. The menu bar has the same monitor."
                    : "Shows only while a recording runs."
            ) {
                EmptyView()
            }
            if session.isRunning {
                CardNote {
                    AudioMonitorContent()
                        .padding(House.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                .fill(House.ColorToken.chipFill)
                        )
                }
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
        SettingsCard("Real-Time Analysis", detail: "Runs by itself while recording.", rows: true) {
            SettingsToggleRow(title: "Write notes", isFirst: true, isOn: $notesEnabled)
            SettingsRow(title: "Notes interval") {
                HStack(spacing: House.Spacing.xs) {
                    Slider(value: $notesInterval, in: AnalysisSettingsDefaults.intervalRange, step: 60) {}
                        .labelsHidden()
                        .frame(width: House.Layout.settingsRail)
                    Text("\(Int(notesInterval / 60)) min")
                        .font(House.TypeToken.meta)
                        .monospacedDigit()
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
                .disabled(!notesEnabled)
            }
            SettingsToggleRow(title: "Match the discussion guide", isOn: $guideEnabled)
            SettingsToggleRow(title: "Keep the intelligence ledger", isOn: $findingsEnabled)
            SettingsToggleRow(title: "Show next-move cards (Auto)", isOn: $autoAssistEnabled)
            CardNote {
                Button("Reset to Defaults") {
                    notesEnabled = AnalysisSettingsDefaults.defaultNotesEnabled
                    guideEnabled = AnalysisSettingsDefaults.defaultGuideEnabled
                    findingsEnabled = AnalysisSettingsDefaults.defaultFindingsEnabled
                    autoAssistEnabled = AnalysisSettingsDefaults.defaultAutoAssistEnabled
                    notesInterval = AnalysisSettingsDefaults.defaultInterval
                }
            }
        }
    }
}

// MARK: - Appearance

/// Theme, text size, speaker colours, and motion. The accent and contrast
/// controls are gone (the accent paints no chrome), and so are the window
/// size sliders: the RTI window keeps the frame you give it.
private struct AppearanceSection: View {
    @AppStorage(OverlayAppearanceDefaults.appearanceModeKey) private var appearanceMode: String = OverlayAppearanceDefaults.defaultAppearanceMode
    @AppStorage(OverlayAppearanceDefaults.uiFontSizeKey) private var uiFontSize: Double = OverlayAppearanceDefaults.defaultUIFontSize
    @AppStorage(OverlayAppearanceDefaults.reduceMotionKey) private var reduceMotion: String = OverlayAppearanceDefaults.defaultReduceMotion

    var body: some View {
        SettingsCard("Appearance", rows: true) {
            SettingsRow(title: "Appearance", isFirst: true) {
                InkSegmentedControl(
                    selection: $appearanceMode,
                    options: RTIAppearanceMode.allCases.map { InkSegment(value: $0.rawValue, title: $0.label) }
                )
                .frame(maxWidth: House.Layout.settingsRail)
                .onChange(of: appearanceMode) { _, _ in postAppearanceChanged() }
            }
            SettingsRow(title: "Text size", detail: "Transcript and answer text in the RTI window.") {
                HStack(spacing: House.Spacing.xs) {
                    Slider(value: $uiFontSize, in: OverlayAppearanceDefaults.uiFontSizeRange, step: 1) { editing in
                        if !editing { postAppearanceChanged() }
                    }
                    .labelsHidden()
                    .frame(width: House.Layout.settingsRail)
                    Text("\(Int(uiFontSize)) pt")
                        .font(House.TypeToken.meta)
                        .monospacedDigit()
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
            }
            SettingsRow(title: "Speaker colours", detail: "Transcript speaker chips use these six colours so speakers stay distinct.") {
                // The one allowed categorical palette (DESIGN.md): data
                // colour, not chrome, local to RTI.
                HStack(spacing: House.Spacing.xxs) {
                    ForEach(Array(RTIDesign.Color.speakerPalette.enumerated()), id: \.offset) { index, colour in
                        Circle()
                            .fill(colour)
                            .frame(width: House.Control.keyCap / 2, height: House.Control.keyCap / 2)
                            .accessibilityLabel("Speaker \(index + 1)")
                    }
                }
            }
            SettingsRow(title: "Reduce motion") {
                InkSegmentedControl(
                    selection: $reduceMotion,
                    options: RTIReduceMotionMode.allCases.map { InkSegment(value: $0.rawValue, title: $0.label) }
                )
                .frame(maxWidth: House.Layout.settingsRail)
                .onChange(of: reduceMotion) { _, _ in postAppearanceChanged() }
            }
            CardNote {
                Button("Reset to Defaults") {
                    appearanceMode = OverlayAppearanceDefaults.defaultAppearanceMode
                    uiFontSize = OverlayAppearanceDefaults.defaultUIFontSize
                    reduceMotion = OverlayAppearanceDefaults.defaultReduceMotion
                    UserDefaults.standard.removeObject(forKey: OverlayAppearanceDefaults.lightModeKey)
                    postAppearanceChanged()
                }
            }
        }
    }

    private func postAppearanceChanged() {
        NotificationCenter.default.post(name: .rtiOverlayAppearanceChanged, object: nil)
    }
}

// MARK: - Hotkeys

private struct HotkeysSection: View {
    private struct Hotkey: Identifiable {
        let title: String
        var detail: String? = nil
        let keys: [String]
        var id: String { title }
    }

    /// The Carbon hotkeys in `HotkeyCoordinator` (the source of truth), plus
    /// the house list key in RTI's list windows.
    private let hotkeys = [
        Hotkey(title: "Show or hide RTI", detail: "Works from any app.", keys: ["⌘", "\\"]),
        Hotkey(title: "Start or finish a recording", detail: "Works from any app.", keys: ["⌘", "⇧", "R"]),
        Hotkey(title: "Pause or resume", keys: ["⌘", "⇧", "P"]),
        Hotkey(title: "Primary action", detail: "The assistant action you picked as primary.", keys: ["⌘", "↩"]),
        Hotkey(title: "Note mode", detail: "Type a note into the transcript.", keys: ["⌘", "⌥", "N"]),
        Hotkey(title: "Read the screen", keys: ["⌘", "⇧", "H"]),
        Hotkey(title: "Show the list", detail: "In the Sessions and Meeting Brief windows.", keys: ["⌃", "⌘", "S"]),
    ]

    var body: some View {
        SettingsCard("Hotkeys", rows: true) {
            ForEach(Array(hotkeys.enumerated()), id: \.element.id) { index, hotkey in
                SettingsRow(title: hotkey.title, detail: hotkey.detail, isFirst: index == 0) {
                    KeyCapGroup(keys: hotkey.keys)
                        .accessibilityLabel(hotkey.keys.joined(separator: " "))
                }
            }
            CardNote {
                CardText("Pause, the primary action, note mode, and reading the screen work only while a recording runs.")
            }
        }
    }
}

// MARK: - Data & Support

private struct DataAndSupportSection: View {
    @State private var crashLogAvailable: Bool = false

    var body: some View {
        SettingsCard(
            "Data and Support",
            detail: "Audio goes to your transcription provider. Transcripts and prompts go to your assistant provider. Session records save to your vault when you stop, and every 5 minutes while recording."
        ) {
            HStack(spacing: House.Spacing.xs) {
                Button("Show RTI Folder") { revealRTIFolder() }
                Button("Show Crash Log") { revealCrashLog() }
                    .disabled(!crashLogAvailable)
                Button("View Logs") { SettingsWindowController.shared.show(pane: .logs) }
            }
        }
        .onAppear {
            crashLogAvailable = CrashLog.logURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    private func revealRTIFolder() {
        guard let rti = AppSupportPaths.rtiDirectory() else { return }
        NSWorkspace.shared.open(rti)
    }

    private func revealCrashLog() {
        guard let url = CrashLog.logURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - About

/// Settings → About: version, the update check, the diagnostics line, and
/// the source.
struct AboutTab: View {
    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: House.Spacing.sm) {
                SettingsCard("Version", rows: true) {
                    SettingsRow(title: "RTI", isFirst: true) {
                        Text(Self.versionLine)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textSecondary)
                            .textSelection(.enabled)
                    }
                    SettingsRow(title: "Updates") {
                        Button("Check for Updates") { UpdateChecker.checkAndReport() }
                    }
                }
                DiagnosticsSection()
                SettingsCard("Source", rows: true) {
                    SettingsRow(title: "Repository", isFirst: true) {
                        if let url = URL(string: "https://github.com/tristan-mcinnis/rti") {
                            // Links are the one place the accent is allowed.
                            Link("Source on GitHub", destination: url)
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.accent)
                        }
                    }
                }
            }
        }
    }

    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSection: View {
    var body: some View {
        SettingsCard("Diagnostics", rows: true) {
            diagRow("Assistant", "\(LLMProviders.active.displayName) · \(LLMProviders.active.model)", isFirst: true)
            diagRow("Transcription", STTProviders.active.displayName)
            diagRow("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
            CardNote {
                Button("Copy Diagnostics") { copyDiagnostics() }
            }
        }
    }

    private func diagRow(_ label: String, _ value: String, isFirst: Bool = false) -> some View {
        SettingsRow(title: label, isFirst: isFirst) {
            Text(value)
                .font(House.TypeToken.code)
                .foregroundStyle(House.ColorToken.textSecondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func copyDiagnostics() {
        let provider = LLMProviders.active
        let lines = [
            "RTI \(AboutTab.versionLine)",
            "Platform: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Assistant: \(provider.displayName) · \(provider.model) · \(provider.baseURL.absoluteString)",
            "Transcription: \(STTProviders.active.displayName)",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
