import RTICore
import SwiftUI

// Shared SwiftUI building blocks for rendering a parsed discussion guide
// (objectives → sections → questions, with matched quotes). The live surface
// is the overlay's Guide tab (`GuideTabView`); these views are factored out
// here so the tab can reuse them. There is no longer a standalone floating
// Discussion Guide panel — it was folded into the tabbed overlay.

struct ObjectiveSection: View {
    let objective: GuideObjective

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(objective.title)
                .font(.system(size: House.TypeToken.Size.bodySmall, weight: .bold))
                .foregroundStyle(Color.overlayInk)
            if let desc = objective.description, !desc.isEmpty {
                Text(desc)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkSecondary)
            }
            ForEach(objective.sections) { section in
                SectionGroup(section: section)
            }
        }
    }
}

struct SectionGroup: View {
    let section: GuideSection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.system(size: House.TypeToken.Size.caption, weight: .semibold))
                .foregroundStyle(Color.overlayInkSecondary)
            ForEach(section.questions) { q in
                QuestionRow(question: q)
            }
        }
        .padding(.leading, 4)
    }
}

struct QuestionRow: View {
    let question: GuideQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: House.TypeToken.Size.caption, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(question.text)
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(question.status == .pending ? Color.overlayInkSecondary : Color.overlayInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let response = question.response {
                Text(response.summary)
                    .font(.system(size: House.TypeToken.Size.caption, weight: .medium))
                    .foregroundStyle(Color.overlayInkSecondary)
                    .padding(.leading, 17)
                if !response.quotes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(response.quotes) { quote in
                            GuideQuoteView(quote: quote)
                        }
                    }
                    .padding(.leading, 17)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch question.status {
        case .pending: "square"
        case .partial: "minus.square"
        case .answered: "checkmark.square.fill"
        }
    }

    private var iconColor: Color {
        switch question.status {
        case .pending: Color.overlayInkTertiary
        case .partial: .yellow.opacity(0.8)
        case .answered: .green.opacity(0.85)
        }
    }
}

struct GuideQuoteView: View {
    let quote: GuideQuote

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Rectangle()
                .fill(Color.overlayInkTertiary)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if let speaker = quote.speaker, !speaker.isEmpty {
                        // Normalize raw Soniox IDs (self / them_1) to the same
                        // "You" / "Speaker N" labels the Transcript tab uses, so
                        // the Guide tab doesn't leak internal diarization IDs.
                        Text(SpeakerLabels.displayName(for: speaker))
                            .font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                            .foregroundStyle(Color.overlayInkSecondary)
                    }
                    if !quote.formattedTimestamp.isEmpty {
                        Text(quote.formattedTimestamp)
                            .font(RTIDesign.Font.micro)
                            .foregroundStyle(Color.overlayInkSecondary)
                    }
                }
                Text(quote.text)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
    }
}
