import SwiftUI

/// Live translation overlay. Mirrors the translated stream coming back
/// from Soniox so the user can read the conversation in their target
/// language without having to keep the Live Transcript tab open.
struct TranslationPanelView: View {
    @ObservedObject private var coordinator = SessionCoordinator.shared
    @AppStorage(translationOpacityKey) private var backgroundOpacity: Double = translationDefaultOpacity
    @AppStorage("rti.translation.enabled") private var translationEnabled = false
    @AppStorage("rti.translation.showOriginal") private var showOriginal = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

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
                            LazyVStack(alignment: .leading, spacing: 10) {
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
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }

            ResizeHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding([.bottom, .trailing], 6)
        }
    }

    private var header: some View {
        HStack {
            Text("Translation")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            if translationEnabled, coordinator.isRunning {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 7, height: 7)
            }

            Spacer()

            Toggle(isOn: $showOriginal) {
                Text("Show original")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.blue)

            OpacitySlider(opacity: $backgroundOpacity)
                .frame(width: 60)

            Button(action: {
                NotificationCenter.default.post(name: .rtiToggleTranslationPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }

    private var disabledHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Translation is off")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Enable translation in Live Transcript → Translation. RTI sends a translation config to Soniox and the translated stream lands here.")
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
            VStack(alignment: .leading, spacing: 4) {
                Text(speakerLabel(paragraph.speakerId))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                if !paragraph.translation.isEmpty {
                    Text(paragraph.translation)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showOriginal, !paragraph.original.isEmpty {
                    Text(paragraph.original)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
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

private struct OpacitySlider: View {
    @Binding var opacity: Double
    var body: some View {
        Slider(value: $opacity, in: 0.30...0.95, step: 0.05) {}
            .tint(.white.opacity(0.4))
            .frame(height: 12)
    }
}
