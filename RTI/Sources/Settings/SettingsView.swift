import SwiftUI

struct SettingsView: View {
    var onClose: (() -> Void)? = nil

    var body: some View {
        TabView {
            KeysTab()
                .tabItem { Label("Keys", systemImage: "key.fill") }
            ModesTab()
                .tabItem { Label("Modes", systemImage: "square.stack.3d.up") }
            GlossaryTab()
                .tabItem { Label("Glossary", systemImage: "character.book.closed") }
            CalendarTab()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            CorpusTab()
                .tabItem { Label("Corpus", systemImage: "doc.text.magnifyingglass") }
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(width: 560, height: 460)
        .overlay(alignment: .bottomTrailing) {
            if let onClose {
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .padding(8)
            }
        }
    }
}

// MARK: - Keys

private struct KeysTab: View {
    @State private var deepseek = ""
    @State private var soniox = ""
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
        VStack(alignment: .leading, spacing: 16) {
            if isFirstRun {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to RTI")
                        .font(.system(size: 18, weight: .semibold))
                    Text("RTI needs two API keys to work: DeepSeek for the LLM, and Soniox for live transcription. Both stay in the macOS Keychain on this Mac.")
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

            field("DeepSeek API key", "sk-…", $deepseek)
            field("Soniox API key", "…", $soniox)

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

// MARK: - Modes

private struct ModesTab: View {
    private let store = ModeStore.shared
    @State private var selection: String?
    @State private var name = ""
    @State private var prompt = ""
    @State private var reference = ""
    @State private var saved = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
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
                HStack(spacing: 4) {
                    Button {
                        if let newId = store.addMode(
                            name: "New Mode",
                            systemPrompt: "You are RTI, a real-time intelligence assistant. Keep responses short and actionable."
                        ) {
                            selection = newId
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New mode")

                    Button {
                        guard let id = selection,
                              let mode = store.modes.first(where: { $0.id == id }),
                              !mode.isBuiltin else { return }
                        store.deleteMode(id: id)
                        selection = store.activeModeId ?? store.modes.first?.id
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection.flatMap { id in store.modes.first { $0.id == id } }?.isBuiltin ?? true)
                    .help("Delete mode (built-in modes cannot be deleted)")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
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
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        store.update(id: id, name: trimmedName, systemPrompt: prompt, referenceText: reference)
        saved = true
        Task { try? await Task.sleep(for: .seconds(1.2)); await MainActor.run { saved = false } }
    }
}

// MARK: - Calendar

private struct CalendarTab: View {
    private let calendar = CalendarManager.shared
    @State private var requestInProgress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Calendar")
                .font(.system(size: 16, weight: .semibold))

            if calendar.isAuthorized {
                Label("Calendar access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                Text("When you start a session, RTI looks at events happening right now in your default calendar. If it finds one, the event title becomes the session title and the attendees are attached for context. Nothing else is read or written — RTI never modifies your calendar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Calendar access not granted", systemImage: "xmark.circle.fill")
                    .foregroundStyle(Color.orange)
                Text("Without access, sessions are titled by date/time only. Granting access lets RTI auto-name sessions from the calendar event in progress when you start recording. Read-only — RTI never modifies your calendar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedInputUID: String = AudioInputDeviceStore.preferredUID
    @State private var crashLogAvailable: Bool = false

    @AppStorage(OverlayAppearanceDefaults.widthKey) private var overlayWidth: Double = OverlayAppearanceDefaults.defaultWidth
    @AppStorage(OverlayAppearanceDefaults.heightKey) private var overlayHeight: Double = OverlayAppearanceDefaults.defaultHeight
    @AppStorage(OverlayAppearanceDefaults.opacityKey) private var overlayOpacity: Double = OverlayAppearanceDefaults.defaultOpacity
    @AppStorage(AnalysisSettingsDefaults.notesEnabledKey) private var notesEnabled: Bool = true
    @AppStorage(AnalysisSettingsDefaults.notesIntervalKey) private var notesInterval: Double = AnalysisSettingsDefaults.defaultInterval
    @AppStorage(AnalysisSettingsDefaults.dossiersEnabledKey) private var dossiersEnabled: Bool = true
    @AppStorage(AnalysisSettingsDefaults.themesEnabledKey) private var themesEnabled: Bool = true
    @AppStorage(AnalysisSettingsDefaults.guideEnabledKey) private var guideEnabled: Bool = true

    var body: some View {
        // TODO(perf): extract sections into sub-views to limit redraws
        ScrollView {
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

            Text("Assistant")
                .font(.system(size: 13, weight: .medium))
            llmProviderRow
            Text("Provider is selected in code (`LLMProviders.activeId`). All providers must speak OpenAI-compatible streaming chat. Add your API key in the Keys tab.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 8)

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

            Divider().padding(.vertical, 8)

            Text("Real-Time Analysis")
                .font(.system(size: 13, weight: .medium))

            Toggle("Enable notes generation", isOn: $notesEnabled)
            Toggle("Enable dossier generation", isOn: $dossiersEnabled)
            Toggle("Enable themes & quotes generation", isOn: $themesEnabled)
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

            Text("Notes and dossiers generate automatically while recording. They appear in overlay panels you can open with ⌘⇧N and ⌘⇧D.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    notesEnabled = true
                    dossiersEnabled = true
                    themesEnabled = true
                    guideEnabled = true
                    notesInterval = AnalysisSettingsDefaults.defaultInterval
                }
                .controlSize(.small)
            }

            Divider().padding(.vertical, 8)

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

            Divider().padding(.vertical, 8)

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

            Divider().padding(.vertical, 8)

            Text("Data & Support")
                .font(.system(size: 13, weight: .medium))
            Text("Audio is streamed to Soniox for transcription. Transcripts and prompts are sent to your configured LLM provider (DeepSeek by default) to generate answers. Everything else — recordings, transcripts, chat history, summaries — stays on this Mac. See PRIVACY.md in the repo for the full picture.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Show RTI Folder") { revealRTIFolder() }
                Button("Show Crash Log") { revealCrashLog() }
                    .disabled(!crashLogAvailable)
                Button("View Logs…") { showLogs() }
            }

            Divider().padding(.vertical, 8)

            diagnosticsSection

            Spacer()
        }
        .padding(.bottom, 4)
        }
        .onAppear {
            inputDevices = AudioInputDeviceStore.availableInputDevices()
            crashLogAvailable = crashLogURL() != nil && FileManager.default.fileExists(atPath: crashLogURL()?.path ?? "")
        }
    }

    // MARK: - Assistant section

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

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsSection: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics")
                .font(.system(size: 13, weight: .medium))
            diagRow("Version", "RTI \(version) (\(build))")
            diagRow("Corpus", CorpusManager.shared.corpusDirectory.path)
            diagRow("Database", databasePath)
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

    private var databasePath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return base?.appendingPathComponent("RTI/rti.db").path ?? "(unknown)"
    }

    private func copyDiagnostics() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let provider = LLMProviders.active
        let lines = [
            "RTI \(version) (\(build))",
            "Platform: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Corpus: \(CorpusManager.shared.corpusDirectory.path)",
            "Database: \(databasePath)",
            "Provider: \(provider.displayName) · \(provider.model) · \(provider.baseURL.absoluteString)"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
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

    private func hotkeyRow(_ label: String, _ key: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(key).font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Corpus

private struct CorpusTab: View {
    @AppStorage(CorpusManager.corpusPathKey) private var corpusPath: String = ""
    @State private var copyConfirmation: String?
    @State private var reindexStatus: String?
    @State private var migratedCount: Int?
    @State private var corpusStats: (sessionCount: Int, projectCount: Int, synthesisCount: Int) = (0, 0, 0)

    private var resolvedPath: String {
        if corpusPath.isEmpty {
            return "~/meetings"
        }
        return (corpusPath as NSString).abbreviatingWithTildeInPath
    }

    private var bundledMCPBinary: String {
        // Use the bundled binary inside the running .app. Falls back to a
        // placeholder when running unbundled (development).
        if let resourceURL = Bundle.main.url(forResource: "rti-mcp", withExtension: nil) {
            return resourceURL.path
        }
        return "/Applications/RTI.app/Contents/Resources/rti-mcp"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Corpus")
                    .font(.system(size: 16, weight: .semibold))
                Text("Every meeting RTI records is written as a markdown file to this directory. The Corpus is the canonical store — RTI's database is a derived index over it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top) {
                    Text("Location:")
                    Text(resolvedPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Choose…") { chooseDirectory() }
                        HStack(spacing: 6) {
                            Button("Reveal") { revealInFinder() }
                                .controlSize(.small)
                            Button("Reset") { resetToDefault() }
                                .controlSize(.small)
                                .disabled(corpusPath.isEmpty)
                                .help("Revert to the default location (~/meetings)")
                        }
                    }
                }

                corpusStatsLine

                Divider().padding(.vertical, 8)

                Text("MCP Server")
                    .font(.system(size: 13, weight: .medium))
                Text("Expose the Corpus to external agents (Claude Desktop, Codex, OpenCode, Gemini CLI). Read-only. Agents can read your session markdown plus every project's PROJECT.md, synthesis.md, and chat history. Click below to copy a Claude-Desktop-shaped config snippet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Copy MCP Config") { copyMCPConfig() }
                if let copyConfirmation {
                    Text(copyConfirmation)
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }

                Divider().padding(.vertical, 8)

                Text("Maintenance")
                    .font(.system(size: 13, weight: .medium))
                HStack {
                    Button("Reindex Corpus") { reindex() }
                    if let reindexStatus {
                        Text(reindexStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Rebuilds the search index from markdown files. Useful after editing files outside RTI or after restoring a backup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let migratedCount, migratedCount > 0 {
                    Text("Migrated \(migratedCount) legacy session(s) from the database to the Corpus on first launch with this version.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }
        .onChange(of: corpusPath) { _, _ in
            NotificationCenter.default.post(name: .rtiSessionsChanged, object: nil)
            loadCorpusStats()
        }
        .onAppear { loadCorpusStats() }
    }

    @ViewBuilder
    private var corpusStatsLine: some View {
        HStack(spacing: 16) {
            Label("\(corpusStats.sessionCount) sessions", systemImage: "doc.text")
            Label("\(corpusStats.projectCount) projects", systemImage: "folder")
            if corpusStats.synthesisCount > 0 {
                Label("\(corpusStats.synthesisCount) synthesis", systemImage: "sparkles")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func loadCorpusStats() {
        let dir = CorpusManager.shared.corpusDirectory
        let sessionCount = (try? CorpusReader.listMarkdownFiles(in: dir).count) ?? 0
        let projectCount = ProjectStore.shared.projects.count
        let projectsDir = dir.appendingPathComponent("projects", isDirectory: true)
        let synthesisCount: Int = {
            guard let folders = try? FileManager.default.contentsOfDirectory(
                at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return 0 }
            return folders.filter {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("synthesis.md").path)
            }.count
        }()
        corpusStats = (sessionCount, projectCount, synthesisCount)
    }

    private func revealInFinder() {
        let dir = CorpusManager.shared.corpusDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func resetToDefault() {
        // Surface the same confirmation the picker uses — resetting is a
        // corpus switch like any other, and projects can be orphaned by
        // it if the default dir doesn't contain the same sessions.
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("meetings", isDirectory: true)
        if defaultDir.path == resolvedPath { return }

        let oldDir = URL(fileURLWithPath: resolvedPath)
        let oldSessionCount = (try? CorpusReader.listMarkdownFiles(in: oldDir).count) ?? 0
        let newSessionCount = (try? CorpusReader.listMarkdownFiles(in: defaultDir).count) ?? 0
        let projectCount = ProjectStore.shared.projects.count

        let alert = NSAlert()
        alert.messageText = "Reset corpus to default?"
        alert.informativeText = """
        Current:  \(oldDir.path)
        \(oldSessionCount) session\(oldSessionCount == 1 ? "" : "s"), \(projectCount) project\(projectCount == 1 ? "" : "s").

        Default:  \(defaultDir.path)
        \(newSessionCount) session\(newSessionCount == 1 ? "" : "s") found there.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        corpusPath = ""
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Corpus directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Pointing at the same directory is a no-op.
        let newPath = url.path
        if newPath == resolvedPath { return }

        // Surface migration consequences before flipping the switch. The
        // existing corpus has N sessions and M projects; the new dir
        // either contains them or it doesn't. We can't move files for
        // the user (their iCloud / sync setup may already cover that),
        // but we can stop them from silently degrading projects whose
        // sessions are about to become unreachable.
        let oldDir = URL(fileURLWithPath: resolvedPath)
        let newDir = url
        let oldSessionCount = (try? CorpusReader.listMarkdownFiles(in: oldDir).count) ?? 0
        let newSessionCount = (try? CorpusReader.listMarkdownFiles(in: newDir).count) ?? 0
        let projectCount = ProjectStore.shared.projects.count

        let alert = NSAlert()
        alert.messageText = "Switch corpus directory?"
        alert.informativeText = """
        Current:  \(oldDir.path)
        \(oldSessionCount) session\(oldSessionCount == 1 ? "" : "s"), \(projectCount) project\(projectCount == 1 ? "" : "s").

        New:  \(newDir.path)
        \(newSessionCount) session\(newSessionCount == 1 ? "" : "s") found there.

        Projects keep their session-id references after the switch. Sessions present in the old corpus but missing from the new one will appear as orphaned members until you point back to the old corpus or copy the files over.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        corpusPath = newPath
    }

    private func copyMCPConfig() {
        let cfg: [String: Any] = [
            "mcpServers": [
                "rti": [
                    "command": bundledMCPBinary,
                    "args": ["--corpus", resolvedPath]
                ]
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted])) ?? Data()
        let str = String(data: data, encoding: .utf8) ?? "{}"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(str, forType: .string)
        copyConfirmation = "Copied. Paste into your agent's MCP server config."
        Task { try? await Task.sleep(for: .seconds(4)); await MainActor.run { self.copyConfirmation = nil } }
    }

    private func reindex() {
        reindexStatus = "Reindexing…"
        let corpusDir = CorpusManager.shared.corpusDirectory
        let dbPool = RTIDatabase.shared.pool
        Task.detached {
            do {
                try CorpusFTSReindexer.reindex(
                    from: corpusDir,
                    in: dbPool
                )
                try CorpusIndexer.reindex(from: corpusDir, in: dbPool)
                await MainActor.run { reindexStatus = "Done." }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    if reindexStatus == "Done." { reindexStatus = nil }
                }
            } catch {
                await MainActor.run { reindexStatus = "Failed: \(error)" }
            }
        }
    }
}

// MARK: - Glossary

private struct GlossaryTab: View {
    @Bindable private var store = GlossaryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Glossary")
                .font(.headline)
            Text("Names, acronyms, and domain terms the assistant should use **exactly as written**. RTI sends these to the model as a system instruction before every chat, summary, and recall call — so the LLM picks up jargon, proper names, and your in-house spellings instead of guessing from context.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Format: one entry per line — `Term — meaning`. Separator can be em-dash (`—`), colon (`:`), or hyphen (`-`). Lines starting with `#` are ignored (use them as section headers). Caps at 200 entries so the prompt stays bounded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Examples")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text("""
            # People
            Alec — head of design (often misheard as "Alex")
            Jane — Acme marketing lead

            # Projects
            NSW — Acme Sportswear zone
            ICP — Ideal Customer Profile
            """)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.06))
                )

            TextEditor(text: $store.rawText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )

            let count = store.entries.count
            Text(count == 0 ? "No entries parsed yet — the glossary is not currently sent to the model." : "\(count) entr\(count == 1 ? "y" : "ies") parsed. Sent as a system instruction with every LLM call.")
                .font(.caption)
                .foregroundStyle(count == 0 ? Color.secondary : Color.green)
            Spacer(minLength: 0)
        }
        .padding(8)
    }
}
