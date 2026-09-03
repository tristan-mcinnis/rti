import RTICore
import SwiftUI

/// The tabs of the consolidated overlay. One window, one toggle (⌘\), tabs
/// across the top — instead of a constellation of floating panels.
enum OverlayTab: String, CaseIterable, Identifiable {
    // Prepare is the meeting home; the rest are live surfaces.
    case setup, assist, auto, transcript, notes, guide, findings
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .setup: "Prepare"
        case .assist: "Assist"
        case .auto: "Auto"
        case .transcript: "Transcript"
        case .notes: "Notes"
        case .guide: "Guide"
        case .findings: "Intel"
        }
    }

    var icon: String {
        switch self {
        case .setup: "slider.horizontal.3"
        case .assist: "sparkles"
        case .auto: "wand.and.stars"
        case .transcript: "bubble.left.and.text.bubble.right"
        case .notes: "note.text"
        case .guide: "list.bullet.clipboard"
        case .findings: "checklist.checked"
        }
    }
}

struct OverlayTabBar: View {
    @Binding var selection: OverlayTab
    /// Which tabs to show. Notes/Guide are opt-in (toggled in Prepare), so the
    /// bar only renders the ones currently enabled.
    var tabs: [OverlayTab] = OverlayTab.allCases

    /// Reading the @Observable controller here makes the bar re-render when a
    /// proactive card arrives, lighting the Auto tab's unread badge.
    private var autoUnseen: Int {
        AutoAssistController.shared.unseenCount
    }

    var body: some View {
        HStack(spacing: RTIDesign.Spacing.xxs - 1) {
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
                HStack(spacing: RTIDesign.Spacing.xxs + 2) {
                    Image(systemName: tab.icon)
                        .font(RTIDesign.Font.bodySmall)
                    // Selection is a raised tile that names itself; the rest
                    // stay icon-only in secondary ink. No accent anywhere.
                    if isSelected {
                        Text(tab.title)
                            .font(RTIDesign.Font.tab)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, isSelected ? 10 : 0)
                .frame(minWidth: isSelected ? 0 : 30, minHeight: RTIDesign.Control.chip)
                // Unread badge: Auto surfaced cards the user hasn't seen.
                if tab == .auto, !isSelected, autoUnseen > 0 {
                    SlateStatusDot(color: RTIDesign.Color.danger)
                        .offset(x: -3, y: 5)
                }
            }
            .foregroundStyle(isSelected
                ? Color.overlayInk
                : (hovering ? Color.overlayInkSecondary : Color.overlayInkTertiary))
            .slateRaisedTile(isSelected, hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hovering)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .help(tab.title)
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
            Image(systemName: OverlayTab.setup.icon)
                .font(RTIDesign.Font.body)
                .foregroundStyle(selection == .setup
                    ? Color.overlayInk
                    : (hovering ? Color.overlayInkSecondary : Color.overlayInkTertiary))
                .frame(width: 30, height: RTIDesign.Control.chip)
                .slateRaisedTile(selection == .setup, hovering: hovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hovering)
        .accessibilityLabel("Prepare meeting")
        .accessibilityHint("Project, calendar, screen context, discussion guide, and live-analysis toggles")
        .help("Prepare meeting — project, calendar, screen context, discussion guide, and live-analysis toggles (⌘⌥0)")
    }
}
