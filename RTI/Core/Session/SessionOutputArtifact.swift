import Foundation

/// Everything recorded about how one saved-meeting output was produced.
///
/// Deliberately credential-free: provider id/name/model, a sanitized
/// (userinfo-, query- and fragment-free) endpoint, the source transcript's
/// file name, byte count and content hash, the session folder and id, the
/// archived mode, and the template id/name/hash. Enough to trace an output
/// back to its inputs and the exact recipe wording; nothing secret.
public struct SessionOutputProvenance: Codable, Equatable, Sendable {
    public let templateID: String
    public let templateName: String
    public let templateHash: String
    /// Always `transcript.md` today: outputs read the retained transcript only.
    public let sourceFile: String
    public let sourceHash: String
    public let sourceBytes: Int
    /// The archive folder name, e.g. `2026-06-08 161305` — the session version.
    public let sessionFolder: String
    public let sessionID: String?
    public let mode: String?
    public let providerID: String
    public let providerName: String
    public let model: String
    /// The provider endpoint, stripped of any userinfo, query and fragment so
    /// no embedded credential can ever reach a public repository. Nil when the
    /// URL could not be reduced to a scheme and host.
    public let endpoint: String?
    /// ISO-8601 creation instant.
    public let generatedAt: String

    public init(
        templateID: String,
        templateName: String,
        templateHash: String,
        sourceFile: String,
        sourceHash: String,
        sourceBytes: Int,
        sessionFolder: String,
        sessionID: String?,
        mode: String?,
        providerID: String,
        providerName: String,
        model: String,
        endpoint: String? = nil,
        generatedAt: String
    ) {
        self.templateID = templateID
        self.templateName = templateName
        self.templateHash = templateHash
        self.sourceFile = sourceFile
        self.sourceHash = sourceHash
        self.sourceBytes = sourceBytes
        self.sessionFolder = sessionFolder
        self.sessionID = sessionID
        self.mode = mode
        self.providerID = providerID
        self.providerName = providerName
        self.model = model
        self.endpoint = endpoint
        self.generatedAt = generatedAt
    }
}

/// One generated output file on disk.
public struct SessionOutputArtifact: Identifiable, Equatable, Sendable {
    public let url: URL
    public let templateID: String
    public let templateName: String
    /// Parsed from the provenance `generated` line; nil if absent/unparseable.
    public let generatedAt: Date?

    public init(url: URL, templateID: String, templateName: String, generatedAt: Date?) {
        self.url = url
        self.templateID = templateID
        self.templateName = templateName
        self.generatedAt = generatedAt
    }

    public var id: URL { url }
    public var displayName: String {
        templateName.isEmpty ? url.deletingPathExtension().lastPathComponent : templateName
    }
}

public enum SessionOutputError: LocalizedError, Equatable {
    case emptyOutput
    case truncatedOutput
    case missingTranscript
    case uncontainedDestination
    case destinationExists
    case writeFailed(String)
    case unsafeSource(String)
    case sourceTooLarge(String)
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOutput: "The model returned nothing, so no output was saved."
        case .truncatedOutput: "The response was cut off before it finished, so no output was saved."
        case .missingTranscript: "This session has no retained transcript to build an output from."
        case .uncontainedDestination: "The output path escaped the session folder and was refused."
        case .destinationExists: "An output with that name already exists; nothing was overwritten."
        case let .writeFailed(detail): "Couldn't save the output: \(detail)"
        case let .unsafeSource(name): "The archived \(name) is linked or unreadable and was not sent."
        case let .sourceTooLarge(name): "The archived \(name) is too large to process safely. Nothing was sent."
        case let .requestFailed(detail): "The output request failed: \(detail)"
        }
    }
}

/// Path rules for the `outputs/` folder inside one archived session.
public enum SessionOutputPaths {
    public static let directoryName = "outputs"

    public static func directory(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The session's `outputs/` directory, but only when it is a real
    /// directory (never a symlink) that resolves to a direct child of the
    /// session folder. Nil otherwise, so a linked `outputs/` can never
    /// redirect a read OR a write outside the archive.
    public static func safeDirectory(
        in sessionDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let session = sessionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let raw = directory(in: sessionDirectory)
        // A symlink at the outputs path itself is refused outright, even if it
        // points back inside the session: the archive owns a real folder.
        if let values = try? raw.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: raw.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        let resolved = raw.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == session else { return nil }
        return raw
    }

    /// A candidate file is contained only when the `outputs/` directory is
    /// itself safe (see `safeDirectory`) and the file is a direct, non-hidden,
    /// non-symlink child of it — resolved through symlinks so a linked folder
    /// or file cannot redirect the read or write.
    public static func isContained(
        _ url: URL,
        in sessionDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let outputs = safeDirectory(in: sessionDirectory, fileManager: fileManager) else { return false }
        let resolvedOutputs = outputs.standardizedFileURL.resolvingSymlinksInPath()
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard parent == resolvedOutputs else { return false }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix(".") else { return false }
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            return false
        }
        return true
    }
}

