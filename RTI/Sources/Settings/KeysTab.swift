import SwiftUI

// MARK: - Providers

struct ProvidersTab: View {
    @State private var selectedLLMProviderId = LLMProviders.activeId
    @State private var keyValues: [String: String] = [:]
    @State private var saved = false
    @State private var saveError: String?

    private var activeLLMOption: LLMProviderOption {
        LLMProviders.option(id: selectedLLMProviderId)
    }

    private var activeLLMHasKey: Bool {
        !(keyValues[activeLLMOption.keychainAccount] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var activeRealtimeSTTHasKey: Bool {
        !(keyValues["soniox"] ?? "")
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
                            selection: $selectedLLMProviderId,
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
                if let saveError {
                    SettingsStatusLabel(text: saveError, systemImage: "xmark.octagon.fill", color: RTIDesign.Color.danger)
                }

                HStack {
                    if saved {
                        SettingsStatusLabel(text: "Saved", systemImage: "checkmark.circle.fill", color: RTIDesign.Color.success)
                    }
                    Spacer()
                    Button("Save Provider Settings") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear(perform: load)
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
            get: { keyValues[account] ?? "" },
            set: { keyValues[account] = $0 }
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

    private func load() {
        selectedLLMProviderId = LLMProviders.activeId
        var next: [String: String] = [:]
        for provider in LLMProviders.all {
            next[provider.keychainAccount] = CredentialStore.value(for: provider.keychainAccount) ?? ""
        }
        next["soniox"] = CredentialStore.soniox ?? ""
        keyValues = next
    }

    private func save() {
        saveError = nil

        for provider in LLMProviders.all {
            CredentialStore.setValue(
                (keyValues[provider.keychainAccount] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                for: provider.keychainAccount
            )
        }
        CredentialStore.setSoniox((keyValues["soniox"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))

        LLMProviders.activeId = selectedLLMProviderId
        STTProviders.activeId = STTProviders.soniox.id

        let llmKey = (keyValues[activeLLMOption.keychainAccount] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard CredentialStore.value(for: activeLLMOption.keychainAccount) == llmKey else {
            saveError = "Could not save \(activeLLMOption.displayName) credentials to disk. Check that ~/Library/Application Support/RTI is writable."
            return
        }

        let soniox = (keyValues["soniox"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard CredentialStore.soniox == (soniox.isEmpty ? nil : soniox) else {
            saveError = "Could not save speech-to-text credentials to disk. Check that ~/Library/Application Support/RTI is writable."
            return
        }

        saved = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { saved = false }
        }
    }
}
