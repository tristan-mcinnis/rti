import SwiftUI

struct PromptActionRow: View {
    let onDeferred: (String) -> Void

    var body: some View {
        HStack(spacing: 14) {
            actionButton(icon: "sparkles", label: "Assist", isPrimary: true) {
                LLMController.shared.sendAssist()
            }
            dot
            actionButton(icon: "wand.and.rays", label: "What should I say?", isPrimary: false) {
                onDeferred("What should I say?")
            }
            dot
            actionButton(icon: "bubble.left.and.text.bubble.right", label: "Follow-up questions", isPrimary: false) {
                onDeferred("Follow-up questions")
            }
            dot
            actionButton(icon: "arrow.clockwise", label: "Recap", isPrimary: false) {
                onDeferred("Recap")
            }
            Spacer(minLength: 0)
        }
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
