import AppKit
import HouseDesign
import Observation
import RTICore
import UniformTypeIdentifiers

extension SessionsWindowModel {
    // MARK: - Find

    func recomputeFindHits() {
        guard isFindPresented else {
            findHits = []
            findHitsByBlock = [:]
            return
        }
        findHits = document.blockTexts.enumerated().flatMap { index, text in
            SessionsWindowRules.findRanges(of: findQuery, in: text).map { FindHit(block: index, range: $0) }
        }
        findHitsByBlock = Dictionary(grouping: findHits, by: \.block).mapValues { $0.map(\.range) }
    }

    var currentFindHit: FindHit? {
        let hits = findHits
        guard !hits.isEmpty else { return nil }
        return hits[min(max(findIndex, 0), hits.count - 1)]
    }

    var findStatus: String {
        SessionsWindowRules.findStatus(current: findIndex, total: findHits.count, query: findQuery)
    }

    /// Every hit range in one block, and the current one if it is here.
    func findHighlights(inBlock block: Int) -> (all: [Range<String.Index>], current: Range<String.Index>?) {
        guard let ranges = findHitsByBlock[block] else { return ([], nil) }
        let current = currentFindHit.flatMap { $0.block == block ? $0.range : nil }
        return (ranges, current)
    }

    func findNext() {
        stepFind(1)
    }

    func findPrevious() {
        stepFind(-1)
    }

    private func stepFind(_ delta: Int) {
        let count = findHits.count
        guard count > 0 else { return }
        findIndex = (findIndex + delta + count) % count
    }

    func showFind() {
        isFindPresented = true
        findFocusRequest += 1
    }

    func closeFind() {
        isFindPresented = false
        findQuery = ""
        if focus == .find {
            focus = .none
        }
    }

    // MARK: - Loading

