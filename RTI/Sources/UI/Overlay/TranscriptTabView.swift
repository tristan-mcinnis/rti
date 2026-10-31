import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers
import HouseDesign

// MARK: - Transcript

struct TranscriptTabView: View {
    var isActive = true
    private let session = SessionCoordinator.shared
    @AppStorage(TranslationDefaults.enabledKey) private var translationEnabled = false
    @AppStorage(TranslationDefaults.modeKey) private var translationMode = "one_way"
    @AppStorage(TranslationDefaults.targetLanguageKey) private var targetLanguage = "en"
    @AppStorage(TranslationDefaults.languageAKey) private var languageA = "en"
    @AppStorage(TranslationDefaults.languageBKey) private var languageB = "zh"
    @State private var presentationOwner = UUID()
    /// A rename refreshes the shared projection and copied text together.
    private let speakerNames = SpeakerNameStore.shared

    private static let languageOptions: [(code: String, label: String)] = [
        ("en", "English"), ("zh", "Chinese"), ("es", "Spanish"), ("fr", "French"),
        ("de", "German"), ("ja", "Japanese"), ("ko", "Korean"), ("pt", "Portuguese"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            // The strip lines up with the tabs row. The captured-time clock
            // is the header's record chip; it is not repeated here.
            OverlayTabStrip {
                HStack(spacing: House.Spacing.xs) {
                    SlateStatusDot(color: healthColor)
                    Text(healthLabel)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Transcription: \(healthLabel)")
            } trailing: {
                if session.canRetryLiveTranscription {
                    Button("Retry transcription", systemImage: "arrow.clockwise") { session.retryLiveTranscription() }
                        .buttonStyle(.plain)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textPrimary)
                }
                translateControl
                OverlayToolbarButton(icon: "doc.on.doc", help: "Copy transcript", disabled: session.liveEntries.isEmpty) {
                    NSPasteboard.copyString(session.transcriptTextForCopy())
                }
            }
            if let notice = session.micAudioNotice {
                Text(notice).font(House.TypeToken.caption).foregroundStyle(House.ColorToken.warning)
            }
            if let notice = session.systemAudioNotice {
                Text(notice).font(House.TypeToken.caption).foregroundStyle(House.ColorToken.warning)
            }
            LiveTranscriptList(rows: session.transcriptRows, revision: session.transcriptDisplayRevision,
                               isActive: isActive, sessionID: session.currentSessionId)
                .equatable()
                .overlay {
                    if session.transcriptRows.isEmpty {
                        overlayEmptyHints([
                            overlayRecordHint(),
                            "What you say shows on the right, everyone else on the left",
                            "Click a speaker to give them a name",
                        ])
                    }
                }
        }
        // SessionCoordinator observes UserDefaults and is the sole writer of
        // `translationConfig`. The view only reads the same defaults keys for
        // its controls; it no longer pushes config directly.
        .onAppear { if isActive { activatePresentation() } }
        .onDisappear { session.deactivateTranscriptPresentation(for: presentationOwner) }
        .onChange(of: isActive) { _, active in
            if active { activatePresentation() }
            else { session.deactivateTranscriptPresentation(for: presentationOwner) }
        }
        .onChange(of: translationEnabled) { _, _ in session.refreshTranscriptPresentation() }
        .onChange(of: speakerNames.names) { _, _ in session.refreshTranscriptPresentation() }
    }

    // MARK: - Translation control

    private var translateControl: some View {
        HStack(spacing: 4) {
            Button {
                translationEnabled.toggle()
            } label: {
                HStack(spacing: HouseChatMetrics.chipGap) {
                    Image(systemName: "globe").font(House.TypeToken.caption)
                    Text(translationEnabled ? pillLabel : "Translate")
                        .font(House.TypeToken.meta)
                }
                .foregroundStyle(translationEnabled ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                .padding(.horizontal, House.Spacing.xs)
                .frame(height: House.Control.chip)
                .background(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .fill(translationEnabled ? House.ColorToken.selectionFill : House.ColorToken.chipFill)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(translationEnabled ? "Turn translation off" : "Turn translation on")
            .help(translationEnabled ? "Translation is on. It shows under each line." : "Translate the transcript inline")

            if translationEnabled {
                Menu {
                    Picker("Mode", selection: $translationMode) {
                        Text("One-way (all into one language)").tag("one_way")
                        Text("Two-way (between two languages)").tag("two_way")
                    }
                    Divider()
                    if translationMode == "two_way" {
                        Picker("From", selection: $languageA) { languageItems }
                        Picker("To", selection: $languageB) { languageItems }
                    } else {
                        Picker("Target", selection: $targetLanguage) { languageItems }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                        .foregroundStyle(Color.overlayInkTertiary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 14)
                .accessibilityLabel("Translation mode and languages")
                .help("Translation mode and languages")
            }
        }
    }

    private var languageItems: some View {
        ForEach(Self.languageOptions, id: \.code) { opt in
            Text(opt.label).tag(opt.code)
        }
    }

    private var pillLabel: String {
        translationMode == "two_way"
            ? "\(languageA.uppercased())↔\(languageB.uppercased())"
            : languageLabel(targetLanguage)
    }

    private func activatePresentation() {
        session.activateTranscriptPresentation(for: presentationOwner)
    }

    private func languageLabel(_ code: String) -> String {
        Self.languageOptions.first { $0.code == code }?.label ?? code.uppercased()
    }

    private var healthColor: Color {
        if session.isPaused { return RTIDesign.Color.warning }
        guard session.isRunning else { return Color.overlayInkTertiary }
        switch session.transcriptionHealth {
        case .live: return RTIDesign.Color.success
        case .connecting, .reconnecting: return RTIDesign.Color.warning
        case .failed, .idle: return RTIDesign.Color.danger
        }
    }

    private var healthLabel: String {
        if session.isPaused { return "Paused" }
        guard session.isRunning else { return "Idle" }
        switch session.transcriptionHealth {
        case .live: return "Live"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .failed: return "Connection lost"
        case .idle: return "Recording…"
        }
    }
}
