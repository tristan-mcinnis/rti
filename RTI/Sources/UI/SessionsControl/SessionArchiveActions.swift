import Foundation
import RTICore

actor SessionArchiveActions {
    func moveToTrash(_ directory: URL) throws {
        guard let root = SessionArchive.sessionsBaseDirectory(),
              SessionArchiveActionRules.canTrash(sessionDirectory: directory, archiveRoot: root),
              SessionArchiveActionRules.canTrash(sessionDirectory: directory.resolvingSymlinksInPath(), archiveRoot: root.resolvingSymlinksInPath())
        else { throw ActionError.notOwned }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ActionError.notOwned }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("automatic-upgrade.pending").path)
        else { throw ActionError.processing }
        // User-confirmed, recoverable removal; never removeItem on meeting data.
        try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }
    enum ActionError: LocalizedError {
        case notOwned, processing
        var errorDescription: String? {
            switch self {
            case .notOwned: "Only RTI session folders can be moved to Trash here."
            case .processing: "This session is still being processed. Try again after the transcript upgrade finishes."
            }
        }
    }
}
