import AppKit
import HouseDesign

/// One geometry for every workspace page. Navigation never resizes the window.
enum WorkspaceLayout {
    /// The chat width plus the sidebar, so the Live side panel keeps its
    /// full rail beside the transcript with the sidebar open.
    static let standardSize = NSSize(
        width: House.Layout.chatWidth + House.Layout.chatRail,
        height: House.Layout.chatHeight + House.Control.row
    )
    static let minimumSize = NSSize(
        width: House.Layout.chatMinWidth,
        height: House.Layout.chatMinHeight + House.Control.row
    )
}

/// AppKit may move a saved frame to the display hosting a newly created window.
/// Resolve its own autosave descriptor in screen coordinates before presenting.
enum WorkspaceFramePlacement {
    static func restore(_ descriptor: String?, legacy: NSRect?, screenFrames: [NSRect],
                        preferred: NSRect, standard: NSSize, minimum: NSSize) -> NSRect {
        let fields = (descriptor ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        let saved: NSRect?
        if fields.count >= 4, fields.prefix(4).allSatisfy(\.isFinite), fields[2] > 0, fields[3] > 0 {
            saved = NSRect(x: fields[0], y: fields[1], width: fields[2], height: fields[3])
        } else {
            saved = legacy
        }
        func area(overlapping screen: NSRect) -> CGFloat {
            guard let saved else { return 0 }
            let part = screen.intersection(saved)
            return part.isNull ? 0 : part.width * part.height
        }
        let target = screenFrames.max(by: { area(overlapping: $0) < area(overlapping: $1) })
            .flatMap { area(overlapping: $0) > 0 ? $0 : nil } ?? preferred
        let margin = saved == nil ? House.Spacing.md : 0
        let available = target.insetBy(dx: margin, dy: margin)
        let sourceSize = saved?.size ?? standard
        let size = NSSize(width: min(available.width, max(minimum.width, sourceSize.width)),
                          height: min(available.height, max(minimum.height, sourceSize.height)))
        let x = saved?.minX ?? available.minX
        let top = saved?.maxY ?? available.maxY
        return NSRect(x: min(max(x, available.minX), available.maxX - size.width),
                      y: min(max(top - size.height, available.minY), available.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
