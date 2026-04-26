import GRDB
import SwiftUI

extension Notification.Name {
    static let openSessionDetail = Notification.Name("rti.openSessionDetail")
}

struct SessionHistoryView: View {
    @State private var searchText = ""
    @State private var sessions: [Session] = []
    @State private var searchResults: [SessionSearchResult] = []
    @State private var isSearching = false
    @State private var sortOrder: SortOrder = .newest

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
                    }
                } else {
                    ForEach(sortedSessions) { session in
                        sessionRow(session, snippet: nil)
                            .contentShape(Rectangle())
                            .onTapGesture { openSession(session.id) }
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

    private func sessionRow(_ session: Session, snippet: String?) -> some View {
        VStack(alignment: .leading, spacing: RTIDesign.Spacing.xxs) {
            HStack {
                Text(sessionTitle(session))
                    .font(RTIDesign.Font.bodySmall.weight(.medium))
                    .foregroundStyle(RTIDesign.Color.textPrimary)
                Spacer()
                if session.id == currentSessionId, isCurrentSessionActive {
                    Text("Active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(RTIDesign.Color.chipActiveText)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RTIDesign.Color.chipActiveBg, in: RoundedRectangle(cornerRadius: 8))
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

    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            searchResults = []
            return
        }
        isSearching = true
        Task {
            let results = SessionSearch.search(query: trimmed)
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        }
    }
}
