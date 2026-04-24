import SwiftUI

struct OverlayPanelView: View {
    @ObservedObject private var llm = LLMController.shared
    var onOpenSettings: () -> Void = {}

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(spacing: 0) {
                ResponseView(
                    entries: llm.entries,
                    streaming: llm.streaming,
                    error: llm.lastError,
                    errorIsAuth: llm.lastErrorIsAuth,
                    onOpenSettings: onOpenSettings
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 18)
                .padding(.top, 16)

                PromptActionRow()
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                AssistantInputView()
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
    }
}
