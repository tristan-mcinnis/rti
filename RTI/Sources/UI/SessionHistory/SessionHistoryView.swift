import GRDB
import SwiftUI

extension Notification.Name {
    static let openSessionDetail = Notification.Name("rti.openSessionDetail")
    static let rtiToggleOverlay = Notification.Name("rti.toggleOverlay")
    static let rtiClearChat = Notification.Name("rti.clearChat")
    static let rtiOverlayDidBecomeKey = Notification.Name("rti.overlayDidBecomeKey")
    static let rtiOverlaySizeChanged = Notification.Name("rti.overlaySizeChanged")
    static let rtiShowLiveTranscript = Notification.Name("rti.showLiveTranscript")
}

enum OverlayAppearanceDefaults {
    static let widthKey = "rti.overlay.width"
    static let heightKey = "rti.overlay.height"
    static let opacityKey = "rti.overlay.opacity"
    static let defaultWidth: Double = 700
    static let defaultHeight: Double = 440
    static let defaultOpacity: Double = 0.90
    static let widthRange: ClosedRange<Double> = 320...800
    static let heightRange: ClosedRange<Double> = 400...900
    static let opacityRange: ClosedRange<Double> = 0.30...0.95
}

struct SessionHistoryView: View {
    @State private var searchText = ""
    @State private var sessions: [Session] = []
    @State private var searchResults: [SessionSearchResult] = []
    @State private var isSearching = false
    @State private var sortOrder: SortOrder = .newest
    @State private var searchTask: Task<Void, Never>?

    enum SortOrder: String, CaseIterable, CustomStringConvertible {
        case newest = "Newest"
        case oldest = "Oldest"
        case longest = "Longest"
        var description: String { rawValue }
    }

    private var isCurrentSessionActive: Bool {
        SessionCoordinator.shared.isRunning
    }
    private var currentSessionId: String? {
        SessionCoordinator.shared.currentSessionId
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: RTIDesign.Spacing.md) {
                Text("Session History")
                    .font(RTIDesign.Font.pageTitle)
                    .foregroundStyle(RTIDesign.Color.textPrimary)

                HStack(spacing: RTIDesign.Spacing.md) {
                    HStack(spacing: RTIDesign.Spacing.xs) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(RTIDesign.Color.textTertiary)
                            .font(.system(size: 14))
                        TextField("Search sessions…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(RTIDesign.Font.bodySmall)
                        if isSearching {
                            ProgressView().scaleEffect(0.7)
                        }
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(RTIDesign.Color.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, RTIDesign.Spacing.md)
                    .frame(height: RTIDesign.Control.heightMd)
                    .background(
                        RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                            .fill(RTIDesign.Color.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                                    .stroke(RTIDesign.Color.border, lineWidth: 1)
                            )
                    )

                    Spacer()

                    RTISegmentedPicker(selection: $sortOrder, items: SortOrder.allCases)
                        .frame(width: 320)
                }
            }
            .padding(.horizontal, RTIDesign.Spacing.xl)
            .padding(.top, RTIDesign.Spacing.xl)

            Divider()
                .padding(.top, RTIDesign.Spacing.lg)

            List {
                if isSearching && !searchText.isEmpty {
                    ForEach(searchResults) { result in
                        sessionRow(result.session, snippet: result.snippet)
                            .contentShape(Rectangle())
                            .onTapGesture { openSession(result.session.id) }
                            .contextMenu { contextMenu(for: result.session) }
                    }
                } else {
                    // Group only on the default Newest sort, where chronological
                    // bands map cleanly to recency. Other sort orders ignore
                    // grouping and just show the flat list.
                    if sortOrder == .newest {
                        ForEach(groupedSessions, id: \.label) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    sessionRow(session, snippet: nil)
                                        .contentShape(Rectangle())
                                        .onTapGesture { openSession(session.id) }
                                        .contextMenu { contextMenu(for: session) }
                                }
                            } header: {
                                Text(group.label)
                                    .font(RTIDesign.Font.meta.weight(.semibold))
                                    .foregroundStyle(RTIDesign.Color.textSecondary)
                                    .textCase(nil)
                                    .padding(.top, RTIDesign.Spacing.sm)
                            }
                        }
                    } else {
                        ForEach(sortedSessions) { session in
                            sessionRow(session, snippet: nil)
                                .contentShape(Rectangle())
                                .onTapGesture { openSession(session.id) }
                                .contextMenu { contextMenu(for: session) }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .background(RTIDesign.Color.panelBackground)
        .task { loadSessions() }
        .onChange(of: searchText) { _, _ in performSearch() }
    }

    private var sortedSessions: [Session] {
        switch sortOrder {
        case .newest:
            return sessions.sorted { $0.startedAt > $1.startedAt }
        case .oldest:
            return sessions.sorted { $0.startedAt < $1.startedAt }
        case .longest:
            return sessions.sorted { sessionDuration($0) > sessionDuration($1) }
        }
    }

    private struct SessionGroup {
        let label: String
        let sessions: [Session]
    }

    private var groupedSessions: [SessionGroup] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let startOfMonth = cal.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday

        var today: [Session] = []
        var yesterday: [Session] = []
        var thisWeek: [Session] = []
        var thisMonth: [Session] = []
        var earlier: [Session] = []

        for s in sortedSessions {
            switch s.startedAt {
            case startOfToday...:
                today.append(s)
            case startOfYesterday..<startOfToday:
                yesterday.append(s)
            case startOfWeek..<startOfYesterday:
                thisWeek.append(s)
            case startOfMonth..<startOfWeek:
                thisMonth.append(s)
            default:
                earlier.append(s)
            }
        }

        var groups: [SessionGroup] = []
        if !today.isEmpty { groups.append(.init(label: "Today", sessions: today)) }
        if !yesterday.isEmpty { groups.append(.init(label: "Yesterday", sessions: yesterday)) }
        if !thisWeek.isEmpty { groups.append(.init(label: "This Week", sessions: thisWeek)) }
        if !thisMonth.isEmpty { groups.append(.init(label: "This Month", sessions: thisMonth)) }
        if !earlier.isEmpty { groups.append(.init(label: "Earlier", sessions: earlier)) }
        return groups
    }

