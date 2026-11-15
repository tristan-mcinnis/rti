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
                    .foregroundStyle(House.ColorToken.accent)
                    .accessibilityHidden(true)
                Text(llm.streaming ? "Answering…" : "Answer")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.accent)
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
            // A tinted header band marks the card as the answer, apart from
            // the white transcript behind it (2026-11-15: the card read as
            // white on white).
            .background(House.ColorToken.accentSoft)
            HouseDivider()
            // One thread with one identity: switching between a hugging and a
            // scrolling copy mid-stream reset its scroll and following state
            // (2026-11-15 SwiftUI review). The card takes its full share.
            thread.frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .background(House.ColorToken.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .strokeBorder(House.ColorToken.strokeStrong, lineWidth: House.hairline)
        }
        .overlay(alignment: .top) {
            House.ColorToken.highlightTop
                .frame(height: House.hairline)
                .padding(.horizontal, House.Spacing.xs)
        }
        // A raised card inside the window: `Radius.lg` and the `card`
        // shadow (DESIGN.md), not the floating-panel treatment.
        .shadow(color: .black.opacity(House.Shadow.card.opacity(dark: scheme == .dark)),
                radius: House.Shadow.card.blur / 2, y: House.Shadow.card.y)
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
