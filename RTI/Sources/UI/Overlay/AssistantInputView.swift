import RTICore
import SwiftUI
import UniformTypeIdentifiers

struct AssistantInputView: View {
    var onOpenSettings: () -> Void = {}

    @State private var input: String = ""
    @State private var isDropTargeted = false
    @State private var selectedSlashIndex = 0
    @FocusState private var isInputFocused: Bool
    @AppStorage(OverlayAppearanceDefaults.invisibilityKey) private var isHiddenFromCapture: Bool = true
    @AppStorage(OverlayAppearanceDefaults.opacityKey) private var backgroundOpacity: Double = OverlayAppearanceDefaults.defaultOpacity
    private let llm = LLMController.shared
    private let modes = ModeStore.shared
    private let session = SessionCoordinator.shared
    private let inputState = OverlayInputState.shared

    /// Discrete opacity presets — SwiftUI's `Menu` does not render `Slider`
    /// interactively, so we expose a submenu of fixed steps instead.
    private let opacityPresets: [Double] = [0.20, 0.40, 0.60, 0.75, 0.85, 0.95, 1.00]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showSlashCommands {
                slashCommandBar
            }

            if shouldShowContextDashboard {
                contextDashboard
            }

            // One composer pill: leading actions, flexible field, trailing send.
            HStack(spacing: 6) {
                actionsMenu
                moreDots
                if session.isRunning {
                    noteModeToggle
                }

                ZStack(alignment: .leading) {
                    if input.isEmpty {
                        Text(textFieldPrompt)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.overlayInk.opacity(0.45))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.overlayInk.opacity(0.95))
                        .focused($isInputFocused)
                        .onSubmit(submit)
                }
                .frame(maxWidth: .infinity)
                .padding(.leading, 2)

