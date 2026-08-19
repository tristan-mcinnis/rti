import SwiftUI

/// One row of the first-run permission checklist. File-private — no
/// collision risk with any existing `PermissionRow` type.
private struct PermissionRow: View {
    let title: String
    let detail: String
    let required: Bool
    let state: AppPermissions.State
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.inkPrimary)
                    if required {
                        Text("Required")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.stateWarn)
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkFaint)
            }

            Spacer()

            if state != .granted {
                Button(state == .denied ? "Open settings" : "Allow", action: onRequest)
                    .buttonStyle(.bordered)
                    .pressable()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surfaceRaised)
        )
    }

    private var iconName: String {
        switch state {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "circle"
        }
    }

    private var iconColor: Color {
        switch state {
        case .granted: return Palette.stateLive
        case .denied: return Palette.stateError
        case .notDetermined: return Palette.inkFaint
        }
    }
}

/// First-run onboarding card: microphone (required) and screen recording
/// (optional) permissions, then one primary button. The caller supplies
/// `onFinish` to wire what happens next (close the card / show the
/// overlay) — this view doesn't own window lifecycle.
struct MinimalFirstRunCard: View {
    var onFinish: () -> Void = {}

    @State private var micState = AppPermissions.microphone
    @State private var screenState = AppPermissions.screenRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow RTI to hear your meetings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.inkPrimary)
                Text("RTI listens live and never saves audio.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkSecondary)
            }

            VStack(spacing: 8) {
                PermissionRow(
                    title: "Microphone",
                    detail: "Needed to transcribe what you say.",
                    required: true,
                    state: micState,
                    onRequest: requestMic
                )
                PermissionRow(
                    title: "Screen recording",
                    detail: "Optional — lets RTI read what's on screen.",
                    required: false,
                    state: screenState,
                    onRequest: requestScreen
                )
            }

            Button("Start using RTI", action: onFinish)
                .buttonStyle(.borderedProminent)
                .pressable()
                .disabled(micState != .granted)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: 380)
        .background(Palette.surfacePanel)
        .transition(.opacity.combined(with: .scale))
        .animation(Motion.panelReveal, value: micState)
    }

    private func requestMic() {
        switch micState {
        case .notDetermined:
            AppPermissions.requestMicrophone { granted in
                micState = granted ? .granted : .denied
            }
        case .denied:
            AppPermissions.openMicrophoneSettings()
        case .granted:
            break
        }
    }

    private func requestScreen() {
        switch screenState {
        case .notDetermined:
            let granted = AppPermissions.requestScreenRecording()
            screenState = granted ? .granted : .notDetermined
        case .denied:
            AppPermissions.openScreenRecordingSettings()
        case .granted:
            break
        }
    }
}
