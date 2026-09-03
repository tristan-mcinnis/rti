import SwiftUI

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
        .frame(height: RTIDesign.Control.chip)
        .background(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous)
                .strokeBorder(borderColor, lineWidth: House.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: RTIDesign.Radius.chip, style: .continuous))
        .hoverHighlight($hovering)
    }

    private var muteButton: some View {
        Button {
            session.micMuted.toggle()
        } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: session.micMuted ? "mic.slash.fill" : "mic.fill")
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(session.micMuted ? RTIDesign.Color.warning : Color.overlayInkSecondary)
                // Zoom-style reassurance: a faint green level bar under the
                // mic while recording, so you can SEE it's hearing you.
                if session.isRunning, !session.micMuted {
                    TimelineView(.periodic(from: .now, by: 0.15)) { _ in
                        let level = CGFloat(min(1, max(0, session.audioLevels().mic)))
                        Capsule()
                            .fill(RTIDesign.Color.success)
                            .frame(width: 3 + 11 * level, height: 2)
                            .animation(.linear(duration: 0.12), value: level)
                    }
                    .padding(.bottom, 3)
                }
            }
            .frame(width: 24, height: RTIDesign.Control.chip)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.micMuted ? "Unmute microphone" : "Mute microphone")
        .accessibilityHint(session.micMuted
            ? "Your mic isn't being captured; system audio still is."
            : "Mute your mic. System audio keeps recording. Don't mute in-person sessions — the mic captures the room.")
        .help(session.micMuted
            ? "Mic muted — your mic isn't being captured (system audio still is). Click to unmute."
            : "Mute your mic (system audio keeps recording). Don't mute in-person sessions — the mic captures the room.")
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
            Section("Output device (speaker — capture follows it)") {
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
                if !captureAppBundleID.isEmpty {
                    Text("Falls back to all apps if it isn't running")
                }
            }
            Divider()
            Button {
                session.micMuted.toggle()
            } label: {
                if session.micMuted {
                    Label("Muted (system audio still recording)", systemImage: "checkmark")
                } else {
                    Label("Mute my mic", systemImage: "mic.slash")
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: House.TypeToken.Size.micro, weight: .bold))
                .foregroundStyle(Color.overlayInkTertiary)
                .frame(width: 14, height: RTIDesign.Control.chip)
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
