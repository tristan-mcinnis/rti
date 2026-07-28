import RTICore
import SwiftUI

/// The tabs of the consolidated overlay. One window, one toggle (⌘\), tabs
/// across the top — instead of a constellation of floating panels.
enum OverlayTab: String, CaseIterable, Identifiable {
    // Setup is leftmost — it's the pre-call surface (who the meeting is about +
    // the discussion guide). The rest are live.
    case setup, assist, auto, transcript, notes, guide, findings
    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .setup: "Setup"
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
    /// Which tabs to show. Notes/Guide are opt-in (toggled in Setup), so the
    /// bar only renders the ones currently enabled.
    var tabs: [OverlayTab] = OverlayTab.allCases

    /// Reading the @Observable controller here makes the bar re-render when a
    /// proactive card arrives, lighting the Auto tab's unread badge.
    private var autoUnseen: Int {
        AutoAssistController.shared.unseenCount
    }

    var body: some View {
        HStack(spacing: 2) {
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
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 30, height: 28)
                // Unread badge: Auto surfaced cards the user hasn't seen.
                if tab == .auto, !isSelected, autoUnseen > 0 {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                        .offset(x: -3, y: 5)
                }
            }
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

/// Leading icon button that opens the Setup surface. Setup is a pre-call
/// surface (project, discussion guide, live-analysis toggles), so it sits to
/// the left of the live tabs as a dedicated pill rather than competing with
/// them for equal weight. Click toggles into Setup and back to where you were.
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
        .accessibilityLabel("Setup")
        .accessibilityHint("Project, screen context, discussion guide, and live-analysis toggles")
        .help("Setup — project, screen context, discussion guide, and live-analysis toggles (⌘⌥0)")
    }
}
