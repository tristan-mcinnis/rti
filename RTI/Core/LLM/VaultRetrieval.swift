import Foundation

public enum VaultRetrieval {
    /// The normalized state of one retrieval, so a caller can tell "the scan
    /// found nothing" apart from "the scan could not run".
    public enum Status: Equatable {
        /// The keyword scan found rows.
        case available
        /// The keyword scan ran and has nothing for the query.
        case noMatch
        /// There is no notes folder to scan.
        case unavailable(reason: String)

        /// Why the scan could not run; nil otherwise. One short diagnostic line.
        public var reason: String? {
            switch self {
            case .available, .noMatch: nil
            case .unavailable(let reason): reason
            }
        }
    }

    public enum ZeroResultPolicy: Equatable {
        case soft
        case hard
        case latestPoint
    }

    public struct Response: Equatable {
        public let query: String
        public let scopeRelativePath: String?
        public let results: [VaultSearch.Result]
        public let inScope: Bool
        public let elapsedMS: Int
        public let zeroResultPolicy: ZeroResultPolicy
        /// Which retrieval state this answer is in.
        public let status: Status

        public var hasResults: Bool { !results.isEmpty }
        public var scopeLabel: String { scopeRelativePath == nil ? "Vault-wide" : "Project-scoped" }
        public var sourcePaths: [String] { results.map(\.relativePath) }

        public var trace: String {
            var text = "\(scopeRelativePath == nil ? "Vault-wide" : "Scoped") search · \(elapsedMS)ms"
            if !sourcePaths.isEmpty {
                text += " · \(sourcePaths.count) source\(sourcePaths.count == 1 ? "" : "s"): "
                    + sourcePaths.prefix(3).joined(separator: ", ")
                if sourcePaths.count > 3 { text += ", +" + String(sourcePaths.count - 3) }
            }
            return text
        }

        public var modelContextForQuestion: String {
            if hasResults {
                return "\(scopeLabel) retrieval for this question:\n---\n\(formattedResults)\n---"
            }
            // A retrieval that never ran is not a statement about the vault.
            if case .unavailable(let reason) = status {
                return "Vault search could not run for this question (\(reason)). Say the vault search is unavailable and answer without it — do not say the vault has nothing on this."
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

        public var formattedResults: String {
            // The model reads this through the `search_vault` tool, so a run
            // that never reached the index must not read as an empty vault.
            if results.isEmpty, case .unavailable(let reason) = status {
                return "Vault search could not run: \(reason). That is a retrieval failure, not a statement about what the vault contains — say the vault search is unavailable and answer without it."
            }
            return Self.format(results, query: query, inScope: inScope)
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
            out += "\n\nThese are from the user's knowledge vault. Cite the document name when you use one; say so if none actually answers the question."
            return out
        }

        public init(
            query: String,
            scopeRelativePath: String?,
            results: [VaultSearch.Result],
            inScope: Bool,
            elapsedMS: Int,
            zeroResultPolicy: ZeroResultPolicy,
            status: Status
        ) {
            self.query = query
            self.scopeRelativePath = scopeRelativePath
            self.results = results
            self.inScope = inScope
            self.elapsedMS = elapsedMS
            self.zeroResultPolicy = zeroResultPolicy
            self.status = status
        }
    }

    public static func search(
        query: String,
        scopeRelativePath: String?,
        zeroResultPolicy: ZeroResultPolicy = .soft
    ) async -> Response {
        let start = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = await localResults(query: trimmed, scopeRelativePath: scopeRelativePath)
        let status: Status
        if !local.vaultReachable {
            status = .unavailable(reason: "no notes folder is configured")
        } else {
            status = local.results.isEmpty ? .noMatch : .available
        }
        return localResponse(
            query: trimmed,
            scopeRelativePath: scopeRelativePath,
            results: local.results,
            inScope: local.inScope,
            elapsedMS: Int(Date().timeIntervalSince(start) * 1000),
            zeroResultPolicy: zeroResultPolicy,
            status: status
        )
    }

    public static func localResponse(
        query: String,
        scopeRelativePath: String?,
        results: [VaultSearch.Result],
        inScope: Bool,
        elapsedMS: Int = 0,
        zeroResultPolicy: ZeroResultPolicy = .soft,
        status: Status = .available
    ) -> Response {
        Response(
            query: query,
            scopeRelativePath: scopeRelativePath,
            results: results,
            inScope: inScope,
            elapsedMS: elapsedMS,
            zeroResultPolicy: zeroResultPolicy,
            status: status
        )
    }

    private static func localResults(
        query: String,
        scopeRelativePath: String?
    ) async -> (results: [VaultSearch.Result], inScope: Bool, vaultReachable: Bool) {
        let vaultReachable = VaultWorkstreamStore.databasesDir() != nil
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
        return (results, inScope && !results.isEmpty, vaultReachable)
    }
}
