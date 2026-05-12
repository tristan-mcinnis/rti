import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct SessionHistoryView: View {
    @State private var searchText = ""
    @State private var sessions: [Session] = []
    @State private var searchResults: [SessionSearchResult] = []
    @State private var isSearching = false
    @State private var sortOrder: SortOrder = .newest
    @State private var searchDebounceItem: DispatchWorkItem?
    @State private var isDropTargeted = false
    private let importer = SessionImporter.shared

    enum SortOrder: String, CaseIterable, CustomStringConvertible {
        case newest = "Newest"
        case oldest = "Oldest"
        case longest = "Longest"
        var description: String { rawValue }
    }

    /// Row indents that put list content on the same x-grid as the page
    /// title and toolbar (`xl = 32`). Without this the rows visibly hug the
    /// panel's left edge whenever the sidebar is collapsed.
    private static let rowInsets = EdgeInsets(
        top: 0,
        leading: RTIDesign.Spacing.xl,
        bottom: 0,
        trailing: RTIDesign.Spacing.xl
    )
    private static let headerInsets = EdgeInsets(
        top: RTIDesign.Spacing.md,
        leading: RTIDesign.Spacing.xl,
        bottom: RTIDesign.Spacing.xs,
        trailing: RTIDesign.Spacing.xl
    )

    private var isCurrentSessionActive: Bool {
        SessionCoordinator.shared.isRunning
    }
    private var currentSessionId: String? {
        SessionCoordinator.shared.currentSessionId
    }

    var body: some View {
        bodyContent
            .overlay { dropOverlay }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    @ViewBuilder
    private var bodyContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: RTIDesign.Spacing.lg) {
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
                    .frame(maxWidth: 480)
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
                }

                if importer.activeFilename != nil || importer.lastError != nil {
                    importBanner
                }
            }
            .padding(.horizontal, RTIDesign.Spacing.xl)
            .padding(.top, RTIDesign.Spacing.xl)
            .padding(.bottom, RTIDesign.Spacing.lg)

            if sessions.isEmpty && searchText.isEmpty {
                sessionListEmptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if isSearching && !searchText.isEmpty {
                        if searchResults.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView("Searching…")
                                    .font(RTIDesign.Font.caption)
                                    .foregroundStyle(RTIDesign.Color.textTertiary)
                                Spacer()
                            }
                            .padding(.vertical, RTIDesign.Spacing.xl)
                            .listRowSeparator(.hidden)
                        } else {
                            ForEach(searchResults) { result in
                                sessionRow(result.session, snippet: result.snippet)
                                    .listRowInsets(Self.rowInsets)
                                    .contentShape(Rectangle())
                                    .onTapGesture { openSession(result.session.id) }
                                    .contextMenu { contextMenu(for: result.session) }
                                    .listRowSeparator(.visible)
                            }
                        }
                    } else if !isSearching && !searchText.isEmpty && searchResults.isEmpty {
                        searchNoResultsView
                    } else {
                    // Group only on the default Newest sort, where chronological
                    // bands map cleanly to recency. Other sort orders ignore
                    // grouping and just show the flat list.
                    if sortOrder == .newest {
                        ForEach(groupedSessions, id: \.label) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    sessionRow(session, snippet: nil)
                                        .listRowInsets(Self.rowInsets)
                                        .contentShape(Rectangle())
                                        .onTapGesture { openSession(session.id) }
                                        .contextMenu { contextMenu(for: session) }
                                }
                            } header: {
                                Text(group.label)
                                    .font(RTIDesign.Font.meta.weight(.semibold))
                                    .foregroundStyle(RTIDesign.Color.textSecondary)
                                    .textCase(nil)
                                    .listRowInsets(Self.headerInsets)
                            }
                        }
                    } else {
                        ForEach(sortedSessions) { session in
                            sessionRow(session, snippet: nil)
                                .listRowInsets(Self.rowInsets)
                                .contentShape(Rectangle())
                                .onTapGesture { openSession(session.id) }
                                .contextMenu { contextMenu(for: session) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            }
        }
        .background(RTIDesign.Color.panelBackground)
        .task { loadSessions() }
        .onAppear { loadSessions() }
        .onReceive(NotificationCenter.default.publisher(for: .rtiSessionsChanged)) { _ in
            loadSessions()
        }
        .onChange(of: searchText) { _, _ in performSearch() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: loadSessions) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh session list")
            }
        }
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
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                    .layoutPriority(1)
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
        return TimeFormat.duration(sessionDuration(session))
    }

    private func liveDurationText(start: Date, now: Date) -> String {
        TimeFormat.elapsed(now.timeIntervalSince(start))
    }

    private func modeName(for session: Session) -> String? {
        guard let modeId = session.modeId else { return nil }
        return ModeStore.shared.modes.first(where: { $0.id == modeId })?.name
    }

    private func loadSessions() {
        Task.detached(priority: .userInitiated) {
            let markdownSessions = CorpusBackedStore.allMarkdownSessions()
            await MainActor.run {
                var sessions = markdownSessions
                if let active = ActiveSessionProjection.currentSession(),
                   !sessions.contains(where: { $0.id == active.id }) {
                    sessions.insert(active, at: 0)
                }
                self.sessions = sessions.sorted { $0.startedAt > $1.startedAt }
            }
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

    private var sessionListEmptyState: some View {
        VStack(spacing: RTIDesign.Spacing.md) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 32))
                .foregroundStyle(RTIDesign.Color.textTertiary)
                .allowsHitTesting(false)
            Text("No sessions yet")
                .font(RTIDesign.Font.heading)
                .foregroundStyle(RTIDesign.Color.textSecondary)
            Text("Start recording with ⌘\\ to create your first session.")
                .font(RTIDesign.Font.bodySmall)
                .foregroundStyle(RTIDesign.Color.textTertiary)
            Text("Or drag an audio or video file here to transcribe it.")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchNoResultsView: some View {
        HStack {
            Spacer()
            VStack(spacing: RTIDesign.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(RTIDesign.Color.textTertiary)
                Text("No sessions match your search")
                    .font(RTIDesign.Font.bodySmall)
                    .foregroundStyle(RTIDesign.Color.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, RTIDesign.Spacing.xxl)
        .listRowSeparator(.hidden)
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

    // MARK: - Drop / import

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                RTIDesign.Color.panelBackground.opacity(0.85)
                VStack(spacing: RTIDesign.Spacing.md) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(RTIDesign.Color.textSecondary)
                    Text("Drop audio, video, or a folder to transcribe")
                        .font(RTIDesign.Font.heading)
                        .foregroundStyle(RTIDesign.Color.textPrimary)
                    Text("Each file becomes its own session. Folders are scanned recursively.")
                        .font(RTIDesign.Font.bodySmall)
                        .foregroundStyle(RTIDesign.Color.textSecondary)
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var importBanner: some View {
        HStack(spacing: RTIDesign.Spacing.sm) {
            if let filename = importer.activeFilename {
                ProgressView().scaleEffect(0.6)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(filename)
                            .font(RTIDesign.Font.bodySmall.weight(.medium))
                            .foregroundStyle(RTIDesign.Color.textPrimary)
                            .lineLimit(1)
                        if importer.batchTotal > 1 {
                            Text("(\(importer.batchCompleted + 1) of \(importer.batchTotal))")
                                .font(RTIDesign.Font.caption)
                                .foregroundStyle(RTIDesign.Color.textTertiary)
                        }
                    }
                    if let msg = importer.progressMessage {
                        Text(importer.queueCount > 0
                             ? "\(msg)  ·  \(importer.queueCount) queued"
                             : msg)
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(RTIDesign.Color.textSecondary)
                    }
                }
                Spacer()
                Button(importer.batchTotal > 1 ? "Cancel all" : "Cancel") {
                    importer.cancel()
                }
                .buttonStyle(.plain)
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.textSecondary)
            } else if let error = importer.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(RTIDesign.Color.textSecondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    importer.clearError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RTIDesign.Color.textTertiary)
            }
        }
        .padding(.horizontal, RTIDesign.Spacing.md)
        .padding(.vertical, RTIDesign.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                .fill(RTIDesign.Color.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: RTIDesign.Radius.md)
                        .stroke(RTIDesign.Color.border, lineWidth: 1)
                )
        )
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        // Fan out: each provider resolves async to a URL; once all have
        // resolved we hand the full list (which may include directories)
        // to the importer, which expands directories and queues serially.
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            importer.importFiles(urls)
        }
        return true
    }

    private func performSearch() {
        // Debounce: wait 200 ms after the last keystroke before hitting the
        // DB so fast typing doesn't fan out N concurrent scans.
        searchDebounceItem?.cancel()
        let item = DispatchWorkItem { [self] in
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                isSearching = false
                searchResults = []
                return
            }
            isSearching = true
            Task.detached(priority: .userInitiated) {
                let results = SessionSearch.search(query: trimmed)
                await MainActor.run {
                    self.searchResults = results
                    self.isSearching = false
                }
            }
        }
        searchDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: item)
    }
}
