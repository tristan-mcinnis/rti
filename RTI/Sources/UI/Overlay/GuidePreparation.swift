import Foundation
import Observation
import RTICore

/// Prepare choices belong to one call. Recording takes its own immutable snapshot.
@Observable @MainActor
final class GuidePreparation {
    static let shared = GuidePreparation()

    private(set) var guide: GuideDocument?
    private(set) var guideURL: URL?
    private(set) var roster: [GuideSeat] = []
    private(set) var rosterURL: URL?
    var groupText = ""

    var group: String? {
        let trimmed = groupText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.wholeMatch(of: /G[0-9]+/) != nil else { return nil }
        return trimmed
    }

    func setGuide(_ guide: GuideDocument, url: URL) {
        if guideURL != url {
            reset()
        }
        self.guide = guide
        guideURL = url
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
        groupText = ""
        clearRoster()
    }
}

/// Folder scans and reads run away from the UI. Ambiguous folders require an explicit file.
actor GuideFileReader {
    static let shared = GuideFileReader()

    enum ReadError: LocalizedError {
        case noGuide, severalGuides

        var errorDescription: String? {
            switch self {
            case .noGuide: "No dg-questions.json found. Choose the guide JSON directly."
            case .severalGuides: "This folder has several guides. Choose the guide JSON for this call."
            }
        }
    }

    func readGuide(at url: URL) throws -> (GuideDocument, URL) {
        let file = try guideURL(at: url)
        return try (GuideDocument.parse(Data(contentsOf: file)), file)
    }

    func readRoster(at url: URL) throws -> [GuideSeat] {
        try GuideRoster.parse(Data(contentsOf: url), fileExtension: url.pathExtension)
    }

    private func guideURL(at url: URL) throws -> URL {
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return url }
        let files = FileManager.default
        let direct = url.appendingPathComponent("dg-questions.json")
        if files.fileExists(atPath: direct.path) {
            return direct
        }
        let defaultGuide = url.appendingPathComponent("06-discussion-guide/dg-questions.json")
        if files.fileExists(atPath: defaultGuide.path) {
            return defaultGuide
        }
        // The workbook can emit its JSON in a separate extraction work directory.
        let items = files.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var match: URL?
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
