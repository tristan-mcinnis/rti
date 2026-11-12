import Foundation

/// The mic state of a live call, kept apart from the pre-call preset.
///
/// The preset is what the user picks in Prepare before a call ("Listening
/// only" or speaking). It applies to the next call only. The mode is what the
/// mic does now. An in-call mute changes the mode and never the preset, and a
/// stop resets both, so a mute can never carry into the next call. Only a call
/// that went live consumes the preset: a start cancelled before it goes live
/// keeps it.
public struct MicControl: Equatable, Sendable {
    public enum Preset: Equatable, Sendable {
        case speaking
        case listeningOnly
    }

    public enum Mode: Equatable, Sendable {
        case open
        case mutedInCall
        case listeningOnly
    }

    public enum Event: Equatable, Sendable {
        /// Pick the preset for the next call. Ignored while a call is live.
        case setPreset(Preset)
        case sessionStarted
        /// Mute or unmute during a call. Ignored outside a call.
        case toggleMute
        /// The live call has stopped and is finishing. The mic is no longer
        /// live, so the Prepare switch takes input again. The one-call preset
        /// is still reset at `sessionStopped`, unless the user picked a new
        /// one while the call finished.
        case sessionFinishing
        /// The call is over. Resets the mode, and the preset when a live call
        /// consumed it. A stop with no live call keeps the preset.
        case sessionStopped
    }

    /// Help for the mute controls while no call is live.
    public static let muteUnavailableHelp =
        "Mute works during a call. For an observed session, turn on Listening only in Prepare."

    public private(set) var preset: Preset
    public private(set) var mode: Mode
    public private(set) var isLive: Bool
    /// A live call ended and its preset has not been replaced yet.
    private var presetConsumed = false

    public init(preset: Preset = .speaking) {
        self.preset = preset
        mode = .open
        isLive = false
    }

    /// The audio pipeline sends silence for the mic leg when true.
    public var micMuted: Bool {
        mode != .open
    }

    /// The "Your mic is muted" banner shows only for a plain in-call mute.
    public var bannerVisible: Bool {
        mode == .mutedInCall
    }

    public var isListeningOnly: Bool {
        mode == .listeningOnly
    }

    /// The mute controls act only on a live call.
    public var canToggleMute: Bool {
        isLive
    }

    public mutating func reduce(_ event: Event) {
        switch event {
        case let .setPreset(newPreset):
            guard !isLive else { return }
            preset = newPreset
            presetConsumed = false
        case .sessionStarted:
            isLive = true
            presetConsumed = false
            mode = preset == .listeningOnly ? .listeningOnly : .open
        case .toggleMute:
            // Outside a call there is nothing to mute; the preset is the
            // pre-call choice.
            guard isLive else { return }
            switch mode {
            case .open: mode = .mutedInCall
            case .mutedInCall, .listeningOnly: mode = .open
            }
        case .sessionFinishing:
            guard isLive else { return }
            isLive = false
            presetConsumed = true
        case .sessionStopped:
            if isLive || presetConsumed {
                preset = .speaking
            }
            isLive = false
            presetConsumed = false
            mode = .open
        }
    }

    public func reduced(_ event: Event) -> MicControl {
        var copy = self
        copy.reduce(event)
        return copy
    }
}
