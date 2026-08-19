import RTICore
import SwiftUI

/// The tabs of the consolidated overlay. One window, one toggle (⌘\), tabs
/// across the top — instead of a constellation of floating panels.
enum OverlayTab: String, CaseIterable, Identifiable {
    // Prepare is the meeting home; the rest are live surfaces.
    case setup, assist, transcript
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .setup: "Prepare"
        case .assist: "Assist"
        case .transcript: "Transcript"
        }
    }

    var icon: String {
        switch self {
        case .setup: "slider.horizontal.3"
        case .assist: "sparkles"
        case .transcript: "bubble.left.and.text.bubble.right"
        }
    }
}

struct OverlayTabBar: View {
    @Binding var selection: OverlayTab
    /// Which tabs to show. Notes/Guide are opt-in (toggled in Prepare), so the
    /// bar only renders the ones currently enabled.
    var tabs: [OverlayTab] = OverlayTab.allCases

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                OverlayTabButton(
                    tab: tab,
                    isSelected: selection == tab,
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
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 30, height: 28)
            .foregroundStyle(isSelected ? Color.overlayAccent : Color.overlayInk.opacity(hovering ? 0.68 : 0.46))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                        ? Color.overlayAccent.opacity(0.12)
                        : Color.overlayInk.opacity(hovering ? 0.055 : 0))
            )
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
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(selection == .setup ? Color.overlayAccent : Color.overlayInk.opacity(hovering ? 0.68 : 0.46))
                .frame(width: 30, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selection == .setup
                        ? Color.overlayAccent.opacity(0.12)
                        : Color.overlayInk.opacity(hovering ? 0.055 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hovering)
        .accessibilityLabel("Prepare meeting")
        .accessibilityHint("Project, calendar, screen context, discussion guide, and live-analysis toggles")
        .help("Prepare meeting — project, calendar, screen context, discussion guide, and live-analysis toggles (⌘⌥0)")
    }
}
