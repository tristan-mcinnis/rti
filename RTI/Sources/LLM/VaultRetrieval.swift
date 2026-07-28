import Foundation

enum VaultRetrieval {
    enum Adapter: String, Equatable {
        case hybrid
        case local
    }

    enum ZeroResultPolicy: Equatable {
        case soft
        case hard
        case latestPoint
    }

    struct Response: Equatable {
        let query: String
        let scopeRelativePath: String?
        let adapter: Adapter
        let results: [VaultSearch.Result]
        let inScope: Bool
        let elapsedMS: Int
        let zeroResultPolicy: ZeroResultPolicy

        var hasResults: Bool { !results.isEmpty }
        var scopeLabel: String { scopeRelativePath == nil ? "Vault-wide" : "Project-scoped" }
        var sourcePaths: [String] { results.map(\.relativePath) }

        var trace: String {
            var text = "\(scopeRelativePath == nil ? "Vault-wide" : "Scoped") search · \(elapsedMS)ms"
            if !sourcePaths.isEmpty {
                text += " · \(sourcePaths.count) source\(sourcePaths.count == 1 ? "" : "s"): "
                    + sourcePaths.prefix(3).joined(separator: ", ")
                if sourcePaths.count > 3 { text += ", +" + String(sourcePaths.count - 3) }
            }
            return text
        }

        var formattedResults: String {
            Self.format(results, query: query, inScope: inScope)
        }

        var modelContextForQuestion: String {
            if hasResults {
                return "\(scopeLabel) retrieval for this question:\n---\n\(formattedResults)\n---"
            }
            switch zeroResultPolicy {
            case .hard:
                return "Vault search ran for this question (searched: 0 results). This question names a known project/client or repeats one already asked this session — do not answer from general knowledge or guesswork. Say plainly that the vault has nothing on this yet."
            case .latestPoint:
                return "Vault search ran for the latest point (searched: 0 results). Answer from the live transcript if you can; if the point needs vault or project material, say the vault had no hits instead of guessing."
            case .soft:
                return "Vault search ran for this question (searched: 0 results). If you can still help from the live transcript or general knowledge, say so explicitly and note the vault had no hits."
            }
        }

        private static func format(_ results: [VaultSearch.Result], query: String, inScope: Bool) -> String {
            guard !results.isEmpty else {
                return "No vault documents matched \"\(query)\". The knowledge base may not cover this — try different or broader terms, or rely on the live transcript."
            }
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd"
            let focus = inScope ? " (focused on this meeting's project)" : ""
            var out = "Found \(results.count) relevant vault document\(results.count == 1 ? "" : "s")\(focus) for \"\(query)\":\n"
            for (i, r) in results.enumerated() {
                out += "\n\(i + 1). \(r.title) (\(r.relativePath), updated \(stamp.string(from: r.modified)))"
                if !r.excerpt.isEmpty { out += "\n   \(r.excerpt)" }
            }
            out += "\n\nThese are from Tristan's knowledge vault. Cite the document name when you use one; say so if none actually answers the question."
            return out
        }
    }

    static func search(
        query: String,
        scopeRelativePath: String?,
        zeroResultPolicy: ZeroResultPolicy = .soft
    ) async -> Response {
        let start = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let adapter: Adapter
        let scoped: (results: [VaultSearch.Result], inScope: Bool)
        if let hybrid = await VaultSearchCLI.search(query: trimmed, limit: scopeRelativePath == nil ? 6 : 16) {
            adapter = .hybrid
            scoped = VaultSearch.applyScope(hybrid, scope: scopeRelativePath)
        } else {
            adapter = .local
            scoped = await localResults(query: trimmed, scopeRelativePath: scopeRelativePath)
        }
        return Response(
            query: trimmed,
            scopeRelativePath: scopeRelativePath,
            adapter: adapter,
            results: scoped.results,
            inScope: scoped.inScope,
            elapsedMS: Int(Date().timeIntervalSince(start) * 1000),
            zeroResultPolicy: zeroResultPolicy
        )
    }

    static func localResponse(
        query: String,
        scopeRelativePath: String?,
        results: [VaultSearch.Result],
        inScope: Bool,
        elapsedMS: Int = 0,
        zeroResultPolicy: ZeroResultPolicy = .soft
    ) -> Response {
        Response(
            query: query,
            scopeRelativePath: scopeRelativePath,
            adapter: .local,
            results: results,
            inScope: inScope,
            elapsedMS: elapsedMS,
            zeroResultPolicy: zeroResultPolicy
        )
    }

    private static func localResults(query: String, scopeRelativePath: String?) async -> (results: [VaultSearch.Result], inScope: Bool) {
        var inScope = scopeRelativePath != nil
        var results = await withCheckedContinuation { (cont: CheckedContinuation<[VaultSearch.Result], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: VaultSearch.search(query: query, scopeRelativePath: scopeRelativePath))
            }
        }
        if results.isEmpty, scopeRelativePath != nil {
            inScope = false
            results = await withCheckedContinuation { (cont: CheckedContinuation<[VaultSearch.Result], Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: VaultSearch.search(query: query, scopeRelativePath: nil))
                }
            }
        }
        return (results, inScope && !results.isEmpty)
    }
}
