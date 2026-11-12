import AppKit
import HouseDesign
import RTICore
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var following = LiveTranscriptList.startsFollowing
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
                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    HStack(spacing: House.Spacing.xs) {
                        SlateStatusDot(color: healthColor)
                        Text(healthLabel).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.textSecondary)
                        if session.isRunning {
                            Text(following ? "Following" : "Browsing").font(House.TypeToken.meta.weight(.semibold))
                        }
                    }
                    if let start = session.audioPipeline.captureStartWall ?? session.startedAt, session.isRunning {
                        TranscriptActivityCaption(activity: session.readerActivity, start: start, active: isActive && !session.isPaused,
                                                  stoppedAt: session.pausedAt)
                    }
                }
                .accessibilityElement(children: .combine)
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
            if translationEnabled && translationMode == "two_way" && languageA == languageB {
                Text("Choose two different languages to start two-way translation.")
                    .font(House.TypeToken.caption).foregroundStyle(House.ColorToken.warning)
            } else if !session.switchingLegs.isEmpty {
                Text("Switching transcription settings…")
                    .font(House.TypeToken.caption).foregroundStyle(House.ColorToken.textSecondary)
            }
            if let notice = session.micAudioNotice {
                Text(notice).font(House.TypeToken.caption).foregroundStyle(House.ColorToken.warning)
            }
            if let notice = session.systemAudioNotice {
                Text(notice).font(House.TypeToken.caption).foregroundStyle(House.ColorToken.warning)
            }
            LiveTranscriptList(turns: session.transcriptTurns, revision: session.transcriptDisplayRevision,
                               isActive: isActive, sessionID: session.currentSessionId, onFollowingChanged: { following = $0 })
                .equatable()
                .overlay {
                    if session.transcriptRows.isEmpty {
                        overlayEmptyHints([
                            overlayRecordHint(),
                            "Spoken words appear here as they arrive",
                            "Click a speaker to give them a name",
                        ])
                    }
                }
        }
        // SessionCoordinator observes UserDefaults and is the sole writer of
        // `translationConfig`. The view only reads the same defaults keys for
        // its controls; it no longer pushes config directly.
        .onAppear {
            if isActive {
                activatePresentation()
            }
        }
        .onDisappear { session.deactivateTranscriptPresentation(for: presentationOwner) }
        .onChange(of: isActive) { _, active in
            if active {
                activatePresentation()
            } else {
                session.deactivateTranscriptPresentation(for: presentationOwner)
            }
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
                        Picker("From", selection: $languageA) { languageItems(excluding: languageB) }
                        Picker("To", selection: $languageB) { languageItems(excluding: languageA) }
                    } else {
                        Picker("Target", selection: $targetLanguage) { languageItems() }
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

    private func languageItems(excluding otherLanguage: String? = nil) -> some View {
        ForEach(Self.languageOptions, id: \.code) { opt in
            Text(opt.label).tag(opt.code).disabled(opt.code == otherLanguage)
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
        guard session.isRunning else { return House.ColorToken.textTertiary }
        if session.isPaused { return House.ColorToken.warning }
        let active = session.micMuted ? [session.systemTranscriptionHealth] : [session.transcriptionHealth, session.systemTranscriptionHealth]
        if active.contains(.failed) { return RTIDesign.Color.danger }
        if active.contains(.reconnecting) || active.contains(.connecting) { return House.ColorToken.warning }
        return active.contains(.live) ? RTIDesign.Color.success : House.ColorToken.textTertiary
    }

    private var healthLabel: String {
        if session.isPaused { return "Paused" }
        guard session.isRunning else { return "Idle" }
        func label(_ health: TranscriptionHealth, source: String) -> String {
            switch health {
            case .live: "\(source) connected"
            case .connecting: "\(source) connecting"
            case .reconnecting: "\(source) reconnecting"
            case .failed: "\(source) unavailable"
            case .idle: source == "Call" ? "Awaiting call audio" : "Awaiting mic"
            }
        }
        let mic = session.micMuted ? (session.isListeningOnly ? "Listening only" : "Mic off") : label(session.transcriptionHealth, source: "Mic")
        return mic + " · " + label(session.systemTranscriptionHealth, source: "Call")
    }
}

/// This clock repaints the tiny age label only. It never reads the transcript list.
private struct TranscriptActivityCaption: View {
    let activity: TranscriptReaderActivity
    let start: Date
    let active: Bool
    let stoppedAt: Date?

    var body: some View {
        if active {
            TimelineView(.periodic(from: .now, by: 5)) { context in caption(at: context.date) }
        } else {
            caption(at: stoppedAt ?? .now)
        }
    }

    private func caption(at date: Date) -> some View {
        Text(activity.caption(elapsedMs: Int(max(0, date.timeIntervalSince(start)) * 1000)))
            .font(House.TypeToken.meta).monospacedDigit().foregroundStyle(House.ColorToken.textSecondary)
            .help("Times since the last finalized original speech and the last note on the recording timeline.")
    }
}
