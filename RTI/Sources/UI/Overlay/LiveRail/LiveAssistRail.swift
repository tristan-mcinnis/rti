import AppKit
import HouseDesign
import RTICore
import SwiftUI

// MARK: - Layout

/// Where live help sits beside the transcript: a rail when the window is
/// wide enough, otherwise a one-line strip over the transcript.
enum LiveRailLayout {
    enum Mode: Equatable {
        case none, rail, strip
    }

    /// About 290 pt: the chat rail plus the widest spacing step.
    static let width = House.Layout.chatRail + House.Spacing.xxxxl
    /// Below this panel width the rail folds into the strip.
    static let stripBelow = House.Layout.chatMinWidth + House.Spacing.xxl

    static func mode(width: CGFloat, applies: Bool) -> Mode {
        guard applies else { return .none }
        return width < stripBelow ? .strip : .rail
    }
}

// MARK: - Content

/// What the live rail shows, read from the live controllers in one place.
/// A value, so a render proof can draw any state without a live call. The
/// rail keeps no state of its own: the cards' life cycle is the pacer's.
struct LiveRailContent: Equatable {
    enum Kind: Equatable {
        case client, research
    }

    struct Card: Identifiable, Equatable {
        let id: UUID
        let kind: AutoCardKind
        let text: String
        let why: String
        let source: String?
        var pinned = false
        var shownAt: Date?
    }

    struct Question: Equatable {
        let qid: String
        let en: String
        let zh: String
    }

    var kind: Kind
    var isRecording = false
    /// Auto runs on this call (`AutoAssistSettings.isActive`).
    var autoOn = true
    var isGenerating = false
    var error: String?
    var guideActive = false
    var question: Question?
    var gaps: [GuideGap] = []
    var now: [Card] = []
    var threads: [Card] = []
    var earlier: [Card] = []
    /// Cards the pacer is still holding back, per lane.
    var nowWaiting = 0
    var threadsWaiting = 0
    /// The card admitted at the user's request ("Suggest now"). When it
    /// changes, a lane held under the pointer lets it in.
    var requestedID: UUID?
    /// Research calls only, and only while this call records: the codebook
    /// browsed before or after a call is the project's last session.
    var topics: ResearchTopicMap?

    var nowTitle: String {
        kind == .research ? "To ask" : "Now"
    }

    var threadsTitle: String {
        kind == .research ? "Flags" : "Open threads"
    }

