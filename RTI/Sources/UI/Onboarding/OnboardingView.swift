// Welcome block copied from quick-launch@8ee19aa Sources/Views/WelcomeOverlayView.swift
import RTICore
import SwiftUI

/// First-run setup, in the shape of Quick Launch's welcome card: the RTI
/// mark, one line, the five keys that make up the app, then the two setup
/// cards (API keys; microphone and screen access) and one full-width Get
/// Started. Get Started turns on when both keys are saved and the
/// microphone is allowed; until then the footnote says what is missing.
struct OnboardingView: View {
    /// A fixed state for render proofs, so a proof never reads the real
    /// credentials file or the real privacy grants. Nil in the app.
    struct Fixture {
        var soniox = ""
        var assistantKey = ""
        var keysSaved = false
        var microphone: AppPermissions.State = .notDetermined
        var screenRecording: AppPermissions.State = .notDetermined
    }

    /// One line of the welcome: a glyph in a tile and a short sentence.
    struct Line: Identifiable, Equatable {
        let systemImage: String
        let text: String
        var id: String { text }
    }

    static let summary = "Records, transcribes, and answers during your meetings, out of screen shares."

    static let lines: [Line] = [
        Line(systemImage: "record.circle", text: "⌘⇧R starts and finishes a recording"),
        Line(systemImage: "macwindow", text: "⌘\\ shows or hides RTI"),
        Line(systemImage: "sparkles", text: "⌘↩ asks the assistant during a meeting"),
        Line(systemImage: "at", text: "@ adds a vault file to a question"),
        Line(systemImage: "archivebox", text: "Notes and transcripts save to the vault"),
    ]

    var onDone: () -> Void
    var fixture: Fixture? = nil

    @State private var soniox = ""
    @State private var assistantKey = ""
    @State private var keysSaved = false
    @State private var justSaved = false
    @State private var saveError: String?
    @State private var micState: AppPermissions.State = .notDetermined
    @State private var screenState: AppPermissions.State = .notDetermined

    private var providerName: String { LLMProviders.active.displayName }

