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
        .onReceive(NotificationCenter.default.publisher(for: .openSessionDetail)) { notif in
            guard let id = notif.object as? String else { return }
            selectedTab = .sessions
            sessionNavId = id
        }
        .onReceive(NotificationCenter.default.publisher(for: .rtiShowSessionHistory)) { _ in
            selectedTab = .sessions
            sessionNavId = nil
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
                SessionDetailView(sessionId: sessionId)
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
