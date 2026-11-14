import HouseDesign
import RTICore
import SwiftUI

struct ResearchCodebookPreparation: View {
    @Bindable private var controller = ResearchCodebookController.shared

    var body: some View {
        HStack(alignment: .top, spacing: House.Spacing.sm) {
            Image(systemName: "tag")
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textSecondary)
                .frame(width: House.Control.tile, height: House.Control.chip)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: House.Spacing.xs) {
                Text("Brands and words to watch")
                    .font(House.TypeToken.label)
                    .frame(minHeight: House.Control.chip)
                    .setupLayoutMark("text.seeds")
                if SessionCoordinator.shared.isRunning {
                    Text("\(controller.book.cards.filter(\.seeded).count) seeded cards").font(House.TypeToken.meta)
                } else {
                    // Plain lines are names; `type | name` lines still work
                    // (ResearchCodebookStore.seed) but are not taught here.
                    SetupTextEditor(text: $controller.seedText, placeholder: "Morning Cup 晨杯\n洗起来麻烦",
                                    accessibilityLabel: "Brands and words to watch, one per line", growsWithText: true)
                        .setupLayoutMark("field.seeds")
                    Text("One per line. RTI also reads the project's codebook-seed.md.")
                        .font(House.TypeToken.meta).foregroundStyle(House.ColorToken.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
    @State private var open: Set<ResearchCard.ID> = []

    private var groups: [String] {
        Set(controller.book.sessions.map { $0.group ?? $0.id }).sorted()
    }

    /// Codes only: people and organisations from older archives load but
    /// are not codes.
    private var cards: [ResearchCard] {
        controller.book.cards.filter(\.type.isCode)
            .sorted { ($0.pinned ? 0 : 1, -$0.quoteCount, $0.name) < ($1.pinned ? 0 : 1, -$1.quoteCount, $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            HStack {
                // The stored tags stay; the words say what each view is.
                Picker("View", selection: $section) {
                    Text("Ideas").tag("Cards")
                    Text("Respondents").tag("Respondents")
                    Text("Compare with last group").tag("Different from last group")
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if section != "Different from last group", groups.count > 1 {
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
                LazyVStack(alignment: .leading, spacing: section == "Cards" ? 0 : House.Spacing.md) {
                    if section == "Different from last group" {
                        comparison
                    } else if section == "Respondents" {
                        respondents
                    } else if cards.isEmpty {
                        Text("Ideas from the room collect here during a research call, ranked by how often they come up. Add brands and words to watch on Prepare.")
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(House.ColorToken.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(cards) { card in
                            if group == nil || !visible(card).isEmpty || !visibleVotes(card).isEmpty {
                                cardView(card)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.vertical, House.Spacing.sm)
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

    /// A vote card's tallies under the group filter: only that group's sessions.
    private func visibleVotes(_ card: ResearchCard) -> [ResearchVote] {
        ResearchCodebook.votes(card, group: group, sessions: controller.book.sessions)
    }

    /// One idea: its words, gloss and count on one row; open, its summary
    /// once and then its quotes, each with when and where it was said
    /// (2026-11-14 review: one ranked reading list, nothing repeated).
    private func cardView(_ card: ResearchCard) -> some View {
        let entries = visible(card)
        let isOpen = open.contains(card.id)
        return VStack(alignment: .leading, spacing: House.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: House.Spacing.sm) {
                Button {
                    if isOpen { open.remove(card.id) } else { open.insert(card.id) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                        Image(systemName: "chevron.right")
                            .font(House.TypeToken.caption)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .accessibilityHidden(true)
                        ResearchCodeLabel(card: card, entries: entries, votes: visibleVotes(card))
                        Spacer(minLength: House.Spacing.sm)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(card.name), \(isOpen ? "open" : "closed")")
                Menu {
                    Button(card.pinned ? "Unpin" : "Pin") { edit(.pin(card.id, !card.pinned)) }
                    Button("Rename…") { renameText = card.name; renamed = card }
                    Menu("Merge into") { ForEach(cards.filter { $0.id != card.id }) { into in Button(into.name) { edit(.merge(card.id, into: into.id)) } } }
                    Button("Drop card", role: .destructive) { edit(.drop(card.id)) }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(House.ColorToken.textTertiary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Edit \(card.name)")
            }
            if isOpen {
                VStack(alignment: .leading, spacing: House.Spacing.sm) {
                    if !card.summary.isEmpty {
                        Text(card.summary)
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(House.ColorToken.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    ForEach(entries.sorted { ($0.evidence.sessionID, $0.evidence.offsetMs) < ($1.evidence.sessionID, $1.evidence.offsetMs) }) { entry in
                        quoteRow(entry)
                    }
                }
                .padding(.leading, House.Spacing.lg)
            }
        }
        .padding(.vertical, House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { HouseDivider() }
    }

    private func edit(_ change: ResearchCodebook.Edit) {
        Task { await controller.edit(change) }
    }

    /// A quote: the respondent's own words, then when, where and under
    /// which question. A click jumps to it in the live transcript, or opens
    /// the archived transcript at that line.
    private func quoteRow(_ entry: ResearchEntry) -> some View {
        let quote = entry.evidence
        let session = controller.book.sessions.first { $0.id == quote.sessionID }
        let place = [GuideExtraction.locator(quote.offsetMs), session?.group, quote.questionID, quote.markerLabel]
            .compactMap(\.self).joined(separator: " · ")
        return Button {
            if SessionCoordinator.shared.isRunning, SessionCoordinator.shared.currentSessionId == quote.sessionID {
                controller.pendingJump = quote.offsetMs
                NotificationCenter.default.post(name: .rtiSelectTab, object: OverlayTab.transcript.rawValue)
            } else {
                archivedQuote = quote
            }
        } label: {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                if let stance = entry.stance {
                    Text(stance == .support ? "For" : "Against")
                        .font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
                Text(quote.original)
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let counter = entry.counter {
                    Text("vs \(GuideExtraction.locator(counter.offsetMs))  \(counter.original)")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(entry.asrDoubt == true ? place + " · may be misheard" : place)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("Show this line in its transcript")
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
            if turns.isEmpty {
                Text("[\(GuideExtraction.locator(quote.offsetMs)), \(quote.speaker.label)] \(quote.original)").textSelection(.enabled)
                Text("The archived transcript could not be opened, so only the quote is shown.").font(House.TypeToken.meta)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { LazyVStack(alignment: .leading, spacing: House.Spacing.xs) { ForEach(turns) { row in
                        // The quoted line reads in full ink; the lines around it step back.
                        Text("[\(row.timestamp), \(row.speaker)] \(row.text)").textSelection(.enabled).id(row.id)
                            .foregroundStyle(row.id == nearest ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                            .fontWeight(row.id == nearest ? .medium : .regular)
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

/// A code's label: the emic name first, the English gloss after, then the
/// type, origin and quote count, and what the type holds: both sides of a
/// tension, a vote's counts, a hypothesis for and against, a client
/// question's status.
struct ResearchCodeLabel: View {
    let card: ResearchCard
    let entries: [ResearchEntry]
    /// The tallies to show, already filtered to the selected group.
    let votes: [ResearchVote]

    private var quotes: Int {
        entries.count + entries.filter { $0.counter != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                if card.pinned {
                    Image(systemName: "pin.fill").font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textTertiary).accessibilityLabel("Pinned")
                }
                Text(card.name).font(House.TypeToken.label).foregroundStyle(House.ColorToken.textPrimary)
                if let gloss = card.gloss {
                    Text(gloss).font(House.TypeToken.bodySmall).foregroundStyle(House.ColorToken.textSecondary)
                }
            }
            Text(meta).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.textTertiary)
            detail.font(House.TypeToken.meta).foregroundStyle(House.ColorToken.textSecondary)
        }
    }

    private var meta: String {
        // The type in words and the count; seeded or emerged and the guide
        // questions stay in the file, not on the row (2026-11-14 review).
        var parts = [card.type.label.capitalizedFirstLetter]
        if card.type != .vote { parts.append("\(quotes) \(quotes == 1 ? "quote" : "quotes")") }
        if let provenance = card.provenance, provenance != .spontaneous { parts.append(provenance.label) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var detail: some View {
        switch card.type {
        case .tension:
            if let latest = entries.max(by: { $0.evidence.offsetMs < $1.evidence.offsetMs }), let counter = latest.counter {
                let sides = [(counter.offsetMs, counter.original), (latest.evidence.offsetMs, latest.words)].sorted { $0.0 < $1.0 }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sides.enumerated()), id: \.offset) { _, side in
                        Text("\(GuideExtraction.locator(side.0))  \(side.1)").lineLimit(2)
                    }
                }
            }
        case .vote:
            let votes = votes.sorted { $0.count > $1.count }
            if !votes.isEmpty {
                Text(votes.map { "\($0.choice) \($0.count)" }.joined(separator: " · ")).monospacedDigit()
            }
        case .hypothesis:
            let support = entries.filter { $0.stance == .support }.count, against = entries.filter { $0.stance == .against }.count
            Text("\(support) for · \(against) against").monospacedDigit()
        case .clientQuestion:
            Text("Status: \((card.questionStatus ?? .open).rawValue)")
        default:
            EmptyView()
        }
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        prefix(1).uppercased() + dropFirst()
    }
}
