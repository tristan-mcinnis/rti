import HouseDesign
import RTICore
import SwiftUI

/// RTI Lite's answer: the chat thread in a raised card that rises above the
/// ask bar when a question is sent and closes back into it. The transcript
/// stays in view behind it, so an answer never costs you your place in the
/// call (2026-11-14). The thread itself is the house `ResponseView`.
struct LiteAnswerCard: View {
    let close: () -> Void
    private let llm = LLMController.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: House.Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .accessibilityHidden(true)
                Text(llm.streaming ? "Answering…" : "Answer")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textSecondary)
                Spacer(minLength: 0)
                QuickAIGlyphButton(symbol: "chevron.down", font: HouseChatType.glyphSmall,
                                   color: House.ColorToken.textSecondary,
                                   label: "Close the answer", help: "Close the answer; the ask bar keeps the chat") {
                    close()
                }
                .accessibilityIdentifier("rti-lite-answer-close")
            }
            .padding(.horizontal, House.Spacing.lg)
            .frame(height: House.Control.row)
            HouseDivider()
            // The card hugs a short answer and scrolls a long one: the first
            // layout that fits the room wins.
            ViewThatFits(in: .vertical) {
                thread.fixedSize(horizontal: false, vertical: true)
                thread.frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(House.ColorToken.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: House.Radius.xl, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: House.Radius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: House.Radius.xl, style: .continuous)
                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
        }
        .overlay(alignment: .top) {
            House.ColorToken.highlightTop
                .frame(height: House.hairline)
                .padding(.horizontal, House.Radius.xl / 2)
        }
        // Depth from the near panel shadow only: the far one is for windows
        // that float over other apps and hazes the transcript behind a card.
        .shadow(color: .black.opacity(House.Shadow.panelNear.opacity(dark: scheme == .dark)),
                radius: House.Shadow.panelNear.blur / 2, y: House.Shadow.panelNear.y)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer")
        .accessibilityIdentifier("rti-lite-answer")
    }

    private var thread: some View {
        ResponseView(entries: llm.entries, streaming: llm.streaming,
                     error: llm.lastError, errorIsAuth: llm.lastErrorIsAuth)
            .padding(.horizontal, House.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
