import Foundation

/// On-disk persistence for cross-corpus Q&A conversations. Each
/// conversation is a single JSON file under
/// `~/Library/Application Support/RTI/ask-corpus/`. The directory is
/// auto-created on first use. Files are tiny; no DB needed.
struct AskCorpusConversation: Codable, Identifiable {
    let id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [StoredEntry]

    struct StoredEntry: Codable {
        let role: String
        var text: String
        let createdAt: Date
        var citations: [StoredCitation]
    }

    struct StoredCitation: Codable {
        let sessionId: String
        let title: String
    }
}

enum AskCorpusHistoryStore {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("RTI/ask-corpus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// All saved conversations, newest first.
    static func list() -> [AskCorpusConversation] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [AskCorpusConversation] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let conv = try? decoder.decode(AskCorpusConversation.self, from: data)
            else { continue }
            out.append(conv)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(_ conversation: AskCorpusConversation) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(conversation) else { return }
        let url = directory.appendingPathComponent("\(conversation.id).json")
        try? data.write(to: url, options: .atomic)
    }

    static func delete(id: String) {
        let url = directory.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
    }
}
