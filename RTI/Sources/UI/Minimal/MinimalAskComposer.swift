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
    @State private var historyTurns: [HistoryTurn] = []
    @State private var settledParagraphs: [String] = []
    @State private var tailParagraph = ""
    @State private var pollTask: Task<Void, Never>?
    @State private var lastScrollAt = Date.distantPast

    private let answerBottomID = "minimal-answer-bottom"

    var body: some View {
        let controller = LLMController.shared
        let auto = AutoAssistController.shared

        VStack(alignment: .leading, spacing: 16) {
            if !auto.cards.isEmpty {
                autoAssistChips(auto: auto, controller: controller)
            }

            if !historyTurns.isEmpty
                || (controller.streaming && (!settledParagraphs.isEmpty || !tailParagraph.isEmpty)) {
                answerRegion(controller: controller)
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
                // The final delta usually lands before streaming flips, so
                // the last onChange(entries) ran with the answer still
                // classified as live — resync now that it is history.
                syncHistory(controller)
            }
        }
        .onChange(of: controller.entries) { _, _ in
            syncHistory(controller)
        }
        .onAppear { syncHistory(controller) }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Auto-assist chips (opt-in, Settings -> "Suggest follow-up questions")

    /// Proactive suggestions from `AutoAssistController`, rendered as
    /// dismissable chips. Tapping a chip sends its text as the question;
    /// the trailing x dismisses without asking.
    private func autoAssistChips(auto: AutoAssistController, controller: LLMController) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(auto.cards) { card in
                    chip(card, auto: auto, controller: controller)
                }
            }
        }
    }

    private func chip(_ card: AutoAssistCard, auto: AutoAssistController, controller: LLMController) -> some View {
        HStack(spacing: 4) {
            Button {
                auto.dismiss(card.id)
                controller.sendAskAnything(card.text)
            } label: {
                Text(card.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkPrimary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Button {
                auto.dismiss(card.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.inkFaint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Palette.surfaceRaised)
        )
        .overlay(
            Capsule().strokeBorder(Palette.borderHairline)
        )
        .pressable()
    }

    // MARK: - Answer region

    private func answerRegion(controller: LLMController) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(historyTurns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            turnHeader(turn)
                            RTIMarkdown(turn.answer)
                        }
                        .id(turn.id)
                    }
                    if controller.streaming {
                        ForEach(Array(settledParagraphs.enumerated()), id: \.offset) { _, paragraph in
                            RTIMarkdown(paragraph)
                        }
                        if !tailParagraph.isEmpty {
                            RTIMarkdown(tailParagraph)
                        }
                    }
                    Color.clear.frame(height: 1).id(answerBottomID)
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 200)
            .onChange(of: tailParagraph) { _, _ in
                autoscroll(proxy)
            }
            .onChange(of: historyTurns.count) { _, _ in
                autoscroll(proxy)
            }
        }
    }

    /// Throttled scroll-to-bottom shared by stream deltas and new turns.
    private func autoscroll(_ proxy: ScrollViewProxy) {
        let now = Date()
        guard now.timeIntervalSince(lastScrollAt) >= 0.25 else { return }
        lastScrollAt = now
        proxy.scrollTo(answerBottomID, anchor: .bottom)
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

    // MARK: - Turn history

    /// One completed Q&A pair in the scrollback, derived from the ephemeral
    /// entries buffer on LLMController (the same one SessionArchive writes
    /// out at session end). Explicit asks show their question text;
    /// hotkey-driven prompts ("Say next", "Recap", ...) show the action
    /// label instead of their internal prompt text.
    private struct HistoryTurn: Identifiable, Equatable {
        let id: UUID
        let question: String?
        let actionLabel: String?
        let answer: String
    }

    @ViewBuilder
    private func turnHeader(_ turn: HistoryTurn) -> some View {
        if let question = turn.question {
            Text(question)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
        } else if let label = turn.actionLabel {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.inkFaint)
        }
    }

    /// Rebuild the scrollback from the controller entries. While streaming
    /// the last assistant entry is live and rendered by the settled/tail
    /// poll instead. The equality guard keeps finished rows from
    /// re-rendering on token ticks.
    private func syncHistory(_ controller: LLMController) {
        var visible = controller.entries
        if controller.streaming, let last = visible.last, last.role == "assistant" {
            visible.removeLast()
        }
        var turns: [HistoryTurn] = []
        var pendingQuestion: String?
        var pendingAction: String?
        for entry in visible {
            if entry.role == "user" {
                pendingQuestion = entry.action == "Ask" ? entry.text : nil
                pendingAction = entry.action
            } else if !entry.text.isEmpty {
                turns.append(HistoryTurn(
                    id: entry.id,
                    question: pendingQuestion,
                    actionLabel: pendingAction,
                    answer: entry.text
                ))
                pendingQuestion = nil
                pendingAction = nil
            }
        }
        if turns != historyTurns {
            historyTurns = turns
        }
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
