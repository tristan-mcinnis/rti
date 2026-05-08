import Foundation

extension Notification.Name {
    static let openSessionDetail = Notification.Name("rti.openSessionDetail")
    static let rtiToggleOverlay = Notification.Name("rti.toggleOverlay")
    static let rtiClearChat = Notification.Name("rti.clearChat")
    static let rtiOverlayDidBecomeKey = Notification.Name("rti.overlayDidBecomeKey")
    static let rtiOverlaySizeChanged = Notification.Name("rti.overlaySizeChanged")
    static let rtiShowLiveTranscript = Notification.Name("rti.showLiveTranscript")
    static let rtiShowSessionHistory = Notification.Name("rti.showSessionHistory")
    static let rtiOrphansDetected = Notification.Name("rti.orphansDetected")
}

enum OverlayAppearanceDefaults {
    static let widthKey = "rti.overlay.width"
    static let heightKey = "rti.overlay.height"
    static let opacityKey = "rti.overlay.opacity"
    static let defaultWidth: Double = 700
    static let defaultHeight: Double = 440
    static let defaultOpacity: Double = 0.90
    static let widthRange: ClosedRange<Double> = 320...800
    static let heightRange: ClosedRange<Double> = 400...900
    static let opacityRange: ClosedRange<Double> = 0.30...0.95
}
