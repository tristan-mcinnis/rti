import Foundation

/// File-backed credential storage at
/// ~/Library/Application Support/RTI/credentials.json (mode 0600).
///
/// The file name `KeychainStore` is historical — we used to round-trip through
/// the macOS Keychain via SecItem*. With ad-hoc code signing (the default for
/// the non-distribution build configured in project.yml) the bundle's code-
/// signing identity changes on every rebuild, so the Keychain ACL refuses the
/// new binary and prompts the user for their login password each launch. For
/// a non-sandboxed local-only app this prompt provides no real security
/// benefit, so we store credentials in an owner-only JSON file instead.
///
/// If you set up a stable Developer ID and want Keychain back, swap this
/// implementation; the public API is the same.
enum KeychainStore {
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
            RTILog.log("KeychainStore save failed: \(error)", category: "credentials")
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

enum CredentialStore {
    private static let deepseekAccount = "deepseek"
    private static let openAIAccount = "openai"
    private static let openRouterAccount = "openrouter"
    private static let sonioxAccount = "soniox"
    private static let assemblyaiAccount = "assemblyai"
    private static let aliyunAccessKeyIDAccount = "aliyun_access_key_id"
    private static let aliyunAccessKeySecretAccount = "aliyun_access_key_secret"
    private static let aliyunNLSAppKeyAccount = "aliyun_nls_app_key"

    static var deepseek: String? { KeychainStore.get(deepseekAccount) }
    static var openai: String? { KeychainStore.get(openAIAccount) }
    static var openrouter: String? { KeychainStore.get(openRouterAccount) }
    static var soniox: String? { KeychainStore.get(sonioxAccount) }
    static var assemblyai: String? { KeychainStore.get(assemblyaiAccount) }
    static var aliyunAccessKeyID: String? {
        firstCredential([aliyunAccessKeyIDAccount, "aliyun_access_key", "alibaba_cloud_access_key_id"], env: ["ALIBABA_CLOUD_ACCESS_KEY_ID", "ALIYUN_ACCESS_KEY_ID"])
    }
    static var aliyunAccessKeySecret: String? {
        firstCredential([aliyunAccessKeySecretAccount, "aliyun_access_secret", "alibaba_cloud_access_key_secret"], env: ["ALIBABA_CLOUD_ACCESS_KEY_SECRET", "ALIYUN_ACCESS_KEY_SECRET"])
    }
    static var aliyunNLSAppKey: String? {
        firstCredential([aliyunNLSAppKeyAccount, "aliyun_app_key", "nls_app_key"], env: ["NLS_APP_KEY", "ALIYUN_NLS_APPKEY", "ALIYUN_NLS_APP_KEY"])
    }

    static func setDeepSeek(_ value: String) { KeychainStore.set(value, for: deepseekAccount) }
    static func setOpenAI(_ value: String) { KeychainStore.set(value, for: openAIAccount) }
    static func setOpenRouter(_ value: String) { KeychainStore.set(value, for: openRouterAccount) }
    static func setSoniox(_ value: String) { KeychainStore.set(value, for: sonioxAccount) }
    static func setAssemblyAI(_ value: String) { KeychainStore.set(value, for: assemblyaiAccount) }
    static func setAliyunAccessKeyID(_ value: String) { KeychainStore.set(value, for: aliyunAccessKeyIDAccount) }
    static func setAliyunAccessKeySecret(_ value: String) { KeychainStore.set(value, for: aliyunAccessKeySecretAccount) }
    static func setAliyunNLSAppKey(_ value: String) { KeychainStore.set(value, for: aliyunNLSAppKeyAccount) }

    static func value(for account: String) -> String? {
        KeychainStore.get(account)
    }

    static func setValue(_ value: String, for account: String) {
        KeychainStore.set(value, for: account)
    }

    private static func firstCredential(_ accounts: [String], env names: [String]) -> String? {
        for account in accounts {
            if let value = KeychainStore.get(account)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        for name in names {
            if let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// One-time migration of any plaintext keys still living in Secrets.swift.
    /// Earlier versions also wrote into the macOS Keychain; we no longer touch
    /// the system Keychain at all (see KeychainStore comment). Any orphaned
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
        if KeychainStore.get(aliyunAccessKeyIDAccount) == nil, let value = aliyunAccessKeyID {
            setAliyunAccessKeyID(value)
        }
        if KeychainStore.get(aliyunAccessKeySecretAccount) == nil, let value = aliyunAccessKeySecret {
            setAliyunAccessKeySecret(value)
        }
        if KeychainStore.get(aliyunNLSAppKeyAccount) == nil, let value = aliyunNLSAppKey {
            setAliyunNLSAppKey(value)
        }
        defaults.set(true, forKey: flag)
    }
}
