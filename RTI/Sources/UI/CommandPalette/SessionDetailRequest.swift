import Foundation

/// Typed payload for `.openSessionDetail`. Carries a session id and an
/// optional search query the user came from, so the detail view can
/// highlight matched terms and scroll to the first hit.
///
/// Receivers must also accept a bare `String` id for backwards compat with
/// older callers (menu, deep links, etc.) — see `extract` below.
struct SessionDetailRequest {
    let id: String
    let highlightQuery: String?

    init(id: String, highlightQuery: String? = nil) {
        self.id = id
        let trimmed = highlightQuery?.trimmingCharacters(in: .whitespaces)
        self.highlightQuery = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Decode the `object` of an `.openSessionDetail` notification into
    /// `(id, query)`. Returns nil for malformed payloads so callers can
    /// safely ignore them.
    static func extract(from notificationObject: Any?) -> (id: String, query: String?)? {
        if let req = notificationObject as? SessionDetailRequest {
            return (req.id, req.highlightQuery)
        }
        if let id = notificationObject as? String, !id.isEmpty {
            return (id, nil)
        }
        return nil
    }
}
