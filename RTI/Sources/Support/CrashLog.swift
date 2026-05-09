import Foundation

enum CrashLog {
    private static let maxBytes: Int = 1_000_000 // 1 MB

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let entry = """

            --- \(Date()) ---
            \(exception.name.rawValue): \(exception.reason ?? "")
            \(stack)
            """
            CrashLog.append(entry)
        }
    }

    static var logURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let rti = dir.appendingPathComponent("RTI", isDirectory: true)
        try? FileManager.default.createDirectory(at: rti, withIntermediateDirectories: true)
        return rti.appendingPathComponent("crash.log")
    }

    private static func append(_ text: String) {
        guard let url = logURL else { return }
        rotateIfNeeded(url: url)
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
            // Crash logs may contain stack-frame strings — restrict to
            // owner read/write so the file isn't world-readable on
            // shared machines.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        }
    }

    private static func rotateIfNeeded(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let rotated = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}
