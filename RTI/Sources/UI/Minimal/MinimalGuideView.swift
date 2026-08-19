import RTICore
import SwiftUI
import UniformTypeIdentifiers

/// Read-only discussion-guide coverage (opt-in, Settings -> "Live analysis"
/// -> "Track discussion guide"). One "Import guide" button when nothing is
/// loaded; otherwise the coverage line plus objectives/sections/questions,
/// each question showing its matched summary and quotes once the live
/// matcher has evidence.
struct MinimalGuideView: View {
    private let controller = DiscussionGuideController.shared
    @State private var isPickingFile = false

    var body: some View {
        Group {
            if let guide = controller.guide {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        coverageLine(guide)
                        ForEach(guide.objectives) { objective in
                            objectiveBlock(objective)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                emptyState
            }
        }
        .frame(minHeight: 240)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.plainText, .pdf, .rtf, .item],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                await controller.loadFile(from: url)
                controller.confirmPending()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(controller.isImporting ? "Reading guide…" : "No guide imported")
                .font(.system(size: 13))
                .foregroundStyle(Palette.inkFaint)
            Button("Import guide") { isPickingFile = true }
                .buttonStyle(.bordered)
                .pressable()
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func coverageLine(_ guide: DiscussionGuide) -> some View {
        let cov = guide.coverage
        return Text("\(guide.fileName) — \(cov.answered)/\(cov.total) answered (\(cov.percent)%)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.inkSecondary)
    }

    private func objectiveBlock(_ objective: GuideObjective) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(objective.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.inkPrimary)
            ForEach(objective.sections) { section in
                sectionBlock(section)
            }
        }
    }

    private func sectionBlock(_ section: GuideSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
            ForEach(section.questions) { question in
                questionRow(question)
            }
        }
        .padding(.leading, 4)
    }

    private func questionRow(_ question: GuideQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: statusIcon(question.status))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor(question.status))
                Text(question.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkPrimary)
                    .textSelection(.enabled)
            }
            if let response = question.response {
                Text(response.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.leading, 17)
            }
        }
    }

    private func statusIcon(_ status: GuideQuestionStatus) -> String {
        switch status {
        case .pending: "square"
        case .partial: "minus.square"
        case .answered: "checkmark.square.fill"
        }
    }

    private func statusColor(_ status: GuideQuestionStatus) -> Color {
        switch status {
        case .pending: Palette.inkFaint
        case .partial: Palette.stateWarn
        case .answered: Palette.stateLive
        }
    }
}
