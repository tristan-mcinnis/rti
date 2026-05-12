import SwiftUI

/// Live translation overlay. Mirrors the translated stream coming back
/// from Soniox so the user can read the conversation in their target
/// language without having to keep the Live Transcript tab open.
struct TranslationPanelView: View {
    private let coordinator = SessionCoordinator.shared
    @AppStorage(translationOpacityKey) private var backgroundOpacity: Double = translationDefaultOpacity
    @AppStorage("rti.translation.enabled") private var translationEnabled = false
    @AppStorage("rti.translation.showOriginal") private var showOriginal = true
    @AppStorage("rti.translation.mode") private var translationMode = "one_way"
    @AppStorage("rti.translation.targetLanguage") private var targetLanguage = "es"
    @AppStorage("rti.translation.languageA") private var languageA = "en"
    @AppStorage("rti.translation.languageB") private var languageB = "es"

    private static let languageOptions: [(code: String, label: String)] = [
        ("en", "English"), ("es", "Spanish"), ("zh", "Chinese"), ("fr", "French"),
        ("de", "German"), ("ja", "Japanese"), ("ko", "Korean"), ("pt", "Portuguese"),
        ("it", "Italian"), ("ru", "Russian"), ("ar", "Arabic"), ("hi", "Hindi")
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

    var body: some View {
        FloatingPanelChrome(
            title: "Translation",
            opacityKey: translationOpacityKey,
            defaultOpacity: translationDefaultOpacity,
            panelID: .translation,
            titleAccessory: {
                if translationEnabled, coordinator.isRunning {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 7, height: 7)
                }
                Toggle("", isOn: $translationEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.blue)
                    .labelsHidden()
                    .help(translationEnabled ? "Translation on" : "Turn translation on")
            },
            headerActions: {
                PanelHeaderEllipsisMenu(panelID: .translation) {
                    Toggle("Show original", isOn: $showOriginal)
                }
            }
        ) {
            VStack(spacing: 0) {
                if translationEnabled {
                    languageBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                if !translationEnabled {
                    Spacer()
                    disabledHint
                    Spacer()
                } else if paragraphs.isEmpty {
                    Spacer()
                    waitingHint
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(paragraphs) { p in
                                    Row(paragraph: p, showOriginal: showOriginal)
                                        .id(p.id)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        }
                        .scrollContentBackground(.hidden)
                        .onChange(of: paragraphs.last?.id) { _, _ in
                            if let last = paragraphs.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { syncTranslationConfig() }
        .onChange(of: translationEnabled) { _, _ in syncTranslationConfig() }
        .onChange(of: translationMode) { _, _ in syncTranslationConfig() }
        .onChange(of: targetLanguage) { _, _ in syncTranslationConfig() }
        .onChange(of: languageA) { _, _ in syncTranslationConfig() }
        .onChange(of: languageB) { _, _ in syncTranslationConfig() }
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $translationMode) {
                Text("One-way").tag("one_way")
                Text("Two-way").tag("two_way")
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(width: 140)
            .labelsHidden()

            if translationMode == "two_way" {
                languagePicker("From", selection: $languageA)
                Text("↔")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                languagePicker("To", selection: $languageB)
            } else {
                Text("→")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                languagePicker("Target", selection: $targetLanguage)
            }
            Spacer()
        }
    }

    private func languagePicker(_ label: String, selection: Binding<String>) -> some View {
        Picker(label, selection: selection) {
            ForEach(Self.languageOptions, id: \.code) { opt in
                Text(opt.label).tag(opt.code)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.mini)
        .frame(maxWidth: 110)
        .labelsHidden()
        .tint(.white.opacity(0.85))
    }

    private var disabledHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Translation is off")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Flip the switch above to start translating the live transcript.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private var waitingHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Waiting for translated speech…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Paragraph coalescing (mirrors DebugConsole logic)

    private struct Paragraph: Identifiable {
        let id: UUID
        let speakerId: String
        let startMs: Int
        let original: String
        var translation: String
    }

    /// Pair each `original` paragraph with its `translation` paragraph by
    /// speaker + start window. Soniox emits originals and translations
    /// as separate token streams; we merge them so a row shows both.
    private var paragraphs: [Paragraph] {
        var pairs: [Paragraph] = []
        var pendingTranslations: [(speaker: String, text: String)] = []
        for entry in coordinator.liveEntries {
            if entry.translationStatus == "translation" {
                // Try to attach to the last open original of the same speaker.
                if let idx = pairs.lastIndex(where: { $0.speakerId == entry.speakerId && $0.translation.isEmpty }) {
                    pairs[idx].translation = entry.text
                } else if let last = pairs.last, last.speakerId == entry.speakerId {
                    let idx = pairs.count - 1
                    pairs[idx].translation += (pairs[idx].translation.isEmpty ? "" : " ") + entry.text
                } else {
                    pendingTranslations.append((entry.speakerId, entry.text))
                }
            } else {
                if let last = pairs.last, last.speakerId == entry.speakerId {
                    let idx = pairs.count - 1
                    pairs[idx] = Paragraph(
                        id: last.id,
                        speakerId: last.speakerId,
                        startMs: last.startMs,
                        original: last.original + " " + entry.text,
                        translation: last.translation
                    )
                } else {
                    pairs.append(Paragraph(
                        id: entry.id,
                        speakerId: entry.speakerId,
                        startMs: entry.startMs,
                        original: entry.text,
                        translation: ""
                    ))
                }
            }
        }
        // Flush any orphan translations into their own pseudo-rows so they
        // don't get silently dropped on the floor.
        for orphan in pendingTranslations {
            pairs.append(Paragraph(
                id: UUID(),
                speakerId: orphan.speaker,
                startMs: 0,
                original: "",
                translation: orphan.text
            ))
        }
        return pairs
    }

    private struct Row: View {
        let paragraph: Paragraph
        let showOriginal: Bool

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(speakerLabel(paragraph.speakerId))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 60, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    if !paragraph.translation.isEmpty {
                        Text(paragraph.translation)
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if showOriginal, !paragraph.original.isEmpty {
                        Text(paragraph.original)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.50))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
        }

        private func speakerLabel(_ id: String) -> String {
            if id == "self" { return "You" }
            if id.hasPrefix("them_") {
                let n = id.replacingOccurrences(of: "them_", with: "")
                return "Speaker \(n)"
            }
            return id
        }
    }
}