    /// The strip's one line, such as "2 to ask · 1 to revisit · 14 topics".
    /// A gap is a question passed thin or skipped, so it is one to revisit,
    /// not one missed.
    var summary: String {
        var parts: [String] = []
        switch kind {
        case .research:
            if !now.isEmpty {
                parts.append("\(now.count) to ask")
            }
            if !threads.isEmpty {
                parts.append(Self.count(threads.count, "flag"))
            }
            if !gaps.isEmpty {
                parts.append("\(gaps.count) to revisit")
            }
            if let topics, topics.total > 0 {
                parts.append(Self.count(topics.total, "topic"))
            }
        case .client:
            if !now.isEmpty {
                parts.append(Self.count(now.count, "suggestion"))
            }
            if !threads.isEmpty {
                parts.append(Self.count(threads.count, "open thread"))
            }
        }
        if parts.isEmpty {
            guard autoOn else { return "Auto is off for this call" }
            return kind == .research ? "Nothing to ask yet" : "No suggestions yet"
        }
        return parts.joined(separator: " · ")
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

/// What a rail control does. The live host routes these to the controllers.
struct LiveRailActions {
    var jump: (String) -> Void = { _ in }
    var pin: (UUID) -> Void = { _ in }
    var dismiss: (UUID) -> Void = { _ in }
    var copy: (String) -> Void = { _ in }
    /// Client calls only.
    var suggestNow: (() -> Void)?
}

@MainActor
extension LiveRailContent {
    /// Read the live controllers. Called from a view's body, so the rail
    /// redraws when any of them changes.
    static func live(
        callType: CallType,
        autoOn: Bool,
        auto: AutoAssistController = .shared,
        guide: GuideSessionController = .shared,
        codebook: ResearchCodebookController = .shared,
        session: SessionCoordinator = .shared
    ) -> LiveRailContent {
        let cards = Dictionary(auto.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func card(_ item: LiveRailItem) -> Card? {
            guard let found = cards[item.id] else { return nil }
            return Card(id: item.id, kind: found.kind, text: found.text, why: found.why, source: found.source,
                        pinned: item.state == .pinned, shownAt: item.shownAt)
        }
        var content = LiveRailContent(kind: callType == .research ? .research : .client)
        content.isRecording = session.isRunning
        content.autoOn = autoOn
        content.isGenerating = auto.isGenerating
        content.error = auto.lastError
        content.guideActive = guide.isActive
        if guide.isActive {
            content.question = guide.currentQuestionID.flatMap { qid in
                guide.guide?.questions.first { $0.qid == qid }
            }.map { Question(qid: $0.qid, en: $0.en, zh: $0.zh) }
            content.gaps = guide.gaps
        }
        if autoOn {
            content.now = auto.rail.nowItems.compactMap(card)
            content.threads = auto.rail.threadItems.compactMap(card)
            content.earlier = auto.rail.earlier.compactMap(card)
            content.nowWaiting = auto.rail.waitingCount(in: .now)
            content.threadsWaiting = auto.rail.waitingCount(in: .threads)
            content.requestedID = auto.rail.requestedID
        }
        // Topics only while this call records, and only from this call's
        // codebook: before and after a call it shows the project's last
        // session, whose counts are not live.
        if callType == .research, session.isRunning,
           codebook.location.map({ $0.session.id == session.currentSessionId }) ?? true
        {
            content.topics = codebook.book.topicMap(sessionID: codebook.location?.session.id)
        }
        return content
    }
}

@MainActor
extension LiveRailActions {
    static func live(auto: AutoAssistController = .shared, guide: GuideSessionController = .shared,
                     callType: CallType) -> LiveRailActions
    {
        LiveRailActions(
            jump: { guide.jump(to: $0) },
            pin: { auto.pin($0) },
            dismiss: { auto.dismiss($0) },
            copy: { NSPasteboard.copyString($0) },
            suggestNow: callType == .research ? nil : {
                guard let sid = SessionCoordinator.shared.currentSessionId else { return }
                Task { _ = await auto.generate(sessionId: sid, explicit: true) }
            }
        )
    }
}

// MARK: - Live hosts

/// The rail beside the live transcript, reading the live controllers.
/// Mounted only while the Live page and its Transcript tab are on screen.
struct LiveAssistRailHost: View {
    let callType: CallType
    let autoOn: Bool

    var body: some View {
        LiveAssistRail(content: .live(callType: callType, autoOn: autoOn),
                       actions: .live(callType: callType))
    }
}

/// The strip that stands in for the rail in a narrow window. `open` asks
/// the Live page for the rail's sheet.
struct LiveRailStripHost: View {
    let callType: CallType
    let autoOn: Bool
    let open: () -> Void

    var body: some View {
        LiveRailStrip(summary: LiveRailContent.live(callType: callType, autoOn: autoOn).summary, open: open)
    }
}

// MARK: - Rail

/// Live help beside the transcript. A research call shows the guide's
/// current question, what was missed, follow-ups and the topic map; a client
/// call shows the newest suggestions and open threads. Calm by design: the
/// pacer admits one card a minute, the newest card is lit for a moment,
/// older cards are dimmed, and nothing moves while the pointer is over a
/// list.
struct LiveAssistRail: View {
    let content: LiveRailContent
    var actions = LiveRailActions()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: House.Spacing.lg) {
                if content.kind == .research, content.guideActive {
                    questionSection
                    gapsSection
                }
                nowSection
                // Topics sit above the flags and the faded cards, so the
                // map stays in view in a short window.
                if let topics = content.topics {
                    LiveRailTopics(map: topics)
                }
                if content.autoOn {
                    laterSections
                }
            }
            .padding(.horizontal, House.Spacing.sm)
            .padding(.vertical, House.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(House.ColorToken.surfaceSunken)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live help")
    }

    // MARK: Research

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SlateSectionLabel(text: "Now asking")
            if let question = content.question {
                Text(question.en)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !question.zh.isEmpty {
                    Text(question.zh)
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LiveRailEmptyLine("The guide's current question shows here.")
            }
        }
    }

    private var gapsSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SlateSectionLabel(text: "Go back to")
            if content.gaps.isEmpty {
                LiveRailEmptyLine("Nothing missed so far.")
            } else {
                ForEach(content.gaps) { gap in
                    LiveRailGapRow(gap: gap, enabled: content.isRecording) { actions.jump(gap.qid) }
                }
            }
        }
    }

    // MARK: Cards

    @ViewBuilder
    private var nowSection: some View {
        if !content.autoOn {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                SlateSectionLabel(text: content.nowTitle)
                LiveRailEmptyLine("Auto is off for this call. Turn it on in Prepare.")
            }
        } else {
            LiveRailLane(
                title: content.nowTitle,
                cards: content.now,
                waiting: content.nowWaiting,
                requestedID: content.requestedID,
                // With a guide on screen, older asks fold to one line so the
                // topic map stays in view.
                compactOlder: content.kind == .research && content.guideActive,
                empty: emptyNowCopy,
                actions: actions,
                trailing: { nowTrailing }
            )
        }
    }

    @ViewBuilder
    private var laterSections: some View {
        if !content.threads.isEmpty || content.threadsWaiting > 0 || content.kind == .client {
            LiveRailLane(
                title: content.threadsTitle,
                cards: content.threads,
                waiting: content.threadsWaiting,
                requestedID: content.requestedID,
                empty: "Unsettled owners and dates show here.",
                actions: actions,
                trailing: { EmptyView() }
            )
        }
        if !content.earlier.isEmpty {
            LiveRailEarlier(cards: content.earlier, copy: actions.copy)
        }
        if let error = content.error {
            Text(error)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyNowCopy: String {
        guard content.isRecording else { return "Start a recording to get suggestions." }
        return content.kind == .research
            ? "Follow-up questions show here as the group talks."
            : "Suggestions show here as the call goes on."
    }

    @ViewBuilder
    private var nowTrailing: some View {
        if content.isGenerating {
            ProgressView().controlSize(.mini).accessibilityLabel("Reading the call")
        }
        if let suggestNow = actions.suggestNow {
            LiveRailTextButton(title: "Suggest now", disabled: !content.isRecording || content.isGenerating,
                               action: suggestNow)
        }
    }
}

// MARK: - Pieces

/// A plain line for an empty section.
struct LiveRailEmptyLine: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A quiet text action in a section header.
struct LiveRailTextButton: View {
    let title: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(House.TypeToken.meta)
                .foregroundStyle(disabled ? House.ColorToken.textTertiary : House.ColorToken.textSecondary)
                .padding(.horizontal, House.Spacing.xs)
                .frame(height: House.Control.keyCap)
                .background { RowHighlight(isSelected: false, isHovering: hovering && !disabled, radius: House.Radius.sm) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .hoverHighlight($hovering)
        .help(title)
    }
}

/// One passed question to return to. A click moves the guide back to it.
private struct LiveRailGapRow: View {
    let gap: GuideGap
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                Image(systemName: "arrow.uturn.backward")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    Text(gap.title)
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .lineLimit(2)
                    // The Mandarin wording under the English, as "Now
                    // asking" shows it, so a Mandarin session has words to use.
                    if let zh = gap.titleZH, !zh.isEmpty {
                        Text(zh)
                            .font(House.TypeToken.caption)
                            .foregroundStyle(House.ColorToken.textSecondary)
                            .lineLimit(2)
                    }
                    Text(gap.detail)
                        .font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, House.Spacing.xs)
            .padding(.vertical, House.Spacing.xxs)
            .background { RowHighlight(isSelected: false, isHovering: hovering && enabled, radius: House.Radius.sm) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .hoverHighlight($hovering)
        .accessibilityLabel("Go back to \(gap.title). \(gap.titleZH.map { "\($0). " } ?? "")\(gap.detail)")
        .help(enabled ? "Go back to this question" : "Start a recording to move the guide")
    }
}