                if llm.streaming {
                    stopButton
                } else {
                    sendButton
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.overlayInk.opacity(isDropTargeted ? 0.12 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isDropTargeted
                                ? Color.blue.opacity(0.7)
                                : (inputState.isNoteMode
                                    ? Color.yellow.opacity(0.55)
                                    : Color.overlayInk.opacity(0.10)),
                                lineWidth: isDropTargeted ? 1.5 : 1)
                    )
            )
        }
        // Drop an image here → it's OCR'd on-device and attached as context for
        // the next message (same path as ⌘⇧H screen capture; no image is sent
        // to the model, only the extracted text).
        .onDrop(of: [.image], isTargeted: $isDropTargeted) { providers in
            handleImageDrop(providers)
        }
        // A draft typed during one meeting must not survive into the next —
        // an accidental ⏎ would send stale text into the wrong conversation.
        .onReceive(NotificationCenter.default.publisher(for: .rtiSessionDidStop)) { _ in
            input = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiOverlayDidBecomeKey)) { _ in
            // Defer so the focus change lands after the panel finishes its
            // becomeKey transition; otherwise SwiftUI sometimes drops it.
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
        .onChange(of: input) { _, _ in
            selectedSlashIndex = 0
        }
        .onMoveCommand { direction in
            guard showSlashCommands else { return }
            switch direction {
            case .down, .right:
                moveSlashSelection(1)
            case .up, .left:
                moveSlashSelection(-1)
            default:
                break
            }
        }
    }

    private var contextDashboard: some View {
        HStack(spacing: 6) {
            let labels = llm.contextPreviewLabels().filter { $0 != "Screen OCR" }
            if !labels.isEmpty {
                Menu {
                    Section("Context") {
                        ForEach(labels, id: \.self) { label in
                            Label(label, systemImage: "checkmark")
                        }
                    }
                    Section("Tools") {
                        ForEach(llm.toolPreviewLabels(), id: \.self) { label in
                            Text(label)
                        }
                    }
                } label: {
                    miniPill(contextSummary(labels), icon: "scope", active: true)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Context and tools available to the next message")
            }

            if llm.pendingScreenContext != nil {
                Button {
                    llm.clearPendingScreenContext()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.viewfinder")
                        Text("Screen · once")
                        Image(systemName: "xmark")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.blue.opacity(0.95))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .help("Remove screen OCR from the next message")
            }

            if llm.smartMode {
                miniPill("Smart", icon: "sparkles", active: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
    }

    private var shouldShowContextDashboard: Bool {
        !llm.contextPreviewLabels().filter { $0 != "Screen OCR" }.isEmpty
            || llm.pendingScreenContext != nil
            || llm.smartMode
    }

    private func contextSummary(_ labels: [String]) -> String {
        guard let first = labels.first else { return "Context" }
        if labels.count == 1 { return first }
        return "\(first) +\(labels.count - 1)"
    }

    private var showSlashCommands: Bool {
        input.hasPrefix("/") && !input.contains(" ") && !input.contains("\n")
    }

    private var slashCommandBar: some View {
        HStack(spacing: 5) {
            ForEach(Array(visibleSlashCommands.enumerated()), id: \.element.id) { idx, command in
                Button {
                    performSlashCommand(command.id)
                    input = ""
                    DispatchQueue.main.async { isInputFocused = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: command.symbol)
                        Text(command.label)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.overlayInk.opacity(idx == selectedSlashIndex ? 0.92 : 0.68))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.overlayInk.opacity(idx == selectedSlashIndex ? 0.12 : 0.06)))
                    .overlay(
                        Capsule().stroke(Color.overlayInk.opacity(idx == selectedSlashIndex ? 0.16 : 0), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(command.help)
            }
            Spacer(minLength: 0)
        }
    }

    private var visibleSlashCommands: [SlashCommand] {
        Array(filteredSlashCommands.prefix(6))
    }

    private var filteredSlashCommands: [SlashCommand] {
        let q = input.dropFirst().lowercased()
        guard !q.isEmpty else { return slashCommands }
        return slashCommands.filter { $0.id.contains(q) || $0.label.lowercased().contains(q) }
    }

    private var slashCommands: [SlashCommand] {
        [
            SlashCommand(id: "assist", label: "Assist", symbol: "sparkles", help: "Suggest what to do next"),
            SlashCommand(id: "say", label: "Say next", symbol: "wand.and.rays", help: "Draft a quick reply"),
            SlashCommand(id: "followups", label: "Follow-ups", symbol: "bubble.left.and.text.bubble.right", help: "Generate follow-up questions"),
            SlashCommand(id: "recap", label: "Recap", symbol: "arrow.clockwise", help: "Recap the recent conversation"),
            SlashCommand(id: "summary", label: "Summary", symbol: "doc.text", help: "Summarize the full session"),
            SlashCommand(id: "note", label: "Note", symbol: "note.text", help: "Insert a live note"),
            SlashCommand(id: "screen", label: "Screen", symbol: "camera.viewfinder", help: "Attach screen OCR to the next message"),
            SlashCommand(id: "recent", label: "Recent", symbol: "calendar", help: "Ask about recent project meetings"),
        ]
    }

    private func moveSlashSelection(_ delta: Int) {
        let count = visibleSlashCommands.count
        guard count > 0 else { return }
        selectedSlashIndex = (selectedSlashIndex + delta + count) % count
    }

    private func miniPill(_ text: String, icon: String?, active: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .truncationMode(.tail)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(active ? Color.overlayInk.opacity(0.58) : Color.overlayInk.opacity(0.38))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.overlayInk.opacity(active ? 0.055 : 0.035)))
    }

    private var moreDots: some View {
        Menu {
            Menu("Opacity — \(Int(backgroundOpacity * 100))%") {
                ForEach(opacityPresets, id: \.self) { value in
                    Button {
                        backgroundOpacity = value
                    } label: {
                        if abs(value - backgroundOpacity) < 0.01 {
                            Label("\(Int(value * 100))%", systemImage: "checkmark")
                        } else {
                            Text("\(Int(value * 100))%")
                        }
                    }
                }
            }

            Divider()

            // Panel housekeeping only — AI actions live in the ✦ menu.
            Section("Panel") {
                Button {
                    NotificationCenter.default.post(name: .rtiToggleOverlay, object: nil)
                } label: {
                    Label("Show / hide overlay", systemImage: "rectangle.dashed")
                }
                .keyboardShortcut("\\", modifiers: .command)

                Button {
                    SessionCoordinator.shared.toggleSession()
                } label: {
                    Label(session.isRunning ? "Stop session" : "Start session",
                          systemImage: session.isRunning ? "stop.circle" : "mic")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button {
                    ScreenshotManager.shared.captureAndAttach()
                } label: {
                    Label("Capture screen under cursor", systemImage: "camera.viewfinder")
                }
                .keyboardShortcut("h", modifiers: .command)
                .help("Reads the whole display your mouse is on (not a single window) via on-device OCR, then attaches the text to your next message.")

                Button {
                    NotificationCenter.default.post(name: .rtiClearChat, object: nil)
                } label: {
                    Label("Clear chat", systemImage: "eraser")
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            Menu {
                ForEach(LLMProviders.all) { provider in
                    Button {
                        LLMProviders.activeId = provider.id
                    } label: {
                        if provider.id == LLMProviders.activeId {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }
                }
            } label: {
                Label("Assistant provider", systemImage: "sparkles.rectangle.stack")
            }

            Menu {
                ForEach(STTProviders.all, id: \.id) { provider in
                    Button {
                        STTProviders.activeId = provider.id
                    } label: {
                        if provider.id == STTProviders.activeId {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }
                }
            } label: {
                Label("Transcription provider", systemImage: "waveform.badge.mic")
            }

            Menu {
                ForEach(modes.modes) { mode in
                    Button {
                        modes.activeModeId = mode.id
                    } label: {
                        if mode.id == modes.activeModeId {
                            Label(mode.name, systemImage: "checkmark")
                        } else {
                            Text(mode.name)
                        }
                    }
                }
            } label: {
                Label("Modes", systemImage: "square.stack.3d.up")
            }

            recentSessionsSection

            Divider()

            Button(action: toggleHiddenFromCapture) {
                if isHiddenFromCapture {
                    Label("Hidden from Screen Capture", systemImage: "checkmark")
                } else {
                    Text("Hidden from Screen Capture")
                }
            }

            Divider()

            Button(action: onOpenSettings) {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        } label: {
            // Menu's .borderlessButton style was recoloring the SF Symbol back
            // to the system label color (black on the dark overlay), which made
            // the dots invisible even though the hit target still worked. Force
            // the symbol to render monochrome with an explicit white tint, and
            // pin the surrounding Menu's tint so it doesn't override us.
            Image(systemName: "ellipsis")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.overlayInk.opacity(0.7))
                .frame(width: 28, height: 26)
                .background(Capsule().fill(Color.overlayInk.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Color.overlayInk.opacity(0.7))
        .frame(width: 28)
        .accessibilityLabel("More actions")
        .accessibilityHint("Quick actions and settings")
        .help("Quick actions and settings")
    }

    private var noteModeToggle: some View {
        Button {
            inputState.isNoteMode.toggle()
            DispatchQueue.main.async {
                isInputFocused = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: inputState.isNoteMode ? "note.text" : "text.cursor")
                    .font(.system(size: 10, weight: .semibold))
                Text(inputState.isNoteMode ? "Note" : "Chat")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(inputState.isNoteMode ? Color.yellow.opacity(0.95) : Color.overlayInk.opacity(0.7))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    inputState.isNoteMode
                        ? Color.yellow.opacity(0.14)
                        : Color.overlayInk.opacity(0.06)
                )
            )
            .overlay(
                Capsule()
                    .stroke(
                        inputState.isNoteMode
                            ? Color.yellow.opacity(0.4)
                            : Color.overlayInk.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(inputState.isNoteMode ? "Switch to chat mode" : "Switch to note mode")
        .help(inputState.isNoteMode ? "Note mode on — next Enter inserts inline into the transcript" : "Chat mode on — toggle to drop a quick note into the transcript")
    }

    /// Saved session records — opens the in-app read-only browser (Sessions
    /// tab of the control window). Finder stays available from inside the
    /// browser for anyone who wants the raw folders.
    @ViewBuilder
    private var recentSessionsSection: some View {
        Divider()
        Button {
            WindowCoordinator.shared.showSessionsControl(tab: .sessions)
        } label: {
            Label("Past sessions…", systemImage: "clock.arrow.circlepath")
        }
    }

    /// Leading "✦" button — folds the prompt actions (Assist / What should I
    /// say? / Follow-ups / Recap), the Smart toggle, and Note mode into one
    /// menu so the composer reclaims the whole action row. The glyph tints blue
    /// when Smart is on, preserving at-a-glance state without a permanent pill.
    private var actionsMenu: some View {
        Menu {
            // Mode-aware: the visible actions follow the active mode + listener
            // state (a fieldwork observer gets "Key tensions / What's unsaid /
            // Themes", not "What should I say"). One source of truth lives in
            // AssistantAction.all (RTICore).
            ForEach(llm.availableQuickActions()) { action in
                Button { llm.perform(actionID: action.id) } label: {
                    Label(actionLabel(action), systemImage: action.symbol)
                }
            }

            Divider()

            Menu("⌘⏎ runs: \(AssistantAction.byID(llm.primaryActionID)?.label ?? "Assist")") {
                ForEach(AssistantAction.primaryEligibleActions) { action in
                    Button {
                        llm.primaryActionID = action.id
                    } label: {
                        if llm.primaryActionID == action.id {
                            Label(action.label, systemImage: "checkmark")
                        } else {
                            Text(action.label)
                        }
                    }
                }
            }

            // How long ⌘⌥R (and the primary action, when set to Recap) runs.
            // Sticky default; one-shot brief/detailed live in the palette.
            Menu("Recap depth: \(llm.recapDepth.label)") {
                ForEach(RecapDepth.allCases, id: \.rawValue) { depth in
                    Button {
                        llm.recapDepth = depth
                    } label: {
                        if llm.recapDepth == depth {
                            Label(depth.label, systemImage: "checkmark")
                        } else {
                            Text(depth.label)
                        }
                    }
                }
            }

            Button { llm.listenerMode.toggle() } label: {
                if llm.listenerMode {
                    Label("Listener mode (I'm not speaking)", systemImage: "checkmark")
                } else {
                    Label("Listener mode (I'm not speaking)", systemImage: "ear")
                }
            }

            Button(action: applyFieldworkPreset) {
                Label("Fieldwork preset (interview + listener)", systemImage: "person.2.wave.2")
            }
            .help("Interview mode + listener mode + ⌘⏎ → Assist in one click; pick the project in Setup")

            Divider()

            Button { llm.smartMode.toggle() } label: {
                if llm.smartMode {
                    Label("Smart mode (slower, deeper)", systemImage: "checkmark")
                } else {
                    Label("Smart mode (slower, deeper)", systemImage: "sparkles")
                }
            }

            if session.isRunning {
                Button { inputState.isNoteMode.toggle() } label: {
                    if inputState.isNoteMode {
                        Label("Note mode", systemImage: "checkmark")
                    } else {
                        Label("Note mode", systemImage: "note.text")
                    }
                }
            }
        } label: {
            Image(systemName: "sparkles")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(llm.smartMode ? Color.blue : Color.overlayInk.opacity(0.7))
                .frame(width: 28, height: 26)
                .background(Capsule().fill(llm.smartMode
                        ? Color.blue.opacity(0.16)
                        : Color.overlayInk.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Color.overlayInk.opacity(0.7))
        .frame(width: 28)
        .accessibilityLabel("Assist actions")
        .accessibilityHint(llm.smartMode ? "Assist actions. Smart mode is on." : "Assist actions")
        .help(llm.smartMode ? "Assist actions · Smart on" : "Assist actions")
    }

    private var sendButton: some View {
        let isEmpty = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.overlayInk.opacity(isEmpty ? 0.45 : 1.0))
                .frame(width: 34, height: 30)
                .background(
                    Capsule().fill(Color.overlayInk.opacity(isEmpty ? 0.06 : 0.10))
                )
                .liquidMetalBorder(Capsule(), lineWidth: 1.2, period: 4.0, glow: 5, active: !isEmpty)
        }
        .buttonStyle(.plain)
        .disabled(isEmpty || llm.streaming)
        .accessibilityLabel("Send message")
        .accessibilityHint("Send the current message")
        .help("Send message (return)")
    }

    private var stopButton: some View {
        Button(action: { llm.cancel() }) {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 30)
                .background(Capsule().fill(Color.red.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop streaming")
        .accessibilityHint("Stop the current assistant response")
        .help("Stop streaming response")
    }

    private var textFieldPrompt: String {
        if inputState.isNoteMode {
            return "Quick note — Enter inserts inline, then returns to chat"
        }
        return "Ask, drop an image, or ⌘↵ for Assist"
    }

    /// Menu label for a quick action: append "⌘⏎" when it's the bound primary,
    /// otherwise its own hotkey hint (if any). Hints mirror CommandPaletteFactory.
    private func actionLabel(_ action: AssistantAction) -> String {
        if action.id == llm.primaryActionID {
            return "\(action.label)  ⌘⏎"
        }
        let hint = action.hotkey?.display ?? ""
        return hint.isEmpty ? action.label : "\(action.label)  \(hint)"
    }

    /// Route through the registered command so the menubar item and command
    /// palette share one toggle path that both persists the flag and applies
    /// sharingType to every panel.
    private func toggleHiddenFromCapture() {
        CommandRegistry.shared.commands.first { $0.id == "invisibility.toggle" }?.perform()
    }

    /// One-click setup for sitting in on fieldwork (FGD/IDI as an observer):
    /// Interview mode + listener mode + ⌘⏎ bound to Assist. The workstream
    /// (project) still gets picked in Setup — that's a per-meeting fact.
    private func applyFieldworkPreset() {
        if let interview = modes.modes.first(where: { $0.name.localizedCaseInsensitiveContains("interview") }) {
            modes.activeModeId = interview.id
        }
        llm.listenerMode = true
        llm.primaryActionID = "assist"
    }

    /// Load the first dropped image and hand it to ScreenshotManager for
    /// on-device OCR → attach as pending context. Returns true if we took it.
    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSImage.self) { object, _ in
            guard let image = object as? NSImage else { return }
            Task { @MainActor in ScreenshotManager.shared.attachDroppedImage(image) }
        }
        return true
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if inputState.isNoteMode {
            if SessionCoordinator.shared.insertNote(text) {
                input = ""
                inputState.isNoteMode = false
                DispatchQueue.main.async {
                    isInputFocused = true
                }
            }
        } else {
            if text.hasPrefix("/") {
                if performSlashSubmit(String(text.dropFirst())) {
                    input = ""
                }
                DispatchQueue.main.async { isInputFocused = true }
                return
            }
            llm.sendAskAnything(text)
            input = ""
        }
    }

    @discardableResult
    private func performSlashSubmit(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("note ") {
            let noteText = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard SessionCoordinator.shared.insertNote(noteText) else { return false }
            inputState.isNoteMode = false
            return true
        }

        if showSlashCommands, let command = visibleSlashCommands[safe: selectedSlashIndex] {
            return performSlashCommand(command.id)
        }

        return performSlashCommand(trimmed)
    }

    @discardableResult
    private func performSlashCommand(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "assist":
            llm.sendAssist()
        case "say", "saynext":
            llm.sendSaySomething()
        case "followups", "followup":
            llm.sendFollowupQuestions()
        case "recap":
            llm.sendRecap()
        case "summary", "summarize":
            llm.sendSummary()
        case "note":
            inputState.isNoteMode = true
        case "screen":
            ScreenshotManager.shared.captureAndAttach()
        case "recent":
            llm.sendAskAnything("What were the most recent meetings or sessions for this project? Use the recent meetings tool if project context is available.")
        default:
            return false
        }
        return true
    }
}

private struct SlashCommand: Identifiable {
    let id: String
    let label: String
    let symbol: String
    let help: String
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
