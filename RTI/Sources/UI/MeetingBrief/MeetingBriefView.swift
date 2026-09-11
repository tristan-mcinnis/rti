// Header and rail copied from quick-launch@8ee19aa Sources/Views/AIChatWindowView.swift
// (header, AIChatRail, OpenChatMarker), adapted to a read-only reader.
import RTICore
import SwiftUI

/// What the Meeting Brief window shows: the vault's pre-meeting briefs
/// (written by Hermes "Meeting Prep"), the open one, and the rail's state.
/// Read-only: RTI never writes briefs.
@Observable @MainActor
final class MeetingBriefModel {
    /// The house "show the list" key in every house window (⌃⌘S, the macOS
    /// sidebar key). RTI's `⌘\` stays its global show or hide.
    static let listKeyCaps = ["⌃", "⌘", "S"]
    static let railVisibleKey = "rti.meetingBrief.railVisible"

    private(set) var briefs: [MeetingBrief] = []
    private(set) var openBrief: MeetingBrief?
    private(set) var content = ""
    var query = "" {
        didSet { railIndex = 0 }
    }
    /// The keyboard highlight in the rail, an index into `railItems`.
    var railIndex = 0
    /// Bumped to move focus into the rail's search field.
    private(set) var railFocusRequest = 0
    /// Remembered between windows; hidden by default (no split pane).
    var isRailVisible: Bool {
        didSet { UserDefaults.standard.set(isRailVisible, forKey: Self.railVisibleKey) }
    }
    /// `yyyy-MM-dd` of the day the list is grouped against.
    private let today: String

    init(railVisible: Bool? = nil, now: Date = Date()) {
        isRailVisible = railVisible ?? UserDefaults.standard.bool(forKey: Self.railVisibleKey)
        today = Self.dayStamp.string(from: now)
    }

    // MARK: Rail

    var sections: [BriefRail.Section] {
        BriefRail.sections(for: briefs.map(\.railItem), query: query, today: today)
    }

    var railItems: [BriefRail.Item] { BriefRail.flattened(sections) }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var railEmptyText: String {
        if briefs.isEmpty { return "No briefs yet" }
        return isSearching ? "No briefs match" : ""
    }

    func toggleRail() {
        isRailVisible.toggle()
        if isRailVisible {
            railIndex = railItems.firstIndex { $0.id == openBrief?.url.path } ?? 0
            railFocusRequest += 1
        } else {
            query = ""
        }
    }

    /// `↑↓` in the rail search move the highlight; true when handled.
    func moveHighlight(_ step: Int) -> Bool {
        let count = railItems.count
        guard count > 0 else { return false }
        railIndex = min(max(railIndex + step, 0), count - 1)
        return true
    }

    /// `↩` in the rail search opens the highlighted brief.
    func openHighlighted() {
        let items = railItems
        guard items.indices.contains(railIndex) else { return }
        open(id: items[railIndex].id)
    }

    /// `⌘1`…`⌘9`: the nth brief in rail order, rail showing or not.
    func open(number: Int) {
        let items = railItems
        guard items.indices.contains(number - 1) else { return }
        railIndex = number - 1
        open(id: items[number - 1].id)
    }

    /// `esc`: clear the search, then slide the rail out. False when there
    /// was nothing to pop.
    func escape() -> Bool {
        if isSearching {
            query = ""
            return true
        }
        if isRailVisible {
            isRailVisible = false
            return true
        }
        return false
    }

    // MARK: Briefs

    func reload() {
        briefs = MeetingBriefStore.recentBriefs()
        if let openBrief, let same = briefs.first(where: { $0.url == openBrief.url }) {
            open(same)
        } else if let first = railItems.first.flatMap({ item in briefs.first { $0.url.path == item.id } }) {
            open(first)
        } else {
            openBrief = nil
            content = ""
        }
    }

    /// Open the brief at `url`, when the list has it (the Prepare tab's
    /// "Brief" link hands one over).
    func open(url: URL) {
        if briefs.isEmpty { briefs = MeetingBriefStore.recentBriefs() }
        guard let brief = briefs.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        open(brief)
    }

    func open(id: String) {
        guard let brief = briefs.first(where: { $0.url.path == id }) else { return }
        open(brief)
    }

    private func open(_ brief: MeetingBrief) {
        openBrief = brief
        content = MeetingBriefStore.content(of: brief)
    }

    // MARK: Words

