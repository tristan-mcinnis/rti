import AppKit
import RTICore
import SwiftUI

struct LiveTranscriptView: View {
    @Environment(SessionCoordinator.self) var coordinator: SessionCoordinator
    private let modes = ModeStore.shared
    @State private var copiedFlash: String?
    @State private var hoveredId: UUID?
    @State private var paragraphs: [LiveTranscriptPresentation.Row] = []

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            Divider()
            modeBar
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            Divider()
            translationBar
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
            Divider()
            transcriptList
        }
        .onAppear { paragraphs = makeParagraphs() }
        .onChange(of: coordinator.liveEntries.count) { _, _ in paragraphs = makeParagraphs() }
        .onChange(of: translationEnabled) { _, _ in paragraphs = makeParagraphs() }
    }

    // MARK: - Translation state

    @AppStorage(TranslationDefaults.enabledKey) private var translationEnabled = false
    @AppStorage(TranslationDefaults.modeKey) private var translationMode = "one_way"
    @AppStorage(TranslationDefaults.targetLanguageKey) private var targetLanguage = "en"
    @AppStorage(TranslationDefaults.languageAKey) private var languageA = "en"
    @AppStorage(TranslationDefaults.languageBKey) private var languageB = "zh"

    private let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"),
        ("zh", "Chinese"), ("ru", "Russian"), ("ar", "Arabic"), ("hi", "Hindi"),
        ("nl", "Dutch"), ("pl", "Polish"), ("tr", "Turkish"), ("vi", "Vietnamese"),
    ]

    private var translationSummary: String {
        guard translationEnabled else { return "Off" }
        switch translationMode {
        case "two_way":
            return "\(languageA.uppercased()) ↔ \(languageB.uppercased())"
        default:
            return "→ \(targetLanguage.uppercased())"
        }
    }

    private var healthColor: Color {
        guard coordinator.isRunning else { return .secondary }
        switch coordinator.transcriptionHealth {
        case .live: return .green
        case .connecting: return .yellow
        case .reconnecting: return .orange
        case .failed: return .red
        case .idle: return .red
        }
    }

    private var healthLabel: String {
        guard coordinator.isRunning else { return "Idle" }
        switch coordinator.transcriptionHealth {
        case .live: return "Live"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .failed: return "Connection lost"
        case .idle: return "Recording…"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(healthColor)
                .frame(width: 10, height: 10)
            Text(healthLabel)
                .font(.system(size: 13, weight: .medium))
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                Text("Realtime")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.orange.opacity(0.10))
            )
            Spacer()
            if coordinator.isRunning, let start = coordinator.startedAt {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(formatElapsed(Date().timeIntervalSince(start)))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if let err = coordinator.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            if let notice = coordinator.systemAudioNotice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Button(action: copyAll) {
                HStack(spacing: 4) {
                    Image(systemName: copiedFlash == "all" ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text(copiedFlash == "all" ? "Copied" : "Copy")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(paragraphs.isEmpty)
            .help("Copy the full live transcript")
        }
    }

    // MARK: - Mode bar

    /// Lets the user switch the active mode (system prompt + reference) at
    /// any time, including mid-session. Mode applies to the next LLM turn —
    /// no restart needed since prompts are evaluated per-request.
    private var modeBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Mode")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { modes.activeModeId ?? "" },
                set: { modes.activeModeId = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(modes.modes) { mode in
                    Text(mode.name).tag(mode.id)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 220)
            Spacer()
            if let active = modes.activeMode {
                Text(active.name)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Translation bar

    private var translationBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(translationEnabled ? Color.blue : .secondary)

            Text("Translation")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Toggle("", isOn: $translationEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)

            if translationEnabled {
                Picker("Mode", selection: $translationMode) {
                    Text("One-way").tag("one_way")
                    Text("Two-way").tag("two_way")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 120)

                if translationMode == "one_way" {
                    Picker("To", selection: $targetLanguage) {
                        ForEach(supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 100)
                } else {
                    Picker("A", selection: $languageA) {
                        ForEach(supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 100)
                    Text("↔").font(.system(size: 10)).foregroundStyle(.secondary)
                    Picker("B", selection: $languageB) {
                        ForEach(supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 100)

                    if languageA == languageB {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .help("Choose two different languages for two-way translation")
                    }
                }
            }

            if coordinator.isRunning {
                Text("Live")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("Translation changes reconnect the transcription stream — expect a 1–2s gap.")
            }

            Spacer()

            Text(translationSummary)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(translationEnabled ? Color.blue : .secondary)
        }
    }

    /// Soniox finalizes in 1–3s windows so the raw stream is dozens of tiny
    /// fragments. Coalesce consecutive same-speaker entries into paragraphs
    /// for a readable live view. Cached in `@State` and rebuilt only when
    /// `liveEntries` changes, so long transcripts don't re-coalesce on every
    /// SwiftUI render.
    private func makeParagraphs() -> [LiveTranscriptPresentation.Row] {
        var names: [String: String] = [:]
        for entry in coordinator.liveEntries where names[entry.speakerId] == nil {
            names[entry.speakerId] = speakerDisplayName(entry.speakerId)
        }
        return LiveTranscriptPresentation.rows(
            from: coordinator.liveEntries,
            showTranslations: translationEnabled,
            speakerLabelStyle: .displayNames(names)
        )
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if paragraphs.isEmpty,
                       (coordinator.interimLine ?? "").isEmpty,
                       coordinator.isRunning
                    {
                        waitingPlaceholder
                    }
                    ForEach(paragraphs) { p in
                        paragraphRow(p)
                            .id(p.id)
                    }
                    if let interim = coordinator.interimLine, !interim.isEmpty {
                        Text(interim)
                            .font(.system(size: 14))
                            .italic()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("interim")
                    }
                }
                .padding(20)
            }
            .onChange(of: paragraphs.last?.id) { _, _ in
                if let last = paragraphs.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: coordinator.interimLine) { _, _ in
                proxy.scrollTo("interim", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func paragraphRow(_ p: LiveTranscriptPresentation.Row) -> some View {
        let isNote = p.speakerId == "note"
        let original = p.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = p.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isNote {
                    Image(systemName: "note.text")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                }
                if translationEnabled, !translation.isEmpty {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }
                Text(p.speakerLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isNote ? Color.yellow : .secondary)
                Text(timeLabel(ms: p.startMs))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if hoveredId == p.id {
                    Button(action: { copyParagraph(p) }) {
                        Image(systemName: copiedFlash == p.id.uuidString ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy this paragraph")
                }
            }
            if isNote {
                Text(original)
                    .font(.system(size: 14))
                    .italic()
                    .lineSpacing(3)
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.08)))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.yellow.opacity(0.5))
                            .frame(width: 2)
                    }
            } else {
                if !original.isEmpty {
                    Text(original)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if translationEnabled, !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: 14))
                        .italic()
                        .lineSpacing(3)
                        .foregroundStyle(Color.blue.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.06)))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.blue.opacity(0.4))
                                .frame(width: 2)
                        }
                }
            }
        }
        .contentShape(Rectangle())
        .hoverHighlight($hoveredId, id: p.id)
    }

    private func timeLabel(ms: Int) -> String {
        TimeFormat.elapsedMs(ms)
    }

    private func copyAll() {
        let text = LiveTranscriptPresentation.copyText(rows: paragraphs, showTranslations: translationEnabled)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied("all")
    }

    private func copyParagraph(_ p: LiveTranscriptPresentation.Row) {
        let text = LiveTranscriptPresentation.copyText(row: p, showTranslations: translationEnabled)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied(p.id.uuidString)
    }

    private func flashCopied(_ key: String) {
        copiedFlash = key
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { if copiedFlash == key { copiedFlash = nil } }
        }
    }

    /// Shown when the session is recording but Soniox hasn't returned any
    /// tokens yet — so the user can tell the difference between "nothing was
    /// said" and "the transcript pipeline is broken." Settings → View Logs…
    /// has the underlying connection / token receipt timeline.
    private var waitingPlaceholder: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for transcription…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Audio is being captured. Words will appear as Soniox finalizes them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    private func speakerDisplayName(_ id: String) -> String {
        SpeakerLabels.displayName(for: id)
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        TimeFormat.elapsed(t)
    }
}
