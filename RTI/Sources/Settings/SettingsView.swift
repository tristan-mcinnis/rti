// Shell copied from quick-launch@8ee19aa Sources/Views/SettingsView.swift
// (rail, pane header, footer well) and SlateChrome.swift (SettingsCard,
// SettingsRow, CardNote, InkSegmentedControl), adapted to RTI.
import AppKit
import RTICore
import SwiftUI

/// Which pane the settings window shows and what its rail search holds.
/// `SettingsWindowController` keeps one, so `show(pane:)` can switch the
/// pane of a window that is already open.
@Observable @MainActor
final class SettingsNavigation {
    var pane: SettingsView.SettingsTab
    var query: String

    init(pane: SettingsView.SettingsTab = .providers, query: String = "") {
        self.pane = pane
        self.query = query
    }
}

/// The settings window: a 220 pt rail on `surfaceSunken` (search, then one
/// row per pane with its `⌘`-number) beside one pane. A pane is a title, a
/// subtitle, its cards, and a footer well ("Applies immediately" on the
/// left, "Next ⌘n" on the right). No Close button: `esc` and `⌘W` close
/// the window. Each pane lives in its own file (`KeysTab.swift`,
/// `ModesTab.swift`, …).
struct SettingsView: View {
    enum SettingsTab: String, CaseIterable, Identifiable {
        case providers, modes, prompts, glossary, voices, general, logs, about

        var id: String { rawValue }

        var label: String {
            switch self {
            case .providers: "Providers"
            case .modes: "Modes"
            case .prompts: "Prompts"
            case .glossary: "Glossary"
            case .voices: "Voices"
            case .general: "General"
            case .logs: "Logs"
            case .about: "About"
            }
        }

        var systemImage: String {
            switch self {
            case .providers: "server.rack"
            case .modes: "square.stack.3d.up"
            case .prompts: "text.bubble"
            case .glossary: "character.book.closed"
            case .voices: "person.wave.2"
            case .general: "gearshape"
            case .logs: "doc.text.magnifyingglass"
            case .about: "info.circle"
            }
        }

        /// One plain line under the pane title.
        var description: String {
            switch self {
            case .providers: "Assistant and transcription providers, and their keys."
            case .modes: "The assistant's persona and reference text for each mode."
            case .prompts: "The instructions RTI sends to the model for each action."
            case .glossary: "Names, acronyms, and terms the model keeps as written."
            case .voices: "The voice samples behind speaker name suggestions."
            case .general: "Capture, audio, analysis, appearance, and hotkeys."
            case .logs: "Recent activity and the crash log."
            case .about: "Version, updates, and diagnostics."
            }
        }

        /// The quiet hint on the left of the footer well. Keep it true.
        var footerHint: String {
            switch self {
            case .providers, .modes: "Changes apply when you save"
            case .prompts, .glossary: "Applies on the next call"
            case .voices: "Changes go to the vault voice store"
            case .general: "Applies immediately"
            case .logs: "Logs stay on this Mac"
            case .about: "Version and updates"
            }
        }

        /// Settings inside the pane, so the rail search reaches them.
        var keywords: [String] {
            switch self {
            case .providers: ["API", "keys", "DeepSeek", "OpenAI", "OpenRouter", "Soniox", "Aliyun", "model", "transcription", "credentials"]
            case .modes: ["persona", "system prompt", "reference", "meeting", "interview"]
            case .prompts: ["Assist", "recap", "summary", "instructions"]
            case .glossary: ["terms", "names", "acronyms", "spelling"]
            case .voices: ["speakers", "voice profiles", "samples"]
            case .general: ["login", "microphone", "audio", "input", "echo", "Bluetooth", "screen", "privacy", "capture",
                            "notes", "analysis", "appearance", "theme", "dark", "light", "text size", "font", "motion",
                            "speaker colours", "hotkeys", "shortcuts", "folder", "data"]
            case .logs: ["crash", "diagnostics", "errors"]
            case .about: ["version", "updates", "diagnostics", "source"]
            }
        }

        /// 1-based, as the `⌘`-number keys are.
        var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

