import Foundation
import Observation
import RTICore
import HouseChatCore

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
    private(set) var isWindowVisible = true
    private(set) var chatOrigin: SessionsWindowModel.ReadingOrigin?
    private(set) var resumedChatID: String?
    private var hasResumedChat = false
    var isLivePageActive: Bool { isWindowVisible && page == .live }
    let sessions: SessionsWindowModel
    var isBriefPresented = false
    let brief = MeetingBriefModel()
    let settings: SettingsNavigation
    @ObservationIgnored var onNavigate: ((Page) -> Void)?

    init(sessions: SessionsWindowModel = SessionsWindowModel(), settings: SettingsNavigation = SettingsNavigation()) {
        self.sessions = sessions
        self.settings = settings
        sessions.isWindowVisible = false
        sessions.onAsk = { [weak self] in self?.rememberSessionOrigin() }
        sessions.onOpenRelatedChat = { [weak self] id in self?.openRelatedChat(id: id) }
        sessions.chatLibrary.onResume = { [weak self] id in self?.prepareToResumeChat(id: id) }
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
        updateLibraryVisibility()
        if !sessions.isWindowVisible {
            sessions.playback.pause()
            sessions.closeActions()
            sessions.isCommandHeld = false
        }
        reloadRequest &+= 1
        onNavigate?(page)
    }

    /// Hiding the window retires UI work, never capture or the current draft.
    func setWindowVisible(_ visible: Bool) {
        let becameVisible = visible && !isWindowVisible
        isWindowVisible = visible
        updateLibraryVisibility()
        if becameVisible { reloadRequest &+= 1 }
        if !visible {
            sessions.playback.pause()
            sessions.closeActions()
            sessions.isCommandHeld = false
        }
    }

    private func updateLibraryVisibility() {
        sessions.isWindowVisible = isWindowVisible && (page == .sessions || page == .chats)
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

    /// Explicit session metadata is the only route back from a saved chat.
    var linkedSessionRows: [SessionsWindowModel.Row] {
        let links = sessions.chatLibrary.openID.flatMap { sessions.chatLibrary.sessionLinksByID[$0] } ?? []
        return sessions.rows.filter { row in
            guard let id = row.sessionID else { return false }
            return links.contains { $0.kind == "rti-session" && $0.id == id }
        }
    }

    var selectedChatHasSessionLink: Bool {
        guard let id = sessions.chatLibrary.openID else { return false }
        return sessions.chatLibrary.sessionLinksByID[id]?.contains { $0.kind == "rti-session" } == true
    }

    var returnSessionRow: SessionsWindowModel.Row? {
        if page == .live {
            guard resumedChatID == nil || hasResumedChat else { return nil }
            return chatOrigin.flatMap { origin in sessions.rows.first { $0.id == origin.rowID } }
        }
        guard page == .chats else { return nil }
        let linked = linkedSessionRows
        if let origin = chatOrigin, let row = linked.first(where: { $0.id == origin.rowID }) { return row }
        return linked.count == 1 ? linked.first : nil
    }

    func rememberSessionOrigin() {
        chatOrigin = sessions.readingOrigin
        resumedChatID = nil
        hasResumedChat = false
    }

    func openRelatedChat(id: String) {
        guard sessions.relatedChats.contains(where: { $0.id == id }) else { return }
        rememberSessionOrigin()
        sessions.chatLibrary.select(id: id)
        select(.chats)
    }

    func prepareToResumeChat(id: String) {
        // Keep an existing origin only if this thread explicitly names it.
        let links = sessions.chatLibrary.sessionLinksByID[id] ?? []
        let linked = sessions.rows.filter { row in
            row.sessionID.map { sessionID in links.contains { $0.kind == "rti-session" && $0.id == sessionID } } == true
        }
        if let origin = chatOrigin, linked.contains(where: { $0.id == origin.rowID }) {
            // Keep the selected file and reader origin for this round trip.
        } else if let row = linked.first, linked.count == 1 {
            chatOrigin = sessions.openRowID == row.id ? sessions.readingOrigin
                : SessionsWindowModel.ReadingOrigin(rowID: row.id, fileName: "chat", railVisible: sessions.isRailVisible)
        } else {
            chatOrigin = nil
        }
        resumedChatID = id
        hasResumedChat = false
    }

    /// An older active thread may remain visible while resume is loading.
    func conversationDidChange(to id: String?) {
        guard let resumedChatID else { return }
        if id == resumedChatID { hasResumedChat = true }
        else if hasResumedChat { clearChatOrigin() }
    }

    func conversationDidFinishResume(id: String, succeeded: Bool) {
        guard id == resumedChatID else { return }
        if succeeded { hasResumedChat = true }
        else { clearChatOrigin() }
    }

    func conversationWillReset(resumingChatID: String?) {
        guard let resumingChatID, resumingChatID == resumedChatID else {
            clearChatOrigin()
            return
        }
    }

    func clearChatOrigin() {
        chatOrigin = nil
        resumedChatID = nil
        hasResumedChat = false
    }

    func returnToSession(_ row: SessionsWindowModel.Row) {
        if let origin = chatOrigin, origin.rowID == row.id {
            sessions.restore(origin)
        } else if sessions.openRowID != row.id {
            sessions.open(row.id)
            sessions.selectFile(named: "chat")
        }
        select(.sessions)
    }

    /// Re-entering a library refreshes its linked records as well as its list.
    func reloadVisiblePage() async {
        guard isWindowVisible else { return }
        switch page {
        case .sessions:
            await sessions.reload()
        case .chats:
            await sessions.reload()
            guard !Task.isCancelled, isWindowVisible, page == .chats else { return }
            await sessions.loadActiveLibrary()
        case .live, .settings:
            break
        }
    }

    func showSession(folder: String? = nil) {
        select(.sessions)
        if let folder { sessions.open(folder: folder) }
    }
}
