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
        unique: String = String(UUID().uuidString.prefix(4)).lowercased()
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
        let url = stagingDirectory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic])
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return name
    }

    /// Move every staged `.jpg` into `<sessionDirectory>/frames/` and remove
    /// the staging directory. Best-effort by design: a frame that fails to
    /// move is dropped with the staging dir rather than failing the archive.
    @discardableResult
    public static func promoteStagedFrames(
        stagingDirectory: URL,
        into sessionDirectory: URL
    ) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: nil
        ), !entries.isEmpty else {
            try? manager.removeItem(at: stagingDirectory)
            return 0
        }
        let framesDirectory = sessionDirectory.appendingPathComponent("frames", isDirectory: true)
        try? manager.createDirectory(
            at: framesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var moved = 0
        for entry in entries where entry.pathExtension.lowercased() == "jpg" {
            let destination = framesDirectory.appendingPathComponent(entry.lastPathComponent)
            try? manager.removeItem(at: destination)
            if (try? manager.moveItem(at: entry, to: destination)) != nil {
                try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                moved += 1
            }
        }
        try? manager.removeItem(at: stagingDirectory)
        return moved
    }
}
