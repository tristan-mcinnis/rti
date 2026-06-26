import SwiftUI
import UniformTypeIdentifiers

/// Read-only browser for archived session records (the Markdown folders
/// SessionArchive writes to the vault on stop). Browse and read — never
/// resume: past sessions are vault content, and anything beyond reading
/// (search, analysis, Q&A) is a vault job, not an app feature.
struct SessionsBrowserView: View {
    @State private var sessions: [SessionArchive.ArchivedSession] = []
    @State private var selected: SessionArchive.ArchivedSession?
    @State private var files: [SessionFile] = []
    @State private var selectedFile: SessionFile?
    @State private var fileText: String = ""

    struct SessionFile: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let name: String
    }

    /// Preferred reading order when a session folder is opened.
    private static let fileOrder = ["summary.md", "notes.md", "transcript.md", "chat.md", "discussion-guide.md"]

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 320)

            VStack(alignment: .leading, spacing: 0) {
                if let selected {
                    detailToolbar(for: selected)
                    Divider()
                    ScrollView {
                        HStack(alignment: .top, spacing: 0) {
                            RTIMarkdown(fileText, style: .panel)
                                .frame(maxWidth: 700, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 22)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .background(SessionReadingBackground())
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 380)
        }
        .onAppear(perform: reload)
        .onChange(of: selected) { _, _ in loadFiles() }
        .onChange(of: selectedFile) { _, _ in loadText() }
    }

    // MARK: - Session list

    private var sessionList: some View {
        List(selection: $selected) {
            ForEach(groupedSessions, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.sessions) { session in
                        sessionRow(session).tag(session)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.thinMaterial)
    }

    /// One row: AI-generated title as the primary label, the start time as a
    /// quiet secondary. No redundant clock icon — every row is a past session,
    /// so the icon was just clutter. A small dot marks sessions whose
    /// auto-summary hasn't landed yet (still "Untitled").
    private func sessionRow(_ session: SessionArchive.ArchivedSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title ?? "Untitled session")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(session.title == nil ? .secondary : .primary)
            HStack(spacing: 6) {
                Text(timeString(for: session))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if session.title == nil {
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 4, height: 4)
                        .help("No summary yet — the title appears once the end-of-session summary finishes.")
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Detail toolbar

    /// File picker (summary / notes / transcript / …) aligned with the
    /// reading column, with contextual actions trailing in the titlebar-style
    /// header.
    @ViewBuilder
    private func detailToolbar(for session: SessionArchive.ArchivedSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Picker("", selection: $selectedFile) {
                ForEach(files) { file in
                    Text(file.name).tag(Optional(file))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(
                minWidth: min(CGFloat(files.count) * 74, 180),
                idealWidth: min(CGFloat(files.count) * 90, 480),
                maxWidth: min(CGFloat(files.count) * 104, 560),
                alignment: .leading
            )

            Spacer(minLength: 12)

            Button {
                NSPasteboard.copyMarkdownRich(fileText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Copy as Markdown")
            .disabled(fileText.isEmpty)

            Menu {
                Button("Save as Markdown…") { exportMarkdown() }
                Button("Save as PDF…") { exportPDF() }
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.open(session.url) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .help("Export or reveal this session")
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(sessions.isEmpty ? "No saved sessions yet" : "Select a session")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if !sessions.isEmpty {
                Text("Sessions appear here once they're saved on stop.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Date grouping

    /// Buckets sessions into native macOS-style date sections: Today,
    /// Yesterday, This Week, then one section per older month
    /// ("June 2026"). Sessions with an unparseable folder stamp fall into
    /// "Earlier". Removes the repetitive month/day text from individual rows
    /// — the section header carries the date, the row carries just the time.
    private var groupedSessions: [(label: String, sessions: [SessionArchive.ArchivedSession])] {
        let cal = Calendar.current
        let now = Date()
        var today: [SessionArchive.ArchivedSession] = []
        var yesterday: [SessionArchive.ArchivedSession] = []
        var thisWeek: [SessionArchive.ArchivedSession] = []
        var byMonth: [(label: String, key: String, sessions: [SessionArchive.ArchivedSession])] = []
        var earlier: [SessionArchive.ArchivedSession] = []

        for session in sessions {
            guard let date = session.date else {
                earlier.append(session)
                continue
            }
            if cal.isDateInToday(date) {
                today.append(session)
            } else if cal.isDateInYesterday(date) {
                yesterday.append(session)
            } else if let days = cal.dateComponents([.day], from: date, to: now).day, days < 7 {
                thisWeek.append(session)
            } else {
                let key = monthKey(date)
                let label = monthLabel(date)
                if let idx = byMonth.firstIndex(where: { $0.key == key }) {
                    byMonth[idx].sessions.append(session)
                } else {
                    byMonth.append((label, key, [session]))
                }
            }
        }

        var out: [(label: String, sessions: [SessionArchive.ArchivedSession])] = []
        if !today.isEmpty { out.append(("Today", today)) }
        if !yesterday.isEmpty { out.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { out.append(("This Week", thisWeek)) }
        // Months are newest-first because `sessions` is newest-first.
        for m in byMonth.sorted(by: { $0.key > $1.key }) {
            out.append((m.label, m.sessions))
        }
        if !earlier.isEmpty { out.append(("Earlier", earlier)) }
        return out
    }

    /// "16:13" for the row's quiet secondary text. Falls back to the pretty
    /// name when the folder stamp can't be parsed.
    private func timeString(for session: SessionArchive.ArchivedSession) -> String {
        guard let date = session.date else { return session.displayName }
        return Self.rowTimeStamp.string(from: date)
    }

    private static let rowTimeStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func monthKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    private func monthLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    // MARK: - Loading

    private func reload() {
        sessions = SessionArchive.recentSessions(limit: 100)
        if selected == nil { selected = sessions.first }
    }

    private func loadFiles() {
        guard let selected else { files = []; selectedFile = nil; return }
        let present = (try? FileManager.default.contentsOfDirectory(at: selected.url, includingPropertiesForKeys: nil)) ?? []
        let byName = Dictionary(uniqueKeysWithValues: present.map { ($0.lastPathComponent, $0) })
        files = Self.fileOrder.compactMap { name in
            byName[name].map { SessionFile(url: $0, name: String(name.dropLast(3))) }
        }
        selectedFile = files.first
    }

    private func exportMarkdown() {
        guard let selectedFile, let selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rti-\(selectedFile.name)-\(selected.displayName.replacingOccurrences(of: " · ", with: "-").replacingOccurrences(of: ":", with: "")).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let content = fileText
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Render the markdown to a paginated PDF via NSAttributedString printing.
    private func exportPDF() {
        guard let selectedFile else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = panelBaseName(selectedFile) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        let content = fileText
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let attributed = (try? NSAttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? NSAttributedString(string: content)
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
            textView.textStorage?.setAttributedString(attributed)
            textView.font = .systemFont(ofSize: 11)
            let printInfo = NSPrintInfo()
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            printInfo.topMargin = 36; printInfo.bottomMargin = 36
            printInfo.leftMargin = 36; printInfo.rightMargin = 36
            let op = NSPrintOperation(view: textView, printInfo: printInfo)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            op.run()
        }
    }

    private func panelBaseName(_ file: SessionFile) -> String {
        let stamp = selected?.displayName
            .replacingOccurrences(of: " · ", with: "-")
            .replacingOccurrences(of: ":", with: "") ?? "session"
        return "rti-\(file.name)-\(stamp)"
    }

    private func loadText() {
        guard let selectedFile else { fileText = ""; return }
        var text = (try? String(contentsOf: selectedFile.url, encoding: .utf8)) ?? "(couldn't read file)"
        // Hide the machine-facing frontmatter block from the reading view.
        if text.hasPrefix("---"), let end = text.range(of: "\n---\n") {
            text = String(text[end.upperBound...])
        }
        fileText = text
    }
}

private struct SessionReadingBackground: View {
    var body: some View {
        Color(nsColor: .textBackgroundColor)
            .overlay(
                LinearGradient(
                    colors: [
                        Color.secondary.opacity(0.018),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}
