import Foundation

enum VaultRetrieval {
    enum Adapter: String, Equatable {
        case hybrid
        case local
    }

    /// The normalized state of one retrieval, so a caller can tell "the index
    /// answered and found nothing" apart from "the index never answered".
    /// Quick Launch's vault adapter reports the same four states for its lane.
    enum Status: Equatable {
        /// The hybrid index answered with rows.
        case available
        /// The hybrid index answered and has nothing for the query.
        case noMatch
        /// The hybrid index could not answer; the local keyword scan did.
        case degraded(reason: String)
        /// Neither adapter could produce an answer.
        case unavailable(reason: String)

        /// Why the hybrid index was not the adapter that answered; nil when it
        /// was. One short diagnostic line.
        var reason: String? {
            switch self {
            case .available, .noMatch: nil
            case .degraded(let reason), .unavailable(let reason): reason
            }
        }
    }

    /// One retrieval's decision, before it becomes a `Response`.
    struct Decision: Equatable {
        let adapter: Adapter
        let results: [VaultSearch.Result]
        let inScope: Bool
        let status: Status
        let fallbackReason: String?
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
        /// Which of the four retrieval states this answer is in.
        let status: Status
        /// Why the hybrid index was not the adapter that answered; nil when it
        /// was. Kept beside `status` so a log line can name the cause.
        let fallbackReason: String?

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

        var modelContextForQuestion: String {
            if hasResults {
                var text = "\(scopeLabel) retrieval for this question:\n---\n\(formattedResults)\n---"
                if case .degraded(let reason) = status {
                    text += "\n(The semantic vault index did not answer — \(reason) — so these results come from the local keyword scan, not the index.)"
                }
                return text
            }
            // A retrieval that never ran is not a statement about the vault.
            if case .unavailable(let reason) = status {
                return "Vault search could not run for this question (\(reason)). Say the vault search is unavailable and answer without it — do not say the vault has nothing on this."
            }
            let policy: String
            switch zeroResultPolicy {
            case .hard:
                policy = "Vault search ran for this question (searched: 0 results). This question names a known project/client or repeats one already asked this session — do not answer from general knowledge or guesswork. Say plainly that the vault has nothing on this yet."
            case .latestPoint:
                policy = "Vault search ran for the latest point (searched: 0 results). Answer from the live transcript if you can; if the point needs vault or project material, say the vault had no hits instead of guessing."
            case .soft:
                policy = "Vault search ran for this question (searched: 0 results). If you can still help from the live transcript or general knowledge, say so explicitly and note the vault had no hits."
            }
            // A local-only zero is not the index saying the vault has nothing.
            guard case .degraded(let reason) = status else { return policy }
            return "The semantic vault index did not answer (\(reason)); the local keyword scan ran instead. " + policy
        }

        var formattedResults: String {
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
    }

    static func search(
        query: String,
        scopeRelativePath: String?,
        zeroResultPolicy: ZeroResultPolicy = .soft
    ) async -> Response {
        let start = Date()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unambiguous project scope is filtered by the index itself; the
        // local scope filter below still runs as the safety net.
        let project = projectScopeSlug(scopeRelativePath)
        let outcome = await VaultSearchCLI.searchOutcome(
            query: trimmed,
            limit: scopeRelativePath == nil ? 6 : 16,
            project: project
        )
        let decision: Decision
        switch outcome {
        case .results(let rows):
            decision = answered(rows, scopeRelativePath: scopeRelativePath, projectScoped: project != nil)
        case .noMatch:
            decision = Decision(adapter: .hybrid, results: [], inScope: false, status: .noMatch, fallbackReason: nil)
        case .unavailable(let reason):
            decision = fallback(
                reason: reason,
                local: await localResults(query: trimmed, scopeRelativePath: scopeRelativePath)
            )
        }
        return Response(
            query: trimmed,
            scopeRelativePath: scopeRelativePath,
            adapter: decision.adapter,
            results: decision.results,
            inScope: decision.inScope,
            elapsedMS: Int(Date().timeIntervalSince(start) * 1000),
            zeroResultPolicy: zeroResultPolicy,
            status: decision.status,
            fallbackReason: decision.fallbackReason
        )
    }

    /// The hybrid index answered. Rows that survive the scope filter are
    /// `available`; an answer with no rows is an honest `noMatch`.
    static func answered(
        _ rows: [VaultSearch.Result],
        scopeRelativePath: String?,
        projectScoped: Bool
    ) -> Decision {
        let scoped: (results: [VaultSearch.Result], inScope: Bool)
        if projectScoped {
            // The CLI filtered by project server-side, so every row belongs to
            // it even when the row itself lives outside the project directory
            // (a meeting note does). Only the displayed count needs trimming.
            let ordered = VaultSearch.applyScope(rows, scope: nil).results
            scoped = (ordered, !ordered.isEmpty)
        } else {
            scoped = VaultSearch.applyScope(rows, scope: scopeRelativePath)
        }
        guard !scoped.results.isEmpty else {
            return Decision(adapter: .hybrid, results: [], inScope: false, status: .noMatch, fallbackReason: nil)
        }
        return Decision(
            adapter: .hybrid,
            results: scoped.results,
            inScope: scoped.inScope,
            status: .available,
            fallbackReason: nil
        )
    }

    /// The hybrid index could not answer, so the local keyword scan stood in.
    /// `degraded` while the vault is on this Mac; `unavailable` when the local
    /// scan had nothing to read either.
    static func fallback(
        reason: String,
        local: (results: [VaultSearch.Result], inScope: Bool, vaultReachable: Bool)
    ) -> Decision {
        guard local.vaultReachable else {
            return Decision(
                adapter: .local,
                results: [],
                inScope: false,
                status: .unavailable(reason: reason),
                fallbackReason: reason
            )
        }
        return Decision(
            adapter: .local,
            results: local.results,
            inScope: local.inScope,
            status: .degraded(reason: reason),
            fallbackReason: reason
        )
    }

    /// `projects/acme-tennis` → `acme-tennis`, the slug the CLI takes for a
    /// server-side `--project` filter. A deeper scope (`projects/personal/rti`)
    /// or a non-project path has no single slug and stays local-filtered.
    static func projectScopeSlug(_ scopeRelativePath: String?) -> String? {
        guard let scope = scopeRelativePath else { return nil }
        let parts = scope.split(separator: "/")
        guard parts.count == 2, parts[0] == "projects" else { return nil }
        let slug = String(parts[1])
        guard slug.range(of: "^[a-z0-9][a-z0-9-]{1,79}$", options: .regularExpression) != nil else { return nil }
        return slug
    }

    static func localResponse(
        query: String,
        scopeRelativePath: String?,
        results: [VaultSearch.Result],
        inScope: Bool,
        elapsedMS: Int = 0,
        zeroResultPolicy: ZeroResultPolicy = .soft,
        status: Status = .degraded(reason: "local keyword scan"),
        fallbackReason: String? = nil
    ) -> Response {
        Response(
            query: query,
            scopeRelativePath: scopeRelativePath,
            adapter: .local,
            results: results,
            inScope: inScope,
            elapsedMS: elapsedMS,
            zeroResultPolicy: zeroResultPolicy,
            status: status,
            fallbackReason: fallbackReason
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
