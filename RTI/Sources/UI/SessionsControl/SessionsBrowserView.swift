import SwiftUI

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
            List(selection: $selected) {
                ForEach(sessions) { session in
                    Label(session.displayName, systemImage: "clock.arrow.circlepath")
                        .tag(session)
                }
            }
            .frame(minWidth: 170, maxWidth: 240)

            VStack(alignment: .leading, spacing: 0) {
                if let selected {
                    HStack(spacing: 8) {
                        Picker("", selection: $selectedFile) {
                            ForEach(files) { file in
                                Text(file.name).tag(Optional(file))
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(selected.url)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Reveal this session in Finder")
                    }
                    .padding(10)

                    Divider()

                    ScrollView {
                        Text(fileText)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text(sessions.isEmpty ? "No saved sessions yet" : "Select a session")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
        .onAppear(perform: reload)
        .onChange(of: selected) { _, _ in loadFiles() }
        .onChange(of: selectedFile) { _, _ in loadText() }
    }

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
