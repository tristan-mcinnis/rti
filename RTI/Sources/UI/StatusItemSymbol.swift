import Foundation

/// The menu-bar glyph family.
///
/// DESIGN.md bans letters in circles and asks the status item to use the same
/// silhouette as the app icon, so RTI's status item is the record ring — not
/// the old `r.circle`. Idle draws as a template (it inherits the menu bar's
/// ink); recording keeps the ring in ink and fills the centre with `danger`,
/// the one status colour the chrome is allowed.
enum StatusItemSymbol {
    /// Not recording. Rendered as a template image.
    static let idle = "record.circle"
    /// Recording. Rendered with a palette so the centre reads as a red dot.
    static let recording = "record.circle.fill"
    /// Point size of the status item glyph.
    static let pointSize: CGFloat = 15

    static func name(running: Bool) -> String {
        running ? recording : idle
    }

    /// The VoiceOver description that travels with each state.
    static func accessibilityDescription(running: Bool) -> String {
        running ? "RTI recording" : "RTI"
    }
}
