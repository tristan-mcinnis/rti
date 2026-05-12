import SwiftUI

struct PromptActionRow: View {
    @ObservedObject private var inputState = OverlayInputState.shared
    @ObservedObject private var session = SessionCoordinator.shared

    var body: some View {
        HStack(spacing: 8) {
            actionButton(icon: "sparkles", label: "Assist", isPrimary: true) {
                LLMController.shared.sendAssist()
            }
            actionButton(icon: "wand.and.rays", label: "What should I say?", isPrimary: false) {
                LLMController.shared.sendSaySomething()
            }
            actionButton(icon: "bubble.left.and.text.bubble.right", label: "Follow-ups", isPrimary: false) {
                LLMController.shared.sendFollowupQuestions()
            }
            actionButton(icon: "arrow.clockwise", label: "Recap", isPrimary: false) {
                LLMController.shared.sendRecap()
            }
            // Note is a *mode toggle* on the input bar, not a one-shot LLM call.
            // Only meaningful while a session is recording — there's no
            // transcript to attach to otherwise.
            if session.isRunning {
                noteToggle
            }
            Spacer(minLength: 0)
        }
    }

    private var noteToggle: some View {
        Button(action: { inputState.isNoteMode.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 12, weight: .semibold))
                Text("Note")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(inputState.isNoteMode ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(inputState.isNoteMode
                               ? Color.yellow
                               : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(inputState.isNoteMode
              ? "Note mode on — Enter inserts the input as an inline note"
              : "Switch to Note mode — Enter will insert as a transcript note")
    }

    private func actionButton(icon: String, label: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isPrimary ? Color.white : Color.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isPrimary
                               ? Color.white.opacity(0.14)
                               : Color.white.opacity(0.08))
            )
            .liquidMetalBorder(Capsule(), lineWidth: 1.0, period: 5.0, glow: 4, active: isPrimary)
        }
        .buttonStyle(.plain)
    }
}
