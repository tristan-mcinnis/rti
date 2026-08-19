import SwiftUI

/// Settings sheet: Soniox key, LLM key (for the active provider), a
/// microphone picker over physical devices only, and a single save action.
/// Keys round-trip through `KeychainStore` the same way `ProvidersTab`
/// (`Settings/KeysTab.swift`) does.
struct MinimalSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var sonioxKey = ""
    @State private var llmKey = ""
    @State private var selectedMicUID = AudioInputDeviceStore.preferredUID
    @State private var saved = false

    // Live analysis — opt-in, all off by default. Same UserDefaults keys the
    // pre-strip GeneralTab used.
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled = AnalysisSettingsDefaults.defaultNotesEnabled
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled = AnalysisSettingsDefaults.defaultGuideEnabled
    @AppStorage(AnalysisSettingsDefaults.autoAssistEnabledKey) private var autoAssistEnabled = AnalysisSettingsDefaults.defaultAutoAssistEnabled

    // Appearance — overlay transparency + reduce motion, bound to the
    // existing OverlayAppearanceDefaults keys.
    @AppStorage(OverlayAppearanceDefaults.translucentPanelKey) private var translucentPanel = OverlayAppearanceDefaults.defaultTranslucentPanel
    @AppStorage(OverlayAppearanceDefaults.opacityKey) private var panelOpacity = OverlayAppearanceDefaults.defaultOpacity
    @AppStorage(OverlayAppearanceDefaults.reduceMotionKey) private var reduceMotion = OverlayAppearanceDefaults.defaultReduceMotion

    private var activeLLMOption: LLMProviderOption {
        LLMProviders.option(id: LLMProviders.activeId)
    }

    private var micOptions: [AudioInputDevice] {
        AudioInputDeviceStore.physicalInputDevices()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.inkPrimary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Soniox API key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                SecureField("soniox-...", text: $sonioxKey)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("\(activeLLMOption.displayName) API key")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                SecureField(activeLLMOption.apiKeyPlaceholder, text: $llmKey)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Microphone")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                Picker("Microphone", selection: $selectedMicUID) {
                    Text("System default").tag(AudioInputDevice.systemDefaultUID)
                    ForEach(micOptions) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Live analysis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                Toggle("Generate live notes", isOn: $notesEnabled)
                Toggle("Track discussion guide", isOn: $guideEnabled)
                Toggle("Suggest follow-up questions", isOn: $autoAssistEnabled)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 13))

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                Toggle("Use a translucent panel", isOn: $translucentPanel)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                if translucentPanel {
                    HStack {
                        Text("Opacity")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.inkFaint)
                        Slider(value: $panelOpacity, in: OverlayAppearanceDefaults.opacityRange)
                    }
                }
                Text("Reduce motion")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkFaint)
                Picker("Reduce motion", selection: $reduceMotion) {
                    ForEach(RTIReduceMotionMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            HStack {
                if saved {
                    Text("Saved")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.stateLive)
                }
                Spacer()
                Button("Save keys") { save() }
                    .buttonStyle(.borderedProminent)
                    .pressable()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Palette.surfacePanel)
        .onAppear(perform: load)
    }

    private func load() {
        sonioxKey = CredentialStore.soniox ?? ""
        llmKey = CredentialStore.value(for: activeLLMOption.keychainAccount) ?? ""
        selectedMicUID = AudioInputDeviceStore.preferredUID
    }

    private func save() {
        CredentialStore.setSoniox(sonioxKey.trimmingCharacters(in: .whitespacesAndNewlines))
        CredentialStore.setValue(
            llmKey.trimmingCharacters(in: .whitespacesAndNewlines),
            for: activeLLMOption.keychainAccount
        )
        AudioInputDeviceStore.preferredUID = selectedMicUID
        saved = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { saved = false }
        }
    }
}
