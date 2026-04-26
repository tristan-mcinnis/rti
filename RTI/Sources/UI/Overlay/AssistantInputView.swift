import SwiftUI

struct AssistantInputView: View {
    var onOpenSettings: () -> Void = {}

    @State private var input: String = ""
    @ObservedObject private var llm = LLMController.shared
    @ObservedObject private var modes = ModeStore.shared
    @ObservedObject private var session = SessionCoordinator.shared

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField("Ask about your screen or conversation, or ⌘↵ for Assist", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.95))
                    .onSubmit(submit)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )

            HStack(spacing: 10) {
                moreDots
                smartPill
                Spacer()
                if llm.streaming {
                    stopButton
                } else {
                    sendButton
                }
            }
            .padding(.horizontal, 4)
        }
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

            Button(action: onOpenSettings) {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 28, height: 26)
                .background(Capsule().fill(Color.white.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
        .help(llm.smartMode ? "Smart: K2.6 with thinking (slower, deeper)" : "Fast: Turbo (tap to switch to Smart)")
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 30)
                .background(
                    Capsule().fill(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   ? Color.blue.opacity(0.45)
                                   : Color.blue)
                )
        }
        .buttonStyle(.plain)
        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || llm.streaming)
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

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        llm.sendAskAnything(text)
        input = ""
    }
}
