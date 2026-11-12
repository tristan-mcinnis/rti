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
                HStack(spacing: House.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(pending.readingLabel).font(House.TypeToken.label)
                }
            } else if let guide = preparation.guide, let file = preparation.guideURL {
                readyGuide(guide, file: file)
            } else {
                Text("Choose a guide to file respondent answers by question. You can also record without a guide.")
                    .font(House.TypeToken.bodySmall)
                Text("Word (.docx), Markdown (.md) or dg-questions.json")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                HStack(spacing: House.Spacing.xs) {
                    Button("Choose guide…") { choose(roster: false) }
                    if let project, project.isProject {
                        Button("Use project guide") { request(.project(project.url)) }
                            .buttonStyle(.borderless)
                    }
                }
                .disabled(!editable)
            }
            if let error {
                Text(error)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .accessibilityLabel("Guide selection error: \(error)")
            }
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .task(id: pending) {
            if let choice = pending {
                await load(choice)
            }
        }
    }

    @ViewBuilder
    private func readyGuide(_ guide: GuideDocument, file: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            Label("Ready", systemImage: "checkmark.circle")
                .font(House.TypeToken.label)
                .fixedSize()
            Text(guide.title)
                .font(House.TypeToken.label)
                .lineLimit(2)
            Spacer(minLength: House.Spacing.xs)
            Button("Change guide…") { choose(roster: false) }
                .disabled(!editable)
            Button("Clear") {
                preparation.reset()
                error = nil
                previewExpanded = false
            }
            .disabled(!editable)
        }
        Text("\(file.lastPathComponent) · \(count(guide.sections.count, "section")) · \(count(guide.questions.count, "question"))")
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textSecondary)
            .help(file.path)
        Text("Guide files respondent answers under these questions during recording.")
            .font(House.TypeToken.bodySmall)
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

        HStack(spacing: House.Spacing.xs) {
            Text("Group").font(House.TypeToken.label)
            TextField("G1", text: $preparation.groupText)
                .accessibilityLabel("Optional group ID")
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: House.Control.composer * 2)
            Spacer(minLength: House.Spacing.xs)
            Button(preparation.rosterURL?.lastPathComponent ?? "Choose roster…") { choose(roster: true) }
                .lineLimit(1)
                .help("Choose respondent seats from JSON or CSV")
            if preparation.rosterURL != nil {
                Button("Clear roster") { preparation.clearRoster(); error = nil }
            }
        }
        .disabled(!editable)
        if !preparation.groupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, preparation.group == nil {
            Text("Use a group ID such as G1. This group will be saved as unassigned.").font(House.TypeToken.meta)
        }
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
