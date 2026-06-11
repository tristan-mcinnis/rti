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
                        Menu {
                            Button("Copy as Markdown") {
                                NSPasteboard.copyMarkdownRich(fileText)
                            }
                            Button("Save as Markdown…") { exportMarkdown() }
                            Button("Save as PDF…") { exportPDF() }
                            Divider()
                            Button("Reveal in Finder") { NSWorkspace.shared.open(selected.url) }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 40)
                        .help("Copy or export this file")
                    }
                    .padding(10)

                    Divider()

                    ScrollView {
                        RTIMarkdown(fileText, style: .panel)
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
