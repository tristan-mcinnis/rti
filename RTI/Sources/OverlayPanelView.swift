import SwiftUI

struct OverlayPanelView: View {
    @ObservedObject private var llm = LLMController.shared
    @State private var deferredHint: String?

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
                    error: llm.lastError
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 18)
                .padding(.top, 16)

                if let hint = deferredHint {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.yellow.opacity(0.8))
                        Text("\(hint): not wired in POC-3 — only Assist + Ask Anything call Kimi.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                }

                PromptActionRow(onDeferred: { label in
                    deferredHint = label
                })
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