    private var canSave: Bool {
        !soniox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !assistantKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var checklist: OnboardingChecklist {
        OnboardingChecklist(
            keysSaved: keysSaved,
            microphone: Self.access(micState),
            screenRecording: Self.access(screenState)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: House.Spacing.md) {
                    welcome
                    keysCard
                    accessCard
                }
                .padding(.horizontal, House.Spacing.xl)
                // Clears the transparent title bar's traffic lights.
                .padding(.top, House.Spacing.xxl)
                .padding(.bottom, House.Spacing.md)
            }
            HouseDivider()
            footer
        }
        .background(House.ColorToken.surface)
        // Chrome is ink, not the system accent.
        .tint(House.ColorToken.textPrimary)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have flipped a switch in System Settings and come back.
            refreshPermissions()
        }
        .onAppear(perform: load)
    }

    // MARK: - Welcome

    private var welcome: some View {
        VStack(spacing: House.Spacing.md) {
            // The app icon's own shape: one flat ink tile, one glyph.
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .fill(House.ColorToken.textPrimary)
                .frame(width: House.Spacing.xxxxl, height: House.Spacing.xxxxl)
                .overlay {
                    Image(systemName: "record.circle")
                        .font(House.TypeToken.display)
                        .foregroundStyle(House.ColorToken.textInverse)
                }
                .accessibilityHidden(true)

            Text("Welcome to RTI")
                .font(House.TypeToken.title)
                .foregroundStyle(House.ColorToken.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(Self.summary)
                .font(House.TypeToken.body)
                .foregroundStyle(House.ColorToken.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: House.Spacing.xs) {
                ForEach(Self.lines) { line in
                    HStack(spacing: House.Spacing.sm) {
                        SlateIconTile(systemName: line.systemImage, glyphSize: House.TypeToken.Size.caption)
                        Text(line.text)
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(House.ColorToken.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, House.Spacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, House.Spacing.xs)
    }

    // MARK: - Step 1: keys

    private var keysCard: some View {
        SettingsCard("API Keys", rows: true) {
            keyRow(
                "Soniox",
                detail: "Live transcription.",
                placeholder: "soniox-…",
                text: $soniox,
                linkURL: "https://console.soniox.com",
                isFirst: true
            )
            keyRow(
                providerName,
                detail: "The assistant.",
                placeholder: LLMProviders.activeOption.apiKeyPlaceholder,
                text: $assistantKey,
                linkURL: LLMProviders.activeOption.consoleURL
            )
            CardNote {
                Button("Save Keys") { saveKeys() }
                    .disabled(!canSave)
                if let saveError {
                    SettingsStatusLabel(text: saveError, systemImage: "xmark.octagon.fill", color: House.ColorToken.danger)
                } else if keysSaved {
                    SettingsStatusLabel(text: justSaved ? "Saved" : "Saved on this Mac",
                                        systemImage: "checkmark.circle.fill",
                                        color: House.ColorToken.success)
                        .fixedSize()
                }
                Text("Kept in an owner-only file on this Mac. Never synced.")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func keyRow(
        _ title: String,
        detail: String,
        placeholder: String,
        text: Binding<String>,
        linkURL: String,
        isFirst: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            if !isFirst { HouseDivider() }
            HStack(spacing: House.Spacing.sm) {
                VStack(alignment: .leading, spacing: House.Spacing.xxs / 2) {
                    Text(title)
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                    HStack(spacing: House.Spacing.xxs) {
                        Text(detail)
                            .font(House.TypeToken.caption)
                            .foregroundStyle(House.ColorToken.textTertiary)
                        if let url = URL(string: linkURL) {
                            // Links are the one place the accent is allowed.
                            Link("Get a key", destination: url)
                                .font(House.TypeToken.caption)
                                .foregroundStyle(House.ColorToken.accent)
                        }
                    }
                }
                Spacer(minLength: House.Spacing.sm)
                SecureField(text: text, prompt: Text("")) {
                    Text("\(title) API key")
                }
                .textFieldStyle(.plain)
                .font(House.TypeToken.code)
                .foregroundStyle(House.ColorToken.textPrimary)
                // The placeholder is an overlay: a styled prompt takes the
                // field's ink on macOS.
                .overlay(alignment: .leading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(House.TypeToken.code)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .settingsField()
                .frame(width: House.Layout.settingsRail)
                .onSubmit { if canSave { saveKeys() } }
            }
            .padding(.vertical, House.Spacing.xs)
            .frame(minHeight: House.Control.row)
        }
    }

    // MARK: - Step 2: access

    private var accessCard: some View {
        SettingsCard("Access", rows: true) {
            SettingsRow(title: "Microphone", detail: "Needed to transcribe.", isFirst: true) {
                accessControl(
                    state: micState,
                    grant: { AppPermissions.requestMicrophone { _ in micState = AppPermissions.microphone } },
                    openSettings: AppPermissions.openMicrophoneSettings
                )
            }
            SettingsRow(title: "Screen Recording", detail: "Optional. Lets ⌘⇧H read your screen.") {
                accessControl(
                    state: screenState,
                    grant: {
                        _ = AppPermissions.requestScreenRecording()
                        screenState = AppPermissions.screenRecording
                    },
                    openSettings: AppPermissions.openScreenRecordingSettings
                )
            }
        }
    }

    @ViewBuilder
    private func accessControl(
        state: AppPermissions.State,
        grant: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        switch state {
        case .granted:
            SettingsStatusLabel(text: "Allowed", systemImage: "checkmark.circle.fill", color: House.ColorToken.success)
                .fixedSize()
        case .notDetermined:
            Button("Allow", action: grant)
        case .denied:
            Button("Open System Settings", action: openSettings)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: House.Spacing.xs) {
            Text(checklist.footnote)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .multilineTextAlignment(.center)
            Button("Get Started") { onDone() }
                .buttonStyle(GetStartedButtonStyle())
                .disabled(!checklist.isReady)
                .keyboardShortcut(checklist.isReady ? .defaultAction : nil)
                .padding(.top, House.Spacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, House.Spacing.xl)
        .padding(.vertical, House.Spacing.md)
        .accessibilityElement(children: .contain)
    }

    // MARK: - State

    private func load() {
        if let fixture {
            soniox = fixture.soniox
            assistantKey = fixture.assistantKey
            keysSaved = fixture.keysSaved
            micState = fixture.microphone
            screenState = fixture.screenRecording
            return
        }
        soniox = CredentialStore.soniox ?? ""
        assistantKey = CredentialStore.value(for: LLMProviders.activeOption.keychainAccount) ?? ""
        keysSaved = LLMProviders.activeHasKey && STTProviders.activeHasKey
        refreshPermissions()
    }

    private func refreshPermissions() {
        guard fixture == nil else { return }
        micState = AppPermissions.microphone
        screenState = AppPermissions.screenRecording
    }

    private func saveKeys() {
        guard fixture == nil else { return }
        let s = soniox.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = assistantKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !k.isEmpty else { saveError = "Both keys are needed."; return }
        CredentialStore.setSoniox(s)
        CredentialStore.setValue(k, for: LLMProviders.activeOption.keychainAccount)
        guard CredentialStore.soniox == s,
              CredentialStore.value(for: LLMProviders.activeOption.keychainAccount) == k else {
            saveError = "Could not save the keys. Check that ~/Library/Application Support/RTI can be written."
            return
        }
        saveError = nil
        keysSaved = true
        justSaved = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            justSaved = false
        }
    }

    private static func access(_ state: AppPermissions.State) -> OnboardingChecklist.Access {
        switch state {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notAsked
        }
    }
}

/// The one primary action of the welcome window: full width, ink fill,
/// inverse text. Disabled, it is a quiet chip fill with tertiary text.
private struct GetStartedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(House.TypeToken.label)
            .foregroundStyle(isEnabled ? House.ColorToken.textInverse : House.ColorToken.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: House.Control.row)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                    .fill(isEnabled ? House.ColorToken.textPrimary : House.ColorToken.chipFill)
            )
            .opacity(configuration.isPressed ? HouseChatMetrics.pressedOpacity : 1)
            .contentShape(Rectangle())
    }
}
