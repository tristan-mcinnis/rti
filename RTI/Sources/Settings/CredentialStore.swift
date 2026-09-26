import Foundation

/// File-backed credential storage at
/// ~/Library/Application Support/RTI/credentials.json (mode 0600).
///
/// Formerly `KeychainStore` (renamed 2026-09-02): an earlier build round-
/// tripped through the macOS Keychain via SecItem*. With ad-hoc code signing
/// (the default for the non-distribution build configured in project.yml) the
/// bundle's code-signing identity changes on every rebuild, so the Keychain
/// ACL refuses the new binary and prompts the user for their login password
/// each launch. For a non-sandboxed local-only app this prompt provides no
/// real security benefit, so we store credentials in an owner-only JSON file
/// instead. The file path and format are unchanged by the rename.
///
/// If you set up a stable Developer ID and want Keychain back, swap the
/// `get`/`set`/`delete` primitives; the account accessors stay the same.
enum CredentialStore {
    nonisolated(unsafe) private static var cached: [String: String]?
    private static let queue = DispatchQueue(label: "com.tristan.rti.credentials", attributes: .concurrent)

    private static var fileURL: URL? {
        AppSupportPaths.file("credentials.json")
    }

    static func set(_ value: String, for account: String) {
        queue.sync(flags: .barrier) {
            var dict = loadLocked()
            if value.isEmpty {
                dict.removeValue(forKey: account)
            } else {
                dict[account] = value
            }
            saveLocked(dict)
        }
    }

    static func get(_ account: String) -> String? {
        queue.sync {
            let dict = loadLocked()
            let v = dict[account] ?? ""
            return v.isEmpty ? nil : v
        }
    }

    static func delete(_ account: String) {
        queue.sync(flags: .barrier) {
            var dict = loadLocked()
            dict.removeValue(forKey: account)
            saveLocked(dict)
        }
    }

    // MARK: - Locked helpers (must be called from inside `queue`)

    private static func loadLocked() -> [String: String] {
        if let cached { return cached }
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            cached = [:]
            return [:]
        }
        cached = dict
        return dict
    }

    private static func saveLocked(_ dict: [String: String]) {
        cached = dict
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(dict)
            // Avoid the umask race in `Data.write(.atomic)` by creating
            // the file ourselves with mode 0600. Atomic-via-rename then
            // happens on the underlying open file, so the owner-only
            // permission is in place from the first write.
            try writeAtomicallyOwnerOnly(data: data, to: url)
            // Tighten the parent directory too; atomic-write copies the
            // file into the same directory before rename, so a misconfigured
            // parent could let a co-tenant see the temp.
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: parent.path
            )
        } catch {
            RTILog.log("CredentialStore save failed: \(error)", category: .credentials)
        }
    }

    /// Write `data` to `url` with mode 0600 from the very first byte — no
    /// umask-dependent intermediate state. Uses a sibling temp file +
    /// `rename(2)` to retain crash-safety.
    private static func writeAtomicallyOwnerOnly(data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let written = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return write(fd, base, data.count)
        }
        close(fd)
        guard written == data.count else {
            try? FileManager.default.removeItem(at: temp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno))
        }
        do {
            // `replaceItemAt` requires an existing destination, so the very
            // first onboarding save must move the owner-only temp file into
            // place instead. Calls are serialized by `queue`, avoiding a
            // concurrent first-write race.
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        // Re-affirm 0600 after the replace, in case replaceItemAt copies
        // the destination's old attributes.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - Named accounts

extension CredentialStore {
    private static let deepseekAccount = "deepseek"
    private static let openAIAccount = "openai"
    private static let openRouterAccount = "openrouter"
    private static let sonioxAccount = "soniox"

    static var deepseek: String? { Self.get(deepseekAccount) }
    static var openai: String? { Self.get(openAIAccount) }
    static var openrouter: String? { Self.get(openRouterAccount) }
    static var soniox: String? { Self.get(sonioxAccount) }

    static func setDeepSeek(_ value: String) { set(value, for: deepseekAccount) }
    static func setOpenAI(_ value: String) { set(value, for: openAIAccount) }
    static func setOpenRouter(_ value: String) { set(value, for: openRouterAccount) }
    static func setSoniox(_ value: String) { set(value, for: sonioxAccount) }

    static func value(for account: String) -> String? {
        get(account)
    }

    static func setValue(_ value: String, for account: String) {
        set(value, for: account)
    }

    /// One-time migration of any plaintext keys still living in Secrets.swift.
    /// Earlier versions also wrote into the macOS Keychain; we no longer touch
    /// the system Keychain at all (see the CredentialStore comment above). Any orphaned
    /// entries from older builds (under com.tristan.rti) linger there
    /// harmlessly until the user clears them via Keychain Access. We don't
    /// try to read them because reading would trigger the very prompt this
    /// migration was intended to silence.
    static func migrateLegacyIfNeeded() {
        let flag = "rti.credentials.migratedV1"
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: flag) { return }
        if deepseek == nil, !Secrets._legacyDeepSeekKey.isEmpty, !Secrets._legacyDeepSeekKey.hasPrefix("<") {
            setDeepSeek(Secrets._legacyDeepSeekKey)
        }
        if soniox == nil, !Secrets._legacySonioxKey.isEmpty, !Secrets._legacySonioxKey.hasPrefix("<") {
            setSoniox(Secrets._legacySonioxKey)
        }
        defaults.set(true, forKey: flag)
    }
}
