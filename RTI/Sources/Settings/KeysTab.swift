import SwiftUI

// MARK: - Keys

struct KeysTab: View {
    @State private var deepseek = ""
    @State private var soniox = ""
    @State private var assemblyai = ""
    @State private var saved = false
    @State private var saveError: String?

    private var hasMissingKey: Bool {
        deepseek.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        soniox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isFirstRun: Bool {
        deepseek.isEmpty && soniox.isEmpty
    }

    var body: some View {
        let providerName = LLMProviders.active.displayName
        SettingsPage(maxWidth: 640) {
            VStack(alignment: .leading, spacing: 14) {
                if isFirstRun {
                    SettingsCard("Welcome to RTI", detail: "Add the two required keys to start live transcription and assistant responses. Keys stay in an owner-only file on this Mac.") {
                        storageLocation
                    }
                } else {
                    SettingsCard("Credential Storage", detail: "API keys are stored locally and are required before RTI can start a session.") {
                        storageLocation
                    }
                }

                SettingsCard("Required Keys", detail: "\(providerName) powers assistant responses. Soniox powers live transcription.") {
                    VStack(alignment: .leading, spacing: 12) {
                        field("\(providerName) API key", "sk-…", $deepseek)
                        field("Soniox API key", "…", $soniox)
                    }
                }

                SettingsCard("Optional Provider", detail: "Only needed if you pick AssemblyAI as the transcription provider in General. Soniox remains the default.") {
                    field("AssemblyAI API key", "…", $assemblyai)
                }

                if hasMissingKey {
                    SettingsStatusLabel(text: "Both required keys are needed before RTI can run.", systemImage: "exclamationmark.triangle.fill", color: .orange)
                }
                if let saveError {
                    SettingsStatusLabel(text: saveError, systemImage: "xmark.octagon.fill", color: .red)
                }

                HStack {
                    if saved {
                        SettingsStatusLabel(text: "Saved", systemImage: "checkmark.circle.fill", color: .green)
                    }
                    Spacer()
                    Button("Save Keys") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(hasMissingKey)
                }
            }
        }
        .onAppear {
            deepseek = CredentialStore.deepseek ?? ""
            soniox = CredentialStore.soniox ?? ""
            assemblyai = CredentialStore.assemblyai ?? ""
        }
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

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
        }
    }

    private func save() {
        let k = deepseek.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = soniox.trimmingCharacters(in: .whitespacesAndNewlines)
        // Belt-and-braces: the button is disabled when either is empty,
        // but if a hotkey-driven Save bypasses the disabled state we
        // should still refuse rather than wipe a key.
        guard !k.isEmpty, !s.isEmpty else {
            saveError = "Both keys must be filled in."
            return
        }
        saveError = nil
        CredentialStore.setDeepSeek(k)
        CredentialStore.setSoniox(s)
        // AssemblyAI is optional; an empty value clears it (CredentialStore.set
        // removes the entry on empty).
        CredentialStore.setAssemblyAI(assemblyai.trimmingCharacters(in: .whitespacesAndNewlines))
        // Verify the write actually landed in the keychain store. If
        // CredentialStore returns nil after set, surface a real error
        // instead of flashing a misleading green check.
        if CredentialStore.deepseek != k || CredentialStore.soniox != s {
            saveError = "Could not save keys to disk. Check that ~/Library/Application Support/RTI is writable."
            return
        }
        saved = true
        Task { try? await Task.sleep(for: .seconds(1.2)); await MainActor.run { saved = false } }
    }
}
