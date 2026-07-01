import SwiftUI

// MARK: - Providers

struct ProvidersTab: View {
    @State private var selectedLLMProviderId = LLMProviders.activeId
    @State private var selectedRealtimeSTTProviderId = STTProviders.activeId
    @State private var selectedAsyncTranscriptProviderId = AsyncTranscriptProviders.activeId
    @State private var keyValues: [String: String] = [:]
    @State private var saved = false
    @State private var saveError: String?

    private var activeLLMOption: LLMProviderOption {
        LLMProviders.option(id: selectedLLMProviderId)
    }

    private var activeRealtimeSTTOption: STTProviderConfig {
        STTProviders.all.first { $0.id == selectedRealtimeSTTProviderId } ?? STTProviders.soniox
    }

    private var activeAsyncTranscriptOption: AsyncTranscriptProviderOption {
        AsyncTranscriptProviders.all.first { $0.id == selectedAsyncTranscriptProviderId } ?? AsyncTranscriptProviders.aliyun
    }

    private var activeLLMHasKey: Bool {
        !(keyValues[activeLLMOption.keychainAccount] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var activeRealtimeSTTHasKey: Bool {
        switch activeRealtimeSTTOption.id {
        case "assemblyai":
            let raw = (keyValues["assemblyai"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { return true }
            return !(keyValues["soniox"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return !(keyValues["soniox"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var activeAsyncTranscriptHasKey: Bool {
        activeAsyncTranscriptOption.credentialFields.allSatisfy {
            !(keyValues[$0.account] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    var body: some View {
        SettingsPage(maxWidth: 720) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsCard("Provider Routing", detail: "Pick providers per lane: assistant, live speech-to-text, and transcript upgrade. LLM swaps take effect on the next turn; live STT swaps reconnect if a session is already running.") {
                    VStack(alignment: .leading, spacing: 12) {
                        providerPicker(
                            title: "Assistant",
                            selection: $selectedLLMProviderId,
                            options: LLMProviders.all.map { ($0.id, $0.displayName) },
                            detail: "\(activeLLMOption.model) • \(activeLLMOption.config.baseURL.host ?? activeLLMOption.config.baseURL.absoluteString)"
                        )
                        providerPicker(
                            title: "Real-time speech-to-text",
                            selection: $selectedRealtimeSTTProviderId,
                            options: STTProviders.all.map { ($0.id, $0.displayName) },
                            detail: selectedRealtimeSTTProviderId == "assemblyai"
                                ? "AssemblyAI if configured; otherwise falls back to Soniox."
                                : "Soniox, with live translation support."
                        )
                        providerPicker(
                            title: "Default transcript upgrade choice",
                            selection: $selectedAsyncTranscriptProviderId,
                            options: AsyncTranscriptProviders.all.map { ($0.id, $0.displayName) },
                            detail: "Used as the first option when you click Upgrade Transcript. You still choose Soniox or Aliyun for each archived session."
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

                SettingsCard("Speech-to-Text Provider Keys", detail: "Soniox is the default live-transcription backend. AssemblyAI is optional and can be swapped in at any time.") {
                    VStack(alignment: .leading, spacing: 12) {
                        field("Soniox API key", "soniox-...", binding(for: "soniox"))
                        field("AssemblyAI API key", "...", binding(for: "assemblyai"))
                    }
                }

                SettingsCard("Transcript Upgrade Provider Keys", detail: "These keys are only for the post-hoc Upgrade Transcript lane. That lane replaces the rough live transcript using the session-local retained audio, then regenerates the summary from the upgraded text.") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(AsyncTranscriptProviders.all) { provider in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(provider.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                ForEach(provider.credentialFields) { credential in
                                    field(
                                        credential.label,
                                        credential.placeholder,
                                        binding(for: credential.account)
                                    )
                                }
                            }
                        }
                    }
                }

                if !activeLLMHasKey {
                    SettingsStatusLabel(
                        text: "The selected assistant provider (\(activeLLMOption.displayName)) is missing its API key.",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange
                    )
                }
                if !activeRealtimeSTTHasKey {
                    SettingsStatusLabel(
                        text: "The selected real-time speech-to-text path needs a Soniox key or a configured AssemblyAI key.",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange
                    )
                }
                if !activeAsyncTranscriptHasKey {
                    SettingsStatusLabel(
                        text: "The selected transcript-upgrade provider (\(activeAsyncTranscriptOption.displayName)) is missing one or more required credentials.",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange
                    )
                }
                if selectedRealtimeSTTProviderId == "assemblyai",
                   (keyValues["assemblyai"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !(keyValues["soniox"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SettingsStatusLabel(
                        text: "AssemblyAI is selected but not configured yet, so RTI will keep using Soniox until you add an AssemblyAI key.",
                        systemImage: "arrow.triangle.branch",
                        color: .secondary
                    )
                }
                if let saveError {
                    SettingsStatusLabel(text: saveError, systemImage: "xmark.octagon.fill", color: .red)
                }

                HStack {
                    if saved {
                        SettingsStatusLabel(text: "Saved", systemImage: "checkmark.circle.fill", color: .green)
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
                .foregroundStyle(.secondary)
            Text("~/Library/Application Support/RTI/credentials.json")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("0600")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
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
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
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

    private func binding(for account: String) -> Binding<String> {
        Binding(
            get: { keyValues[account] ?? "" },
            set: { keyValues[account] = $0 }
        )
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
        }
    }

    private func load() {
        selectedLLMProviderId = LLMProviders.activeId
        selectedRealtimeSTTProviderId = STTProviders.activeId
        selectedAsyncTranscriptProviderId = AsyncTranscriptProviders.activeId
        var next: [String: String] = [:]
        for provider in LLMProviders.all {
            next[provider.keychainAccount] = CredentialStore.value(for: provider.keychainAccount) ?? ""
        }
        for provider in AsyncTranscriptProviders.all {
            for credential in provider.credentialFields {
                next[credential.account] = CredentialStore.value(for: credential.account) ?? ""
            }
        }
        next["soniox"] = CredentialStore.soniox ?? ""
        next["assemblyai"] = CredentialStore.assemblyai ?? ""
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
        CredentialStore.setAssemblyAI((keyValues["assemblyai"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        CredentialStore.setAliyunAccessKeyID((keyValues["aliyun_access_key_id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        CredentialStore.setAliyunAccessKeySecret((keyValues["aliyun_access_key_secret"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        CredentialStore.setAliyunNLSAppKey((keyValues["aliyun_nls_app_key"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))

        LLMProviders.activeId = selectedLLMProviderId
        STTProviders.activeId = selectedRealtimeSTTProviderId
        AsyncTranscriptProviders.activeId = selectedAsyncTranscriptProviderId

        let llmKey = (keyValues[activeLLMOption.keychainAccount] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard CredentialStore.value(for: activeLLMOption.keychainAccount) == llmKey else {
            saveError = "Could not save \(activeLLMOption.displayName) credentials to disk. Check that ~/Library/Application Support/RTI is writable."
            return
        }

        let soniox = (keyValues["soniox"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assembly = (keyValues["assemblyai"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let aliyunAccessKeyID = (keyValues["aliyun_access_key_id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let aliyunAccessKeySecret = (keyValues["aliyun_access_key_secret"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let aliyunNLSAppKey = (keyValues["aliyun_nls_app_key"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard CredentialStore.soniox == (soniox.isEmpty ? nil : soniox),
              CredentialStore.assemblyai == (assembly.isEmpty ? nil : assembly),
              CredentialStore.aliyunAccessKeyID == (aliyunAccessKeyID.isEmpty ? nil : aliyunAccessKeyID),
              CredentialStore.aliyunAccessKeySecret == (aliyunAccessKeySecret.isEmpty ? nil : aliyunAccessKeySecret),
              CredentialStore.aliyunNLSAppKey == (aliyunNLSAppKey.isEmpty ? nil : aliyunNLSAppKey) else {
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
