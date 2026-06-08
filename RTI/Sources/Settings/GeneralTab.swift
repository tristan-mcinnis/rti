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

// MARK: - Audio Input

private struct AudioInputSection: View {
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedInputUID: String = AudioInputDeviceStore.preferredUID
    @AppStorage(AudioSettingsDefaults.echoCancellationKey) private var echoCancellation: Bool = true

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
            Text("Cancels the other party's voice bleeding from your speakers into the mic, which otherwise gets transcribed twice. Recommended on speakers; harmless on headphones. Applies on the next session. Some external/aggregate devices may not support it.")
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
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled: Bool = true
    @AppStorage(AnalysisSettingsDefaults.notesIntervalKey) private var notesInterval: Double = AnalysisSettingsDefaults.defaultInterval
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled: Bool = true

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

            Text("Notes and discussion-guide matching run automatically while recording. They appear in the overlay's Notes and Guide tabs (⌘\\ to open the overlay).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    notesEnabled = true
                    guideEnabled = true
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Overlay Appearance")
                .font(.system(size: 13, weight: .medium))

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
                hotkeyRow("Open sessions", "⌘ ⇧ S")
                hotkeyRow("Toggle notes panel", "⌘ ⇧ N")
                hotkeyRow("Toggle dossiers panel", "⌘ ⇧ D")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Text("Hotkeys are fixed in this build; customization is planned. The overlay's \"…\" menu lists the same keybinds for quick access.")
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
            Text("Audio is streamed to Soniox for transcription. Transcripts and prompts are sent to your configured LLM provider (DeepSeek by default) to generate answers. Nothing is stored: the live transcript and chat stay in memory for the session and are dropped when it ends; the recording is deleted on stop. Only your API keys and modes are kept on this Mac.")
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
