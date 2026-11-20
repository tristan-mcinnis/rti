import Foundation

/// The call type an automatically picked calendar event points to, used only
/// when the user has not chosen one since the last call (2026-11-20: a client
/// catch-up ran as Research, left over from the call before).
public enum CallTypeSuggestion {
    /// Words in an event title that mean a research session.
    static let researchPattern =
        #"\b(focus groups?|fgds?|idis?|in-depth|interviews?|respondents?|ethnograph\w*|home visits?|shop-?alongs?|groups? \d)\b|访谈|座谈|小组"#
    /// Words that mean a meeting about research, not the research itself.
    static let aboutResearchPattern =
        #"\b(follow[ -]?up|debrief|readout|read-out|catch[ -]?up|review|discussion|alignment|kick-?off|briefing|sync|planning)\b"#

    /// The suggested call type, or nil to keep the current one.
    public static func suggest(
        title: String,
        attendees: [CalendarMeeting.Attendee],
        current: CallType,
        hasGuide: Bool
    ) -> CallType? {
        // A personal call stays personal: its attendees prove nothing.
        if current == .personal { return nil }
        if hasGuide {
            return current == .research ? nil : .research
        }
        let lower = title.lowercased()
        let research = lower.range(of: researchPattern, options: .regularExpression) != nil
            && lower.range(of: aboutResearchPattern, options: .regularExpression) == nil
        let others = attendees.filter { !$0.isCurrentUser }
        let suggested: CallType? = if research {
            .research
        } else if let domain = ownDomain(attendees), !others.isEmpty,
                  others.allSatisfy({ Self.domain(of: $0.email) == domain })
        {
            .internal
        } else if !others.isEmpty {
            .client
        } else {
            // No attendees: only undo a research call type the title gives no reason for.
            current == .research ? .client : nil
        }
        return suggested == current ? nil : suggested
    }

    static func ownDomain(_ attendees: [CalendarMeeting.Attendee]) -> String? {
        attendees.first(where: \.isCurrentUser).flatMap { domain(of: $0.email) }
    }

    static func domain(of email: String?) -> String? {
        guard let email, let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].lowercased()
        return domain.isEmpty ? nil : domain
    }
}