        var searchPane: SettingsSearch.Pane {
            SettingsSearch.Pane(id: rawValue, title: label, keywords: keywords)
        }
    }

    /// Called by `esc` (with an empty search) and `⌘W`. Nil in the SwiftUI
    /// `Settings` scene, whose window closes itself.
    var onClose: (() -> Void)?
    /// Render proofs only: invented log lines for the Logs pane, so a proof
    /// never reads the real log files.
    var logsFixture: LogsView.Fixture?
    /// The mode store the Modes pane edits. Defaults to the shared store for
    /// production; a render proof passes an in-memory one so it never reads or
    /// writes the user's live modes.
    var modeStore: ModeStore
    @State private var navigation: SettingsNavigation
    @State private var hoveredTab: SettingsTab?
    @FocusState private var searchFocused: Bool

    init(
        onClose: (() -> Void)? = nil,
        initialSection: SettingsTab = .providers,
        navigation: SettingsNavigation? = nil,
        logsFixture: LogsView.Fixture? = nil,
        modeStore: ModeStore = .shared
    ) {
        self.onClose = onClose
        self.logsFixture = logsFixture
        self.modeStore = modeStore
        _navigation = State(initialValue: navigation ?? SettingsNavigation(pane: initialSection))
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle()
                .fill(House.ColorToken.divider)
                .frame(width: House.hairline)
                .accessibilityHidden(true)
            pane
        }
        .frame(
            minWidth: House.Layout.settingsWidth,
            maxWidth: .infinity,
            minHeight: House.Layout.settingsHeight,
            maxHeight: .infinity
        )
        .background(House.ColorToken.surface)
        // Chrome is ink, never the system accent; toggles are ink too.
        .tint(House.ColorToken.textPrimary)
        .toggleStyle(SlateToggleStyle())
        .background { shortcuts }
    }

    // MARK: - Keys

    /// `⌘1`…`⌘8` switch panes; `esc` clears the search, then closes; `⌘W`
    /// closes.
    private var shortcuts: some View {
        Group {
            ForEach(SettingsTab.allCases) { tab in
                Button("") { navigation.pane = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(tab.number))), modifiers: .command)
            }
            Button("") {
                if navigation.query.isEmpty {
                    onClose?()
                } else {
                    navigation.query = ""
                }
            }
            .keyboardShortcut(.cancelAction)
            Button("") { onClose?() }
                .keyboardShortcut("w", modifiers: .command)
        }
        .hidden()
        .accessibilityHidden(true)
    }

    // MARK: - Pane

    private var pane: some View {
        VStack(spacing: 0) {
            paneHeader
            Group {
                switch navigation.pane {
                case .providers: ProvidersTab()
                case .modes: ModesTab(modeStore: modeStore)
                case .prompts: PromptsTab()
                case .glossary: GlossaryTab()
                case .voices: VoicesTab()
                case .general: GeneralTab()
                case .logs: LogsView(fixture: logsFixture)
                case .about: AboutTab()
                }
            }
            // A fresh subtree per pane: a ScrollView-rooted pane swapped in
            // place can mount without painting (seen 2026-08-30).
            .id(navigation.pane)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            SlateFooter(statusColor: nil, status: navigation.pane.footerHint) {
                KeyHint(label: "Next", keys: ["⌘", "\(nextNumber)"])
            }
        }
        .background(House.ColorToken.surface)
    }

    private var paneHeader: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            Text(navigation.pane.label)
                .font(House.TypeToken.title)
                .foregroundStyle(House.ColorToken.textPrimary)
            Text(navigation.pane.description)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, House.Spacing.lg)
        .padding(.vertical, House.Spacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The `⌘`-number of the pane after this one; the last wraps to 1.
    private var nextNumber: Int {
        SettingsSearch.nextNumber(after: navigation.pane.number - 1, count: SettingsTab.allCases.count)
    }

    // MARK: - Rail

    private var filteredTabs: [SettingsTab] {
        let hits = Set(SettingsSearch.filter(SettingsTab.allCases.map(\.searchPane), query: navigation.query).map(\.id))
        return SettingsTab.allCases.filter { hits.contains($0.rawValue) }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            searchField

            ScrollView {
                VStack(spacing: House.Spacing.xxs) {
                    let tabs = filteredTabs
                    if tabs.isEmpty {
                        Text("No settings match")
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: House.Control.row)
                    }
                    ForEach(tabs) { tab in
                        railRow(tab)
                    }
                }
            }
            .scrollIndicators(.never)

            Text(versionLine)
                .font(House.TypeToken.caption)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
        }
        .padding(House.Spacing.sm)
        .frame(width: House.Layout.settingsRail)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(House.ColorToken.surfaceSunken)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings panes")
    }

    private var searchField: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(House.TypeToken.caption)
                .foregroundStyle(House.ColorToken.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $navigation.query, prompt: Text("")) {
                Text("Search settings")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textPrimary)
            .overlay(alignment: .leading) {
                if navigation.query.isEmpty {
                    Text("Search settings…")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($searchFocused)
            .onSubmit {
                if let first = filteredTabs.first { navigation.pane = first }
            }
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                moveSelection(press.key == .upArrow ? -1 : 1) ? .handled : .ignored
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(height: House.Control.small)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .strokeBorder(House.ColorToken.tileStroke, lineWidth: House.hairline)
        )
    }

    /// `↑↓` from the search field walk the panes it lists.
    private func moveSelection(_ step: Int) -> Bool {
        let tabs = filteredTabs
        guard !tabs.isEmpty else { return false }
        let index = tabs.firstIndex(of: navigation.pane) ?? (step > 0 ? -1 : tabs.count)
        navigation.pane = tabs[min(max(index + step, 0), tabs.count - 1)]
        return true
    }

    private func railRow(_ tab: SettingsTab) -> some View {
        let isSelected = navigation.pane == tab
        return Button {
            navigation.pane = tab
        } label: {
            HStack(spacing: House.Spacing.xs) {
                SlateIconTile(systemName: tab.systemImage, glyphSize: House.TypeToken.Size.meta)
                Text(tab.label)
                    .font(House.TypeToken.label)
                    .foregroundStyle(isSelected ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: House.Spacing.xxs)
                Text("⌘\(tab.number)")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, House.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: House.Control.railRow, alignment: .leading)
            .background(RowHighlight(isSelected: isSelected, isHovering: hoveredTab == tab, radius: House.Radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hoveredTab, id: tab)
        .accessibilityLabel(tab.label)
        .accessibilityHint("Command \(tab.number)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        return "RTI \(version)"
    }
}

// MARK: - Shared settings pieces

/// Settings sits in an opaque window, so its ground is `surface`, not glass.
struct SettingsSurfaceBackground: View {
    var body: some View {
        House.ColorToken.surface
    }
}

/// A pane's scrolling body: the cards stacked `Spacing.sm` apart at the
/// pane's side inset, capped at `maxWidth` on a wide window.
struct SettingsPage<Content: View>: View {
    let maxWidth: CGFloat
    private let content: Content

    init(maxWidth: CGFloat = House.Layout.settingsWidth, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                content
                    .frame(maxWidth: maxWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, House.Spacing.lg)
            .padding(.bottom, House.Spacing.md)
        }
        .background(SettingsSurfaceBackground())
        // Toggles are ink, never blue (DESIGN.md).
        .toggleStyle(SlateToggleStyle())
    }
}

/// A settings group drawn as a card: an uppercase section label, an
/// optional caption, then the content.
///
/// `rows: true` is the house row grammar (`SettingsRow`, `SettingsToggleRow`,
/// `CardNote`): 40 pt rows with a divider above all but the first. The
/// default keeps free-form content (editors, lists) padded all round.
struct SettingsCard<Content: View>: View {
    let title: String?
    let detail: String?
    let rows: Bool
    private let content: Content

    init(_ title: String? = nil, detail: String? = nil, rows: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.rows = rows
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rows ? 0 : House.Spacing.sm) {
            if title != nil || detail != nil {
                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    if let title {
                        SlateSectionLabel(text: title)
                    }
                    if let detail {
                        CardText(detail)
                    }
                }
                .padding(.top, rows ? House.Spacing.sm : 0)
                .padding(.bottom, rows ? House.Spacing.xxs : 0)
            }
            content
        }
        .padding(.horizontal, House.Spacing.md)
        .padding(.top, rows ? 0 : House.Spacing.sm)
        .padding(.bottom, rows ? House.Spacing.xxs : House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
    }
}

