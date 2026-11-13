import AppKit
import HouseDesign
import RTICore
import SwiftUI
import UniformTypeIdentifiers

struct GuidePrepareControls: View {
    let project: VaultItem?
    @Bindable var preparation = GuidePreparation.shared
    private let session = SessionCoordinator.shared

    private enum Pick: Equatable {
        case guide(URL), project(URL), roster(URL)

        var readingLabel: String {
            switch self {
            case let .guide(url), let .roster(url): "Reading \(url.lastPathComponent)…"
            case .project: "Looking for the project guide…"
            }
        }
    }

    @State private var pending: Pick?
    @State private var error: String?
    @State private var previewExpanded = false

    private var editable: Bool {
        !session.isRunning && session.phase != .finishing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            if let pending {
                HStack(spacing: House.Spacing.sm) {
                    ProgressView().controlSize(.small)
                        .frame(width: House.Control.tile)
                    Text(pending.readingLabel).font(House.TypeToken.label)
                }
            } else if let guide = preparation.guide, let file = preparation.guideURL {
                readyGuide(guide, file: file)
            } else {
                HStack(alignment: .top, spacing: House.Spacing.sm) {
                    glyph
                    VStack(alignment: .leading, spacing: House.Spacing.xs) {
                        Text("No guide chosen")
                            .font(House.TypeToken.label)
                            .foregroundStyle(House.ColorToken.textPrimary)
                        Text("Word (.docx), Markdown (.md) or dg-questions.json. Optional: answers are filed by question.")
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: House.Spacing.xs) {
                            Button("Choose guide…") { choose(roster: false) }
                            if let project, project.isProject {
                                Button("Use project guide") { request(.project(project.url)) }
                            }
                        }
                        .fixedSize()
                        .disabled(!editable)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let error {
                Text(error)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SetupGrid.textIndent)
                    .accessibilityLabel("Guide selection error: \(error)")
            }
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.setupAction)
        .controlSize(.small)
        .task(id: pending) {
            if let choice = pending {
                await load(choice)
            }
        }
    }

    private var glyph: some View {
        Image(systemName: "list.bullet.rectangle")
            .font(House.TypeToken.label)
            .foregroundStyle(House.ColorToken.textSecondary)
            .frame(width: House.Control.tile)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func readyGuide(_ guide: GuideDocument, file: URL) -> some View {
        HStack(spacing: House.Spacing.sm) {
            glyph
            VStack(alignment: .leading, spacing: 0) {
                Text(guide.title)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .setupLayoutMark("text.guide")
                Text("\(file.lastPathComponent) · \(count(guide.sections.count, "section")) · \(count(guide.questions.count, "question"))")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Guide ready: \(guide.title)")
            Spacer(minLength: House.Spacing.xs)
            HStack(spacing: House.Spacing.xs) {
                Button("Change…") { choose(roster: false) }
                Button("Remove") {
                    preparation.reset()
                    error = nil
                    previewExpanded = false
                }
            }
            .fixedSize()
            .disabled(!editable)
        }
        HStack(spacing: House.Spacing.xs) {
            Text("Group").font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
            TextField("Group", text: $preparation.groupText, prompt: Text(""))
                .accessibilityLabel("Optional group ID")
                .setupField("G1", isEmpty: preparation.groupText.isEmpty)
                .frame(width: House.Control.hero)
            Button(preparation.rosterURL?.lastPathComponent ?? "Choose roster…") { choose(roster: true) }
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Choose respondent seats from JSON or CSV")
            if preparation.rosterURL != nil {
                Button("Clear roster") { preparation.clearRoster(); error = nil }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, SetupGrid.textIndent)
        .disabled(!editable)
        if !preparation.groupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, preparation.group == nil {
            Text("Use a group ID such as G1. This group will be saved as unassigned.")
                .font(House.TypeToken.meta)
                .padding(.leading, SetupGrid.textIndent)
        }
        DisclosureGroup("Preview questions", isExpanded: $previewExpanded) {
            VStack(alignment: .leading, spacing: House.Spacing.xs) {
                ForEach(guide.sections, id: \.id) { section in
                    Text(section.title).font(House.TypeToken.label)
                    ForEach(section.questions, id: \.qid) { question in
                        Text("\(question.qid) · \(question.en.isEmpty ? question.zh : question.en)")
                            .font(House.TypeToken.bodySmall)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, House.Spacing.xxs)
        }
        .font(House.TypeToken.meta)
        .padding(.leading, SetupGrid.textIndent)
    }

    private func count(_ amount: Int, _ noun: String) -> String {
        "\(amount) \(noun)\(amount == 1 ? "" : "s")"
    }

    private var projectIsCurrent: Bool {
        project?.id == MeetingContextStore.shared.workstreamItem?.id
    }

    private func load(_ choice: Pick) async {
        defer {
            if !Task.isCancelled {
                pending = nil
            }
        }
        do {
            switch choice {
            case let .guide(url), let .project(url):
                let loaded = try await GuideFileReader.shared.loadGuide(at: url)
                try Task.checkCancellation()
                if editable, projectIsCurrent {
                    preparation.setGuide(loaded.document, url: loaded.sourceURL, parsedSourceJSON: loaded.parsedSourceJSON)
                }
            case let .roster(url):
                let seats = try await GuideFileReader.shared.readRoster(at: url)
                try Task.checkCancellation()
                if editable, projectIsCurrent {
                    preparation.setRoster(seats, url: url)
                }
            }
        } catch {
            guard !Task.isCancelled, editable, projectIsCurrent else { return }
            self.error = error.localizedDescription
            if case .project = choice {
                switch error {
                case GuideFileReader.ReadError.noGuide, GuideFileReader.ReadError.severalGuides:
                    choose(roster: false)
                default:
                    break
                }
            }
        }
    }

    private func request(_ choice: Pick) {
        guard editable, projectIsCurrent else { return }
        error = nil
        switch choice {
        case .guide, .project:
            // Record can be started with a hotkey while the replacement is being read.
            preparation.reset()
            previewExpanded = false
        case .roster:
            preparation.clearRoster()
        }
        pending = choice
    }

    private func choose(roster: Bool) {
        let panel = NSOpenPanel()
        panel.title = roster ? "Choose respondent roster" : "Choose discussion guide"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = roster ? [.json, .commaSeparatedText] : ["docx", "md", "json"].compactMap { UTType(filenameExtension: $0) }
        if let project, project.isProject {
            let guideFolder = project.url.appendingPathComponent("06-discussion-guide", isDirectory: true)
            var isDir: ObjCBool = false
            panel.directoryURL = !roster && FileManager.default.fileExists(atPath: guideFolder.path, isDirectory: &isDir) && isDir.boolValue
                ? guideFolder : project.url
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            request(roster ? .roster(url) : .guide(url))
        }
    }
}