/// One lane of cards, newest first. While the pointer is over the lane the
/// list holds still; a new arrival waits, counted in the header, until the
/// pointer leaves. Two things break the hold: a dismissed card leaves at
/// once, and a card the user asked for ("Suggest now") comes in.
private struct LiveRailLane<Trailing: View>: View {
    let title: String
    let cards: [LiveRailContent.Card]
    /// Cards the pacer still holds back.
    var waiting = 0
    var requestedID: UUID?
    /// Older unpinned cards show one line.
    var compactOlder = false
    let empty: String
    let actions: LiveRailActions
    @ViewBuilder var trailing: Trailing

    @State private var held: [LiveRailContent.Card]?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: [LiveRailContent.Card] {
        LiveRailHold.shown(cards: cards, held: held)
    }

    private var arrived: Int {
        LiveRailHold.arrived(cards: cards, held: held)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            HStack(spacing: House.Spacing.xs) {
                SlateSectionLabel(text: title)
                if arrived > 0 {
                    Text("\(arrived) new")
                        .font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
                if waiting > 0 {
                    Text("\(waiting) waiting")
                        .font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .help("The rail shows one new card a minute.")
                }
                Spacer(minLength: House.Spacing.xs)
                trailing
            }
            if shown.isEmpty {
                LiveRailEmptyLine(empty)
            } else {
                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, card in
                        AutoCardRow(
                            kind: card.kind, text: card.text, why: card.why, source: card.source,
                            pinned: card.pinned, dimmed: index > 0 && !card.pinned,
                            compact: compactOlder && index > 0 && !card.pinned,
                            actions: .init(pin: { actions.pin(card.id) }, dismiss: { actions.dismiss(card.id) },
                                           copy: { actions.copy(card.text) })
                        )
                        .padding(House.Spacing.xs)
                        .modifier(LiveRailFreshHighlight(shownAt: card.shownAt))
                        .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: shown.map(\.id))
            }
        }
        // `hoverHighlight` keeps the hover closure off the main-actor check
        // (see its note); the hold follows the flag.
        .hoverHighlight($hovering)
        .onChange(of: hovering) { _, inside in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                held = inside ? cards : nil
            }
        }
        // A card the user asked for comes in even under the pointer.
        .onChange(of: requestedID) { _, _ in
            if held != nil {
                held = cards
            }
        }
    }
}

