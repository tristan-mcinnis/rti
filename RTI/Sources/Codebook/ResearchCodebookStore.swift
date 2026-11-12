import Darwin
import Foundation
import RTICore

actor ResearchCodebookStore {
    static let shared = ResearchCodebookStore()

    struct Location: Equatable, Sendable {
        let session: ResearchCodebook.Session
        let directory: URL
        let project: URL?
    }

    enum Change: Sendable {
        case prepare(seeds: [String], hypotheses: [String])
        case pass(ResearchProposal, [ResearchQuote], endMs: Int)
        case edit(ResearchCodebook.Edit)
        case finish(incomplete: Bool)
    }

    /// Only the selected business project may gain these two output files. Personal vault
    /// projects and git clones can also appear in Prepare and must never receive quotes.
    nonisolated static func eligibleProject(_ item: VaultItem?, roots: [ProjectRoots.Root] = ProjectRoots.roots()) -> URL? {
        guard let item, item.isProject else { return nil }
        let url = item.url.resolvingSymlinksInPath().standardizedFileURL
        let permitted = roots.contains { root in
            let base = root.url.resolvingSymlinksInPath().standardizedFileURL
            return url.path.hasPrefix(base.path + "/") && url.pathComponents.count >= base.pathComponents.count + 3
        }
        guard permitted else { return nil }
        var ancestor = url
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                return nil
            }
            ancestor.deleteLastPathComponent()
        }
        return url
    }

    nonisolated static func sidecarFields(in dir: URL) -> [String] {
        var fields: [String] = []
        for (key, file) in [("codebook_json", "codebook.json"), ("codebook_markdown", "codebook.md"), ("quote_bank", "quotes.jsonl")] where FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
            fields.append("\(key): \(file)")
        }
        // Project links are resolved relative to the path printed in the session projection.
        if let data = try? Data(contentsOf: dir.appendingPathComponent("codebook.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = json["projectDirectory"] as? String
        {
            for (key, file) in [("project_codebook_json", "codebook.json"), ("project_codebook_markdown", "codebook.md")] {
                let target = URL(fileURLWithPath: path).appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: target.path), let escaped = try? JSONEncoder().encode(target.path) {
                    fields.append("\(key): \(String(decoding: escaped, as: UTF8.self))")
                }
            }
        }
        return fields
    }

    private func safeFile(_ name: String, in directory: URL) throws -> URL {
        let target = directory.appendingPathComponent(name)
        if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CocoaError(.fileWriteNoPermission)
        }
        return target
    }

    private func read(_ dir: URL) throws -> ResearchCodebook {
        let src = try safeFile("codebook.json", in: dir)
        guard FileManager.default.fileExists(atPath: src.path) else { return ResearchCodebook() }
        let book = try JSONDecoder().decode(ResearchCodebook.self, from: Data(contentsOf: src))
        guard book.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return book
    }

    private func lock<T>(_ directory: URL, _ body: () throws -> T) throws -> T {
        let lockURL = try safeFile(".rti-codebook.lock", in: directory)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body()
    }

    private func save(_ data: Data, as name: String, in dir: URL) throws {
        let dest = try safeFile(name, in: dir)
        let temp = dir.appendingPathComponent(".rti-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temp) }
        let handle = try FileHandle(forWritingTo: temp)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
        guard rename(temp.path, dest.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func save(_ book: ResearchCodebook, in dir: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try save(encoder.encode(book), as: "codebook.json", in: dir)
        var lines = ["# Research codebook", ""]
        for card in book.cards.sorted(by: { ($0.pinned ? 0 : 1, -$0.entries.count, $0.name) < ($1.pinned ? 0 : 1, -$1.entries.count, $1.name) }) {
            lines += ["## \(card.name)", card.summary]
            for session in book.sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
                let evidence = card.entries.filter { $0.evidence.sessionID == session.id }.sorted { $0.evidence.offsetMs < $1.evidence.offsetMs }
                if !evidence.isEmpty {
                    lines.append("### \(session.group ?? session.id)")
                }
                for item in evidence {
                    let quote = item.evidence
                    lines += ["- \(item.point) [\(item.valence.rawValue)]", "  [\(GuideExtraction.locator(quote.offsetMs)), \(quote.speaker.label)] \(quote.original)"]
                }
            }
            lines.append("")
        }
        try save(Data(lines.joined(separator: "\n").utf8), as: "codebook.md", in: dir)
    }

    /// Restore evidence from a session committed immediately before a failed project write.
    /// Reapply the project's redirects and tombstones, which also protects moderator edits.
    private func recover(_ local: ResearchCodebook, into project: inout ResearchCodebook) {
        for session in local.sessions {
            if let index = project.sessions.firstIndex(where: { $0.id == session.id }) {
                project.sessions[index].consumed.formUnion(session.consumed)
                project.sessions[index].endMs = max(session.endMs, project.sessions[index].endMs)
            } else {
                project.sessions.append(session)
            }
        }
        for card in local.cards {
            let keys = ResearchCodebook.spellings(card.name, aliases: card.aliases)
            guard keys.isDisjoint(with: project.suppressed) else { continue }
            let id = project.redirects[card.id.uuidString] ?? card.id
            if let i = project.cards.firstIndex(where: { $0.id == id }) {
                let existing = Set(project.cards[i].entries.map(\.id))
                project.cards[i].entries += card.entries.filter { !existing.contains($0.id) }
            } else {
                project.cards.append(card)
            }
        }
    }

    func update(_ location: Location, _ change: Change) throws -> ResearchCodebook {
        let project = location.project
        return try lock(project ?? location.directory) {
            var book = try read(project ?? location.directory)
            if let project {
                let local = try read(location.directory)
                recover(local, into: &book)
                book.projectDirectory = project.path
            }
            if !book.sessions.contains(where: { $0.id == location.session.id }) {
                book.sessions.append(location.session)
            }
            guard let index = book.sessions.firstIndex(where: { $0.id == location.session.id }) else { throw CocoaError(.fileWriteUnknown) }
            switch change {
            case let .prepare(seeds, hypotheses):
                var fileSeeds: [String] = []
                if let project {
                    let file = try safeFile("codebook-seed.md", in: project)
                    if FileManager.default.fileExists(atPath: file.path) {
                        fileSeeds = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
                    }
                }
                for line in seeds + fileSeeds {
                    let name = line.trimmingCharacters(in: .whitespaces)
                    if name.hasPrefix("#") || name.isEmpty {
                        continue
                    }
                    let seed = name.hasPrefix("- ") || name.hasPrefix("* ") ? String(name.dropFirst(2)) : name
                    let parts = seed.components(separatedBy: " | ")
                    if parts.count == 2, let type = ResearchCardType(rawValue: parts[0].lowercased()) {
                        book.seed(parts[1], type: type)
                    } else {
                        book.seed(seed)
                    }
                }
                for hypothesis in hypotheses {
                    book.seed(hypothesis, type: .hypothesis)
                }
            case let .pass(response, turns, endMs):
                book.apply(response, sources: turns)
                book.sessions[index].consumed.formUnion(turns.map(\.turnID))
                book.sessions[index].endMs = max(book.sessions[index].endMs, endMs)
            case let .edit(edit): book.edit(edit)
            case let .finish(incomplete): book.sessions[index].incomplete = incomplete
            }
            try save(book.scoped(to: location.session.id), in: location.directory)
            if let project {
                try save(book, in: project)
            }
            return book
        }
    }

    func existingBook(in directory: URL) throws -> ResearchCodebook {
        try read(directory)
    }

    func archivedTurns(folder: String) -> [SessionTranscriptTurn] {
        let root = VaultPaths.sessionsDirectory().resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(folder).resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent().path == root.path else { return [] }
        for name in ["transcript.live.md", "transcript.md"] {
            if let file = try? safeFile(name, in: directory), let text = try? String(contentsOf: file, encoding: .utf8) {
                let rows = SessionTranscriptReview.turns(from: text)
                if !rows.isEmpty {
                    return rows
                }
            }
        }
        return []
    }

    func star(_ evidence: ResearchQuote, in dir: URL) throws {
        try lock(dir) {
            let file = try safeFile("quotes.jsonl", in: dir)
            var data = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : Data()
            for line in data.split(separator: 10) {
                if try JSONDecoder().decode(ResearchQuote.self, from: Data(line)).id == evidence.id {
                    return
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if !data.isEmpty, data.last != 10 {
                data.append(10)
            }
            try data.append(encoder.encode(evidence)); data.append(10)
            try save(data, as: "quotes.jsonl", in: dir)
        }
    }
}
