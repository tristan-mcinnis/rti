import SwiftUI

struct AssistantInputView: View {
    var onOpenSettings: () -> Void = {}

    @State private var input: String = ""
    @FocusState private var isInputFocused: Bool
    @AppStorage("rti.invisible") private var isHiddenFromCapture: Bool = true
    private let llm = LLMController.shared
    private let modes = ModeStore.shared
    private let session = SessionCoordinator.shared
    private let inputState = OverlayInputState.shared

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if input.isEmpty {
                        Text(textFieldPrompt)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.45))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.95))
                        .focused($isInputFocused)
                        .onSubmit(submit)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(inputState.isNoteMode
                                    ? Color.yellow.opacity(0.55)
                                    : Color.white.opacity(0.10),
                                    lineWidth: 1)
                    )
            )

            HStack(spacing: 10) {
                moreDots
                smartPill
                if session.isRunning { recordingBadge }
                Spacer()
                if llm.streaming {
                    stopButton
                } else {
                    sendButton
                }
            }
            .padding(.horizontal, 4)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiOverlayDidBecomeKey)) { _ in
            // Defer so the focus change lands after the panel finishes its
            // becomeKey transition; otherwise SwiftUI sometimes drops it.
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
    }

    private var recordingBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text("Recording")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.red.opacity(0.18)))
        .help("Audio is being captured and transcribed. Press ⌘⇧R to stop.")
    }

    private var moreDots: some View {
        Menu {
            Section("Keybinds") {
                Button {
                    NotificationCenter.default.post(name: .rtiToggleOverlay, object: nil)
                } label: {
                    Label("Show / hide overlay", systemImage: "rectangle.dashed")
                }
                .keyboardShortcut("\\", modifiers: .command)

                Button {
                    LLMController.shared.sendAssist()
                } label: {
                    Label("Assist", systemImage: "sparkles")
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button {
                    NotificationCenter.default.post(name: .rtiClearChat, object: nil)
                } label: {
                    Label("Clear chat", systemImage: "eraser")
                }

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
                    Label("Attach screenshot", systemImage: "camera.viewfinder")
                }
                .keyboardShortcut("h", modifiers: .command)

                Button {
                    NotificationCenter.default.post(name: .rtiShowLiveTranscript, object: nil)
                } label: {
                    Label("Show live transcript", systemImage: "waveform")
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
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
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 28, height: 26)
                .background(Capsule().fill(Color.white.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.white.opacity(0.7))
        .frame(width: 28)
        .help("Quick actions and settings")
    }

    private var smartPill: some View {
        Button(action: { llm.smartMode.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text("Smart")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(llm.smartMode ? 1.0 : 0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(llm.smartMode
                               ? Color.blue
                               : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .disabled(llm.streaming)
        .help(llm.smartMode ? "Smart: deepseek-v4-flash with thinking (slower, deeper)" : "Fast: deepseek-v4-flash (tap to switch to Smart)")
    }

    private var sendButton: some View {
        let isEmpty = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(isEmpty ? 0.45 : 1.0))
                .frame(width: 34, height: 30)
                .background(
                    Capsule().fill(Color.white.opacity(isEmpty ? 0.06 : 0.10))
                )
                .liquidMetalBorder(Capsule(), lineWidth: 1.2, period: 4.0, glow: 5, active: !isEmpty)
        }
        .buttonStyle(.plain)
        .disabled(isEmpty || llm.streaming)
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
        .help("Stop streaming response")
    }

    private var textFieldPrompt: String {
        if inputState.isNoteMode {
            return "Type a note — Enter inserts inline into the transcript"
        }
        return "Ask about your screen or conversation — ⌘↵ for Assist"
    }

    /// Route through the registered command so the menubar item, command
    /// palette, and pill menu all share one toggle path that both persists
    /// the flag and applies sharingType to every panel.
    private func toggleHiddenFromCapture() {
        CommandRegistry.shared.commands.first { $0.id == "invisibility.toggle" }?.perform()
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if inputState.isNoteMode {
            if SessionCoordinator.shared.insertNote(text) {
                input = ""
            }
        } else {
            llm.sendAskAnything(text)
            input = ""
        }
    }
}
