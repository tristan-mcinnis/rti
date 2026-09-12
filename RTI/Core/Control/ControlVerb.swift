import Foundation

/// One word off the control socket.
///
/// The house command contract (`design-system/docs/app-commands.md`) fixes the
/// wire shape: one request per line, a verb then optional argument text after a
/// single space, one reply line. RTI's verbs take no argument yet, so anything
/// after the verb is parsed off and ignored rather than rejected — a later verb
/// that needs one does not change the framing.
public enum ControlVerb: String, CaseIterable, Sendable {
    case start
    case stop
    case pause
    case resume
    case toggle
    case status
    /// Bring the Sessions window forward. Read-only: it browses the archive,
    /// it never deletes or overwrites a session (the contract's safety rule).
    case sessions

    /// Parse one wire line. Case-insensitive, surrounding whitespace ignored,
    /// argument text dropped. An unknown or empty word is `nil`, which the
    /// listener answers with `err unknown command "…"` — never a crash, never
    /// a hang.
    public static func parse(_ line: String) -> ControlVerb? {
        ControlVerb(rawValue: firstWord(line).lowercased())
    }

    /// The first word of a line: the verb a client meant. Named back verbatim
    /// (unlowercased) in the error reply, so a typo is recognisable to whoever
    /// sent it. An empty or blank line yields "".
    public static func firstWord(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let word = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return "" }
        return String(word)
    }

    /// Resolve `toggle` to a concrete intent from the live session state, so
    /// nothing downstream ever sees an ambiguous verb. This is the `ipc.rs`
    /// rule: the listener decides the direction, the app only ever gets told.
    public func resolved(recording: Bool) -> ControlVerb {
        guard self == .toggle else { return self }
        return recording ? .stop : .start
    }
}
