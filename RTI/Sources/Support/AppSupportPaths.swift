import Foundation

/// Single resolver for RTI's local config home,
/// `~/Library/Application Support/RTI/`. Every on-disk config file the app
/// owns (credentials, modes, crash log, the no-vault sessions fallback) is
/// placed through here so the folder is created once, the same way, and a
/// future relocation is a one-line change.
enum AppSupportPaths {
    /// `~/Library/Application Support/RTI`, created on first use unless
    /// `createIfNeeded` is false. Nil only if Application Support itself
    /// cannot be resolved, which never happens on a normal user account.
    static func rtiDirectory(createIfNeeded: Bool = true) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("RTI", isDirectory: true)
        if createIfNeeded {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// `~/Library/Application Support` itself. The shared house command
    /// manifest (`House/commands/rti.json`) lives beside RTI's folder, not
    /// inside it, and still resolves the base through here rather than at the
    /// call site.
    static func applicationSupportBase() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// A file directly inside the RTI config home, e.g. `credentials.json`.
    static func file(_ name: String, createDirectory: Bool = true) -> URL? {
        rtiDirectory(createIfNeeded: createDirectory)?.appendingPathComponent(name)
    }
}
