import AppKit
import HouseDesign

/// Compatibility entry point. Briefs are a dismissible sheet on the workspace.
@MainActor
final class MeetingBriefWindowController {
    static let autosaveName = "rti.meetingbrief"
    static let standardSize = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
    static let minimumSize = NSSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight)

    func show() { WindowCoordinator.shared.showMeetingBrief() }
    func show(brief url: URL) { WindowCoordinator.shared.showMeetingBrief(brief: url) }
}
