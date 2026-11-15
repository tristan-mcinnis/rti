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
        /// The English line, or the only line.
        let text: String
        let why: String
        let source: String?
        var pinned = false
        var shownAt: Date?
        /// The Mandarin line, shown first with `text` as a small gloss.
        var textZH: String?
        /// nil when the user's pinyin setting is off.
        var pinyin: String?

        /// What Copy puts on the pasteboard: the line to say.
        var speakable: String {
            textZH ?? text
        }
    }

    struct Question: Equatable {
        let qid: String
        let en: String
        let zh: String
    }

    /// One guide section on the progress strip.
    struct Section: Equatable, Identifiable {
        let id: String
        /// "Warm-up", without the "SECTION n:" label and the minutes.
        let title: String
        let minutes: Int?
    }

    /// What the group said to one guide question, as the guide pass filed
    /// it: its summary and the respondents' own words.
    struct Answer: Equatable, Identifiable {
        let qid: String
        let question: String
        let summary: String
        let quotes: [String]
        var id: String { qid }

        /// What a click on the card copies: the question, the summary and
        /// the quotes, ready to paste into notes.
        var copyText: String {
            var lines = ["**\(question)**"]
            if !summary.isEmpty { lines.append(summary) }
            lines += quotes.map { "- “\($0)”" }
            return lines.joined(separator: "\n")
        }
    }

    var kind: Kind
    var isRecording = false
    /// Auto runs on this call (`AutoAssistSettings.isActive`).
    var autoOn = true
    var isGenerating = false
    var error: String?
    var guideActive = false
    var question: Question?
    /// The guide's sections and the one being asked, for the progress strip.
    var sections: [Section] = []
    var sectionIndex: Int?
    var gaps: [GuideGap] = []
    /// Listening only (the user observes; someone else moderates): the rail
    /// shows what was said per guide question instead of things to ask.
    var listening = false
    var answers: [Answer] = []
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

    /// The strip's one line, such as "2 to ask · 1 to revisit". Topics are
    /// not counted: the brand and theme chips left the rail (2026-11-14).
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
    /// Recorded time spent in a guide section, for the progress strip.
    var sectionElapsed: ((String, Date) -> TimeInterval)?
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
        session: SessionCoordinator = .shared,
        showsPinyin: Bool = AutoAssistSettings.showsPinyin()
    ) -> LiveRailContent {
        let cards = Dictionary(auto.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func card(_ item: LiveRailItem) -> Card? {
            guard let found = cards[item.id] else { return nil }
            return Card(id: item.id, kind: found.kind, text: found.text, why: found.why, source: found.source,
                        pinned: item.state == .pinned, shownAt: item.shownAt, textZH: found.textZH,
                        pinyin: showsPinyin ? found.pinyin : nil)
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
            if let document = guide.guide {
                content.sections = document.sections.map {
                    Section(id: $0.id, title: Section.shortTitle($0.title), minutes: $0.minutes)
                }
                content.sectionIndex = guide.currentQuestionID.flatMap { qid in
                    document.sections.firstIndex { $0.questions.contains { $0.qid == qid } }
                }
            }
        }
        content.listening = session.isListeningOnly
        if content.listening, guide.isActive, let document = guide.guide, let cells = guide.extraction?.cells {
            let byID = Dictionary(cells.map { ($0.qid, $0) }, uniquingKeysWith: { first, _ in first })
            let order = document.questions.map(\.qid)
            let current = guide.currentQuestionID.flatMap { order.firstIndex(of: $0) } ?? order.count - 1
            // The current question, then the two before it that have answers.
            let candidates = order.indices.filter { $0 <= current }.reversed().map { order[$0] }
            content.answers = candidates.compactMap { qid -> Answer? in
                guard let cell = byID[qid], !(cell.summary.isEmpty && cell.quotes.isEmpty),
                      let question = document.questions.first(where: { $0.qid == qid }) else { return nil }
                return Answer(qid: qid, question: question.en, summary: cell.summary,
                              quotes: cell.quotes.map(\.original))
            }.prefix(3).map { $0 }
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
            content.topics = codebook.liveTopicMap()
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
            sectionElapsed: { guide.elapsed(in: $0, at: $1) },
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
    @AppStorage(AutoAssistSettings.pinyinKey) private var pinyinStored: Bool?

    var body: some View {
        LiveAssistRail(content: .live(callType: callType, autoOn: autoOn,
                                      showsPinyin: AutoAssistSettings.showsPinyin(stored: pinyinStored)),
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
    /// Lite keeps the three things a glance needs: where the guide is, what
    /// to go back to, and the next question. Room topics, flags and older
    /// cards stay in the full workspace.
    @Environment(\.rtiLite) private var lite

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: House.Spacing.lg) {
                if content.kind == .research, content.guideActive {
                    questionSection
                    gapsSection
                }
                // Listening only: what was said, not what to ask (2026-11-15).
                if lite, content.listening {
                    answersSection
                } else {
                    nowSection
                }
                // Topics sit above the flags and the faded cards, so the
                // map stays in view in a short window.
                if !lite, let topics = content.topics {
                    LiveRailTopics(map: topics)
                }
                if content.autoOn, !lite {
                    laterSections
                }
            }
            .padding(.horizontal, House.Spacing.sm)
            .padding(.top, House.Spacing.sm)
            // Room for the last card to clear the fade below.
            .padding(.bottom, House.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Cards running past the bottom fade out instead of cutting at a
        // hard edge, which says there is more to scroll (2026-11-15).
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: House.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(House.ColorToken.surfaceSunken)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live help")
    }

    // MARK: Research

    /// The current question in a card with a strip of the guide's sections
    /// underneath, so where the group is reads at a glance (2026-11-15).
    private var questionSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SlateSectionLabel(text: "Now asking")
            VStack(alignment: .leading, spacing: House.Spacing.xs) {
                if !content.sections.isEmpty {
                    LiveGuideProgress(sections: content.sections, index: content.sectionIndex,
                                      elapsed: actions.sectionElapsed)
                }
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
            .padding(House.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LiveRailCardSurface(raised: true))
            .overlay(alignment: .leading) {
                // An accent edge marks the live question apart from the
                // answer cards below.
                UnevenRoundedRectangle(topLeadingRadius: House.Radius.row, bottomLeadingRadius: House.Radius.row,
                                       style: .continuous)
                    .fill(House.ColorToken.accent)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
    }

    private var gapsSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SlateSectionLabel(text: "Go back to")
            if content.gaps.isEmpty {
                LiveRailEmptyLine("Nothing missed so far.")
            } else {
                // Two at most: the side panel is read in a glance (2026-11-14).
                ForEach(content.gaps.prefix(LiveRailLimits.gaps)) { gap in
                    LiveRailGapRow(gap: gap, enabled: content.isRecording) { actions.jump(gap.qid) }
                }
                if content.gaps.count > LiveRailLimits.gaps {
                    LiveRailEmptyLine("\(content.gaps.count - LiveRailLimits.gaps) more in the Guide.")
                }
            }
        }
    }

    private var answersSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            SlateSectionLabel(text: "What they said")
            if content.answers.isEmpty {
                LiveRailEmptyLine(content.guideActive
                    ? "Answers show here by guide question, every couple of minutes."
                    : "Choose a guide on Prepare to see answers by question.")
            } else {
                ForEach(content.answers) { answer in
                    LiveRailAnswerCard(answer: answer) { actions.copy(answer.copyText) }
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
                // One suggestion at a time on research calls (2026-11-14).
                cards: content.kind == .research ? LiveRailLimits.research(content.now) : content.now,
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
                            textZH: card.textZH, pinyin: card.pinyin,
                            pinned: card.pinned, dimmed: index > 0 && !card.pinned,
                            compact: compactOlder && index > 0 && !card.pinned,
                            actions: .init(pin: { actions.pin(card.id) }, dismiss: { actions.dismiss(card.id) },
                                           copy: { actions.copy(card.speakable) })
                        )
                        .padding(House.Spacing.xs)
                        .modifier(LiveRailCardSurface(raised: index == 0 || card.pinned))
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

/// One guide question's answers. The whole card is the copy target
/// (2026-11-15): hover shows a pointer and a "Copy" hint, a press sinks the
/// card a little, and a copy rings it in the accent with "Copied" for 1.5 s
/// and a spoken "Copied" for VoiceOver. It copies the question, summary and
/// every quote as Markdown.
private struct LiveRailAnswerCard: View {
    let answer: LiveRailContent.Answer
    let copy: () -> Void
    @State private var copied = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            copy()
            QuickAIAnnouncement.post("Copied", priority: .high)
            withAnimation(reduceMotion ? nil : .easeOut(duration: House.Motion.open)) { copied = true }
        } label: {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                HStack(spacing: House.Spacing.xs) {
                    Text(answer.question)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if copied || hovering {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                            .font(House.TypeToken.caption.weight(.medium))
                            .foregroundStyle(copied ? House.ColorToken.accent : House.ColorToken.textSecondary)
                            .padding(.horizontal, House.Spacing.xs)
                            .padding(.vertical, House.Spacing.xxs)
                            .background(copied ? House.ColorToken.accentSoft : House.ColorToken.chipFill, in: Capsule())
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
                if !answer.summary.isEmpty {
                    Text(answer.summary)
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(answer.quotes.prefix(2), id: \.self) { quote in
                    Text("“\(quote)”")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if answer.quotes.count > 2 {
                    Text("+\(answer.quotes.count - 2) more quotes in the copy")
                        .font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
            }
            .padding(House.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(LiveRailCopyCardStyle(hovering: hovering, copied: copied))
        .hoverHighlight($hovering)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("Click to copy this question, its summary and quotes")
        .accessibilityLabel("Answers to \(answer.question)")
        .accessibilityHint("Copies the question, summary and quotes")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { copied = false }
        }
    }
}

/// The copy card's surface: raised white on the rail, a firmer edge on
/// hover, sunk slightly while pressed, ringed in the accent once copied.
private struct LiveRailCopyCardStyle: ButtonStyle {
    let hovering: Bool
    let copied: Bool
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.row, style: .continuous)
        configuration.label
            .background(House.ColorToken.surfaceRaised, in: shape)
            .overlay {
                if configuration.isPressed || hovering { shape.fill(House.ColorToken.hoverFill) }
            }
            .overlay {
                shape.strokeBorder(copied ? House.ColorToken.accent
                                          : (hovering ? House.ColorToken.strokeStrong : House.ColorToken.stroke),
                                   lineWidth: copied ? 1.5 : House.hairline)
            }
            .shadow(color: .black.opacity(House.Shadow.card.opacity(dark: scheme == .dark)),
                    radius: House.Shadow.card.blur / 2, y: House.Shadow.card.y)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Where the group is in the guide: one segment per section, as wide as its
/// planned minutes, done sections filled, the current one filling with the
/// time spent in it. The line under it names the section and its minutes;
/// it turns amber past the plan. Redrawn every 30 seconds.
struct LiveGuideProgress: View {
    let sections: [LiveRailContent.Section]
    let index: Int?
    let elapsed: ((String, Date) -> TimeInterval)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let spent = current.flatMap { section in elapsed?(section.id, context.date) } ?? 0
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                strip(spent: spent)
                    .frame(height: 4)
                if let line = Self.caption(sections: sections, index: index, spentMinutes: Int(spent / 60)) {
                    Text(line.text)
                        .font(House.TypeToken.caption)
                        .foregroundStyle(line.over ? House.ColorToken.warning : House.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var current: LiveRailContent.Section? {
        index.flatMap { sections.indices.contains($0) ? sections[$0] : nil }
    }

    private func strip(spent: TimeInterval) -> some View {
        GeometryReader { geometry in
            let weights = sections.map { CGFloat(max(1, $0.minutes ?? 5)) }
            let gap: CGFloat = 2
            let usable = max(0, geometry.size.width - gap * CGFloat(max(0, sections.count - 1)))
            let total = weights.reduce(0, +)
            HStack(spacing: gap) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { offset, section in
                    let width = total > 0 ? usable * weights[offset] / total : 0
                    let fill: CGFloat = {
                        guard let index else { return 0 }
                        if offset < index { return 1 }
                        if offset > index { return 0 }
                        let planned = Double(max(1, section.minutes ?? 5)) * 60
                        return CGFloat(min(1, max(0.08, spent / planned)))
                    }()
                    let over = offset == index && section.minutes.map { spent > Double($0) * 60 } == true
                    ZStack(alignment: .leading) {
                        Capsule().fill(House.ColorToken.surfaceTint)
                        Capsule()
                            .fill(over ? House.ColorToken.warning : House.ColorToken.accent)
                            .opacity(offset == index ? 1 : 0.45)
                            .frame(width: width * fill)
                    }
                    .frame(width: width)
                }
            }
        }
    }

    /// "Section 3 of 6 · Athletes · 7 of 10 min"; nil before the guide has
    /// a position.
    static func caption(sections: [LiveRailContent.Section], index: Int?, spentMinutes: Int)
        -> (text: String, over: Bool)?
    {
        guard let index, sections.indices.contains(index) else { return nil }
        let section = sections[index]
        var parts = ["Section \(index + 1) of \(sections.count)"]
        if !section.title.isEmpty { parts.append(section.title) }
        var over = false
        if let minutes = section.minutes {
            over = spentMinutes > minutes
            parts.append(over ? "\(spentMinutes) min, \(minutes) planned" : "\(spentMinutes) of \(minutes) min")
        }
        return (parts.joined(separator: " · "), over)
    }
}

extension LiveRailContent.Section {
    /// A guide heading without its "SECTION 2:" label and "(10 min)" tail.
    static func shortTitle(_ heading: String) -> String {
        var text = heading
        if let range = text.range(of: #"^\s*(?i:section)\s*\d+\s*[:：.-]?\s*"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        if let range = text.range(of: #"\s*[(（]\s*\d+\s*(?i:min(ute)?s?)\s*[)）]\s*$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// The card that matters now sits on the grey rail as a white raised card
/// with a hairline, so it reads as an object, not text on grey (2026-11-15:
/// "white on white with a shadow, hard to see what's going on"). Older,
/// dimmed cards stay flat.
private struct LiveRailCardSurface: ViewModifier {
    let raised: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if raised {
            content
                .background(House.ColorToken.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: House.Radius.row, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: House.Radius.row, style: .continuous)
                        .strokeBorder(House.ColorToken.strokeStrong, lineWidth: House.hairline)
                }
                .shadow(color: .black.opacity(House.Shadow.card.opacity(dark: scheme == .dark)),
                        radius: House.Shadow.card.blur / 2, y: House.Shadow.card.y)
        } else {
            content
        }
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
        // Over the card, so the light shows on a raised white card too.
        content
            .overlay { RowHighlight(isSelected: lit, radius: House.Radius.row).allowsHitTesting(false) }
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
                    AutoCardRow(kind: card.kind, text: card.text, why: "", source: card.source,
                                textZH: card.textZH, dimmed: true,
                                actions: .init(copy: { copy(card.speakable) }))
                        .padding(.horizontal, House.Spacing.xs)
                }
            }
        }
    }
}

// MARK: - Topics

/// The codebook as a map of meanings: tensions with both sides, votes with
/// their counts, hypotheses for and against, client questions, then brands
/// and themes as chips with a quote count and a tone dot. Emic names come
/// first, the English gloss after. The topic that moved last is lit for a
/// moment.
/// What the room is working through, in words: tensions, votes, hypotheses
/// and client questions, three at most. Brand and theme chips, and their tone
/// dots, live in the Codebook, not here (2026-11-14 review: the dots had no
/// legend and the chips were noise during a group).
private struct LiveRailTopics: View {
    let map: ResearchTopicMap
    @State private var lit: UUID?
    @State private var lastNewest: UUID?

    private var topics: [ResearchTopic] {
        map.sections.filter { !$0.group.isChips }.flatMap(\.topics)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            SlateSectionLabel(text: "From the room")
            if topics.isEmpty {
                LiveRailEmptyLine("Tensions and open questions from the room show here.")
            } else {
                ForEach(topics.prefix(LiveRailLimits.topics)) { topic in
                    LiveRailTopicRow(topic: topic, lit: lit == topic.id)
                }
                if topics.count > LiveRailLimits.topics {
                    LiveRailEmptyLine("\(topics.count - LiveRailLimits.topics) more in the Codebook.")
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

/// How much the side panel shows at once.
enum LiveRailLimits {
    static let gaps = 2
    static let topics = 3

    /// Research shows one suggestion at a time, but a pinned card always
    /// stays: pinned first, then the newest unpinned one.
    static func research(_ cards: [LiveRailContent.Card]) -> [LiveRailContent.Card] {
        cards.filter(\.pinned) + cards.filter { !$0.pinned }.prefix(1)
    }
}

/// The emic name, then the English gloss in a quieter tone.
private struct LiveRailTopicName: View {
    let topic: ResearchTopic

    var body: some View {
        if let gloss = topic.gloss {
            Text(topic.name).foregroundStyle(House.ColorToken.textPrimary)
                + Text(" " + gloss).foregroundStyle(House.ColorToken.textSecondary)
        } else {
            Text(topic.name).foregroundStyle(House.ColorToken.textPrimary)
        }
    }
}

/// A tension, vote, hypothesis or client question: the name on one line,
/// what it holds below.
private struct LiveRailTopicRow: View {
    let topic: ResearchTopic
    let lit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            LiveRailTopicName(topic: topic)
                .font(House.TypeToken.meta)
                .lineLimit(2)
            detail
                .font(House.TypeToken.caption)
                .foregroundStyle(House.ColorToken.textSecondary)
        }
        .padding(.vertical, House.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if lit {
                RowHighlight(isSelected: true, radius: House.Radius.sm)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(topic.spoken)
        .help(topic.spoken)
    }

    @ViewBuilder private var detail: some View {
        switch topic.type {
        case .tension:
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(topic.sides.enumerated()), id: \.offset) { _, side in
                    Text("\(ResearchTopic.Side.clock(side.offsetMs))  \(side.words)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        case .vote:
            Text(topic.tallies.map { "\($0.choice) \($0.count)" }.joined(separator: " · "))
                .monospacedDigit()
        case .hypothesis:
            Text("\(topic.support) for · \(topic.against) against")
                .monospacedDigit()
        case .clientQuestion:
            Text((topic.status ?? .open).rawValue.capitalizedFirst)
        default:
            Text("\(topic.mentions) \(topic.mentions == 1 ? "quote" : "quotes")")
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