    /// "Today", "Tomorrow", or "Fri, Sep 12".
    func dayLabel(_ day: String?) -> String {
        guard let day, let date = Self.dayStamp.date(from: day) else { return "No date" }
        if day == today { return "Today" }
        let calendar = Calendar.current
        if let todayDate = Self.dayStamp.date(from: today),
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayDate),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return Self.dayLabelFormatter.string(from: date)
    }

    private static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f
    }()
}

extension MeetingBrief {
    var railItem: BriefRail.Item {
        BriefRail.Item(id: url.path, title: displayTitle, day: datePrefix)
    }
}

/// The Meeting Brief window: the AI Chat window's shape with a reader in
/// place of the thread. The header shares the traffic-light row; the brief
/// list is a rail, hidden until `⌃⌘S` or the header toggle; the brief reads
/// in one centred column. No composer: briefs are read-only.
struct MeetingBriefView: View {
    @Bindable var model: MeetingBriefModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The unified toolbar's title-bar row, which the header shares.
    static let titleBarHeight = House.Control.composer
    /// The reading column: the thread's width.
    static let readingWidth = House.Layout.panelWidth - 2 * House.Spacing.lg

    var body: some View {
        HStack(spacing: 0) {
            if model.isRailVisible {
                MeetingBriefRail(model: model)
                    .frame(width: House.Layout.chatRail)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                Rectangle()
                    .fill(House.ColorToken.divider)
                    .frame(width: House.hairline)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                header
                reader
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The scroll view would otherwise draw up under the
                    // header and the transparent title bar.
                    .clipped()
            }
        }
        .frame(
            minWidth: House.Layout.chatMinWidth,
            maxWidth: .infinity,
            minHeight: House.Layout.chatMinHeight,
            maxHeight: .infinity
        )
        .background(House.ColorToken.surface)
        // The header shares the title-bar row with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: House.Motion.select), value: model.isRailVisible)
        .tint(House.ColorToken.textPrimary)
        .background { shortcuts }
        .onAppear { if model.briefs.isEmpty { model.reload() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting Brief")
    }

    // MARK: - Keys

    private var shortcuts: some View {
        Group {
            Button("") { model.toggleRail() }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button("") { model.reload() }
                .keyboardShortcut("r", modifiers: .command)
            ForEach(1...9, id: \.self) { number in
                Button("") { model.open(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: House.Spacing.sm) {
            QuickAIGlyphButton(
                symbol: "sidebar.left",
                font: HouseChatType.glyphSmall,
                color: House.ColorToken.textSecondary,
                label: model.isRailVisible ? "Hide Brief List" : "Show Brief List",
                help: "\(model.isRailVisible ? "Hide" : "Show") brief list (\(MeetingBriefModel.listKeyCaps.joined()))",
                accessibilityValue: model.isRailVisible ? "Open" : "Closed"
            ) {
                model.toggleRail()
            }
            HouseTitleBlock(title: model.openBrief?.displayTitle ?? "Meeting Brief", line: titleLine)
            Spacer(minLength: House.Spacing.sm)
            QuickAIGlyphButton(
                symbol: "arrow.clockwise",
                font: HouseChatType.glyphSmall,
                color: House.ColorToken.textSecondary,
                label: "Reload Briefs",
                help: "Reload briefs from the vault (⌘R)"
            ) {
                model.reload()
            }
        }
        // The traffic lights share this row while the rail is in.
        .padding(.leading, model.isRailVisible ? House.Spacing.sm : HouseChatMetrics.trafficLightInset)
        .padding(.trailing, House.Spacing.lg)
        .frame(height: Self.titleBarHeight)
        .background {
            // The title-bar row drags the window, as a normal title bar does.
            WindowDragArea()
                .background(House.ColorToken.surface)
        }
        .zIndex(1)
    }

    /// The source line: a brief is not the model's, so plain text.
    private var titleLine: [HouseTitleSegment] {
        guard let brief = model.openBrief else {
            return [.text(model.briefs.isEmpty ? "No briefs in the vault" : "Pick a brief")]
        }
        return [.text(model.dayLabel(brief.datePrefix)), .text("Pre-meeting brief")]
    }

    // MARK: - Reader

    @ViewBuilder
    private var reader: some View {
        if model.openBrief == nil {
            emptyHints
        } else {
            ScrollView {
                RTIMarkdown(model.content, style: .panel)
                    .frame(maxWidth: Self.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, House.Spacing.xl)
                    .padding(.horizontal, House.Spacing.lg)
                    .padding(.bottom, House.Spacing.md)
            }
        }
    }

    /// Three hint lines, each naming a way in with its real key.
    private var emptyHints: some View {
        VStack(spacing: House.Spacing.xs) {
            ForEach(emptyLines, id: \.self) { line in
                Text(line)
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textTertiary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLines: [String] {
        model.briefs.isEmpty
            ? ["No briefs in the vault yet. Meeting Prep writes them.", "⌘R looks again", "⌃⌘S shows the brief list"]
            : ["⌃⌘S shows the brief list", "⌘1 opens the first brief", "⌘R reloads from the vault"]
    }
}

// MARK: - Rail

/// The brief list: a search field, then Today, Upcoming, and Earlier, or
/// one Results list while a query is typed. `↑↓` move, `↩` opens,
/// `⌘1`…`⌘9` jump, `esc` clears the search and then slides the list out.
/// The open brief carries an ink bar on its leading edge, apart from the
/// keyboard highlight.
private struct MeetingBriefRail: View {
    @Bindable var model: MeetingBriefModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sections = model.sections
        let items = BriefRail.flattened(sections)
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights' row.
            Color.clear.frame(height: MeetingBriefView.titleBarHeight)
            searchField
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                        if items.isEmpty {
                            Text(model.railEmptyText)
                                .font(House.TypeToken.bodySmall)
                                .foregroundStyle(House.ColorToken.textTertiary)
                                .frame(maxWidth: .infinity, minHeight: House.Control.row)
                        }
                        ForEach(sections, id: \.title) { section in
                            sectionView(section, items: items)
                        }
                    }
                    .padding(.horizontal, House.Spacing.xs)
                    .padding(.bottom, House.Spacing.sm)
                }
                .onChange(of: model.railIndex) { _, index in
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id)
                }
            }
        }
        .background(House.ColorToken.surfaceSunken)
        .clipped()
        .onAppear { searchFocused = true }
        .onChange(of: model.railFocusRequest) { _, _ in searchFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Briefs")
    }

    private var searchField: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $model.query, prompt: Text("")) {
                Text("Search briefs")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(House.TypeToken.bodySmall)
            .foregroundStyle(House.ColorToken.textPrimary)
            .overlay(alignment: .leading) {
                if model.query.isEmpty {
                    Text("Search briefs…")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($searchFocused)
            .onSubmit { model.openHighlighted() }
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                model.moveHighlight(press.key == .upArrow ? -1 : 1) ? .handled : .ignored
            }
            .onExitCommand { _ = model.escape() }
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(height: House.Control.chip)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .padding(.horizontal, House.Spacing.sm)
        .padding(.bottom, House.Spacing.xs)
    }

    private func sectionView(_ section: BriefRail.Section, items: [BriefRail.Item]) -> some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SlateSectionLabel(text: section.title)
                .padding(.horizontal, House.Spacing.xs)
                .padding(.top, House.Spacing.sm)
                .padding(.bottom, House.Spacing.xxs)
            ForEach(section.items) { item in
                row(item, index: items.firstIndex(of: item) ?? 0, total: items.count)
                    .id(item.id)
            }
        }
    }

    private func row(_ item: BriefRail.Item, index: Int, total: Int) -> some View {
        let isSelected = index == model.railIndex
        let isOpen = item.id == model.openBrief?.url.path
        let number = index < 9 ? index + 1 : nil
        let detail = model.dayLabel(item.day)
        return Button {
            model.railIndex = index
            model.open(id: item.id)
        } label: {
            HStack(spacing: House.Spacing.xs) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(detail)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let number, isSelected || isOpen {
                    KeyCap(text: "⌘\(number)")
                }
            }
            .padding(.horizontal, House.Spacing.xs)
            .frame(height: House.Control.row)
            .background { RowHighlight(isSelected: isSelected) }
            .overlay(alignment: .leading) {
                if isOpen { OpenBriefMarker() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(detail)\(isOpen ? ", open" : "")")
        .accessibilityValue(isSelected ? "Selected, \(index + 1) of \(total)" : "\(index + 1) of \(total)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The open brief's mark in the rail: a short ink bar on the row's leading
/// edge. Ink, not colour, and apart from the keyboard highlight's fill.
private struct OpenBriefMarker: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(House.ColorToken.textPrimary)
            .frame(width: HouseChatMetrics.openChatMarkerWidth, height: House.Control.keyCap)
            .accessibilityHidden(true)
    }
}
