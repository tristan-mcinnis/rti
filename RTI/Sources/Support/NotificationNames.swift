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
    static let rtiShowLogs = Notification.Name("rti.showLogs")
    static let rtiSelectSessionsControlTab = Notification.Name("rti.selectSessionsControlTab")
    static let rtiSessionsChanged = Notification.Name("rti.sessionsChanged")
    static let rtiToggleCommandPalette = Notification.Name("rti.toggleCommandPalette")
    /// Posted after a "Clear Current Chat" action so any open auxiliary
    /// panel windows (notes, dossiers, user-spawned) dismiss themselves.
    static let rtiHideAuxiliaryPanels = Notification.Name("rti.hideAuxiliaryPanels")
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
    static let opacityRange: ClosedRange<Double> = 0.10...1.00
}

enum MeetingDetectionDefaults {
    /// Master switch: react to meeting apps launching at all.
    static let enabledKey = "rti.meeting.autoDetectEnabled"
    /// Opt-in: start recording silently instead of prompting.
    static let autoStartKey = "rti.meeting.autoStart"
}

enum AnalysisSettingsDefaults {
    static let notesEnabledKey = "rti.analysis.notesEnabled"
    static let notesIntervalKey = "rti.analysis.notesIntervalSeconds"
    static let dossiersEnabledKey = "rti.analysis.dossiersEnabled"
    static let themesEnabledKey = "rti.analysis.themesEnabled"
    static let guideEnabledKey = "rti.analysis.guideEnabled"
    static let defaultInterval: Double = 120
    static let intervalRange: ClosedRange<Double> = 60...600
}
