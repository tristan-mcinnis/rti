import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI

/// First-run onboarding sheet. Four steps:
///   0. Welcome — what RTI is + the data-flow honesty (audio → Soniox,
///      transcripts → LLM provider, everything else local).
///   1. Permissions — mic + screen recording.
///   2. API keys — Soniox + LLM provider.
///   3. Tour — primary hotkeys + system-audio (BlackHole) note.
///
/// Hero illustrations live in OnboardingArtwork.swift. Completion is
/// persisted under the v2 key — bumped from v1 so anyone who saw the old
/// flow gets the new welcome with the data disclosure once.
enum OnboardingDefaults {
    static let completedKey = "rti.onboarding.completed.v3"

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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to RTI"
        w.contentView = NSHostingView(rootView: OnboardingView(
            onSkip: { [weak self] in self?.dismissWithoutCompletion() },
            onComplete: { [weak self] in self?.complete() }
        ))
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    private func dismissWithoutCompletion() {
        window?.close()
        window = nil
    }

    private func complete() {
        OnboardingDefaults.markCompleted()
        window?.close()
        window = nil
    }
}

// MARK: - Root view

private struct OnboardingView: View {
    var onSkip: () -> Void
    var onComplete: () -> Void

    @State private var step: Int = 0
    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 18)
                .padding(.bottom, 14)

            Group {
                switch step {
                case 0: WelcomeStep()
                case 1: PermissionsStep()
                case 2: KeysStep()
                default: TourStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)

            HStack {
                Button("Skip") { onSkip() }
                Spacer()
                if step > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.2)) { step -= 1 }
                    }
                }
                if step < totalSteps - 1 {
                    Button("Next") {
                        withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { onComplete() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 680, height: 560)
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: i == step ? 24 : 8, height: 6)
                    .animation(.easeInOut(duration: 0.18), value: step)
            }
        }
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WelcomeArtwork()

            VStack(alignment: .leading, spacing: 6) {
                Text("Real-time meeting intelligence.")
                    .font(.system(size: 22, weight: .semibold))
                Text("RTI listens to the conversation, transcribes it as it happens, and answers questions on demand — over an overlay that doesn't show up in other apps' screen captures.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Where your data goes")
                    .font(.system(size: 12, weight: .semibold))
                dataRow(icon: "waveform", text: "Microphone audio is streamed to **Soniox** for transcription.")
                dataRow(icon: "text.bubble", text: "Transcripts and prompts are sent to your **LLM provider** (DeepSeek by default) to generate answers.")
                dataRow(icon: "lock.laptopcomputer", text: "Recordings, transcripts, chat history, summaries, and your API keys **stay on this Mac**.")
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )

            Spacer()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func dataRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            Text(.init(text)) // markdown bold
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 1: Permissions

private struct PermissionsStep: View {
    @State private var micGranted: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenGranted: Bool = CGPreflightScreenCaptureAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PermissionsArtwork(micGranted: micGranted, screenGranted: screenGranted)

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
                detail: "Used by ⌘⇧H to attach the active screen as image + OCR text to your next prompt.",
                granted: screenGranted,
                action: requestScreen
            )

            Spacer()
        }
        .padding(.top, 4)
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

    private var sonioxFilled: Bool {
        !soniox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var llmFilled: Bool {
        !deepseek.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            KeysArtwork(sonioxFilled: sonioxFilled, llmFilled: llmFilled)

            VStack(alignment: .leading, spacing: 4) {
                Text("API Keys")
                    .font(.system(size: 18, weight: .semibold))
                Text("RTI needs two keys to do anything useful. They are stored in an owner-only file on this Mac (~/Library/Application Support/RTI/credentials.json, mode 0600) and only ever sent to the providers below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            field("Soniox API key", "…", $soniox, footnote: "Live transcription. Get one at console.soniox.com.")
            field("LLM provider key (DeepSeek)", "sk-…", $deepseek, footnote: "Assist, Q&A, Summary. Default is DeepSeek; the LLM layer is provider-agnostic.")

            HStack {
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                Spacer()
                Button("Save") { save() }
                    .disabled(!sonioxFilled && !llmFilled)
            }

            Spacer()
        }
        .padding(.top, 4)
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
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                HotkeyCarousel()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick Tour")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Five hotkeys do most of the work.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    tourRow("⌘ \\", "Show / hide the assistant overlay")
                    tourRow("⌘ ⇧ R", "Start / stop a recording session")
                    tourRow("⌘ ↵", "Assist — answer based on what's been said")
                    tourRow("⌘ ⇧ H", "Attach the screen as image + OCR to your next message")
                    tourRow("⌘ ⌥ T", "Show / hide the live transcript window")
                    tourRow("⌘ ⇧ S", "Open Sessions, Projects, Ask-Your-Corpus, Settings")
                    tourRow("⌘ K", "Command palette — search every session + run any action")
                }

                Divider().padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    Text("What else RTI does")
                        .font(.system(size: 14, weight: .semibold))

                    featureRow(
                        icon: "note.text",
                        title: "Live notes, dossiers, themes",
                        body: "Every few minutes during recording, RTI generates structured notes, identifies people/companies/products as dossiers, and groups recurring themes. Toggle each panel from ⌘⇧N / ⌘⇧D or the overlay menu."
                    )
                    featureRow(
                        icon: "eye",
                        title: "On-device vision model",
                        body: "Press ⌘⇧H and RTI captures your screen, runs OCR + a local Qwen3-VL model (MLX, runs on your Mac) and pipes a description into the assistant. No screenshots leave the device. The model auto-downloads on first use (~2 GB); status & cache path are in Settings → General → Vision Model."
                    )
                    featureRow(
                        icon: "doc.text.magnifyingglass",
                        title: "Ask your corpus",
                        body: "Every recording is written as markdown to ~/meetings. Hit ⌘⇧S → Ask, and the assistant searches across every past session (lexical + semantic) and answers with citations."
                    )
                    featureRow(
                        icon: "globe",
                        title: "Real-time translation",
                        body: "Toggle the Translation panel and RTI translates each speaker as they talk. Source + target languages picked per session."
                    )
                    featureRow(
                        icon: "folder",
                        title: "Projects",
                        body: "Group related sessions under a project. The assistant uses project context when answering — useful for recurring meetings with the same client or team."
                    )
                    featureRow(
                        icon: "square.stack.3d.up",
                        title: "Modes",
                        body: "Switch the assistant's voice/style — Coach, Interviewer, Sales-rep, your own — in Settings → Modes. Each mode is a system prompt + reference files."
                    )
                    featureRow(
                        icon: "eye.slash",
                        title: "Hidden from screen capture",
                        body: "RTI's overlay does not appear in QuickTime / Zoom / Meet screen-shares by default. Toggle from the ⋯ menu if you ever want it visible in a recording."
                    )
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
            }
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
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

    private func featureRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(body)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