    /// Load the list once (the window's first appearance), unless a load
    /// is already on its way.
    func loadIfNeeded() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    /// Reload the list and the vault note titles off the main thread, then
    /// keep the open session (or open the newest one) and start the lazy
    /// title generation.
    func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        defer {
            if generation == reloadGeneration {
                isLoading = false
            }
        }
        let limit = Self.listLimit
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadRows(limit: limit)
        }.value
        guard !Task.isCancelled, generation == reloadGeneration else { return }
        apply(rows: loaded.rows, titleMap: loaded.map)
    }

    private func apply(rows newRows: [Row], titleMap map: VaultMeetingTitleMap) {
        rows = newRows
        titleMap = map
        hasLoaded = true
        if let folder = pendingFolder, let row = newRows.first(where: { $0.folderName == folder }) {
            pendingFolder = nil
            open(row.id)
        } else if let openRowID, newRows.contains(where: { $0.id == openRowID }) {
            refreshFiles(keepSelection: true)
        } else {
            openRowID = nil
            if let first = newRows.first {
                open(first.id)
            } else {
                clearReader()
            }
        }
        clampRailIndex()
    }

    /// Read every session's title files, `session.json`, and file list.
    /// Runs on a background task; no state is touched here.
    nonisolated static func loadRows(limit: Int) -> (rows: [Row], map: VaultMeetingTitleMap) {
        let databases = VaultPaths.preferredDatabasesDirectory()
        let meetings = databases?.appendingPathComponent("meetings", isDirectory: true)
        let map = meetings.map { VaultMeetingTitleMap.build(meetingsDirectory: $0) } ?? .empty
        let sessions = SessionArchive.recentSessions(limit: limit)
        return (sessions.map { makeRow($0, titleMap: map, databases: databases) }, map)
    }

    nonisolated static func makeRow(
        _ session: SessionArchive.ArchivedSession,
        titleMap: VaultMeetingTitleMap,
        databases: URL?
    ) -> Row {
        var row = makeBareRow(session, titleMap: titleMap)
        let fm = FileManager.default
        row.recordingError = SessionArchive.recordingError(in: session.url)
        if row.recordingError != nil {
            row.transcriptStatus = "Recording needs review"
        }
        row.hasTranscript = fm.fileExists(atPath: session.transcriptURL.path)
        row.hasRetainedAudio = session.isRTIArchive && !TranscriptUpgradeService.audioInputs(in: session.url).isEmpty
        if row.hasTranscript, let databases {
            let base = databases.standardizedFileURL.path
            let path = session.transcriptURL.standardizedFileURL.path
            if path.hasPrefix(base + "/") {
                row.vaultTranscriptPath = String(path.dropFirst(base.count + 1))
            }
        }
        return row
    }

    private nonisolated static func makeBareRow(_ session: SessionArchive.ArchivedSession, titleMap: VaultMeetingTitleMap) -> Row {
        let fm = FileManager.default
        guard session.isRTIArchive else {
            // A legacy recorded meeting: its sidecar name, unless generic.
            let stamp = session.date.map(canonicalStamp(for:))
            let bytes = (try? fm.attributesOfItem(atPath: session.transcriptURL.path))?[.size] as? Int
            let named = session.title == "Recorded meeting" ? nil : session.title
            let inputs = SessionTitleInputs(
                titleFile: named,
                vaultNoteTitle: stamp.flatMap(titleMap.title(forStamp:)),
                transcriptHead: transcriptHead(of: session.transcriptURL),
                startedAt: session.date,
                transcriptBytes: bytes
            )
            return Row(
                session: session,
                title: SessionTitleResolver.resolve(inputs),
                durationSeconds: nil, project: nil, mode: nil, speakerNames: [],
                stamp: stamp,
                transcriptStatus: bytes == nil ? "No transcript" : nil
            )
        }

        let dir = session.url
        let names = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        func read(_ name: String) -> String? {
            guard names.contains(name) else { return nil }
            return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        let metadata = read("session.json")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(SessionArchiveMetadata.self, from: $0) }
        let speakers = read("speaker-names.json")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            .map { $0.values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.sorted() } ?? []
        let stamp = VaultMeetingTitleMap.canonicalStamp(fromFolderName: dir.lastPathComponent)
        let bytes = names.contains("transcript.md")
            ? (try? fm.attributesOfItem(atPath: session.transcriptURL.path))?[.size] as? Int
            : nil
        let inputs = SessionTitleInputs(
            titleFile: read(SessionTitleResolver.titleFileName),
            hasManualMarker: names.contains(SessionTitleResolver.manualMarkerFileName),
            vaultNoteTitle: stamp.flatMap(titleMap.title(forStamp:)),
            calendarTitle: metadata?.calendarTitle,
            transcriptHead: transcriptHead(of: session.transcriptURL),
            startedAt: session.date,
            durationSeconds: metadata?.durationSeconds,
            transcriptBytes: bytes
        )
        return Row(
            session: session,
            title: SessionTitleResolver.resolve(inputs),
            durationSeconds: metadata?.durationSeconds,
            project: metadata?.workstream,
            mode: metadata?.mode,
            speakerNames: speakers,
            stamp: stamp,
            transcriptStatus: SessionsWindowRules.transcriptStatus(fileNames: names),
            sessionID: metadata?.sessionId
        )
    }

    /// Bytes read from the head of a transcript for its opening line. A
    /// transcript runs to 150 KB; the first spoken line is in the first few
    /// hundred bytes, so never read more than this.
    nonisolated static let transcriptHeadByteLimit = 8 * 1024

    /// A bounded head of `transcript.md`, for `SessionTitleResolver`'s
    /// first-substantive-line title. Nil when there is no transcript.
    private nonisolated static func transcriptHead(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: transcriptHeadByteLimit), !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func canonicalStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: - Opening

    /// Open a session in the reader.
    func open(_ rowID: String) {
        guard rows.contains(where: { $0.id == rowID }) else { return }
        pendingFolder = nil
        let changed = openRowID != rowID
        openRowID = rowID
        if let index = railRows.firstIndex(where: { $0.id == rowID }) {
            railIndex = index
        }
        if changed {
            isEditingTranscript = false
            refreshFiles(keepSelection: false)
        }
    }

    /// Deep link (a command or a mention link): open that
    /// folder with the list hidden. Waits for the list if it is not loaded.
    func open(folder: String) {
        setRailVisible(false, remember: false)
        if let row = rows.first(where: { $0.folderName == folder }) {
            open(row.id)
            selectFile(named: files.first?.name)
        } else {
            pendingFolder = folder
        }
    }

    /// Open the row the rail highlights and hand focus back to the reader.
    func openHighlighted() {
        let list = railRows
        guard list.indices.contains(railIndex) else { return }
        open(list[railIndex].id)
    }

    func openRow(number: Int) -> Bool {
        let list = railRows
        guard (1 ... 9).contains(number), list.indices.contains(number - 1) else { return false }
        railIndex = number - 1
        open(list[number - 1].id)
        return true
    }

    // MARK: - Rail

    func toggleRail() {
        setRailVisible(!isRailVisible, remember: true)
        if isRailVisible {
            railFocusRequest += 1
        }
    }

    func setRailVisible(_ visible: Bool, remember: Bool) {
        isRailVisible = visible
        if remember {
            UserDefaults.standard.set(visible, forKey: Self.railVisibleKey)
        }
        if !visible {
            if actionsPlacement == .rail {
                closeActions()
            }
            if renamingRowID != nil {
                cancelRename()
            }
            if focus == .railSearch {
                focus = .none
            }
        }
    }

    func moveRailHighlight(_ delta: Int) {
        let count = railRows.count
        guard count > 0 else { return }
        railIndex = min(max(railIndex + delta, 0), count - 1)
    }

    private func clampRailIndex() {
        let count = railRows.count
        railIndex = count == 0 ? 0 : min(max(railIndex, 0), count - 1)
    }

    func railQueryChanged() {
        railIndex = 0
        contentSearchTask?.cancel()
        contentSnippets = [:]
        contentOnlyIDs = []
        let query = railQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= SessionsWindowRules.minimumContentQueryLength else {
            contentSearchState = .idle
            return
        }
        guard let search = dependencies.contentSearch else {
            contentSearchState = .unavailable
            return
        }
        contentSearchState = .searching
        contentSearchTask = Task { [weak self] in
            try? await Task.sleep(for: SessionsWindowRules.contentSearchDelay)
            guard !Task.isCancelled else { return }
            let results = await search(query)
            guard !Task.isCancelled else { return }
            self?.applyContentResults(results, for: query)
        }
    }

    /// Map vault search results onto sessions (tier 2). Results outside RTI
    /// sessions and the meetings folder are dropped.
    func applyContentResults(_ results: [VaultSearch.Result]?, for query: String) {
        guard railQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        guard let results else {
            contentSearchState = .unavailable
            return
        }
        let byStamp = Dictionary(rows.compactMap { row in row.stamp.map { ($0, row.id) } }, uniquingKeysWith: { first, _ in first })
        var snippets: [String: SessionSnippet] = [:]
        var order: [String] = []
        for result in results {
            guard let stamp = SessionsWindowRules.sessionStamp(forResultPath: result.relativePath, noteStamps: titleMap.stampsByFileName),
                  let rowID = byStamp[stamp], snippets[rowID] == nil else { continue }
            let label = SessionsWindowRules.snippetLabel(forPath: result.relativePath)
            let snippet = SessionsWindowRules.snippet(label: label, text: result.excerpt, query: query)
                ?? SessionSnippet(label: label, runs: [.init(text: String(result.excerpt.prefix(SessionsWindowRules.snippetContext * 2)), isMatch: false)])
            snippets[rowID] = snippet
            order.append(rowID)
        }
        contentSnippets = snippets
        contentOnlyIDs = order
        contentSearchState = .done
    }

    // MARK: - Rename (inline, in the row)

    func beginRename(_ rowID: String) {
        guard let row = rows.first(where: { $0.id == rowID }), row.session.isRTIArchive else { return }
        if !isRailVisible {
            setRailVisible(true, remember: false)
        }
        closeActions()
        renamingRowID = rowID
        renameText = row.isFallbackTitle ? "" : row.title.text
        renameFocusRequest += 1
    }

    func commitRename() {
        guard let rowID = renamingRowID, let row = rows.first(where: { $0.id == rowID }) else { return }
        let dir = row.session.url
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleURL = dir.appendingPathComponent(SessionTitleResolver.titleFileName)
        let manualURL = dir.appendingPathComponent(SessionTitleResolver.manualMarkerFileName)
        if title.isEmpty {
            try? FileManager.default.removeItem(at: titleURL)
            try? FileManager.default.removeItem(at: manualURL)
        } else {
            try? title.write(to: titleURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: titleURL.path)
            FileManager.default.createFile(atPath: manualURL.path, contents: nil)
        }
        renamingRowID = nil
        if focus == .rename {
            focus = .none
        }
        if let index = rows.firstIndex(where: { $0.id == rowID }) {
            rows[index] = Self.makeRow(rows[index].session, titleMap: titleMap, databases: VaultPaths.preferredDatabasesDirectory())
        }
    }

    func cancelRename() {
        renamingRowID = nil
        renameText = ""
        if focus == .rename {
            focus = .none
        }
    }
}
