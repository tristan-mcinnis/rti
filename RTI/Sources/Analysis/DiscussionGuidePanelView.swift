import SwiftUI
import RTICore
import UniformTypeIdentifiers

struct DiscussionGuidePanelView: View {
    private let controller = DiscussionGuideController.shared

    var body: some View {
        FloatingPanelChrome(
            title: "Discussion guide",
            opacityKey: guideOpacityKey,
            defaultOpacity: guideDefaultOpacity,
            panelID: .discussionGuide,
            titleAccessory: {
                if controller.isImporting || controller.isMatching {
                    ProgressView()
                        .scaleEffect(0.7)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
            },
            menuItems: {
                Button("Import guide…", action: importGuide)
                if controller.guide != nil {
                    Divider()
                    Button("Remove guide", role: .destructive, action: removeGuide)
                }
            }
        ) {
            VStack(spacing: 0) {
                if let error = controller.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }

                if let guide = controller.guide {
                    coverageRow(guide: guide)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(guide.objectives) { obj in
                                ObjectiveSection(objective: obj)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    Spacer()
                    emptyState
                    Spacer()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No guide loaded")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Import a .md or .txt discussion guide. RTI will parse it and pair questions with the live transcript.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Import guide…", action: importGuide)
                .controlSize(.small)
                .padding(.top, 4)
        }
    }

    private func coverageRow(guide: DiscussionGuide) -> some View {
        let cov = guide.coverage
        return HStack(spacing: 8) {
            Text(guide.fileName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(cov.answered)/\(cov.total) answered • \(cov.percent)%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func importGuide() {
        guard let sessionId = SessionCoordinator.shared.currentSessionId else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
            UTType(filenameExtension: "txt") ?? .plainText,
        ]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.importGuide(from: url, sessionId: sessionId) }
    }

    private func removeGuide() {
        guard let sessionId = SessionCoordinator.shared.currentSessionId else { return }
        controller.removeGuide(for: sessionId)
    }
}

struct ObjectiveSection: View {
    let objective: GuideObjective

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(objective.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            if let desc = objective.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(question.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(question.status == .pending ? 0.7 : 0.95))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let response = question.response {
                Text(response.summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
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
        case .pending: return "square"
        case .partial: return "minus.square"
        case .answered: return "checkmark.square.fill"
        }
    }

    private var iconColor: Color {
        switch question.status {
        case .pending: return .white.opacity(0.4)
        case .partial: return .yellow.opacity(0.8)
        case .answered: return .green.opacity(0.85)
        }
    }
}

struct GuideQuoteView: View {
    let quote: GuideQuote

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if let speaker = quote.speaker, !speaker.isEmpty {
                        Text(speaker)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    if !quote.formattedTimestamp.isEmpty {
                        Text(quote.formattedTimestamp)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Text(quote.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.88))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
    }
}
