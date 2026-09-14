// Copied from quick-launch@b9ee129 Sources/Views/QuickAIThread.swift,
// CollapsibleMessageText.swift, and Sources/Models/MessageCollapse.swift
import AppKit
import RTICore
import SwiftUI

// The Assist thread in the house chat grammar (design-system
// docs/chat-surfaces.md section 2): questions as pills on the right, answers
// as prose on the left with no card, tool and status lines above an answer,
// its sources under it, the error line with Retry, empty hints, and the
// Latest chip. Quick Launch's `QuickAIThread` is the reference; the names
// are kept where the pieces match (`toolLine`, `sourceList`, `userPill`).
//
// Adapted for RTI's macOS 14 floor: `ScrollViewReader` and a measured
// content frame stand in for `ScrollPosition` and `onScrollGeometryChange`
// (macOS 15). The view reads values only (`AssistThreadModel`); the adapter
// in `ResponseView` fills them from `LLMController`. RTI divergences, to be
// registered: a canned action's pill carries its glyph; answers cap at
// `Layout.answerMaxWidth` (620), since the overlay can be 600 wide.

// MARK: - Model

/// What the thread draws. Built by `ResponseView` from `LLMController`, or
/// by a render proof from fixtures.
struct AssistThreadModel {
    /// A provider error under the question it failed.
    struct TurnError: Equatable {
        let questionID: UUID
        let message: String
    }

    var entries: [ChatEntry] = []
    /// The answer being streamed, if one is.
    var streamingID: UUID?
    /// The status line while the streamed answer has no text yet.
    var streamingStatus = "Thinking…"
    /// Placeholder answers that are a status, not text yet (the vault
    /// search ahead of an Ask).
    var progress: [UUID: String] = [:]
    var turnError: TurnError?
    /// The depth a Recap pill names.
    var recapDepth: RecapDepth = .standard
    /// Shown, centred, only while the thread is empty.
    var emptyHints: [String] = []
    /// Answer prose size: the text-size setting, 14 by default.
    var proseSize: CGFloat = House.TypeToken.Size.body

    /// The words a user turn's pill shows: a canned action's name (never
    /// its prompt), else what was typed.
    func pillText(for entry: ChatEntry) -> String {
        if let action = entry.action, ChatTurnRecordBuilder.cannedAction(for: action) != nil {
            return ChatTurnRecordBuilder.pillLabel(forAction: action, recapDepth: recapDepth)
        }
        return entry.text
    }
}

/// What the thread can ask its owner to do.
struct AssistThreadActions {
    /// Retry the failed question (the error line, `⌘R`).
    var retry: () -> Void = {}
    /// Copy an answer's Markdown.
    var copy: (String) -> Void = { NSPasteboard.copyString($0) }
    /// Open a source row (an RTI session in Sessions, a vault file in Finder).
    var openSource: (ChatSource) -> Void = { _ in }
}

// MARK: - Thread

/// The Assist thread: one centred reading column that follows the newest
/// text only while the reader is at the bottom.
struct AssistThread: View {
    let model: AssistThreadModel
    /// Find in Chat's hits, painted in the text. Nil when the bar is shut.
    var find: ThreadFindHighlights? = nil
    var actions = AssistThreadActions()
    /// False draws the thread as a reader who scrolled up left it (render
    /// proofs of the Latest chip).
    var startsFollowingBottom = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether new text scrolls the view down. Set only by a move of the
    /// view, never by text landing under a still one.
    @State private var following = true
    @State private var geometry = ThreadGeometry()
    /// Questions opened past their collapsed preview.
    @State private var expanded: Set<UUID> = []