/// One row inside a `SettingsCard(rows: true)`: a label (and a caption) on
/// the left, a control on the right, a divider above every row but the
/// first.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var isFirst: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { HouseDivider() }
            HStack(spacing: House.Spacing.sm) {
                SettingsRowText(title: title, detail: detail)
                Spacer(minLength: House.Spacing.sm)
                trailing
            }
            .padding(.vertical, detail == nil ? 0 : House.Spacing.xs)
            .frame(minHeight: House.Control.row)
        }
    }
}

/// A row whose control is an ink toggle. The whole row toggles.
struct SettingsToggleRow: View {
    let title: String
    var detail: String? = nil
    var isFirst: Bool = false
    @Binding var isOn: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { HouseDivider() }
            Toggle(isOn: $isOn) {
                SettingsRowText(title: title, detail: detail)
            }
            .toggleStyle(SlateToggleStyle())
            .padding(.vertical, detail == nil ? 0 : House.Spacing.xs)
            .frame(minHeight: House.Control.row)
        }
    }
}

/// A row's title in `label` over its caption in `caption` `textTertiary`.
private struct SettingsRowText: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs / 2) {
            Text(title)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}

/// A full-width strip inside a row card that is not a titled row: helper
/// text, an error line, a status, or a lone button. Draws the same divider
/// above itself that `SettingsRow` does.
struct CardNote<Content: View>: View {
    var isFirst = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { HouseDivider() }
            HStack(spacing: House.Spacing.sm) {
                content
                Spacer(minLength: 0)
            }
            .padding(.vertical, House.Spacing.xs)
        }
    }
}

