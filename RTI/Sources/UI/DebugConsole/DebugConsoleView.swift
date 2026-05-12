import AppKit
import SwiftUI

struct DebugConsoleView: View {
    @EnvironmentObject var coordinator: SessionCoordinator
    @ObservedObject private var modes = ModeStore.shared
    @ObservedObject private var projects = ProjectStore.shared
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @State private var copiedFlash: String?
    @State private var hoveredId: UUID?

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
            projectBar
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
        .onAppear(perform: startClock)
        .onAppear(perform: syncTranslationConfig)
        .onDisappear(perform: stopClock)
    }

    // MARK: - Translation state

    @AppStorage("rti.translation.enabled") private var translationEnabled = false
    @AppStorage("rti.translation.mode") private var translationMode = "one_way"
    @AppStorage("rti.translation.targetLanguage") private var targetLanguage = "es"
    @AppStorage("rti.translation.languageA") private var languageA = "en"
    @AppStorage("rti.translation.languageB") private var languageB = "es"

    private let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"),
        ("zh", "Chinese"), ("ru", "Russian"), ("ar", "Arabic"), ("hi", "Hindi"),
        ("nl", "Dutch"), ("pl", "Polish"), ("tr", "Turkish"), ("vi", "Vietnamese"),
    ]

    private var effectiveTranslationConfig: TranslationConfig? {
        guard translationEnabled else { return nil }
        switch translationMode {
        case "two_way":
            guard languageA != languageB else { return nil }
            return .twoWay(languageA: languageA, languageB: languageB)
        default:
            return .oneWay(targetLanguage: targetLanguage)
        }
    }

    private func syncTranslationConfig() {
        coordinator.translationConfig = effectiveTranslationConfig
    }

    private var translationSummary: String {
        guard translationEnabled else { return "Off" }
        switch translationMode {
        case "two_way":
            return "\(languageA.uppercased()) ↔ \(languageB.uppercased())"
        default:
            return "→ \(targetLanguage.uppercased())"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(coordinator.isRunning ? Color.red : Color.secondary)
                .frame(width: 10, height: 10)
            Text(coordinator.isRunning ? "Recording…" : "Idle")
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
            if coordinator.isRunning {
                Text(formatElapsed(elapsed))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let err = coordinator.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
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

    // MARK: - Project bar

    /// Lets the user attach the live session to a project. When set, every
    /// LLM turn this session produces gets the project's instructions
    /// prepended to the system prompt, the assistant bubble shows a small
    /// "Project: X" tag, and the project name is recorded in the session's
    /// markdown frontmatter at render time.
    private var projectBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Project")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { coordinator.activeProjectId ?? "" },
                set: { coordinator.setActiveProject($0.isEmpty ? nil : $0) }
            )) {
                Text("None").tag("")
                ForEach(projects.projects) { project in
                    Text(project.name).tag(project.id)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 220)
            Spacer()
            if let pid = coordinator.activeProjectId,
               let project = projects.projects.first(where: { $0.id == pid })
            {
                let instr = project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(instr.isEmpty ? "No instructions set" : "\(instr.count) chars of instructions")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(instr.isEmpty ? "Edit the project to add instructions" : instr)
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
                .onChange(of: translationEnabled) { _, _ in
                    syncTranslationConfig()
                }

            if translationEnabled {
                Picker("Mode", selection: $translationMode) {
                    Text("One-way").tag("one_way")
                    Text("Two-way").tag("two_way")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 120)
                .onChange(of: translationMode) { _, _ in
                    syncTranslationConfig()
                }

                if translationMode == "one_way" {
                    Picker("To", selection: $targetLanguage) {
                        ForEach(supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 100)
                        .onChange(of: targetLanguage) { _, _ in
                        syncTranslationConfig()
                    }
                } else {
                    Picker("A", selection: $languageA) {
                        ForEach(supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 100)
                        .onChange(of: languageA) { _, _ in
                        syncTranslationConfig()
                    }
                    Text("↔").font(.system(size: 10)).foregroundStyle(.secondary)
                    Picker("B", selection: $languageB) {
                        ForEach(supportedLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    .controlSize(.small)
                    .frame(width: 100)
                        .onChange(of: languageB) { _, _ in
                        syncTranslationConfig()
                    }

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

    private struct LiveParagraph: Identifiable {
        let id: UUID
        let speakerId: String
        let startMs: Int
        let text: String
        let isTranslation: Bool
        let language: String?
    }

    /// Soniox finalizes in 1–3s windows so the raw stream is dozens of tiny
    /// fragments. Coalesce consecutive same-speaker entries into paragraphs
    /// for a readable live view. Computed each render — small list, cheap.
    private var paragraphs: [LiveParagraph] {
        var out: [LiveParagraph] = []
        for entry in coordinator.liveEntries {
            let isTranslation = entry.translationStatus == "translation"
            if let last = out.last,
               last.speakerId == entry.speakerId,
               last.isTranslation == isTranslation {
                let merged = LiveParagraph(
                    id: last.id,
                    speakerId: last.speakerId,
                    startMs: last.startMs,
                    text: last.text + " " + entry.text,
                    isTranslation: last.isTranslation,
                    language: last.language
                )
                out.removeLast()
                out.append(merged)
            } else {
                out.append(LiveParagraph(
                    id: entry.id,
                    speakerId: entry.speakerId,
                    startMs: entry.startMs,
                    text: entry.text,
                    isTranslation: isTranslation,
                    language: entry.language
                ))
            }
        }
        return out
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if paragraphs.isEmpty,
                       (coordinator.interimLine ?? "").isEmpty,
                       coordinator.isRunning {
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
    private func paragraphRow(_ p: LiveParagraph) -> some View {
        let isNote = p.speakerId == "note"
        let isTranslation = p.isTranslation
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isNote {
                    Image(systemName: "note.text")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.yellow)
                }
                if isTranslation {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }
                Text(isTranslation ? translationLabel(p) : speakerDisplayName(p.speakerId))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isNote ? Color.yellow : isTranslation ? Color.blue : .secondary)
                if !isTranslation {
                    Text(timeLabel(ms: p.startMs))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
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
                Text(p.text.trimmingCharacters(in: .whitespaces))
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
            } else if isTranslation {
                Text(p.text.trimmingCharacters(in: .whitespaces))
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
            } else {
                Text(p.text.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in hoveredId = inside ? p.id : (hoveredId == p.id ? nil : hoveredId) }
    }

    private func translationLabel(_ p: LiveParagraph) -> String {
        if let lang = p.language {
            return "→ \(lang.uppercased())"
        }
        return "Translation"
    }

    private func timeLabel(ms: Int) -> String {
        TimeFormat.elapsedMs(ms)
    }

    private func copyAll() {
        let text = paragraphs.map {
            "[\(timeLabel(ms: $0.startMs))] \(speakerDisplayName($0.speakerId)): \($0.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flashCopied("all")
    }

    private func copyParagraph(_ p: LiveParagraph) {
        let text = "[\(timeLabel(ms: p.startMs))] \(speakerDisplayName(p.speakerId)): \(p.text.trimmingCharacters(in: .whitespaces))"
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
                Text("Audio is being captured. Words will appear as Soniox finalizes them. If nothing arrives within a few seconds, check Settings → View Logs.")
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

    private func startClock() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let start = coordinator.startedAt {
                    elapsed = Date().timeIntervalSince(start)
                } else {
                    elapsed = 0
                }
            }
        }
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        TimeFormat.elapsed(t)
    }
}