/// What a lane draws while the pointer holds it still.
enum LiveRailHold {
    /// The held list, with each card's current state. A card no longer in
    /// `cards` (dismissed, faded) drops out at once.
    static func shown(cards: [LiveRailContent.Card], held: [LiveRailContent.Card]?) -> [LiveRailContent.Card] {
        guard let held else { return cards }
        let current = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return held.compactMap { current[$0.id] }
    }

    /// Cards that arrived while the list was held.
    static func arrived(cards: [LiveRailContent.Card], held: [LiveRailContent.Card]?) -> Int {
        guard let held else { return 0 }
        let ids = Set(held.map(\.id))
        return cards.filter { !ids.contains($0.id) }.count
    }
}

/// Lights a card that just arrived, then lets it settle. The light is a
/// selection fill that fades; the card never moves.
private struct LiveRailFreshHighlight: ViewModifier {
    static let window: TimeInterval = 4
    let shownAt: Date?
    @State private var lit: Bool

    init(shownAt: Date?) {
        self.shownAt = shownAt
        _lit = State(initialValue: Self.isFresh(shownAt, now: Date()))
    }

    static func isFresh(_ shownAt: Date?, now: Date) -> Bool {
        guard let shownAt else { return false }
        let age = now.timeIntervalSince(shownAt)
        return age >= 0 && age < window
    }

    func body(content: Content) -> some View {
        content
            .background { RowHighlight(isSelected: lit, radius: House.Radius.row) }
            .task(id: shownAt) {
                guard let shownAt, Self.isFresh(shownAt, now: Date()) else { return }
                lit = true
                let remaining = Self.window - Date().timeIntervalSince(shownAt)
                try? await Task.sleep(for: .seconds(max(0, remaining)))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.6)) { lit = false }
            }
    }
}

