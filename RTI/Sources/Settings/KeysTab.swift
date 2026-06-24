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
        VStack(alignment: .leading, spacing: 16) {
            if isFirstRun {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to RTI")
                        .font(.system(size: 18, weight: .semibold))
                    Text("RTI needs two API keys to work: \(providerName) for the assistant, and Soniox for live transcription. Both stay in an owner-only file on this Mac (~/Library/Application Support/RTI/credentials.json).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("API Keys")
                    .font(.system(size: 16, weight: .semibold))
                Text("Stored on this Mac in ~/Library/Application Support/RTI/credentials.json (mode 0600). Required to use RTI.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            field("\(providerName) API key", "sk-…", $deepseek)
            field("Soniox API key", "…", $soniox)
            field("AssemblyAI API key (optional)", "…", $assemblyai)
            Text("AssemblyAI is optional — only needed if you pick it as the transcription provider in General. Soniox stays the default.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hasMissingKey {
                Text("Both keys are required for RTI to work.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if let saveError {
                Text(saveError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hasMissingKey)
            }
            Spacer()
        }
        .onAppear {
            deepseek = CredentialStore.deepseek ?? ""
            soniox = CredentialStore.soniox ?? ""
            assemblyai = CredentialStore.assemblyai ?? ""
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

