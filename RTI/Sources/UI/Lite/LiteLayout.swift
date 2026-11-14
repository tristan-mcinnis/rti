import HouseDesign
import SwiftUI

/// RTI Lite's few fixed measures, in house tokens.
enum LiteLayout {
    /// The answer card: as wide as the house reading column plus its inset.
    static let answerWidth = House.Layout.chatWidth - House.Spacing.xxl * 2
    /// The card takes at most this share of the page above the ask bar, so
    /// the newest transcript lines stay readable behind it.
    static let answerHeightShare: CGFloat = 0.55
    /// Room the composer may use for its palette and add-context panes.
    static let askBarRoom: CGFloat = 360
    /// The answer rises and settles: quick, no bounce.
    static let rise = Animation.spring(response: 0.32, dampingFraction: 0.92)
}

private struct RTILiteKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the Lite workspace: views drop what Lite leaves out.
    var rtiLite: Bool {
        get { self[RTILiteKey.self] }
        set { self[RTILiteKey.self] = newValue }
    }
}
