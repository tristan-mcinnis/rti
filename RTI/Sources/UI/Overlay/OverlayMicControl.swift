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
    @State private var preferredUID: String = AudioInputDeviceStore.preferredUID
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            muteButton
            deviceMenu
        }
        .background(Capsule(style: .continuous).fill(backgroundColor))
        .overlay(Capsule(style: .continuous).stroke(borderColor, lineWidth: 1))
        .clipShape(Capsule(style: .continuous))
        .onHover { hovering = $0 }
    }

    private var muteButton: some View {
        Button {
            session.micMuted.toggle()
        } label: {
            Image(systemName: session.micMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(session.micMuted ? Color.orange : Color.overlayInk.opacity(0.75))
                .frame(width: 24, height: 26)
        }
        .buttonStyle(.plain)
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
                Text("Device changes apply on the next session")
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
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.overlayInk.opacity(0.55))
                .frame(width: 14, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onAppear { devices = AudioInputDeviceStore.availableInputDevices() }
        .help("Choose input device")
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
        if session.micMuted { return Color.orange.opacity(0.16) }
        return Color.overlayInk.opacity(hovering ? 0.14 : 0.08)
    }

    private var borderColor: Color {
        session.micMuted
            ? Color.orange.opacity(0.5)
            : Color.overlayInk.opacity(hovering ? 0.22 : 0.12)
    }
}