/// Renders and names generated output files. Pure; every rule here is unit-tested.
public enum SessionOutputMarkdown {
    /// `outputs/<recipe>-<stamp>.md`, suffixed `-2`, `-3`… when that name is
    /// already taken, so a generation never overwrites an earlier one.
    public static func fileName(recipeID: String, stamp: String, existing: Set<String>) -> String {
        let safeID = SessionOutputID.isValid(recipeID) ? recipeID : "output"
        let base = "\(safeID)-\(stamp)"
        var candidate = "\(base).md"
        var index = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(index).md"
            index += 1
        }
        return candidate
    }

    /// Provenance as YAML frontmatter lines, so the file is still a readable
    /// Markdown document and the existing Sessions reader strips it.
    public static func provenanceFrontmatter(_ provenance: SessionOutputProvenance) -> [String] {
        var lines = [
            "---",
            "output: \(yamlQuoted(provenance.templateID))",
            "template: \(yamlQuoted(provenance.templateName))",
            "template-hash: \(yamlQuoted(provenance.templateHash))",
            "source: \(yamlQuoted(provenance.sourceFile))",
            "source-hash: \(yamlQuoted(provenance.sourceHash))",
            "source-bytes: \(provenance.sourceBytes)",
            "session: \(yamlQuoted(provenance.sessionFolder))",
        ]
        if let sessionID = provenance.sessionID, !sessionID.isEmpty {
            lines.append("session-id: \(yamlQuoted(sessionID))")
        }
        if let mode = provenance.mode, !mode.isEmpty {
            lines.append("mode: \(yamlQuoted(mode))")
        }
        lines += [
            "provider: \(yamlQuoted(provenance.providerID))",
            "provider-name: \(yamlQuoted(provenance.providerName))",
            "model: \(yamlQuoted(provenance.model))",
        ]
        if let endpoint = provenance.endpoint, !endpoint.isEmpty {
            lines.append("endpoint: \(yamlQuoted(endpoint))")
        }
        lines += [
            "generated: \(yamlQuoted(provenance.generatedAt))",
            "---",
            "",
        ]
        return lines
    }

    /// `scheme://host[:port]` from a provider base URL. Userinfo, path,
    /// query and fragment are removed because credentials can occur in any of them. A URL that has no scheme or host reduces to
    /// nil rather than leaking an opaque string into a public artifact.
    public static func sanitizedEndpoint(_ url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, !scheme.isEmpty,
              let host = components.host, !host.isEmpty
        else { return nil }
        var out = "\(scheme)://\(host)"
        if let port = components.port { out += ":\(port)" }
        return out
    }

    /// The full file: provenance frontmatter, an H1, then the model's body.
    public static func render(
        recipe: SessionOutputRecipe,
        provenance: SessionOutputProvenance,
        body: String
    ) -> String {
        var lines = provenanceFrontmatter(provenance)
        lines.append("# \(recipe.name)")
        lines.append("")
        lines.append(body.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Best-effort read of the provenance block back out of a rendered file,
    /// for listing without a database. Nil when the frontmatter is absent.
    public static func parseProvenance(_ text: String) -> SessionOutputProvenance? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line == "---" { break }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colon])
                let value = unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                fields[key] = value
            }
            index += 1
        }
        guard index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "---",
              let templateID = fields["output"] else { return nil }
        return SessionOutputProvenance(
            templateID: templateID,
            templateName: fields["template"] ?? "",
            templateHash: fields["template-hash"] ?? "",
            sourceFile: fields["source"] ?? "transcript.md",
            sourceHash: fields["source-hash"] ?? "",
            sourceBytes: fields["source-bytes"].flatMap(Int.init) ?? 0,
            sessionFolder: fields["session"] ?? "",
            sessionID: fields["session-id"],
            mode: fields["mode"],
            providerID: fields["provider"] ?? "",
            providerName: fields["provider-name"] ?? "",
            model: fields["model"] ?? "",
            endpoint: fields["endpoint"],
            generatedAt: fields["generated"] ?? ""
        )
    }

    /// Parse the ISO-8601 `generated` value into a date for newest-first sorting.
    public static func parseGeneratedDate(_ iso: String) -> Date? {
        // ISO8601DateFormatter is not Sendable. Keep parsing local to the call
        // rather than share mutable formatter state across archive actors.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    /// Compact, filename-safe stamp from an instant: `yyyyMMdd-HHmmss`.
    public static func filenameStamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    /// A short human label for an artifact's time: `12 Jun, 16:13`. Empty when
    /// the date is missing, so a label never invents a time.
    public static func displayStamp(_ date: Date?) -> String {
        guard let date else { return "" }
        return displayFormatter.string(from: date)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let inner = value.dropFirst().dropLast()
        var out = ""
        var escaped = false
        for character in inner {
            if escaped {
                switch character {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                default: out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
