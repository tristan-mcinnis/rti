import AppKit
import HouseDesign

/// One geometry for every workspace page. Navigation never resizes the window.
enum WorkspaceLayout {
    static let standardSize = NSSize(
        width: House.Layout.chatWidth,
        height: House.Layout.chatHeight + House.Control.row
    )
    static let minimumSize = NSSize(
        width: House.Layout.chatMinWidth,
        height: House.Layout.chatMinHeight + House.Control.row
    )
}
