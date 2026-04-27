import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

/// First-run onboarding sheet. Walks the user through (1) granting Mic +
/// Screen Recording, (2) pasting Soniox + DeepSeek API keys, (3) a quick tour
/// of the four global hotkeys and BlackHole guidance. Completion is persisted
/// so existing users never see it again.
enum OnboardingDefaults {
    static let completedKey = "rti.onboarding.completed.v1"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }
}

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func showIfNeeded() {
        guard !OnboardingDefaults.hasCompleted else { return }
        show()
    }

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to RTI"
        w.contentView = NSHostingView(rootView: OnboardingView(onClose: { [weak self] in self?.close() }))
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func close() {
        OnboardingDefaults.markCompleted()
        window?.close()
        window = nil
    }
}

private struct OnboardingView: View {
    var onClose: () -> Void

    @State private var step: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 18)
                .padding(.bottom, 12)

            Group {
                switch step {
                case 0: PermissionsStep()
                case 1: KeysStep()
                default: TourStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)

            HStack {
                Button("Skip") { onClose() }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                if step < 2 {
                    Button("Next") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { onClose() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 460)
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: i == step ? 24 : 8, height: 6)
                    .animation(.easeInOut(duration: 0.18), value: step)
            }
        }
    }
}

// MARK: - Step 1: Permissions

private struct PermissionsStep: View {
    @State private var micGranted: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenGranted: Bool = CGPreflightScreenCaptureAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions")
                    .font(.system(size: 18, weight: .semibold))
                Text("RTI needs two permissions to capture meetings and ground answers in what's on screen. Both are stored in System Settings → Privacy & Security and can be revoked any time.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionRow(
                title: "Microphone",
                detail: "Captures your voice for live transcription.",
                granted: micGranted,
                action: requestMic
            )

            permissionRow(
                title: "Screen Recording",
                detail: "Used by ⌘H to attach the active screen as image + OCR text to your next prompt.",
                granted: screenGranted,
                action: requestScreen
            )

            Spacer()
        }
        .padding(.top, 8)
    }

    private func permissionRow(title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.system(size: 16))
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button("Grant", action: action)
            }
        }
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { micGranted = granted }
        }
    }

    /// CGRequestScreenCaptureAccess() prompts and immediately returns the
    /// current state. Avoid re-prompting users who have already granted it;
    /// that dialog is confusing. If declined, request and recheck a moment
    /// later for the System Settings roundtrip.
    private func requestScreen() {
        guard !CGPreflightScreenCaptureAccess() else {
            screenGranted = true
            return
        }
        _ = CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            screenGranted = CGPreflightScreenCaptureAccess()
        }
    }
}

// MARK: - Step 2: Keys

private struct KeysStep: View {
    @State private var deepseek = ""
    @State private var soniox = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Keys")
                    .font(.system(size: 18, weight: .semibold))
                Text("RTI needs two keys to do anything useful. Both stay in your macOS Keychain — RTI never uploads them anywhere except the providers themselves.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Soniox API key", "…", $soniox, footnote: "Live transcription. Get one at console.soniox.com.")
            field("DeepSeek API key", "sk-…", $deepseek, footnote: "LLM for Assist, Q&A, and Summary. Get one at platform.deepseek.com.")

            HStack {
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Save") { save() }
                    .disabled(deepseek.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                              soniox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Spacer()
        }
        .padding(.top, 8)
        .onAppear {
            deepseek = CredentialStore.deepseek ?? ""
            soniox = CredentialStore.soniox ?? ""
        }
    }

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
            Text(footnote).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let k = deepseek.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = soniox.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { CredentialStore.setDeepSeek(k) }
        if !s.isEmpty { CredentialStore.setSoniox(s) }
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { saved = false }
    }
}

// MARK: - Step 3: Tour

private struct TourStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quick Tour")
                    .font(.system(size: 18, weight: .semibold))
                Text("Five things to know.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                tourRow("⌘ \\", "Show / hide the assistant overlay")
                tourRow("⌘ ⇧ R", "Start / stop a recording session")
                tourRow("⌘ ↵", "Assist — answer based on what's been said")
                tourRow("⌘ H", "Attach the screen as image + OCR to your next message")
                tourRow("⌘ ⌥ T", "Show / hide the live transcript window")
            }

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Capturing the other side of a call")
                    .font(.system(size: 12, weight: .medium))
                Text("RTI captures whatever your selected input device hears. To record both sides of a call, install BlackHole, build an aggregate device that combines your mic + BlackHole in Audio MIDI Setup, then pick it under Settings → General → Audio Input.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.top, 8)
    }

    private func tourRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            Text(label).font(.system(size: 12))
            Spacer()
        }
    }
}
