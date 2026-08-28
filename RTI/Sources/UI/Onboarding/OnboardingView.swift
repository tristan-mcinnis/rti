import SwiftUI

/// First-run setup: API keys + permissions, with a clear "you're ready" state.
/// Shown once on a fresh machine (no keys); dismisses to the menubar.
struct OnboardingView: View {
    var onDone: () -> Void

    @State private var soniox = ""
    @State private var llmKey = ""
    @State private var keysConfigured = LLMProviders.activeHasKey && STTProviders.activeHasKey
    @State private var justSaved = false
    @State private var saveError: String?
    @State private var micState = AppPermissions.microphone
    @State private var screenState = AppPermissions.screenRecording

    private var providerName: String {
        LLMProviders.active.displayName
    }

    private var canSave: Bool {
        !soniox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !llmKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isReady: Bool {
        keysConfigured && micState == .granted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                keysCard
                permissionsCard
                footer
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 640)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // User may have flipped a toggle in System Settings and come back.
            micState = AppPermissions.microphone
            screenState = AppPermissions.screenRecording
        }
        .onAppear {
            soniox = CredentialStore.soniox ?? ""
            llmKey = CredentialStore.value(for: LLMProviders.activeOption.keychainAccount) ?? ""
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to RTI")
                .font(.system(size: 24, weight: .bold))
            Text("A real-time meeting copilot — live transcription and an on-call assistant, in an overlay that stays out of your screen shares. Two quick steps and you're live.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 1: keys

    private var keysCard: some View {
        card(number: "1", title: "Add your API keys") {
            keyField(
                "Soniox API key",
                placeholder: "soniox-…",
                text: $soniox,
                help: "Live transcription.",
                linkTitle: "Get a key",
                linkURL: "https://console.soniox.com"
            )
            keyField(
                "\(providerName) API key",
                placeholder: LLMProviders.activeOption.apiKeyPlaceholder,
                text: $llmKey,
                help: "The assistant.",
                linkTitle: "Get a key",
                linkURL: LLMProviders.activeOption.consoleURL
            )
            if let saveError {
                Text(saveError).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button("Save provider keys") { saveKeys() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                if justSaved || keysConfigured {
                    Label(justSaved ? "Saved" : "Saved earlier", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.green)
                }
            }
            Text("Stored in an owner-only file on this Mac (~/Library/Application Support/RTI), never synced.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func keyField(_ label: String, placeholder: String, text: Binding<String>, help: String, linkTitle: String, linkURL: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 12, weight: .medium))
                Text(help).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let url = URL(string: linkURL) {
                    Link(linkTitle, destination: url).font(.system(size: 11))
                }
            }
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
        }
    }

    // MARK: - Step 2: permissions

    private var permissionsCard: some View {
        card(number: "2", title: "Grant permissions") {
            permissionRow(
                title: "Microphone",
                subtitle: "Required — RTI can't transcribe without it.",
                state: micState,
                grant: { AppPermissions.requestMicrophone { _ in micState = AppPermissions.microphone } },
                openSettings: AppPermissions.openMicrophoneSettings
            )
            Divider()
            permissionRow(
                title: "Screen Recording",
                subtitle: "Optional — lets ⌘⇧H read what's on your screen.",
                state: screenState,
                grant: {
                    _ = AppPermissions.requestScreenRecording()
                    screenState = AppPermissions.screenRecording
                },
                openSettings: AppPermissions.openScreenRecordingSettings
            )
        }
    }

    private func permissionRow(title: String, subtitle: String, state: AppPermissions.State, grant: @escaping () -> Void, openSettings: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .notDetermined:
                Button("Grant", action: grant)
            case .denied:
                Button("Open Settings", action: openSettings)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                if isReady {
                    Text("You're all set. Press ⌘⇧R anytime to start a session, ⌘\\ to toggle the overlay.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !keysConfigured {
                    Text("Add both keys to get started. You can finish later from the menubar → Settings.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Microphone access is still needed before your first session.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(isReady ? "Start using RTI" : "Done") { onDone() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Card chrome

    private func card(number: String, title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(number)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor))
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func saveKeys() {
        let s = soniox.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = llmKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !k.isEmpty else { saveError = "Both keys are required."; return }
        CredentialStore.setSoniox(s)
        CredentialStore.setValue(k, for: LLMProviders.activeOption.keychainAccount)
        guard CredentialStore.soniox == s,
              CredentialStore.value(for: LLMProviders.activeOption.keychainAccount) == k else {
            saveError = "Couldn't save keys. Check that ~/Library/Application Support/RTI is writable."
            return
        }
        saveError = nil
        keysConfigured = true
        justSaved = true
        Task { try? await Task.sleep(for: .seconds(1.5)); await MainActor.run { justSaved = false } }
    }
}
