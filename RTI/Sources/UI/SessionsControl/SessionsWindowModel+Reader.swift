import AppKit
import Observation
import RTICore
import UniformTypeIdentifiers
import HouseDesign

extension SessionsWindowModel {
    // MARK: - Files and reader

    func selectFile(named name: String?) {
        guard let name, let file = files.first(where: { $0.name == name }) else { return }
        select(file)
    }

    func select(_ file: SessionFile) {
        guard selectedFile != file else { return }
        selectedFile = file
        isEditingTranscript = false
        loadText()
    }

    /// Preferred reading order; screenshots and the processor log follow.
    private static let fileOrder = [
        "notes.md", "transcript.md", "chat.md", "screen-context.md",
    ]

    func refreshFiles(keepSelection: Bool) {
        guard let row = openRow else { clearReader(); return }
        let previous = selectedFile?.name
        files = Self.files(for: row.session)
        loadSpeakerNames()
        let keep = keepSelection ? files.first(where: { $0.name == previous }) : nil
        selectedFile = keep ?? files.first
        loadText()
    }

    func clearReader() {
        files = []
        selectedFile = nil
        fileText = ""
        document = .empty
        speakerNames = [:]
        recomputeFindHits()
    }

    static func files(for session: SessionArchive.ArchivedSession) -> [SessionFile] {
        guard session.isRTIArchive else {
            return [SessionFile(url: session.transcriptURL, name: "transcript")]
        }
        let fm = FileManager.default
        let present = Set((try? fm.contentsOfDirectory(atPath: session.url.path)) ?? [])
        var loaded = fileOrder.filter(present.contains).map {
            SessionFile(url: session.url.appendingPathComponent($0), name: String($0.dropLast(3)))
        }
        let framesDir = session.url.appendingPathComponent("frames", isDirectory: true)
        if let frames = try? fm.contentsOfDirectory(atPath: framesDir.path),
           frames.contains(where: { ["jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }) {
            loaded.append(SessionFile(url: framesDir, name: "frames"))
        }
        if let startedAt = session.date {
            let log = SessionArchive.processingLogURL(forSessionStartedAt: startedAt)
            if fm.fileExists(atPath: log.path) {
                loaded.append(SessionFile(url: log, name: "log"))
            }
        }
        return loaded
    }

    func rawText(of name: String) -> String? {
        guard let file = files.first(where: { $0.name == name }) else { return nil }
        return try? String(contentsOf: file.url, encoding: .utf8)
    }

    private func loadText() {
        guard let file = selectedFile else {
            fileText = ""
            document = .empty
            recomputeFindHits()
            return
        }
        if file.name == "frames" {
            fileText = ""
            document = .frames(file.url)
            recomputeFindHits()
            return
        }
        var text = (try? String(contentsOf: file.url, encoding: .utf8)) ?? "(couldn't read file)"
        // Hide the machine-facing frontmatter block from the reading view.
        if text.hasPrefix("---"), let end = text.range(of: "\n---\n") {
            text = String(text[end.upperBound...])
        }
        fileText = applyingSpeakerNames(to: text)
        document = Self.document(for: file.name, text: fileText)
        findIndex = 0
        recomputeFindHits()
    }

    static func document(for name: String, text: String) -> ReaderDocument {
        switch name {
        case "transcript":
            return .transcript(SessionTranscriptReview.turns(from: text))
        case "chat":
            let turns = ArchivedChat.turns(fromMarkdown: text)
            return turns.isEmpty ? .markdown(SessionsWindowRules.markdownBlocks(text)) : .chat(turns)
        case "log":
            return .log(text)
        default:
            return .markdown(SessionsWindowRules.markdownBlocks(text))
        }
    }

    // MARK: - Speakers

    private func loadSpeakerNames() {
        guard let row = openRow, row.session.isRTIArchive,
              let data = try? Data(contentsOf: row.session.url.appendingPathComponent("speaker-names.json")),
              let names = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            speakerNames = [:]
            return
        }
        // Legacy files are keyed by raw ids (`remote_1`) from live renames;
        // current files by display labels. Normalize so both render.
        speakerNames = SpeakerLabelMapping.displayKeyedNames(names)
    }

    private func applyingSpeakerNames(to text: String) -> String {
        speakerNames
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.key.count > $1.key.count }
            .reduce(text) { result, pair in
                result.replacingOccurrences(of: pair.key, with: pair.value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    /// Anonymous speaker labels in the open transcript, for the editor.
    var speakerLabels: [String] {
        guard let row = openRow else { return [] }
        let text = (try? String(contentsOf: row.session.transcriptURL, encoding: .utf8)) ?? ""
        return SpeakerLabelMapping.archivedSpeakerLabels(in: text)
    }

    func speakerName(for label: String) -> String { speakerNames[label, default: ""] }

    func setSpeakerName(_ name: String, for label: String) { speakerNames[label] = name }

    func saveSpeakerNames() {
        guard let row = openRow else { return }
        let names = speakerNames.reduce(into: [String: String]()) { result, pair in
            let name = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { result[pair.key] = name }
        }
        let url = row.session.url.appendingPathComponent("speaker-names.json")
        if names.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(names) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        speakerNames = names
        isSpeakerEditorPresented = false
        loadText()
    }

    func cancelSpeakerEditor() {
        isSpeakerEditorPresented = false
        loadSpeakerNames()
    }

    // MARK: - Editors

    func saveTranscript() {
        guard let file = selectedFile, file.name == "transcript",
              let original = try? String(contentsOf: file.url, encoding: .utf8)
        else { return }
        let updated = SessionTranscriptReview.replacingTurns(in: original, with: transcriptTurns)
        try? updated.write(to: file.url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        isEditingTranscript = false
        loadText()
    }

    var transcriptSpeakerOptions: [String] {
        let direct = speakerNames.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(Set(transcriptTurns.filter { !$0.isNote }.map(\.speaker) + direct))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Long jobs

    var upgradeProviderChoices: [AsyncTranscriptProviderOption] {
        let active = AsyncTranscriptProviders.active
        return [active] + AsyncTranscriptProviders.all.filter { $0.id != active.id }
    }

    func upgradeProviderTitle(_ provider: AsyncTranscriptProviderOption) -> String {
        if provider.id == AsyncTranscriptProviders.soniox.id {
            return provider.id == AsyncTranscriptProviders.active.id ? "Soniox (default)" : "Soniox"
        }
        return provider.displayName
    }

    func cancelUpgradeChoice() {
        pendingUpgradeRowID = nil
        isUpgradeChoicePresented = false
    }

    func startTranscriptUpgrade(provider: AsyncTranscriptProviderOption) {
        guard let id = pendingUpgradeRowID, let row = rows.first(where: { $0.id == id }) else { return }
        pendingUpgradeRowID = nil
        upgradingRowID = id
        notice = (id, "Starting the transcript upgrade with \(provider.displayName)…")
        let session = row.session
        let report: @Sendable (TranscriptUpgradeProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.notice = (id, progress.message)
                if progress.isTerminal { self?.upgradingRowID = nil }
            }
        }
        Task { [weak self] in
            do {
                let result = try await TranscriptUpgradeService.upgrade(session: session, provider: provider, progress: report)
                guard let self else { return }
                SessionArchive.clearAutomaticUpgradePending(in: session.url)
                self.notice = (id, "Transcript upgraded with \(result.provider).")
                self.upgradingRowID = nil
                await self.reload()
                self.open(id)
                self.selectFile(named: "transcript")
            } catch {
                self?.notice = (id, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                self?.upgradingRowID = nil
            }
        }
    }

    /// The notice line for the open session, and whether a job still runs.
    var openNotice: (text: String, isRunning: Bool)? {
        if let notice, notice.rowID == openRowID { return (notice.text, upgradingRowID == notice.rowID) }
        if let error = openRow?.recordingError { return ("Recording needs review: \(error)", false) }
        return nil
    }

    // MARK: - Ask and export

    /// Show the overlay's Assist tab with this session's transcript attached
    /// as an `@` mention. The Sessions window itself never answers.
    func askInRTI(_ row: Row) {
        guard let path = row.vaultTranscriptPath else { return }
        onAsk?()
        WindowCoordinator.shared.showOverlay()
        NotificationCenter.default.post(name: .rtiSelectTab, object: "assist")
        NotificationCenter.default.post(name: .rtiSeedChatMention, object: path)
    }

    private var exportBaseName: String {
        let stamp = openRow?.session.displayName
            .replacingOccurrences(of: " · ", with: "-")
            .replacingOccurrences(of: ":", with: "") ?? "session"
        return "rti-\(selectedFile?.name ?? "session")-\(stamp)"
    }

    func exportMarkdown() {
        guard selectedFile != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportBaseName + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let content = fileText
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Render the Markdown to a paginated PDF through NSAttributedString.
    func exportPDF() {
        guard selectedFile != nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportBaseName + ".pdf"
        panel.allowedContentTypes = [.pdf]
        let content = fileText
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                Self.writePDF(markdown: content, to: url)
            }
        }
    }

    private static func writePDF(markdown: String, to url: URL) {
        let attributed = (try? NSAttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? NSAttributedString(string: markdown)
        let page = NSPrintInfo()
        let margin = House.Spacing.xxl + House.Spacing.xxs
        page.topMargin = margin
        page.bottomMargin = margin
        page.leftMargin = margin
        page.rightMargin = margin
        let width = page.paperSize.width - 2 * margin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: page.paperSize.height - 2 * margin))
        textView.textStorage?.setAttributedString(attributed)
        textView.font = .systemFont(ofSize: House.TypeToken.Size.caption)
        page.jobDisposition = .save
        page.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: textView, printInfo: page)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }
}
