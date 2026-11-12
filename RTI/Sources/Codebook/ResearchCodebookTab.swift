import HouseDesign
import RTICore
import SwiftUI

struct ResearchCodebookPreparation: View {
    @Bindable private var controller = ResearchCodebookController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            Text("Codebook seeds").font(House.TypeToken.label)
            if SessionCoordinator.shared.isRunning {
                Text("\(controller.book.cards.filter(\.seeded).count) seeded cards").font(House.TypeToken.meta)
            } else {
                TextField("One per line, e.g. brand | Morning Cup（晨杯）", text: $controller.seedText, axis: .vertical)
                    .lineLimit(1 ... 4).textFieldStyle(.roundedBorder)
                Text("Also reads codebook-seed.md from the selected project.")
                    .font(House.TypeToken.meta).foregroundStyle(House.ColorToken.textSecondary)
            }
        }
    }
}

struct ResearchCodebookTab: View {
    private let controller = ResearchCodebookController.shared
    @State private var group: String?
    @State private var section = "Cards"
    @State private var renamed: ResearchCard?
    @State private var renameText = ""
    @State private var archivedQuote: ResearchQuote?

    private var groups: [String] {
        Set(controller.book.sessions.map { $0.group ?? $0.id }).sorted()
    }

    private var cards: [ResearchCard] {
        controller.book.cards.sorted { ($0.pinned ? 0 : 1, -$0.entries.count, $0.name) < ($1.pinned ? 0 : 1, -$1.entries.count, $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            HStack {
                Picker("View", selection: $section) {
                    ForEach(["Cards", "Respondents", "Different from last group"], id: \.self) { Text($0) }
                }.pickerStyle(.menu)
                Spacer()
                if section != "Different from last group" {
                    Picker("Group", selection: $group) {
                        Text("All groups").tag(String?.none)
                        ForEach(groups, id: \.self) { Text($0).tag(Optional($0)) }
                    }.labelsHidden().accessibilityLabel("Filter by group")
                }
                if controller.generating {
                    ProgressView().controlSize(.small).accessibilityLabel("Reading recent turns")
                }
            }
            if let error = controller.error {
                Text(error).font(House.TypeToken.meta).textSelection(.enabled)
            }
            if controller.book.projectMergePending == true {
                HStack { Text("Session saved. Project merge pending.").font(House.TypeToken.meta); Button("Retry merge") { Task { await controller.retryProjectMerge() } } }
            }
            if let notice = controller.notice {
                Text(notice).font(House.TypeToken.meta)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: House.Spacing.md) {
                    if section == "Different from last group" {
                        comparison
                    } else if section == "Respondents" {
                        respondents
                    } else if cards.isEmpty {
                        Text("Seed a card in Setup or record a Research call to collect quoted evidence.")
                    } else {
                        ForEach(cards) { card in
                            if group == nil || !visible(card).isEmpty {
                                cardView(card)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(House.Spacing.sm)
        .task(id: MeetingContextStore.shared.workstreamItem?.id) { await controller.browseSelectedProject() }
        .sheet(item: $archivedQuote) { quote in ResearchArchivedEvidence(quote: quote, folder: controller.book.sessions.first { $0.id == quote.sessionID }?.folder) }
        .alert("Rename card", isPresented: Binding(get: { renamed != nil }, set: {
            if !$0 {
                renamed = nil
            }
        })) {
            TextField("Canonical name", text: $renameText)
            Button("Save") {
                if let renamed {
                    edit(.rename(renamed.id, renameText))
                }; renamed = nil
            }
            Button("Cancel", role: .cancel) { renamed = nil }
        }
    }

    private func visible(_ card: ResearchCard) -> [ResearchEntry] {
        card.entries.filter { group == nil || ($0.evidence.group ?? $0.evidence.sessionID) == group }
    }

    private func cardView(_ card: ResearchCard) -> some View {
        let entries = visible(card)
        return DisclosureGroup {
            if !card.summary.isEmpty {
                Text(card.summary).textSelection(.enabled)
            }
            ForEach(controller.book.sessions.sorted { $0.startedAt < $1.startedAt }) { session in
                let rows = entries.filter { $0.evidence.sessionID == session.id }
                if !rows.isEmpty {
                    let count = Set(rows.compactMap { entry in
                        let speaker = entry.evidence.speaker
                        return speaker.confidence == SpeakerEvidence.confirmed.rawValue ? speaker.seat ?? speaker.label : nil
                    }).count
                    Text("\(session.group ?? session.folder) · \(rows.count) entries\(count > 0 ? " · \(count) confirmed speakers" : "")").font(House.TypeToken.label)
                    Text(ResearchValence.allCases.map { value in "\(value.rawValue) \(rows.filter { $0.valence == value }.count)" }.joined(separator: " · ")).font(House.TypeToken.meta)
                    ForEach(rows.sorted { $0.evidence.offsetMs < $1.evidence.offsetMs }) { entry in quoteRow(entry) }
                }
            }
        } label: {
            HStack {
                if card.pinned {
                    Image(systemName: "pin.fill").accessibilityLabel("Pinned")
                }
                Text(card.name).font(House.TypeToken.label)
                Text("\(card.type.rawValue) · \(card.seeded ? "seeded" : "emerged") · \(entries.count)").font(House.TypeToken.meta)
                Spacer()
                Menu {
                    Button(card.pinned ? "Unpin" : "Pin") { edit(.pin(card.id, !card.pinned)) }
                    Button("Rename…") { renameText = card.name; renamed = card }
                    Menu("Merge into") { ForEach(cards.filter { $0.id != card.id }) { into in Button(into.name) { edit(.merge(card.id, into: into.id)) } } }
                    Button("Drop card", role: .destructive) { edit(.drop(card.id)) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Edit \(card.name)")
            }
        }
    }

    private func edit(_ change: ResearchCodebook.Edit) {
        Task { await controller.edit(change) }
    }

    private func quoteRow(_ entry: ResearchEntry) -> some View {
        let quote = entry.evidence
        return Button {
            if SessionCoordinator.shared.isRunning, SessionCoordinator.shared.currentSessionId == quote.sessionID {
                controller.pendingJump = quote.offsetMs
                NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.transcript.rawValue)
            } else {
                archivedQuote = quote
            }
        } label: {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                Text(entry.point).font(House.TypeToken.bodySmall)
                Text("[\(GuideExtraction.locator(quote.offsetMs)), \(quote.speaker.label)] \(quote.original)").font(House.TypeToken.meta)
                let context = [quote.questionID, quote.markerLabel, quote.shownCodes.map { "Shown: " + $0.joined(separator: ", ") }].compactMap(\.self)
                if let codes = quote.mentionedCodes, !codes.isEmpty {
                    Text("Mentioned: " + codes.joined(separator: ", ")).font(House.TypeToken.meta)
                }
                if quote.anchorNeedsReview == true {
                    Text("Upgraded locator needs review").font(House.TypeToken.meta)
                }
                if !context.isEmpty {
                    Text(context.joined(separator: " · ")).font(House.TypeToken.meta)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).help("Jump to this turn in the transcript")
    }

    @ViewBuilder private var comparison: some View {
        let sessions = controller.book.sessions.sorted { $0.startedAt < $1.startedAt }
        if sessions.count < 2 {
            Text("A second session in this project is needed for comparison.")
        } else {
            let pair = Array(sessions.suffix(2))
            ForEach(cards) { card in
                if card.entries.contains(where: { entry in pair.contains { $0.id == entry.evidence.sessionID } }) {
                    Text(card.name).font(House.TypeToken.label)
                    ForEach(pair) { session in
                        let entries = card.entries.filter { $0.evidence.sessionID == session.id }
                        Text("\(session.group ?? session.folder) · \(entries.count) entries").font(House.TypeToken.label)
                        if entries.isEmpty {
                            Text("No quoted evidence in this session.").font(House.TypeToken.meta)
                        }
                        ForEach(entries) { entry in quoteRow(entry) }
                    }
                }
            }
        }
    }

    private struct Respondent: Identifiable {
        let id: String
        let label: String
        let segment: String?
        var brands: Set<String> = []
        var entries: [ResearchEntry] = []
    }

    private var respondentRows: [Respondent] {
        var output: [String: Respondent] = [:]
        for card in cards {
            for entry in visible(card) {
                let q = entry.evidence, who = q.speaker
                let confirmed = who.confidence == SpeakerEvidence.confirmed.rawValue
                let id = q.sessionID + "/" + (confirmed ? who.seat ?? who.label : who.rawSpeaker)
                let label = confirmed ? who.label : (entry.inferredName.map { "\($0) (inferred)" } ?? "\(who.label) · uncertain speaker")
                var row = output[id] ?? Respondent(id: id, label: label, segment: who.segment)
                if entry.inferredName != nil, !confirmed {
                    row = Respondent(id: id, label: label, segment: row.segment, brands: row.brands, entries: row.entries)
                }
                if card.type == .brand {
                    row.brands.insert(card.name)
                }
                if !row.entries.contains(where: { $0.id == entry.id }) {
                    row.entries.append(entry)
                }
                output[id] = row
            }
        }
        return output.values.sorted { $0.id < $1.id }
    }

    @ViewBuilder private var respondents: some View {
        if respondentRows.isEmpty {
            Text("Respondent cards appear with their first evidenced entry.")
        }
        ForEach(respondentRows) { row in
            let groupLabel = row.entries.first?.evidence.group
            Text([groupLabel, row.label, row.segment].compactMap(\.self).joined(separator: " · ")).font(House.TypeToken.label)
            if !row.brands.isEmpty {
                Text(row.brands.sorted().joined(separator: ", ")).font(House.TypeToken.meta)
            }
            ForEach(Array(row.entries.sorted { $0.evidence.offsetMs < $1.evidence.offsetMs }.prefix(3))) { entry in quoteRow(entry) }
        }
    }
}

private struct ResearchArchivedEvidence: View {
    let quote: ResearchQuote
    let folder: String?
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [SessionTranscriptTurn] = []
    @State private var nearest: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            HStack { Text("Source transcript").font(House.TypeToken.label); Spacer(); Button("Done") { dismiss() } }
            Text("[\(GuideExtraction.locator(quote.offsetMs)), \(quote.speaker.label)] \(quote.original)").textSelection(.enabled)
            if turns.isEmpty {
                Text("The archived transcript could not be opened. The cited original is shown above.").font(House.TypeToken.meta)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { LazyVStack(alignment: .leading, spacing: House.Spacing.xs) { ForEach(turns) { row in
                        Text("[\(row.timestamp), \(row.speaker)] \(row.text)").textSelection(.enabled).id(row.id)
                    } } }
                    .onAppear {
                        if let nearest {
                            proxy.scrollTo(nearest, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(House.Spacing.md).frame(minWidth: 360, idealWidth: 520, minHeight: 250, idealHeight: 420)
        .task {
            guard let folder, folder == URL(fileURLWithPath: folder).lastPathComponent else { return }
            turns = await ResearchCodebookStore.shared.archivedTurns(folder: folder)
            let exact = turns.filter { $0.text == quote.original }
            nearest = (exact.isEmpty ? turns : exact).min { abs(offset($0) - quote.offsetMs) < abs(offset($1) - quote.offsetMs) }?.id
        }
    }

    private func offset(_ row: SessionTranscriptTurn) -> Int {
        Int(row.timestamp.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 } * 1000)
    }
}
