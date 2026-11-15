import Foundation
import Observation
import RTICore

/// Prepare choices belong to one call. Recording takes its own immutable snapshot.
@Observable @MainActor
final class GuidePreparation {
    static let shared = GuidePreparation()

    private(set) var guide: GuideDocument?
    private(set) var guideURL: URL?
    private(set) var parsedSourceJSON: Data?
    private(set) var roster: [GuideSeat] = []
    private(set) var rosterURL: URL?
    var groupText = ""

    var group: String? {
        let trimmed = groupText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.wholeMatch(of: /G[0-9]+/) != nil else { return nil }
        return trimmed
    }

    func setGuide(_ guide: GuideDocument, url: URL, parsedSourceJSON: Data? = nil) {
        if guideURL != url {
            reset()
        }
        self.guide = guide
        guideURL = url
        self.parsedSourceJSON = parsedSourceJSON
    }

    func setRoster(_ seats: [GuideSeat], url: URL) {
        roster = seats
        rosterURL = url
    }

    func clearRoster() {
        roster = []
        rosterURL = nil
    }

    func reset() {
        guide = nil
        guideURL = nil
        parsedSourceJSON = nil
        groupText = ""
        clearRoster()
    }
}

/// Folder scans and reads run away from the UI. Ambiguous folders require an explicit file.
actor GuideFileReader {
    static let shared = GuideFileReader()

    struct LoadedGuide: Sendable {
        let document: GuideDocument
        let sourceURL: URL
        let parsedSourceJSON: Data?
    }

    enum ReadError: LocalizedError {
        case noGuide, severalGuides, missingParser, unreadableGuide, invalidJSON

        var errorDescription: String? {
            switch self {
            case .noGuide: "Choose the Word or Markdown discussion guide for this call."
            case .severalGuides: "This project has several guides. Choose the version for this call."
            case .missingParser: "Word and Markdown need the local ic-synthesis-workbook skill. Install it or choose a prepared guide JSON."
            case .unreadableGuide: "Couldn’t read the guide. Choose a Word or Markdown guide with numbered questions under section headings."
            case .invalidJSON: "This JSON could not be read as a discussion guide. Choose the original Word guide or a prepared guide JSON."
            }
        }
    }

    /// `group` (from Prepare, such as "G1") narrows a bold-line guide to that
    /// group's questions; see `BoldLineGuide`.
    func loadGuide(at url: URL, group: String? = nil) async throws -> LoadedGuide {
        let file = try guideURL(at: url)
        if file.pathExtension.lowercased() == "json" {
            let data = try Data(contentsOf: file)
            guard let document = try? GuideDocument.parse(data) else { throw ReadError.invalidJSON }
            return LoadedGuide(document: document, sourceURL: file, parsedSourceJSON: nil)
        }
        guard Self.isGuideSource(file) else { throw ReadError.unreadableGuide }
        let parser = ExternalTools.workbookGuideParser
        guard FileManager.default.isReadableFile(atPath: parser.path) else { throw ReadError.missingParser }
        try Task.checkCancellation()
        do {
            let json = try await ScriptRunner.run(executable: ExternalTools.systemPython.path,
                                                  arguments: ["-I", parser.path, "questions", file.path],
                                                  environment: [:], timeout: 30)
            try Task.checkCancellation()
            return try LoadedGuide(document: GuideDocument.parse(json), sourceURL: file, parsedSourceJSON: json)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The skill's parser reads numbered guides. A moderator copy whose
            // questions are bold lines (2026-11-15) is read
            // here; a Word guide uses the Markdown copy beside it.
            if let fallback = boldLineGuide(for: file, group: group) { return fallback }
            throw ReadError.unreadableGuide
        }
    }

    private func boldLineGuide(for file: URL, group: String?) -> LoadedGuide? {
        let markdown = file.pathExtension.lowercased() == "md" ? file : file.deletingPathExtension().appendingPathExtension("md")
        guard let text = try? String(contentsOf: markdown, encoding: .utf8) else { return nil }
        let base = markdown.deletingPathExtension().lastPathComponent
        let title = [base, group.map { "(\($0))" }].compactMap(\.self).joined(separator: " ")
        guard let json = BoldLineGuide.json(markdown: text, title: title, group: group),
              let document = try? GuideDocument.parse(json) else { return nil }
        return LoadedGuide(document: document, sourceURL: file, parsedSourceJSON: json)
    }

    private static func isGuideSource(_ file: URL) -> Bool {
        ["docx", "md"].contains(file.pathExtension.lowercased()) && !file.lastPathComponent.hasPrefix("~$")
    }

    func readRoster(at url: URL) throws -> [GuideSeat] {
        try GuideRoster.parse(Data(contentsOf: url), fileExtension: url.pathExtension)
    }

    private func guideURL(at url: URL) throws -> URL {
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return url }
        let files = FileManager.default
        let guideFolder = url.appendingPathComponent("06-discussion-guide", isDirectory: true)
        var source: URL?
        if (try? guideFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for file in try files.contentsOfDirectory(at: guideFolder, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) where Self.isGuideSource(file)
            {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                guard source == nil else { throw ReadError.severalGuides }
                source = file
            }
        }
        for folder in [url, guideFolder] {
            let prepared = folder.appendingPathComponent("dg-questions.json")
            if (try? prepared.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                guard source == nil else { throw ReadError.severalGuides }
                return prepared
            }
        }
        // The workbook can emit its JSON in a separate extraction work directory.
        let items = files.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var match = source
        while let file = items?.nextObject() as? URL {
            try Task.checkCancellation()
            guard file.lastPathComponent == "dg-questions.json",
                  try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            guard match == nil else { throw ReadError.severalGuides }
            match = file
        }
        guard let match else { throw ReadError.noGuide }
        return match
    }
}
