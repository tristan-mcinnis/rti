import SwiftUI

struct SettingsView: View {
    @State private var kimi: String = ""
    @State private var soniox: String = ""
    @State private var saved: Bool = false
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("API Keys")
                .font(.system(size: 16, weight: .semibold))

            Text("Stored in macOS Keychain. Required to use RTI.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            field(label: "Kimi (Moonshot) API key", placeholder: "sk-…", text: $kimi)
            field(label: "Soniox API key", placeholder: "…", text: $soniox)

            HStack {
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Close") { onClose() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(kimi.trimmingCharacters(in: .whitespaces).isEmpty &&
                              soniox.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            kimi = CredentialStore.kimi ?? ""
            soniox = CredentialStore.soniox ?? ""
        }
    }

    private func field(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
        }
    }

    private func save() {
        let k = kimi.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = soniox.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { CredentialStore.setKimi(k) }
        if !s.isEmpty { CredentialStore.setSoniox(s) }
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { saved = false }
    }
}
