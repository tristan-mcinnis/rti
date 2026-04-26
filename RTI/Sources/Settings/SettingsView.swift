import SwiftUI

struct SettingsView: View {
    var onClose: () -> Void = {}

    var body: some View {
        TabView {
            KeysTab()
                .tabItem { Label("Keys", systemImage: "key.fill") }
            ModesTab()
                .tabItem { Label("Modes", systemImage: "square.stack.3d.up") }
            CalendarTab()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(width: 560, height: 460)
        .overlay(alignment: .bottomTrailing) {
            Button("Close") { onClose() }
                .keyboardShortcut(.cancelAction)
                .padding(8)
        }
    }
}

// MARK: - Keys

private struct KeysTab: View {
    @State private var kimi = ""
    @State private var soniox = ""
    @State private var saved = false

    private var isFirstRun: Bool {
        kimi.isEmpty && soniox.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isFirstRun {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to RTI")
                        .font(.system(size: 18, weight: .semibold))
                    Text("RTI needs two API keys to work: Kimi (Moonshot) for the LLM, and Soniox for live transcription. Both stay in the macOS Keychain on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("API Keys")
                    .font(.system(size: 16, weight: .semibold))
                Text("Stored in macOS Keychain. Required to use RTI.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            field("Kimi (Moonshot) API key", "sk-…", $kimi)
            field("Soniox API key", "…", $soniox)

            HStack {
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(kimi.trimmingCharacters(in: .whitespaces).isEmpty &&
                              soniox.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer()
        }
        .onAppear {
            kimi = CredentialStore.kimi ?? ""
            soniox = CredentialStore.soniox ?? ""
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
        let k = kimi.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = soniox.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { CredentialStore.setKimi(k) }
        if !s.isEmpty { CredentialStore.setSoniox(s) }
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { saved = false }
    }
}

// MARK: - Modes

private struct ModesTab: View {
    @ObservedObject private var store = ModeStore.shared
    @State private var selection: String?
    @State private var name = ""
    @State private var prompt = ""
    @State private var reference = ""
    @State private var saved = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            List(selection: $selection) {
                ForEach(store.modes) { mode in
                    HStack {
                        Text(mode.name)
                        if mode.id == store.activeModeId {
                            Spacer()
                            Text("Active").font(.system(size: 10)).foregroundStyle(.blue)
                        }
                    }
                    .tag(Optional(mode.id))
                }
            }
            .frame(width: 160)

            VStack(alignment: .leading, spacing: 10) {
                if selection != nil {
                    Text("Name").font(.system(size: 12, weight: .medium))
                    TextField("Mode name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    Text("System prompt").font(.system(size: 12, weight: .medium))
                    TextEditor(text: $prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 100)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                    Text("Reference text (prepended to every turn, capped at 8k chars)")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $reference)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                    HStack {
                        Button("Set Active") {
                            if let id = selection { store.activeModeId = id }
                        }
                        .disabled(selection == store.activeModeId)

                        Spacer()

                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.green)
                        }

                        Button("Save") { save() }
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Text("Select a mode to edit.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if selection == nil { selection = store.activeModeId ?? store.modes.first?.id }
            loadSelection()
        }
        .onChange(of: selection) { _, _ in loadSelection() }
    }

    private func loadSelection() {
        guard let id = selection, let mode = store.modes.first(where: { $0.id == id }) else { return }
        name = mode.name
        prompt = mode.systemPrompt
        reference = mode.referenceText ?? ""
    }

    private func save() {
        guard let id = selection else { return }
        store.update(id: id, name: name, systemPrompt: prompt, referenceText: reference)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { saved = false }
    }
}

// MARK: - Calendar

private struct CalendarTab: View {
    @ObservedObject private var calendar = CalendarManager.shared
    @State private var requestInProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calendar")
                .font(.system(size: 16, weight: .semibold))

            if calendar.isAuthorized {
                Label("Calendar access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("RTI will detect active meetings when a session starts and attach the event title to the session.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Label("Calendar access not granted", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Grant access so RTI can detect active meetings from your calendar when recording starts.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button(action: requestAccess) {
                    if requestInProgress {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text("Grant Calendar Access")
                    }
                }
                .disabled(requestInProgress)
            }

            Spacer()
        }
    }

    private func requestAccess() {
        requestInProgress = true
        Task {
            _ = await calendar.requestAccess()
            await MainActor.run {
                requestInProgress = false
            }
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("General")
                .font(.system(size: 16, weight: .semibold))

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

            Divider().padding(.vertical, 8)

            Text("Hotkeys")
                .font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: 4) {
                hotkeyRow("Toggle overlay", "⌘ \\")
                hotkeyRow("Start / stop session", "⌘ ⇧ R")
                hotkeyRow("Assist (from any app)", "⌘ ↵")
                hotkeyRow("Attach screenshot", "⌘ H")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            Text("Hotkeys are fixed in this build; customization is planned. The overlay's \"…\" menu lists the same keybinds for quick access.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 8)

            Text("Data & Support")
                .font(.system(size: 13, weight: .medium))
            Text("All session data — transcripts, audio, chat history, summaries — stays on this Mac. Nothing is uploaded except the prompts you send to Kimi and the audio you stream to Soniox.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Show RTI Folder") { revealRTIFolder() }
                Button("Show Crash Log") { revealCrashLog() }
                    .disabled(crashLogURL() == nil || !FileManager.default.fileExists(atPath: crashLogURL()?.path ?? ""))
            }

            Spacer()

            // Version footer — useful when reporting an issue.
            Text(versionFooter)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var versionFooter: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "RTI \(version) (\(build))"
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

    private func hotkeyRow(_ label: String, _ key: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(key).font(.system(.body, design: .monospaced))
        }
    }
}
