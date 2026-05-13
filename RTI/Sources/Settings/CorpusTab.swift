import SwiftUI

// MARK: - Corpus

struct CorpusTab: View {
    @AppStorage(CorpusManager.corpusPathKey) private var corpusPath: String = ""
    @State private var copyConfirmation: String?
    @State private var reindexStatus: String?
    @State private var migratedCount: Int?
    @State private var corpusStats: (sessionCount: Int, projectCount: Int, synthesisCount: Int) = (0, 0, 0)

    private var resolvedPath: String {
        if corpusPath.isEmpty {
            return "~/meetings"
        }
        return (corpusPath as NSString).abbreviatingWithTildeInPath
    }

    private var bundledMCPBinary: String {
        // Use the bundled binary inside the running .app. Falls back to a
        // placeholder when running unbundled (development).
        if let resourceURL = Bundle.main.url(forResource: "rti-mcp", withExtension: nil) {
            return resourceURL.path
        }
        return "/Applications/RTI.app/Contents/Resources/rti-mcp"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Corpus")
                    .font(.system(size: 16, weight: .semibold))
                Text("Every meeting RTI records is written as a markdown file to this directory. The Corpus is the canonical store — RTI's database is a derived index over it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top) {
                    Text("Location:")
                    Text(resolvedPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Choose…") { chooseDirectory() }
                        HStack(spacing: 6) {
                            Button("Reveal") { revealInFinder() }
                                .controlSize(.small)
                            Button("Reset") { resetToDefault() }
                                .controlSize(.small)
                                .disabled(corpusPath.isEmpty)
                                .help("Revert to the default location (~/meetings)")
                        }
                    }
                }

                corpusStatsLine

                Divider().padding(.vertical, 8)

                Text("MCP Server")
                    .font(.system(size: 13, weight: .medium))
                Text("Expose the Corpus to external agents (Claude Desktop, Codex, OpenCode, Gemini CLI). Read-only. Agents can read your session markdown plus every project's PROJECT.md, synthesis.md, and chat history. Click below to copy a Claude-Desktop-shaped config snippet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Copy MCP Config") { copyMCPConfig() }
                if let copyConfirmation {
                    Text(copyConfirmation)
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }

                Divider().padding(.vertical, 8)

                Text("Maintenance")
                    .font(.system(size: 13, weight: .medium))
                HStack {
                    Button("Reindex Corpus") { reindex() }
                    if let reindexStatus {
                        Text(reindexStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Rebuilds the search index from markdown files. Useful after editing files outside RTI or after restoring a backup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let migratedCount, migratedCount > 0 {
                    Text("Migrated \(migratedCount) legacy session(s) from the database to the Corpus on first launch with this version.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }
        .onChange(of: corpusPath) { _, _ in
            NotificationCenter.default.post(name: .rtiSessionsChanged, object: nil)
            loadCorpusStats()
        }
        .onAppear { loadCorpusStats() }
    }

    @ViewBuilder
    private var corpusStatsLine: some View {
        HStack(spacing: 16) {
            Label("\(corpusStats.sessionCount) sessions", systemImage: "doc.text")
            Label("\(corpusStats.projectCount) projects", systemImage: "folder")
            if corpusStats.synthesisCount > 0 {
                Label("\(corpusStats.synthesisCount) synthesis", systemImage: "sparkles")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func loadCorpusStats() {
        let dir = CorpusManager.shared.corpusDirectory
        let sessionCount = (try? CorpusReader.listMarkdownFiles(in: dir).count) ?? 0
        let projectCount = ProjectStore.shared.projects.count
        let projectsDir = dir.appendingPathComponent("projects", isDirectory: true)
        let synthesisCount: Int = {
            guard let folders = try? FileManager.default.contentsOfDirectory(
                at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { return 0 }
            return folders.filter {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("synthesis.md").path)
            }.count
        }()
        corpusStats = (sessionCount, projectCount, synthesisCount)
    }

    private func revealInFinder() {
        let dir = CorpusManager.shared.corpusDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func resetToDefault() {
        // Surface the same confirmation the picker uses — resetting is a
        // corpus switch like any other, and projects can be orphaned by
        // it if the default dir doesn't contain the same sessions.
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("meetings", isDirectory: true)
        if defaultDir.path == resolvedPath { return }

        let oldDir = URL(fileURLWithPath: resolvedPath)
        let oldSessionCount = (try? CorpusReader.listMarkdownFiles(in: oldDir).count) ?? 0
        let newSessionCount = (try? CorpusReader.listMarkdownFiles(in: defaultDir).count) ?? 0
        let projectCount = ProjectStore.shared.projects.count

        let alert = NSAlert()
        alert.messageText = "Reset corpus to default?"
        alert.informativeText = """
        Current:  \(oldDir.path)
        \(oldSessionCount) session\(oldSessionCount == 1 ? "" : "s"), \(projectCount) project\(projectCount == 1 ? "" : "s").

        Default:  \(defaultDir.path)
        \(newSessionCount) session\(newSessionCount == 1 ? "" : "s") found there.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        corpusPath = ""
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Corpus directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Pointing at the same directory is a no-op.
        let newPath = url.path
        if newPath == resolvedPath { return }

        // Surface migration consequences before flipping the switch. The
        // existing corpus has N sessions and M projects; the new dir
        // either contains them or it doesn't. We can't move files for
        // the user (their iCloud / sync setup may already cover that),
        // but we can stop them from silently degrading projects whose
        // sessions are about to become unreachable.
        let oldDir = URL(fileURLWithPath: resolvedPath)
        let newDir = url
        let oldSessionCount = (try? CorpusReader.listMarkdownFiles(in: oldDir).count) ?? 0
        let newSessionCount = (try? CorpusReader.listMarkdownFiles(in: newDir).count) ?? 0
        let projectCount = ProjectStore.shared.projects.count

        let alert = NSAlert()
        alert.messageText = "Switch corpus directory?"
        alert.informativeText = """
        Current:  \(oldDir.path)
        \(oldSessionCount) session\(oldSessionCount == 1 ? "" : "s"), \(projectCount) project\(projectCount == 1 ? "" : "s").

        New:  \(newDir.path)
        \(newSessionCount) session\(newSessionCount == 1 ? "" : "s") found there.

        Projects keep their session-id references after the switch. Sessions present in the old corpus but missing from the new one will appear as orphaned members until you point back to the old corpus or copy the files over.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        corpusPath = newPath
    }

    private func copyMCPConfig() {
        let cfg: [String: Any] = [
            "mcpServers": [
                "rti": [
                    "command": bundledMCPBinary,
                    "args": ["--corpus", resolvedPath]
                ]
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted])) ?? Data()
        let str = String(data: data, encoding: .utf8) ?? "{}"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(str, forType: .string)
        copyConfirmation = "Copied. Paste into your agent's MCP server config."
        Task { try? await Task.sleep(for: .seconds(4)); await MainActor.run { self.copyConfirmation = nil } }
    }

    private func reindex() {
        reindexStatus = "Reindexing…"
        let corpusDir = CorpusManager.shared.corpusDirectory
        let dbPool = RTIDatabase.shared.pool
        Task.detached {
            do {
                try CorpusFTSReindexer.reindex(
                    from: corpusDir,
                    in: dbPool
                )
                try CorpusIndexer.reindex(from: corpusDir, in: dbPool)
                await MainActor.run { reindexStatus = "Done." }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    if reindexStatus == "Done." { reindexStatus = nil }
                }
            } catch {
                await MainActor.run { reindexStatus = "Failed: \(error)" }
            }
        }
    }
}

