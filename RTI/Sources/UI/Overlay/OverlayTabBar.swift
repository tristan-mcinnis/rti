import RTICore
import SwiftUI
import HouseDesign

/// The tabs of the consolidated overlay. One window, one global toggle (⌘\),
/// tabs in a row under the header, instead of a constellation of floating
/// panels. ⌘1…⌘5 pick a tab while the overlay is key (View menu).
enum OverlayTab: String, CaseIterable, Identifiable {
    // Prepare is the meeting home; the rest are live surfaces.
    case setup, assist, auto, transcript, notes, guide, codebook
    var id: String {
        rawValue
    }

    @MainActor var title: String {
        switch self {
        case .setup: "Setup"
        case .assist: "Assist"
        case .auto: "Auto"
        case .transcript: "Transcript"
        case .notes: "Notes"
        case .guide: "Guide"
        case .codebook: "Codebook"
        }
    }

    @MainActor var icon: String {
        switch self {
        case .setup: "slider.horizontal.3"
        case .assist: "sparkles"
        case .auto: "wand.and.stars"
        case .transcript: "bubble.left.and.text.bubble.right"
        case .notes: "note.text"
        case .guide: "list.bullet.rectangle"
        case .codebook: "books.vertical"
        }
    }

    /// The tab's ⌘ digit (⌘1 Prepare … ⌘5 Notes), fixed whether or not an
    /// opt-in tab is showing. Local to the overlay (View menu), never global.
    @MainActor var shortcutNumber: Int {
        OverlayTabShortcut.number(forTab: rawValue, guideActive: GuideSessionController.shared.isActive) ?? 0
    }

    /// "⌘2", for help text and palette rows.
    @MainActor var shortcutLabel: String { "⌘\(shortcutNumber)" }

    /// The live tabs showing, in order. Prepare is not listed: it is the
    /// leading button and always there. Notes defaults on; Auto is opt-in
    /// from Prepare.
    static func visibleTabs(notes: Bool, auto: Bool, guide: Bool = false, codebook: Bool = false) -> [OverlayTab] {
        var tabs: [OverlayTab] = [.assist]
        if auto { tabs.append(.auto) }
        tabs.append(.transcript)
        if guide { tabs.append(.guide) }
        if notes { tabs.append(.notes) }
        if codebook { tabs.append(.codebook) }
        return tabs
    }
}

struct OverlayTabBar: View {
    @Binding var selection: OverlayTab
    /// Which tabs to show. Notes and Auto are toggled in Prepare, so the bar
    /// only renders the ones currently enabled.
    var tabs: [OverlayTab] = OverlayTab.allCases

    /// Reading the @Observable controller here makes the bar re-render when a
    /// proactive card arrives, lighting the Auto tab's unread badge.
    private var autoUnseen: Int {
        AutoAssistController.shared.unseenCount
    }

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            ForEach(tabs) { tab in
                OverlayTabButton(
                    tab: tab,
                    isSelected: selection == tab,
                    autoUnseen: autoUnseen,
                    action: { selection = tab }
                )
            }
            Spacer(minLength: 0)
        }
    }
}

private struct OverlayTabButton: View {
    let tab: OverlayTab
    let isSelected: Bool
    let autoUnseen: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: HouseChatMetrics.chipGap) {
                    Image(systemName: tab.icon)
                        .font(House.TypeToken.bodySmall)
                    Text(tab.title).font(RTIDesign.Font.tab).fixedSize()
                }
                .padding(.horizontal, House.Spacing.xs)
                .frame(minHeight: House.Control.chip)
                // Unread badge: Auto surfaced cards the user hasn't seen.
                if tab == .auto, !isSelected, autoUnseen > 0 {
                    SlateStatusDot(color: House.ColorToken.danger)
                        .padding(House.Spacing.xxs)
                }
            }
            .foregroundStyle(isSelected
                ? Color.overlayInk
                : (hovering ? Color.overlayInk : House.ColorToken.textSecondary))
            .slateRaisedTile(isSelected, hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hovering)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .help("\(tab.title) (\(tab.shortcutLabel))")
    }
}

/// Leading icon button that opens the Prepare surface. It is the meeting home
/// (context, capture readiness, and live aids), so it sits to
/// the left of the live tabs as a dedicated pill rather than competing with
/// them for equal weight. Click toggles into Prepare and back to where you were.
struct OverlaySetupButton: View {
    @Binding var selection: OverlayTab
    @State private var lastNonSetup: OverlayTab = .assist
    @State private var hovering = false

    var body: some View {
        Button {
            if selection == .setup {
                selection = lastNonSetup
            } else {
                lastNonSetup = selection
                selection = .setup
            }
        } label: {
            Label("Setup", systemImage: OverlayTab.setup.icon)
                .font(RTIDesign.Font.tab)
                .padding(.horizontal, House.Spacing.xs)
                .foregroundStyle(selection == .setup
                    ? Color.overlayInk
                    : (hovering ? Color.overlayInk : House.ColorToken.textSecondary))
                .frame(height: House.Control.chip)
                .slateRaisedTile(selection == .setup, hovering: hovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hovering)
        .accessibilityLabel("Prepare meeting")
        .accessibilityHint("Project, calendar, screen context, and the live-aid toggles")
        .help("Prepare the meeting: project, calendar, screen context, and live aids (\(OverlayTab.setup.shortcutLabel))")
    }
}