/// The text of a `CardNote` or a card caption: caption ink, wrapping,
/// never truncated.
struct CardText: View {
    let text: String
    var tone: Color = House.ColorToken.textSecondary

    init(_ text: String, tone: Color = House.ColorToken.textSecondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(House.TypeToken.caption)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One option of an `InkSegmentedControl`.
struct InkSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// A segmented control in ink. The selected segment is the house selection
/// tile (fill, inset ring, 1 pt drop); hover is half the fill. Never the
/// accent tint `.pickerStyle(.segmented)` paints.
struct InkSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [InkSegment<Value>]
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(isSelected ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, House.Spacing.sm)
                        .frame(maxWidth: .infinity, minHeight: House.Control.tile)
                        .background(
                            RowHighlight(isSelected: isSelected, isHovering: hovered == option.value, radius: House.Radius.sm)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight($hovered, id: option.value)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(House.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .strokeBorder(House.ColorToken.tileStroke, lineWidth: House.hairline)
        )
    }
}

/// A status inside a settings group: a 6 pt dot and its word, never colour
/// alone and never a tinted capsule.
struct SettingsStatusLabel: View {
    let text: String
    /// Kept for callers that pass a symbol; the house status is a dot.
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            SlateStatusDot(color: color)
            Text(text)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// A house text field on a card: `surfaceRaised` ground, `stroke`
/// hairline, `Radius.sm`.
struct SettingsFieldBackground: ViewModifier {
    var height: CGFloat? = House.Control.chip

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, House.Spacing.xs)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .fill(House.ColorToken.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
            )
    }
}

extension View {
    func settingsEditorBorder(cornerRadius: CGFloat = House.Radius.sm) -> some View {
        self
            .background(House.ColorToken.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
            )
    }

    /// The house field look for a plain `TextField` or `SecureField`.
    func settingsField(height: CGFloat? = House.Control.chip) -> some View {
        modifier(SettingsFieldBackground(height: height))
    }
}
