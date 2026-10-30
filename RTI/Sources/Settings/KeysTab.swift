import SwiftUI
import HouseDesign

// MARK: - Providers

struct ProvidersTab: View {
    @Bindable var draft: ProviderSettingsDraft

    init(draft: ProviderSettingsDraft = ProviderSettingsDraft()) { self.draft = draft }

    private var activeLLMOption: LLMProviderOption {
        LLMProviders.option(id: draft.selectedLLMProviderId)
    }

    private var activeLLMHasKey: Bool {
        !(draft.keyValues[activeLLMOption.keychainAccount] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var activeRealtimeSTTHasKey: Bool {
        !(draft.keyValues["soniox"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var body: some View {
        SettingsPage(maxWidth: 720) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard("Provider Routing", detail: "Pick the assistant provider. Soniox handles live transcription and the automatic improved pass after Finish.") {
                    VStack(alignment: .leading, spacing: 12) {
                        providerPicker(
                            title: "Assistant",
                            selection: $draft.selectedLLMProviderId,
                            options: LLMProviders.all.map { ($0.id, $0.displayName) },
                            detail: "\(activeLLMOption.model) • \(activeLLMOption.config.baseURL.host ?? activeLLMOption.config.baseURL.absoluteString)"
                        )
                        staticProviderRow(
                            title: "Real-time speech-to-text",
                            value: "Soniox",
                            detail: "Fixed for live transcription, with live translation support."
                        )
                        staticProviderRow(
                            title: "Transcript upgrade",
                            value: "Soniox",
                            detail: "The improved pass after Finish, and Upgrade Transcript on a saved session."
                        )
                    }
                }

                SettingsCard("Credential Storage", detail: "API keys live in an owner-only file on this Mac. You can store several providers at once, then switch between them without re-entering credentials.") {
                    storageLocation
                }

                SettingsCard("Assistant Provider Keys", detail: "Store whichever LLM keys you use. RTI only requires a key for the currently selected assistant provider.") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(LLMProviders.all) { provider in
                            field(
                                provider.apiKeyLabel,
                                provider.apiKeyPlaceholder,
                                binding(for: provider.keychainAccount)
                            )
                        }
                    }
                }

                SettingsCard("Speech-to-Text Provider Keys", detail: "Soniox powers live transcription and the transcript upgrade after Finish.") {
                    VStack(alignment: .leading, spacing: 12) {
                        field("Soniox API key", "soniox-...", binding(for: "soniox"))
                    }
                }

                if !activeLLMHasKey {
                    SettingsStatusLabel(
                        text: "The selected assistant provider (\(activeLLMOption.displayName)) is missing its API key.",
                        systemImage: "exclamationmark.triangle.fill",
                        color: RTIDesign.Color.warning
                    )
                }
                if !activeRealtimeSTTHasKey {
                    SettingsStatusLabel(
                        text: "Live transcription needs a Soniox key.",
                        systemImage: "exclamationmark.triangle.fill",
                        color: RTIDesign.Color.warning
                    )
                }
                if let saveError = draft.saveError {
                    SettingsStatusLabel(text: saveError, systemImage: "xmark.octagon.fill", color: RTIDesign.Color.danger)
                }

                HStack {
                    if draft.hasUnsavedChanges {
                        SettingsStatusLabel(text: "Unsaved changes", systemImage: "pencil", color: House.ColorToken.textSecondary)
                    } else if draft.saved {
                        SettingsStatusLabel(text: "Saved", systemImage: "checkmark.circle.fill", color: RTIDesign.Color.success)
                    }
                    Spacer()
                    Button("Discard Changes") { draft.discardChanges() }
                        .disabled(!draft.hasUnsavedChanges)
                    Button("Save Provider Settings") { draft.save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { draft.loadIfNeeded() }
    }

    private var storageLocation: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.doc")
                .foregroundStyle(RTIDesign.Color.textSecondary)
            Text("~/Library/Application Support/RTI/credentials.json")
                .font(.system(size: House.TypeToken.Size.caption, design: .monospaced))
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .textSelection(.enabled)
            Text("0600")
                .font(.system(size: House.TypeToken.Size.micro, weight: .semibold, design: .monospaced))
                .foregroundStyle(RTIDesign.Color.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(RTIDesign.Color.chipFill))
        }
    }

    private func providerPicker(
        title: String,
        selection: Binding<String>,
        options: [(String, String)],
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: House.TypeToken.Size.meta, weight: .medium))
                Spacer()
                Text(detail)
                    .font(.system(size: House.TypeToken.Size.micro, design: .monospaced))
                    .foregroundStyle(RTIDesign.Color.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func staticProviderRow(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: House.TypeToken.Size.meta, weight: .medium))
                Spacer()
                Text(detail)
                    .font(.system(size: House.TypeToken.Size.micro, design: .monospaced))
                    .foregroundStyle(RTIDesign.Color.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            Text(value)
                .font(.system(size: House.TypeToken.Size.meta, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: RTIDesign.Radius.sm)
                        .fill(RTIDesign.Color.chipFill)
                )
        }
    }

    private func binding(for account: String) -> Binding<String> {
        Binding(
            get: { draft.keyValues[account] ?? "" },
            set: { draft.keyValues[account] = $0 }
        )
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: House.TypeToken.Size.meta, weight: .medium))
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: House.TypeToken.Size.bodySmall, design: .monospaced))
        }
    }

}
