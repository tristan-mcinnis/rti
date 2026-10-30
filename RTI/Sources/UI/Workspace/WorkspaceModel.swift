import Foundation
import Observation
import RTICore

/// Navigation owns presentation only. Capture and chat keep their existing owners.
@Observable @MainActor
final class WorkspaceModel {
    static let shared = WorkspaceModel()

    enum Page: String, CaseIterable, Identifiable {
        case live = "Live", sessions = "Sessions", chats = "Chats", settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .live: "waveform"
            case .sessions: "clock.arrow.circlepath"
            case .chats: "bubble.left.and.bubble.right"
            case .settings: "gearshape"
            }
        }
        var windowKind: RTIWindowKind {
            switch self {
            case .live: .overlay
            case .sessions, .chats: .sessions
            case .settings: .settings
            }
        }
    }

    private(set) var page: Page = .live
    private(set) var previousPage: Page = .live
    private(set) var hasVisitedLibrary = false
    private(set) var reloadRequest = 0
    let sessions: SessionsWindowModel
    var isBriefPresented = false
    let brief = MeetingBriefModel()
    let settings: SettingsNavigation
    @ObservationIgnored var onNavigate: ((Page) -> Void)?

    init(sessions: SessionsWindowModel = SessionsWindowModel(), settings: SettingsNavigation = SettingsNavigation()) {
        self.sessions = sessions
        self.settings = settings
        sessions.isWindowVisible = false
    }

    func select(_ page: Page) {
        if page != self.page {
            previousPage = self.page
            self.page = page
            OverlayShellModel.shared.chooser = nil
            sessions.playback.pause()
        }
        if page == .sessions || page == .chats {
            hasVisitedLibrary = true
            sessions.mode = page == .sessions ? .sessions : .chats
        }
        sessions.isWindowVisible = page == .sessions || page == .chats
        if !sessions.isWindowVisible {
            sessions.playback.pause()
            sessions.closeActions()
            sessions.isCommandHeld = false
        }
        reloadRequest &+= 1
        onNavigate?(page)
    }

    func showSettings(_ pane: SettingsView.SettingsTab = .providers) {
        settings.pane = pane
        settings.query = ""
        select(.settings)
    }

    func leaveSettings() {
        select(previousPage == .settings ? .live : previousPage)
    }

    func showBrief(_ url: URL? = nil) {
        brief.reload()
        if let url {
            brief.open(url: url)
            brief.isRailVisible = false
        }
        isBriefPresented = true
    }

    func showSession(folder: String? = nil) {
        select(.sessions)
        if let folder { sessions.open(folder: folder) }
    }
}
