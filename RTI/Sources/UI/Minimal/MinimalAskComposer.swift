import SwiftUI

/// Answer stream + ask composer. `LLMController` appends one token delta at
/// a time directly onto the streaming entry's `text` with no coalescing
/// (see docs/ux-audit-20260819.md section 5), so this view buffers on its
/// own 50ms poll while streaming: paragraphs before the last "\n\n" are
/// "settled" and rendered once via `RTIMarkdown` (stable id + unchanged
/// content means SwiftUI skips re-diffing them); only the tail paragraph is
/// recomputed each tick.
struct MinimalAskComposer: View {
    @State private var input = ""
    @State private var settledParagraphs: [String] = []
    @State private var tailParagraph = ""
    @State private var pollTask: Task<Void, Never>?
    @State private var lastScrollAt = Date.distantPast

    private let answerBottomID = "minimal-answer-bottom"

    var body: some View {
        let controller = LLMController.shared

        VStack(alignment: .leading, spacing: 16) {
            if !settledParagraphs.isEmpty || !tailParagraph.isEmpty {
                answerRegion
                    .transition(.opacity)
                    .animation(Motion.answerReveal, value: tailParagraph)
            }

            composerRow(controller: controller)
        }
        .onChange(of: controller.streaming) { _, streaming in
            if streaming {
                startPolling(controller)
            } else {
                stopPolling(controller)
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Answer region

    private var answerRegion: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(settledParagraphs.enumerated()), id: \.offset) { _, paragraph in
                        RTIMarkdown(paragraph, style: .overlay)
                    }
                    if !tailParagraph.isEmpty {
                        RTIMarkdown(tailParagraph, style: .overlay)
                            .id(answerBottomID)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 200)
            .onChange(of: tailParagraph) { _, _ in
                let now = Date()
                guard now.timeIntervalSince(lastScrollAt) >= 0.25 else { return }
                lastScrollAt = now
                proxy.scrollTo(answerBottomID, anchor: .bottom)
            }
        }
    }

    // MARK: - Composer

    private func composerRow(controller: LLMController) -> some View {
        HStack(spacing: 8) {
            TextField("Ask about this meeting", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.inkPrimary)
                .lineLimit(1...4)
                .onSubmit { submit(controller) }

            Button {
                if controller.streaming {
                    controller.cancel()
                } else {
                    submit(controller)
                }
            } label: {
                Image(systemName: controller.streaming ? "stop.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.accentSolid)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(Motion.recordState, value: controller.streaming)
            }
            .buttonStyle(.plain)
            .pressable()
            .accessibilityLabel(controller.streaming ? "Stop answer" : "Send question")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surfaceInput)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.borderHairline)
        )
    }

    private func submit(_ controller: LLMController) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !controller.streaming else { return }
        controller.sendAskAnything(trimmed)
        input = ""
    }

    // MARK: - 50ms coalescing poll

    private func startPolling(_ controller: LLMController) {
        pollTask?.cancel()
        settledParagraphs = []
        tailParagraph = ""
        pollTask = Task { @MainActor in
            while !Task.isCancelled, controller.streaming {
                applyLatestText(controller)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func stopPolling(_ controller: LLMController) {
        pollTask?.cancel()
        pollTask = nil
        applyLatestText(controller)
    }

    private func applyLatestText(_ controller: LLMController) {
        guard let text = controller.entries.last(where: { $0.role == "assistant" })?.text,
              !text.isEmpty else { return }
        var paragraphs = text.components(separatedBy: "\n\n")
        let tail = paragraphs.popLast() ?? ""
        settledParagraphs = paragraphs
        tailParagraph = tail
    }
}
