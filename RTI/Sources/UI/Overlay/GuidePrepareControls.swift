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
        case guide(URL), roster(URL)
    }

    @State private var pending: Pick?
    @State private var error: String?

    private var editable: Bool {
        !session.isRunning && session.phase != .finishing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            HStack {
                Text(preparation.guide?.title ?? "Discussion guide")
                    .font(House.TypeToken.label)
                    .lineLimit(2)
                Spacer()
                if let project, project.isProject, preparation.guide == nil {
                    Button("Use project guide") { request(.guide(project.url)) }
                }
                Button(preparation.guide == nil ? "Choose…" : "Change…") { choose(roster: false) }
                if preparation.guide != nil {
                    Button("Clear") { preparation.reset(); error = nil }
                }
            }
            if let file = preparation.guideURL {
                Text(file.lastPathComponent)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .help(file.path)
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
                if !preparation.groupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   preparation.group == nil
                {
                    Text("Use a group ID such as G1. This group will be saved as unassigned.")
                        .font(House.TypeToken.meta)
                }
            }
            if let error {
                Text(error)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .accessibilityLabel("Guide selection error: \(error)")
            }
            if pending != nil {
                ProgressView().controlSize(.small).accessibilityLabel("Reading file")
            }
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!editable || pending != nil)
        .task(id: pending) {
            guard let choice = pending else { return }
            do {
                switch choice {
                case let .guide(url):
                    let (guide, file) = try await GuideFileReader.shared.readGuide(at: url)
                    try Task.checkCancellation()
                    if editable {
                        preparation.setGuide(guide, url: file)
                    }
                case let .roster(url):
                    let seats = try await GuideFileReader.shared.readRoster(at: url)
                    try Task.checkCancellation()
                    if editable {
                        preparation.setRoster(seats, url: url)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
            if !Task.isCancelled {
                pending = nil
            }
        }
    }

    private func request(_ choice: Pick) {
        error = nil
        pending = choice
    }

    private func choose(roster: Bool) {
        let panel = NSOpenPanel()
        panel.title = roster ? "Choose respondent roster" : "Choose guide JSON or project folder"
        panel.canChooseDirectories = !roster
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = roster ? [.json, .commaSeparatedText] : [.json]
        if let project, project.isProject {
            panel.directoryURL = project.url
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url, editable else { return }
            request(roster ? .roster(url) : .guide(url))
        }
    }
}