/// Cards that faded, folded under one line.
private struct LiveRailEarlier: View {
    let cards: [LiveRailContent.Card]
    let copy: (String) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: House.Spacing.xxs) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(House.TypeToken.micro)
                    Text("Earlier (\(cards.count))")
                        .font(House.TypeToken.meta)
                }
                .foregroundStyle(House.ColorToken.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Open" : "Closed")
            if open {
                ForEach(cards) { card in
                    AutoCardRow(kind: card.kind, text: card.text, why: "", source: card.source, dimmed: true,
                                actions: .init(copy: { copy(card.text) }))
                        .padding(.horizontal, House.Spacing.xs)
                }
            }
        }
    }
}

// MARK: - Topics

/// The codebook's topics as chips: a mention count and a tone dot each,
/// grouped Brands, Concepts, Hypotheses. The topic that moved last is lit
/// for a moment.
private struct LiveRailTopics: View {
    let map: ResearchTopicMap
    @State private var lit: UUID?
    @State private var lastNewest: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            HStack(spacing: House.Spacing.xs) {
                SlateSectionLabel(text: "Topics")
                if map.total > 0 {
                    Text("\(map.total)")
                        .font(House.TypeToken.caption.monospacedDigit())
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
            }
            if map.sections.isEmpty {
                LiveRailEmptyLine("Brands and ideas the group mentions show here.")
            } else {
                ForEach(Array(map.sections.enumerated()), id: \.element.group) { index, section in
                    VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                        Text(section.group.title)
                            .font(House.TypeToken.caption)
                            .foregroundStyle(House.ColorToken.textTertiary)
                        LiveRailFlowLayout(spacing: House.Spacing.xxs) {
                            ForEach(section.topics) { topic in
                                LiveRailTopicChip(topic: topic, lit: lit == topic.id)
                            }
                            if index == map.sections.count - 1, map.hidden > 0 {
                                Text("+\(map.hidden)")
                                    .font(House.TypeToken.meta.monospacedDigit())
                                    .foregroundStyle(House.ColorToken.textTertiary)
                                    .padding(.horizontal, House.Spacing.xs)
                                    .frame(height: House.Control.tile)
                                    .accessibilityLabel("\(map.hidden) more topics")
                            }
                        }
                    }
                }
            }
        }
        .onAppear { lastNewest = map.newestID }
        .onChange(of: map.newestID) { _, newest in
            guard let newest, newest != lastNewest else { return }
            lastNewest = newest
            lit = newest
        }
        .task(id: lit) {
            guard lit != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { lit = nil }
        }
    }
}

private struct LiveRailTopicChip: View {
    let topic: ResearchTopic
    let lit: Bool

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            SlateStatusDot(color: topic.valence.dotColor)
            Text(topic.name)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(topic.mentions)")
                .font(House.TypeToken.meta.monospacedDigit())
                .foregroundStyle(House.ColorToken.textTertiary)
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(height: House.Control.tile)
        .frame(maxWidth: LiveRailLayout.width - House.Spacing.xl, alignment: .leading)
        .background {
            if lit {
                RowHighlight(isSelected: true, radius: House.Radius.sm)
            } else {
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous).fill(House.ColorToken.chipFill)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(topic.name), \(topic.mentions) \(topic.mentions == 1 ? "mention" : "mentions"), \(topic.valence.rawValue)")
        .help("\(topic.mentions) \(topic.mentions == 1 ? "mention" : "mentions"), \(topic.valence.rawValue)")
    }
}

extension ResearchValence {
    /// The tone dot. The chip's label and tooltip say the word too.
    var dotColor: Color {
        switch self {
        case .positive: House.ColorToken.success
        case .negative: House.ColorToken.danger
        case .mixed: House.ColorToken.warning
        case .neutral: House.ColorToken.textTertiary
        }
    }
}

/// Lays chips left to right and wraps to a new row when the next one does
/// not fit.
struct LiveRailFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(for: subviews, width: width)
        let used = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = fitted(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func fitted(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: ideal.height))
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = fitted(subviews[index], width: width)
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if added > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
