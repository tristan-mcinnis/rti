import RTICore
import SwiftUI

/// Vertical alignment key that centers a dot on a text run's cap-height
/// (roughly the visual middle of a capital letter), not its full line box.
/// Cap height is approximated as 0.72 of the point size, which matches SF
/// Pro closely enough for an 8pt chip dot; there is no public API to read
/// the exact glyph metric from a `Font` in SwiftUI.
private struct CapHeightAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.center]
    }
}

private extension VerticalAlignment {
    static let capHeightCenter = VerticalAlignment(CapHeightAlignment.self)
}

private func approximateCapHeight(fontSize: CGFloat) -> CGFloat {
    fontSize * 0.72
}

/// Live transcript surface: speaker turn rows with a colored chip, an
/// italic interim line, and an empty state. Rows are coalesced
/// incrementally — only the tail of `liveEntries` past what's already been
/// consumed is processed on each change, never the whole array.
struct MinimalTranscriptView: View {
    private struct Row: Identifiable {
        let id: UUID
        let speakerId: String
        let label: String
        let startMs: Int
        var text: String
        let isNote: Bool
        let speakerIndex: Int
    }

    @State private var rows: [Row] = []
    @State private var processedCount = 0
    @State private var speakerIndexMap: [String: Int] = [:]
    @State private var nextSpeakerIndex = 0
    @State private var isAtBottom = true
    @State private var lastScrollAt = Date.distantPast

    private let bottomAnchorID = "minimal-transcript-bottom"

    var body: some View {
        let coordinator = SessionCoordinator.shared
        let interim = interimText(coordinator.interimLine)

        Group {
            if rows.isEmpty, interim == nil {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(rows) { row in
                                rowView(row)
                            }
                            if let interim {
                                interimRow(interim)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .onAppear { isAtBottom = true }
                                .onDisappear { isAtBottom = false }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: coordinator.liveEntries.count) { _, _ in
                        syncRows(coordinator.liveEntries)
                        followIfAtBottom(proxy)
                    }
                    .onChange(of: coordinator.interimLine) { _, _ in
                        followIfAtBottom(proxy)
                    }
                    .onAppear {
                        syncRows(coordinator.liveEntries)
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 240)
    }

    // MARK: - Rows

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .capHeightCenter, spacing: 8) {
            Circle()
                .fill(row.isNote ? Palette.stateWarn : Palette.speakerChip(index: row.speakerIndex))
                .frame(width: 8, height: 8)
                .alignmentGuide(.capHeightCenter) { $0[VerticalAlignment.center] }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.inkSecondary)
                        .alignmentGuide(.capHeightCenter) {
                            $0[VerticalAlignment.firstTextBaseline] - approximateCapHeight(fontSize: 12) / 2
                        }
                    Text(timeString(row.startMs))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Palette.inkFaint)
                }
                Text(row.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.inkPrimary)
                    .textSelection(.enabled)
            }
        }
        .opacity(1)
        .animation(Motion.transcriptAppend, value: row.text)
        .id(row.id)
    }

    private func interimRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Palette.inkFaint)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            Text(text)
                .font(.system(size: 13).italic())
                .foregroundStyle(Palette.inkFaint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("Nothing yet")
                .font(.system(size: 13))
                .foregroundStyle(Palette.inkFaint)
            Button("Start recording") {
                SessionCoordinator.shared.startSession(userInitiated: true)
            }
            .buttonStyle(.borderedProminent)
            .pressable()
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Incremental coalescing

    /// Only walks `entries[processedCount...]` — never re-runs presentation
    /// over the whole transcript. Mirrors the merge rule in
    /// `LiveTranscriptPresentation.rows(from:)` (same speaker, non-note,
    /// contiguous → merge into the last row) but applied to the tail only.
    /// Translation rows are not shown in the minimal transcript (scope cut —
    /// the minimal UI has no translation surface).
    private func syncRows(_ entries: [LiveEntry]) {
        guard entries.count > processedCount else { return }
        for entry in entries[processedCount...] {
            appendOrMerge(entry)
        }
        processedCount = entries.count
    }

    private func appendOrMerge(_ entry: LiveEntry) {
        guard entry.translationStatus != "translation" else { return }
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let canMerge = !entry.speakerId.isEmpty
            && entry.speakerId != "note"
            && rows.last?.speakerId == entry.speakerId

        if canMerge, let lastIndex = rows.indices.last {
            rows[lastIndex].text += (rows[lastIndex].text.isEmpty ? "" : " ") + text
        } else {
            rows.append(Row(
                id: entry.id,
                speakerId: entry.speakerId,
                label: SpeakerLabels.displayName(for: entry.speakerId),
                startMs: entry.startMs,
                text: text,
                isNote: entry.speakerId == "note",
                speakerIndex: speakerIndex(for: entry.speakerId)
            ))
        }
    }

    private func speakerIndex(for speakerId: String) -> Int {
        if let existing = speakerIndexMap[speakerId] { return existing }
        let index = nextSpeakerIndex
        speakerIndexMap[speakerId] = index
        nextSpeakerIndex += 1
        return index
    }

    // MARK: - Scroll follow (throttled to 1 seek / 250ms, only at bottom)

    private func followIfAtBottom(_ proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        let now = Date()
        guard now.timeIntervalSince(lastScrollAt) >= 0.25 else { return }
        lastScrollAt = now
        withAnimation(Motion.transcriptAppend) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    // MARK: - Formatting

    private func interimText(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let display = LiveTranscriptPresentation.displayInterim(raw)
        return display.isEmpty ? nil : display
    }

    private func timeString(_ ms: Int) -> String {
        let totalSeconds = max(0, ms / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