    private static let space = "rti-assist-thread"
    private static let bottomID = "rti-assist-thread-bottom"
    /// The key the Latest chip names: ⌘↓.
    static let jumpToLatestKeys = ["⌘", "↓"]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    column
                        .background {
                            GeometryReader { inner in
                                Color.clear.preference(key: ContentFrameKey.self, value: inner.frame(in: .named(Self.space)))
                            }
                        }
                    Color.clear
                        .frame(height: House.hairline)
                        .id(Self.bottomID)
                }
            }
            .coordinateSpace(name: Self.space)
            .background {
                GeometryReader { outer in
                    Color.clear.preference(key: ViewportHeightKey.self, value: outer.size.height)
                }
            }
            .onPreferenceChange(ViewportHeightKey.self) { height in
                geometry.visibleHeight = height
            }
            .onPreferenceChange(ContentFrameKey.self) { frame in
                // Only a move of the view (the reader's scroll, or one the
                // thread made) decides whether it follows the bottom.
                let moved = frame.minY != geometry.top
                geometry.top = frame.minY
                geometry.contentHeight = frame.height
                if moved { following = geometry.distanceFromBottom <= House.Control.row }
            }
            .overlay {
                if model.entries.isEmpty, !model.emptyHints.isEmpty { emptyStateHints(model.emptyHints) }
            }
            .overlay(alignment: .bottom) {
                if !following, !geometry.fitsView { latestChip(proxy) }
            }
            .background { collapseShortcut }
            .onAppear { following = startsFollowingBottom }
            // After the first layout, so there is a bottom to go to (coming
            // back to the tab lands on the newest turn).
            .task {
                if startsFollowingBottom { scrollToEnd(proxy, animated: false) }
            }
            // A new question follows the bottom again.
            .onChange(of: model.entries.count) { _, _ in
                following = true
                scrollToEnd(proxy, animated: true)
            }
            .onChange(of: liveTextLength) { _, _ in
                if following { scrollToEnd(proxy, animated: false) }
            }
            .onChange(of: model.turnError) { _, error in
                if following { scrollToEnd(proxy, animated: true) }
                if let error { QuickAIAnnouncement.post("Error. \(error.message)", priority: .high) }
            }
            .onChange(of: find?.current) { _, hit in
                guard let hit else { return }
                // Brings the hit into view without laying the text out: the
                // point at the hit's fraction of its turn meets the same
                // fraction of the view.
                animate { proxy.scrollTo(hit.entryID, anchor: UnitPoint(x: 0.5, y: hit.position)) }
            }
        }
        .accessibilityLabel("Assist conversation")
    }

    /// The one reading column, centred, as wide as the house thread allows.
    private var column: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            ForEach(model.entries) { entry in
                turn(entry)
                    .id(entry.id)
                if let error = model.turnError, error.questionID == entry.id {
                    threadErrorLine(error.message)
                }
            }
        }
        .frame(maxWidth: House.Layout.panelWidth - 2 * House.Spacing.lg, alignment: .leading)
        .padding(.top, House.Spacing.xl)
        .padding(.horizontal, House.Spacing.lg)
        .padding(.bottom, House.Spacing.md)
        .frame(maxWidth: .infinity)
    }

    /// Grows while an answer streams, so the view can follow it down.
    private var liveTextLength: Int {
        guard let id = model.streamingID else { return 0 }
        return model.entries.last { $0.id == id }?.text.utf16.count ?? 0
    }

    // MARK: Turns

    @ViewBuilder
    private func turn(_ entry: ChatEntry) -> some View {
        if entry.role == "user" {
            questionTurn(entry)
        } else if let status = model.progress[entry.id] {
            toolLine(status, symbol: nil)
        } else if entry.id == model.streamingID {
            liveAnswer(entry)
        } else {
            AssistAnswerRow(
                text: entry.text,
                tools: entry.tools,
                sources: entry.sources,
                markdown: find?.markedAnswer(entry.text, entryID: entry.id) ?? entry.text,
                findMarks: !(find?.ranges(in: entry.id, part: .answer).isEmpty ?? true),
                proseSize: model.proseSize,
                copy: actions.copy,
                openSource: actions.openSource
            )
            .equatable()
        }
    }

    private func questionTurn(_ entry: ChatEntry) -> some View {
        let refs = sentAttachments(of: entry)
        let canned = ChatTurnRecordBuilder.cannedAction(for: entry.action)
        return VStack(alignment: .trailing, spacing: House.Spacing.xs) {
            if !refs.isEmpty {
                SentAttachmentChips(refs: refs)
                    .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .trailing)
            }
            if let canned {
                actionPill(model.pillText(for: entry), symbol: canned.symbol, entryID: entry.id)
            } else {
                userPill(entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// A question's chips: the turn's records, or for a turn made before
    /// records existed, its `@` vault paths.
    private func sentAttachments(of entry: ChatEntry) -> [ChatAttachmentRef] {
        guard entry.attachments.isEmpty else { return entry.attachments }
        return ChatTurnRecordBuilder.attachments(
            mentionPaths: entry.referencedPaths.filter { !$0.hasPrefix("Attached file: ") },
            files: entry.referencedPaths.filter { $0.hasPrefix("Attached file: ") }
                .map { ChatTurnRecordBuilder.AttachedFile(name: String($0.dropFirst("Attached file: ".count))) },
            screenAttached: false
        )
    }

    /// A user turn: a pill on the right in secondary ink one step below the
    /// answer prose, wrapping left-aligned inside it. No "You" label.
    private func userPill(_ entry: ChatEntry) -> some View {
        let text = model.pillText(for: entry)
        let collapses = QuestionCollapsePolicy.shouldCollapse(text)
        let isExpanded = expanded.contains(entry.id)
            || (find?.current?.entryID == entry.id && find?.current?.part == .question)
        let shown = collapses && !isExpanded ? QuestionCollapsePolicy.preview(of: text) : text
        let display: AttributedString = find.map { $0.highlightedQuestion(shown, entryID: entry.id) } ?? AttributedString(shown)
        return VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            Text(display)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textSecondary)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if collapses {
                collapseControl(isExpanded: isExpanded, showsShortcut: entry.id == newestCollapsibleID) {
                    toggle(entry.id)
                }
            }
        }
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
                .fill(House.ColorToken.chipFill)
        )
        .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)")
    }

    /// A canned action (Assist, Recap, Say next) as its pill: the action's
    /// glyph and name, never the internal prompt it sent.
    private func actionPill(_ label: String, symbol: String, entryID: UUID) -> some View {
        let text: AttributedString = find.map { $0.highlightedQuestion(label, entryID: entryID) } ?? AttributedString(label)
        return HStack(spacing: House.Spacing.xs) {
            Image(systemName: symbol)
                .font(House.TypeToken.bodySmall)
                .accessibilityHidden(true)
            Text(text)
                .font(House.TypeToken.bodySmall)
                .lineLimit(1)
        }
        .foregroundStyle(House.ColorToken.textSecondary)
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
                .fill(House.ColorToken.chipFill)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(label)")
    }

    /// The answer being streamed: the lines so far, then the status line
    /// until text lands, then live prose with a caret.
    private func liveAnswer(_ entry: ChatEntry) -> some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            if !entry.tools.isEmpty {
                ToolLineGroup(lines: entry.tools)
            }
            if entry.text.isEmpty {
                toolLine(model.streamingStatus, symbol: nil)
            } else {
                RTIMarkdown(entry.text + " ▍", style: .overlay, proseSize: model.proseSize)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: House.Layout.answerMaxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Lines

    /// One quiet line: the thinking dots (no glyph) and tertiary text.
    private func toolLine(_ text: String, symbol: String?) -> some View {
        ThreadToolLine(text: text, symbol: symbol)
    }

    /// A provider error under the question it failed, in the tool line's
    /// style: the warning glyph and the message in danger ink, then Retry
    /// with its key.
    private func threadErrorLine(_ message: String) -> some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.danger)
                .frame(width: House.Control.keyCap)
                .accessibilityHidden(true)
            Text(message)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.danger)
                .lineLimit(2)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: House.Spacing.xs)
            Button(action: actions.retry) {
                KeyHint(label: "Retry", keys: ["⌘", "R"])
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry")
            .help("Ask this question again (⌘R)")
        }
        .frame(minHeight: House.Control.keyCap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(message)")
    }

    /// The empty thread: quiet lines naming the ways in, centred in the
    /// space the thread will take.
    private func emptyStateHints(_ hints: [String]) -> some View {
        VStack(spacing: House.Spacing.xs) {
            ForEach(hints, id: \.self) { hint in
                Text(hint)
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, House.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Latest

    /// "↓ Latest": the reader scrolled up from newer text. A click, or
    /// `⌘↓`, goes back to the bottom and follows it again.
    private func latestChip(_ proxy: ScrollViewProxy) -> some View {
        Button {
            following = true
            scrollToEnd(proxy, animated: true)
        } label: {
            HouseChip(text: "Latest", icon: "arrow.down")
                .raisedCard(radius: House.Radius.sm, fill: House.ColorToken.surfaceRaised)
                .houseShadow(House.Shadow.card)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.downArrow, modifiers: .command)
        .padding(.bottom, House.Spacing.xs)
        .accessibilityLabel("Jump to latest")
        .help("Jump to latest (\(Self.jumpToLatestKeys.joined()))")
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            animate { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func animate(_ move: () -> Void) {
        if reduceMotion {
            move()
        } else {
            withAnimation(.easeOut(duration: House.Motion.select)) { move() }
        }
    }

    // MARK: Collapse

    /// `⇧⌘M` acts on the newest question long enough to collapse.
    private var newestCollapsibleID: UUID? {
        model.entries.last { $0.role == "user" && ChatTurnRecordBuilder.cannedAction(for: $0.action) == nil
            && QuestionCollapsePolicy.shouldCollapse($0.text) }?.id
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        QuickAIAnnouncement.post(expanded.contains(id) ? "Message expanded" : "Message collapsed", priority: .medium)
    }

    @ViewBuilder
    private var collapseShortcut: some View {
        if let id = newestCollapsibleID {
            Button("") { toggle(id) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// "Show more" or "Collapse" inside the pill; the newest collapsible
    /// question also shows its key.
    private func collapseControl(isExpanded: Bool, showsShortcut: Bool, action: @escaping () -> Void) -> some View {
        let title = isExpanded ? "Collapse" : "Show more"
        return Button(action: action) {
            HStack(spacing: House.Spacing.xxs) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(House.TypeToken.micro.weight(.semibold))
                Text(title)
                    .font(House.TypeToken.meta)
                if showsShortcut {
                    KeyCapGroup(keys: ["⇧", "⌘", "M"])
                }
            }
            .foregroundStyle(House.ColorToken.textSecondary)
            .padding(.horizontal, House.Spacing.xs)
            .frame(height: HouseChatMetrics.collapseControlHeight)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .fill(House.ColorToken.chipFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .help(isExpanded ? "Collapse this message (⇧⌘M)" : "Show the rest of this message (⇧⌘M)")
    }
}

// MARK: - Geometry

/// What the thread's scroll view reports: where its view is, how tall the
/// view is, and how tall the content.
private struct ThreadGeometry: Equatable {
    /// The content's top in the scroll view's space: 0 at the top, negative
    /// once scrolled.
    var top: CGFloat = 0
    var visibleHeight: CGFloat = 0
    var contentHeight: CGFloat = 0

    var distanceFromBottom: CGFloat { top + contentHeight - visibleHeight }
    /// The whole thread is in view. False before the first report.
    var fitsView: Bool { visibleHeight > 0 && contentHeight <= visibleHeight }
}

/// The column's frame. Views that do not report it carry the default, so
/// a sibling's default never overwrites the one real frame.
private struct ContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Settled answer

/// A finished answer: its tool lines, the prose, its sources, and a Copy
/// button that is always there. Equatable, so an answer that has settled is
/// not parsed again while a newer one streams.
private struct AssistAnswerRow: View, Equatable {
    /// The answer's Markdown, as copied.
    let text: String
    let tools: [ChatToolLine]
    let sources: [ChatSource]
    /// The prose as drawn: the answer, or with find's hits marked.
    let markdown: String
    let findMarks: Bool
    let proseSize: CGFloat
    let copy: (String) -> Void
    let openSource: (ChatSource) -> Void

    @State private var hovering = false
    @State private var copied = false
    @State private var showsAllSources = false

    /// Sources listed before the rest fold behind "N more".
    static let listedSourceLimit = 5

    nonisolated static func == (lhs: AssistAnswerRow, rhs: AssistAnswerRow) -> Bool {
        lhs.text == rhs.text && lhs.tools == rhs.tools && lhs.sources == rhs.sources
            && lhs.markdown == rhs.markdown
            && lhs.findMarks == rhs.findMarks && lhs.proseSize == rhs.proseSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            if !tools.isEmpty {
                ToolLineGroup(lines: tools)
            }
            // Answers never collapse.
            RTIMarkdown(markdown, style: .overlay, proseSize: proseSize, findMarks: findMarks)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: House.Layout.answerMaxWidth, alignment: .leading)
                .environment(\.openURL, OpenURLAction { url in
                    url.absoluteString == MarkdownFindText.currentLinkTarget ? .handled : .systemAction
                })
            if !sources.isEmpty {
                sourceList(sources)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { copyButton }
        .contentShape(Rectangle())
        .hoverHighlight($hovering)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    /// Copy, always at the row's top right: drawn in every state and always
    /// clickable (user preference, 2026-09-14 — a control that appears only
    /// on hover is a control that cannot be found). The hover only deepens
    /// its ink. It takes no space, so the control never moves the text.
    private var copyButton: some View {
        Button {
            copy(text)
            copied = true
            QuickAIAnnouncement.post("Copied", priority: .medium)
        } label: {
            HStack(spacing: House.Spacing.xxs) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(House.TypeToken.meta)
                if copied {
                    Text("Copied").font(House.TypeToken.meta)
                }
            }
            .foregroundStyle(hovering || copied ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
            .padding(.horizontal, House.Spacing.xs)
            .frame(minWidth: House.Control.compact, minHeight: House.Control.compact)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .fill(House.ColorToken.surfaceRaised)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy answer")
        .help("Copy answer")
    }

    /// The answer's sources: a quiet list under the prose, one row each
    /// (the title, then its day). A row opens its file.
    private func sourceList(_ sources: [ChatSource]) -> some View {
        let shown = showsAllSources ? sources : Array(sources.prefix(Self.listedSourceLimit))
        let hidden = sources.count - shown.count
        return VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            ForEach(shown, id: \.path) { source in
                sourceRow(source)
            }
            if hidden > 0 {
                Button {
                    showsAllSources = true
                } label: {
                    Text("\(hidden) more")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .padding(.leading, House.Control.keyCap + House.Spacing.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show every source")
            }
        }
        .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
    }

    private func sourceRow(_ source: ChatSource) -> some View {
        let day = source.date.map { ChatTurnRecordBuilder.dayText(for: $0) }
        return Button {
            openSource(source)
        } label: {
            HStack(spacing: House.Spacing.xs) {
                // The tool lines' glyph column, so every line's text starts
                // at one edge.
                Image(systemName: "doc.text")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .frame(width: House.Control.keyCap)
                Text(source.title)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let day {
                    Text(day)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(minHeight: House.Control.keyCap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(source.path)
        .accessibilityLabel("Source: \(source.title)\(day.map { ", \($0)" } ?? "")")
        .accessibilityHint("Opens the file")
    }
}

// MARK: - Tool lines

/// Consecutive tool lines, closer together than the turns around them.
private struct ToolLineGroup: View {
    let lines: [ChatToolLine]

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                ThreadToolLine(text: line.text, symbol: line.kind.symbolName)
            }
        }
    }
}

/// One quiet line: a glyph (or the thinking dots) in a fixed column and
/// tertiary text, so consecutive lines start at one edge. Accent is never
/// used.
private struct ThreadToolLine: View {
    let text: String
    let symbol: String?

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                } else {
                    ThinkingIndicator()
                }
            }
            .frame(width: House.Control.keyCap)
            Text(text)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minHeight: House.Control.keyCap)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sent attachments

/// A sent question's chips, over its pill, right aligned and wrapping.
/// Read only. (Package B's composer strip draws the editable chips.)
private struct SentAttachmentChips: View {
    let refs: [ChatAttachmentRef]

    var body: some View {
        SentChipFlowLayout(spacing: House.Spacing.xs) {
            ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                SentAttachmentChip(ref: ref)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(refs.count == 1 ? "1 attachment" : "\(refs.count) attachments")
    }
}

/// One sent chip: kind glyph, name, detail ("12 pp · 84 KB", "· cut").
/// `Control.chip` high on `chipFill`, no colour in any state.
private struct SentAttachmentChip: View {
    let ref: ChatAttachmentRef

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            Image(systemName: ref.kind.symbolName)
                .font(House.TypeToken.caption)
                .foregroundStyle(House.ColorToken.textSecondary)
                .frame(width: House.Spacing.md, height: House.Spacing.md)
            Text(ref.name)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: HouseChatMetrics.attachmentNameMax, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if let detail = ChatTurnRecordBuilder.chipDetail(for: ref) {
                Text(detail)
                    .font(House.TypeToken.meta)
                    .monospacedDigit()
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(height: House.Control.chip)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .fill(House.ColorToken.chipFill)
        )
        .help(ref.path ?? ref.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ChatTurnRecordBuilder.chipAccessibilityLabel(for: ref))
    }
}

/// Lays chips in rows, right aligned, wrapping to a new row when the next
/// chip does not fit.
private struct SentChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
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

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if added > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Collapse policy

/// How long a question has to be before its pill collapses: over ten lines
/// at the pill's width, where a long single paragraph counts by characters.
/// Answers never collapse.
@MainActor
enum QuestionCollapsePolicy {
    /// Lines at or below this count are always shown in full.
    static let collapsedLineCount = 10
    /// Lines the collapsed preview keeps before Show more.
    static let previewLineCount = 6

    /// Characters one line of a pill holds (about 105), measured once with
    /// a real text layout at the pill's width and type size.
    static let charactersPerLine = measuredCharactersPerLine(
        width: House.Layout.quickAIAnswerMaxWidth - House.Spacing.sm * 2,
        fontSize: House.TypeToken.Size.bodySmall
    )

    static func estimatedLineCount(of text: String) -> Int {
        let lines = text.components(separatedBy: .newlines)
        return lines.reduce(lines.count) { total, line in total + max(0, (line.count - 1) / charactersPerLine) }
    }

    static func shouldCollapse(_ text: String) -> Bool {
        estimatedLineCount(of: text) > collapsedLineCount
    }

    /// The first six lines, or the same budget of one paragraph cut at a
    /// word boundary.
    static func preview(of text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        if lines.count > 1 {
            return lines.prefix(previewLineCount).joined(separator: "\n")
        }
        let limit = previewLineCount * charactersPerLine
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        guard let lastSpace = head.lastIndex(where: \.isWhitespace) else { return String(head) }
        return String(head[head.startIndex..<lastSpace])
    }

    private static let measureSample = String(
        repeating: "Could you explain why the sky looks blue during the day but turns red and orange at sunset, and whether the same thing happens on Mars? ",
        count: 12
    )

    static func measuredCharactersPerLine(width: CGFloat, fontSize: CGFloat) -> Int {
        let storage = NSTextStorage(string: measureSample, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        var lines = 0
        var glyph = 0
        var lastLineStart = 0
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            lines += 1
            lastLineStart = range.location
            glyph = NSMaxRange(range)
        }
        guard lines > 1 else { return max(1, measureSample.count) }
        return max(1, layout.characterIndexForGlyph(at: lastLineStart) / (lines - 1))
    }
}

// MARK: - Above the composer

/// An error that belongs to no turn (no key, a permission, a capture
/// fault), above the composer in `meta` `danger`, with a fix-it when there
/// is one.
struct AssistComposerNotice: View {
    let message: String
    var fixTitle: String? = nil
    var onFix: () -> Void = {}

    var body: some View {
        HStack(spacing: House.Spacing.sm) {
            Text(message)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.danger)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: House.Spacing.xs)
            if let fixTitle {
                Button(fixTitle, action: onFix)
                    .buttonStyle(InkButtonStyle())
            }
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.vertical, House.Spacing.xs)
        .accessibilityElement(children: .contain)
    }
}
