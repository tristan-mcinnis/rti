import SwiftUI

/// Tabbed hub view that hosts Live Transcript, Sessions (with push-nav to
/// session detail), Settings, and Logs — replacing five separate windows.
struct SessionsControlView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case liveTranscript = "Live Transcript"
        case sessions = "Sessions"
        case settings = "Settings"
        case logs = "Logs"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .liveTranscript: return "text.bubble.fill"
            case .sessions:      return "list.bullet.rectangle"
            case .settings:      return "gearshape.fill"
            case .logs:          return "doc.text.magnifyingglass"
            }
        }
    }

    @State private var selectedTab: Tab
    /// Non-nil when the Sessions tab has pushed into a session detail view.
    @State private var sessionNavId: String?
    /// Optional FTS query the user came from (palette → session). Forwarded
    /// to `SessionDetailView` so it can highlight matched terms in the
    /// transcript and auto-scroll to the first hit.
    @State private var sessionHighlightQuery: String?

    init(initialTab: Tab = .liveTranscript) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180)
            .safeAreaInset(edge: .bottom) {
                versionFooter
            }
        } detail: {
            contentForTab
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                CommandPaletteSearchButton()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSessionDetail)) { notif in
            guard let parsed = SessionDetailRequest.extract(from: notif.object) else { return }
            selectedTab = .sessions
            sessionNavId = parsed.id
            sessionHighlightQuery = parsed.query
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiShowSessionHistory)) { _ in
            selectedTab = .sessions
            sessionNavId = nil
            sessionHighlightQuery = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiShowLiveTranscript)) { _ in
            selectedTab = .liveTranscript
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiShowLogs)) { _ in
            selectedTab = .logs
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiSelectSessionsControlTab)) { notif in
            guard let tab = notif.object as? Tab else { return }
            selectedTab = tab
        }
    }

    @ViewBuilder
    private var contentForTab: some View {
        switch selectedTab {
        case .liveTranscript:
            DebugConsoleView()
                .environmentObject(SessionCoordinator.shared)

        case .sessions:
            if let sessionId = sessionNavId {
                SessionDetailView(
                    sessionId: sessionId,
                    highlightQuery: sessionHighlightQuery
                )
            } else {
                SessionHistoryView()
            }

        case .settings:
            SettingsView(onClose: nil)

        case .logs:
            LogsView()
        }
    }

    /// Build / version footer pinned to the bottom of the sidebar.
    private var versionFooter: some View {
        VStack(spacing: 2) {
            Divider()
            Text(versionString)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "RTI \(v) (\(b))"
    }
}

/// Toolbar-resident search affordance that opens the command palette. Always
/// visible across every Sessions Control tab so search is never more than
/// one click (or ⌘K) away. Mirrors the Cluely-style "Search or ask anything"
/// pill — purely a button; the actual query happens inside the palette.
@MainActor
private struct CommandPaletteSearchButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: openPalette) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Search or ask anything…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 16)
                HStack(spacing: 2) {
                    Text("⌘")
                    Text("K")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                )
            }
            .padding(.horizontal, 10)
            .frame(width: 360, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(isHovered ? 0.16 : 0.10))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Search sessions, actions, and settings (⌘K)")
        .keyboardShortcut("k", modifiers: .command)
    }

    private func openPalette() {
        NotificationCenter.default.post(name: .rtiToggleCommandPalette, object: nil)
    }
}
