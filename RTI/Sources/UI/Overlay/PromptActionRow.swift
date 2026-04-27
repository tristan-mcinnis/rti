import SwiftUI

struct PromptActionRow: View {
    @ObservedObject private var inputState = OverlayInputState.shared
    @ObservedObject private var session = SessionCoordinator.shared

    var body: some View {
        HStack(spacing: 14) {
            actionButton(icon: "sparkles", label: "Assist", isPrimary: true) {
                LLMController.shared.sendAssist()
            }
            dot
            actionButton(icon: "wand.and.rays", label: "What should I say?", isPrimary: false) {
                LLMController.shared.sendSaySomething()
            }
            dot
            actionButton(icon: "bubble.left.and.text.bubble.right", label: "Follow-ups", isPrimary: false) {
                LLMController.shared.sendFollowupQuestions()
            }
            dot
            actionButton(icon: "arrow.clockwise", label: "Recap", isPrimary: false) {
                LLMController.shared.sendRecap()
            }
            // Note is a *mode toggle* on the input bar, not a one-shot LLM call.
            // Only meaningful while a session is recording — there's no
            // transcript to attach to otherwise.
            if session.isRunning {
                dot
                noteToggle
            }
            Spacer(minLength: 0)
        }
    }

    private var noteToggle: some View {
        Button(action: { inputState.isNoteMode.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 13, weight: .medium))
                Text("Note")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(inputState.isNoteMode ? Color.yellow : Color.white.opacity(0.72))
        }
        .buttonStyle(.plain)
        .help(inputState.isNoteMode
              ? "Note mode on — Enter inserts the input as an inline note"
              : "Switch to Note mode — Enter will insert as a transcript note")
    }

    private var dot: some View {
        Text("·")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white.opacity(0.3))
    }

    private func actionButton(icon: String, label: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isPrimary ? Color.white : Color.white.opacity(0.72))
        }
        .buttonStyle(.plain)
    }
}