    private func sessionRow(_ session: Session, snippet: String?) -> some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.xxs) {
            HStack {
                Text(sessionTitle(session))
                    .font(RTIDesign.Font.bodySmall.weight(.medium))
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                Spacer()
                if session.id == currentSessionId, isCurrentSessionActive {
                    TimelineView(.periodic(from: .now, by: 1.0)) { ctx in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 7, height: 7)
                            Text("Active · \(liveDurationText(start: session.startedAt, now: ctx.date))")
                                .monospacedDigit()
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RTIDesign.Color.chipActiveText)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RTIDesign.Color.chipActiveBg, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack(spacing: 6) {
                Text(sessionDate(session))
                if let duration = sessionDurationText(session) {
                    Text("·")
                    Text(duration)
                }
                if let modeName = modeName(for: session) {
                    Text("·")
                    Text(modeName)
                }
            }
            .font(RTIDesign.Font.caption)
            .foregroundStyle(RTIDesign.Color.textSecondary)

            if let snippet = snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(RTIDesign.Color.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, RTIDesign.Spacing.sm)
        .listRowSeparator(.visible)
    }

    private func sessionTitle(_ session: Session) -> String {
        if let calendarTitle = session.calendarTitle, !calendarTitle.isEmpty {
            return calendarTitle
        }
        if let title = session.title, !title.isEmpty {
            return title
        }
        return "Session \(session.startedAt.formatted(date: .numeric, time: .shortened))"
    }

    private func sessionDate(_ session: Session) -> String {
        session.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func sessionDuration(_ session: Session) -> TimeInterval {
        let end = session.endedAt ?? Date()
        return end.timeIntervalSince(session.startedAt)
    }

    private func sessionDurationText(_ session: Session) -> String? {
        guard session.endedAt != nil else { return nil }
        let duration = sessionDuration(session)
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }

    private func liveDurationText(start: Date, now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func modeName(for session: Session) -> String? {
        guard let modeId = session.modeId else { return nil }
        return ModeStore.shared.modes.first(where: { $0.id == modeId })?.name
    }

    private func loadSessions() {
        do {
            sessions = try RTIDatabase.shared.pool.read { db in
                try Session.order(Column("started_at").desc).fetchAll(db)
            }
        } catch {
            NSLog("[RTI] SessionHistory load failed: \(error)")
        }
    }

    private func openSession(_ id: String) {
        NotificationCenter.default.post(name: .openSessionDetail, object: id)
    }

    @ViewBuilder
    private func contextMenu(for session: Session) -> some View {
        Button("Open") { openSession(session.id) }
        if let path = session.wavPath, FileManager.default.fileExists(atPath: path) {
            Button("Reveal Audio in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Divider()
        Button("Delete Session…", role: .destructive) {
            confirmDelete(session: session)
        }
        .disabled(SessionCoordinator.shared.isRunning && SessionCoordinator.shared.currentSessionId == session.id)
    }

    private func confirmDelete(session: Session) {
        let alert = NSAlert()
        alert.messageText = "Delete this session?"
        alert.informativeText = "This permanently deletes the transcript, chat history, summary, and audio recording for \(sessionTitle(session)). This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            SessionCoordinator.shared.deleteSession(id: session.id)
            loadSessions()
        }
    }

    private func performSearch() {
        // Cancel any in-flight search so rapid typing doesn't fan out N
        // concurrent DB scans whose results race to win the last write.
        searchTask?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            searchResults = []
            return
        }
        isSearching = true
        searchTask = Task {
            let results = SessionSearch.search(query: trimmed)
            if Task.isCancelled { return }
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }
}
