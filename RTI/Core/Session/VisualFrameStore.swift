import Darwin
import Foundation

/// Where captured screen frames live while a session is still recording, and
/// how they move into the finished session archive.
///
/// The live trail and manual captures stage frames under
/// `<config-home>/frame-staging/frames-<stamp>/`; `SessionArchive.write`
/// promotes that directory to `<session>/frames/` when the session ends. Both
/// sides derive the staging path from the session start date alone, so no
/// state needs to be threaded between them. Files are owner-only, and the
/// vault's root .gitignore keeps `*.jpg` out of git (frames stay local/iCloud).
public enum VisualFrameStore {
    public static func stagingRoot(configHome: URL) -> URL {
        configHome.appendingPathComponent("frame-staging", isDirectory: true)
    }

    public static func stagingDirectory(configHome: URL, startedAt: Date) -> URL {
        stagingRoot(configHome: configHome)
            .appendingPathComponent("frames-\(stamp(startedAt))", isDirectory: true)
    }

    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// `frame-00065-ambient-3f2a.jpg` — offset keeps frames sorted by session
    /// time, the trigger names the capture path, the suffix avoids collisions
    /// when two captures share a second.
    public static func frameFilename(
        offsetSeconds: Int,
        trigger: String,
        unique: String = UUID().uuidString.lowercased()
    ) -> String {
        let safeTrigger = trigger.lowercased().filter { $0.isLetter || $0.isNumber }
        let name = safeTrigger.isEmpty ? "capture" : safeTrigger
        return String(format: "frame-%05d-%@-%@.jpg", max(0, offsetSeconds), name, unique)
    }

    /// Write one frame into the staging directory (0700 dir, 0600 file).
    /// Returns the filename the archive will keep.
    @discardableResult
    public static func writeFrame(
        _ data: Data,
        offsetSeconds: Int,
        trigger: String,
        stagingDirectory: URL
    ) throws -> String {
        let manager = FileManager.default
        try manager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name = frameFilename(offsetSeconds: offsetSeconds, trigger: trigger)
        let pending = stagingDirectory.appendingPathComponent(".pending-" + UUID().uuidString)
        defer { try? manager.removeItem(at: pending) }
        try data.write(to: pending, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
        try manager.moveItem(at: pending, to: stagingDirectory.appendingPathComponent(name))
        return name
    }

    /// A checkpoint or Finish retries files still in staging. An existing
    /// destination is accepted only if it already contains the same bytes.
    @discardableResult
    public static func promoteStagedFrames(
        stagingDirectory: URL,
        into sessionDirectory: URL
    ) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: stagingDirectory, includingPropertiesForKeys: nil
        ) else { return 0 }
        let framesDirectory = sessionDirectory.appendingPathComponent("frames", isDirectory: true)
        var moved = 0
        for entry in entries where entry.pathExtension.lowercased() == "jpg" {
            let destination = framesDirectory.appendingPathComponent(entry.lastPathComponent)
            do {
                try manager.createDirectory(at: framesDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if manager.fileExists(atPath: destination.path) {
                    guard manager.contentsEqual(atPath: entry.path, andPath: destination.path) else { continue }
                    try manager.removeItem(at: entry)
                } else {
                    try manager.moveItem(at: entry, to: destination)
                }
                moved += 1
            } catch {
                continue
            }
        }
        // Remove only the directory itself when empty. A concurrent new frame,
        // an unreadable file or a failed move keeps its bytes for the next pass.
        _ = rmdir(stagingDirectory.path)
        return moved
    }
}
