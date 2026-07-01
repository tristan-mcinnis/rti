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
        case .findings: "Findings"
        }
    }

    var icon: String {
        switch self {
        case .setup: "checklist"
        case .assist: "sparkles"
        case .auto: "wand.and.stars"
        case .transcript: "text.bubble"
        case .notes: "note.text"
        case .guide: "list.bullet.clipboard"
        case .findings: "flag"
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
        HStack(spacing: 1) {
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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: tab.icon).font(.system(size: 10, weight: .medium))
                // Single line so a wide record pill never wraps a tab
                // label to two rows; if space is tight the label
                // truncates gracefully rather than squishing.
                Text(tab.title).font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                // Unread badge: Auto surfaced cards the user hasn't seen.
                if tab == .auto, !isSelected, autoUnseen > 0 {
                    Text("\(autoUnseen)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue))
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.overlayInk : Color.overlayInk.opacity(0.5))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.overlayInk.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

/// Leading icon button that opens the Setup surface. Setup is a pre-call
/// surface (project, discussion guide, live-analysis toggles), so it sits to
/// the left of the live tabs as a dedicated pill rather than competing with
/// them for equal weight. Click toggles into Setup and back to where you were.
struct OverlaySetupButton: View {
    @Binding var selection: OverlayTab
    @State private var lastNonSetup: OverlayTab = .assist

    var body: some View {
        Button {
            if selection == .setup {
                selection = lastNonSetup
            } else {
                lastNonSetup = selection
                selection = .setup
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: OverlayTab.setup.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text("Setup")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(selection == .setup ? Color.overlayInk : Color.overlayInk.opacity(0.6))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selection == .setup ? Color.overlayInk.opacity(0.14) : Color.overlayInk.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selection == .setup ? Color.overlayInk.opacity(0.12) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Setup")
        .accessibilityHint("Project, discussion guide, and live-analysis toggles")
        .help("Setup — project, discussion guide, and live-analysis toggles (⌘⌥0)")
    }
}
