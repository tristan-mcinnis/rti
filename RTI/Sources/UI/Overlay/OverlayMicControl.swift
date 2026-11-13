import SwiftUI
import HouseDesign
import RTICore

/// Zoom-style mic control in the overlay top bar: click the mic to mute /
/// unmute the mic leg, click the chevron for the input-device picker.
///
/// Mute is a TRUE mute (buffers dropped before they reach Soniox) and only
/// affects the mic leg — system audio keeps flowing, so it's the right tool
/// for remote meetings where you aren't speaking. For in-person sessions the
/// mic IS the room capture; the menu carries that warning.
struct OverlayMicControl: View {
    private let session = SessionCoordinator.shared

    @State private var devices: [AudioInputDevice] = []
    @State private var outputDevices: [AudioInputDevice] = []
    @State private var preferredUID: String = AudioInputDeviceStore.preferredUID
    @State private var currentOutputUID: String = AudioInputDeviceStore.defaultOutputUID() ?? ""
    @State private var captureApps: [AudioInputDeviceStore.CaptureApp] = []
    @State private var captureAppBundleID: String = AudioInputDeviceStore.captureAppBundleID
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            muteButton
            deviceMenu
        }
        .frame(height: House.Control.chip)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .strokeBorder(borderColor, lineWidth: House.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous))
        .hoverHighlight($hovering)
    }

    private var muteButton: some View {
        Button {
            session.toggleUserMute()
        } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: session.micMuted ? "mic.slash.fill" : "mic.fill")
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(session.micMuted ? RTIDesign.Color.warning : Color.overlayInkSecondary)
                // Zoom-style reassurance: a faint green level bar under the
                // mic while recording, so you can SEE it's hearing you.
                if session.isRunning, !session.micMuted {
                    MicLevelBar(level: { session.audioLevels().mic })
                        .padding(.bottom, 3)
                }
            }
            .frame(width: House.Control.keyCap + House.Spacing.xxs, height: House.Control.chip)
        }
        .buttonStyle(.plain)
        // Mute acts on a live call only; outside one the button would do nothing.
        .disabled(!session.canToggleMute)
        .accessibilityLabel(session.micMuted ? "Unmute microphone" : "Mute microphone")
        .accessibilityHint(muteHelp(muted: "Your mic isn't being captured; system audio still is."))
        .help(muteHelp(muted: "Mic muted. Your mic is not recorded; system audio still is. Click to unmute."))
    }

    private func muteHelp(muted: String) -> String {
        guard session.canToggleMute else { return MicControl.muteUnavailableHelp }
        return session.micMuted
            ? muted
            : "Mute your mic. System audio keeps recording. Do not mute an in-person session: the mic records the room."
    }

    private var deviceMenu: some View {
        Menu {
            Section("Input device") {
                deviceButton(name: "System default", uid: AudioInputDevice.systemDefaultUID)
                ForEach(devices) { device in
                    deviceButton(name: device.name, uid: device.uid)
                }
            }
            if session.isRunning {
                Text("Input changes apply on the next session")
            }
            Section("Speaker output (capture follows it)") {
                ForEach(outputDevices) { device in
                    Button {
                        if AudioInputDeviceStore.setDefaultOutputDevice(device.id) {
                            currentOutputUID = device.uid
                        }
                    } label: {
                        if currentOutputUID == device.uid {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            }
            Section("Capture audio from") {
                captureAppButton(name: "All apps", bundleID: "")
                ForEach(captureApps) { app in
                    captureAppButton(name: app.name, bundleID: app.bundleID)
                }
                if !captureAppBundleID.isEmpty, !captureApps.contains(where: { $0.bundleID == captureAppBundleID }) {
                    captureAppButton(name: "\(captureAppBundleID) (not producing audio)", bundleID: captureAppBundleID)
                }
                if !captureAppBundleID.isEmpty {
                    Text("Falls back to all apps if it isn't running")
                }
            }
            Divider()
            Button {
                session.toggleUserMute()
            } label: {
                if session.micMuted {
                    Label("Muted (system audio still recording)", systemImage: "checkmark")
                } else {
                    Label("Mute my mic", systemImage: "mic.slash")
                }
            }
            .disabled(!session.canToggleMute)
            if !session.canToggleMute {
                Text(MicControl.muteUnavailableHelp)
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: House.TypeToken.Size.micro, weight: .bold))
                .foregroundStyle(Color.overlayInkTertiary)
                .frame(width: House.Spacing.md, height: House.Control.chip)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Choose input device")
        .onAppear { refreshLists() }
        // The overlay can outlive an entire meeting app's lifecycle (Zoom
        // launched after RTI, for instance), so a one-shot .onAppear load
        // goes stale. The mouse always crosses the control before the menu
        // can open — refresh on hover so the lists are current when it does.
        .onChange(of: hovering) { _, isHovering in
            if isHovering { refreshLists() }
        }
        .help("Choose input device")
    }

    private func refreshLists() {
        devices = AudioInputDeviceStore.availableInputDevices()
        outputDevices = AudioInputDeviceStore.availableOutputDevices()
        currentOutputUID = AudioInputDeviceStore.defaultOutputUID() ?? ""
        captureApps = AudioInputDeviceStore.capturableApps()
        captureAppBundleID = AudioInputDeviceStore.captureAppBundleID
    }

    private func captureAppButton(name: String, bundleID: String) -> some View {
        Button {
            AudioInputDeviceStore.captureAppBundleID = bundleID
            captureAppBundleID = bundleID
        } label: {
            if captureAppBundleID == bundleID {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    private func deviceButton(name: String, uid: String) -> some View {
        Button {
            AudioInputDeviceStore.preferredUID = uid
            preferredUID = uid
        } label: {
            if preferredUID == uid {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    private var backgroundColor: Color {
        if session.micMuted { return RTIDesign.Color.warning.opacity(0.12) }
        return hovering ? RTIDesign.Color.selectionFill : RTIDesign.Color.chipFill
    }

    private var borderColor: Color {
        session.micMuted ? RTIDesign.Color.warning.opacity(0.4) : RTIDesign.Color.border
    }
}

/// The faint level bar under the mic. Every `tick` seconds the timeline
/// reads the level (one cheap closure), with no implicit animation. The
/// width snaps to whole points and the capsule is an equatable child, so
/// SwiftUI skips its body and draws nothing new unless the width changes:
/// a quiet or steady level costs a level read per tick, not a redraw
/// (2026-11-13 M1 audit: a 0.15 s tick with a 0.12 s animation kept Core
/// Animation committing about 80% of a call).
struct MicLevelBar: View {
    static let tick: TimeInterval = 0.3
    let level: () -> Float

    /// The bar's width for a level from 0 to 1, in whole points.
    static func width(for level: Float) -> CGFloat {
        3 + (11 * CGFloat(min(1, max(0, level)))).rounded()
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { _ in
            Capsule(width: Self.width(for: level()))
                .equatable()
        }
    }

    /// The drawn bar. Equal widths compare equal, so its body is skipped.
    struct Capsule: View, Equatable {
        let width: CGFloat

        var body: some View {
            SwiftUI.Capsule()
                .fill(RTIDesign.Color.success)
                .frame(width: width, height: 2)
                .transaction { $0.animation = nil }
        }
    }
}
