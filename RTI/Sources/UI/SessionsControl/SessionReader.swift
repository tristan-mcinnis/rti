import AppKit
import HouseDesign
import RTICore
import SwiftUI

// MARK: - Reader

/// The open file in one centred reading column.
struct SessionReader: View {
    @Bindable var model: SessionsWindowModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: SessionsBrowserView.columnWidth, alignment: .leading)
                    .padding(.top, House.Spacing.md)
                    .padding(.horizontal, House.Spacing.lg)
                    .padding(.bottom, House.Spacing.xl)
                    .frame(maxWidth: .infinity)
            }
            .onChange(of: model.currentFindHit) { _, hit in
                guard let hit else { return }
                withAnimation(.easeOut(duration: House.Motion.select)) {
                    proxy.scrollTo(hit.block, anchor: UnitPoint(x: 0.5, y: 0.33))
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEditingTranscript {
            TranscriptEditor(model: model)
        } else {
            switch model.document {
            case .empty:
                Text("This file is empty.")
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textTertiary)
            case let .transcript(turns):
                SessionTranscriptReader(turns: turns, model: model)
            case let .chat(turns):
                ArchivedChatThread(turns: turns, model: model)
            case let .markdown(blocks):
                MarkdownBlocks(blocks: blocks, offset: 0, model: model)
            case let .log(text):
                let marks = model.findHighlights(inBlock: 0)
                Text(highlighted(text, marks.all, marks.current))
                    .font(House.TypeToken.code)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(0)
            case let .frames(directory):
                SessionFramesGallery(directory: directory)
            }
        }
    }
}

/// `text` with every find hit on `hoverFill` and the current one on
/// `selectionFill`.
private func highlighted(_ text: String, _ all: [Range<String.Index>], _ current: Range<String.Index>?) -> AttributedString {
    var attributed = AttributedString(text)
    for range in all {
        guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
        attributed[lower ..< upper].backgroundColor = range == current
            ? House.ColorToken.selectionFill
            : House.ColorToken.hoverFill
    }
    return attributed
}

/// A block with a find hit: `hoverFill` behind it, the house selection
/// behind the block that holds the current hit. MarkdownUI cannot mark a
/// word, so Markdown files mark the block (transcripts and chat questions
/// mark the word).
private struct FindBlockMark: ViewModifier {
    let hasHit: Bool
    let isCurrent: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, hasHit ? House.Spacing.xs : 0)
            .padding(.vertical, hasHit ? House.Spacing.xxs : 0)
            .background {
                if hasHit {
                    RowHighlight(isSelected: isCurrent, isHovering: !isCurrent, radius: House.Radius.sm)
                }
            }
    }
}

private struct MarkdownBlocks: View {
    let blocks: [String]
    /// Index of the first block in the document's block list.
    let offset: Int
    let model: SessionsWindowModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: House.Spacing.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let marks = model.findHighlights(inBlock: offset + index)
                RTIMarkdown(block, style: .panel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(FindBlockMark(hasHit: !marks.all.isEmpty, isCurrent: marks.current != nil))
                    .id(offset + index)
            }
        }
    }
}

// MARK: - Transcript reader

/// Transcript rows as on the live surface: no box per speaker. A run of turns
/// by one speaker carries one quiet label line (the speaker's dot, the name,
/// the time); the turns under it are plain `bodySmall` text at line height
/// 1.5, capped at the reading width.
private struct SessionTranscriptReader: View {
    let turns: [SessionTranscriptTurn]
    let model: SessionsWindowModel

    static let lineSpacing: CGFloat = {
        let font = NSFont.systemFont(ofSize: House.TypeToken.Size.bodySmall)
        let native = font.ascender - font.descender + font.leading
        return max(0, House.TypeToken.Size.bodySmall * House.TypeToken.LineHeight.bodySmall - native)
    }()

    var body: some View {
        if turns.isEmpty {
            Text("No transcript turns found.")
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                    let marks = model.findHighlights(inBlock: index)
                    let opensRun = startsRun(at: index)
                    VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                        if opensRun {
                            label(turn)
                        }
                        Text(highlighted(turn.text, marks.all, marks.current))
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(turn.isNote ? House.ColorToken.textSecondary : House.ColorToken.textPrimary)
                            .lineSpacing(Self.lineSpacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, index == 0 ? 0 : (opensRun ? House.Spacing.lg : House.Spacing.sm))
                    .id(index)
                }
            }
        }
    }

    /// A label line opens each run: a change of speaker, and every note.
    private func startsRun(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let turn = turns[index]
        let previous = turns[index - 1]
        return turn.isNote || previous.isNote || turn.speaker != previous.speaker
    }

    private func label(_ turn: SessionTranscriptTurn) -> some View {
        HStack(spacing: House.Spacing.xs) {
            if turn.isNote {
                Image(systemName: "note.text")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .accessibilityHidden(true)
            } else {
                SlateStatusDot(color: speakerColor(turn))
            }
            Text(turn.isNote ? "Note" : turn.speaker)
                .font(House.TypeToken.meta.weight(.medium))
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
            Text(turn.timestamp)
                .font(House.TypeToken.caption)
                .foregroundStyle(House.ColorToken.textTertiary)
                .monospacedDigit()
        }
        .frame(minHeight: House.Control.keyCap)
    }

    /// Speaker colours are data (DESIGN.md: RTI's one categorical palette),
    /// the same colour the live transcript gave the speaker: the label, or
    /// the label a confirmed name stands for, maps back to its speaker id.
    /// A note has no speaker, so its dot is plain ink.
    private func speakerColor(_ turn: SessionTranscriptTurn) -> Color {
        guard !turn.isNote else { return House.ColorToken.textTertiary }
        let label = model.speakerNames.first { $0.value == turn.speaker }?.key ?? turn.speaker
        guard let raw = SpeakerLabelMapping.rawKey(forDisplayLabel: label) else {
            return House.ColorToken.textTertiary
        }
        return SpeakerLabels.chipColor(for: raw)
    }
}

// MARK: - Archived chat (thread grammar, read only)

/// A past Assist chat as it looked live: the question as a pill on the
/// right (a canned action shows its name and glyph, never its prompt), the
/// context it used as tool lines, then the answer as prose with no card.
private struct ArchivedChatThread: View {
    let turns: [ArchivedChatTurn]
    let model: SessionsWindowModel

    var body: some View {
        LazyVStack(alignment: .leading, spacing: House.Spacing.md) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                Group {
                    if turn.role == .user {
                        question(turn, index: index)
                    } else {
                        answer(turn, index: index, askedBy: index > 0 ? turns[index - 1] : nil)
                    }
                }
                .id(index)
            }
        }
    }

    private func question(_ turn: ArchivedChatTurn, index: Int) -> some View {
        let marks = model.findHighlights(inBlock: index)
        return VStack(alignment: .trailing, spacing: House.Spacing.xs) {
            if !turn.referencedPaths.isEmpty {
                HStack(spacing: House.Spacing.xs) {
                    ForEach(turn.referencedPaths, id: \.self) { path in
                        HouseChip(text: (path as NSString).lastPathComponent, icon: "doc.text")
                            .help(path)
                    }
                }
            }
            HStack(spacing: House.Spacing.xs) {
                if turn.action != nil, !turn.text.hasPrefix("/") {
                    Image(systemName: "sparkles")
                        .font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .accessibilityHidden(true)
                }
                Text(highlighted(turn.pillText, marks.all, marks.current))
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, House.Spacing.sm)
            .padding(.vertical, House.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
                    .fill(House.ColorToken.chipFill)
            )
            .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(turn.pillText)")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func answer(_ turn: ArchivedChatTurn, index: Int, askedBy question: ArchivedChatTurn?) -> some View {
        let marks = model.findHighlights(inBlock: index)
        return VStack(alignment: .leading, spacing: House.Spacing.xs) {
            if let question, question.role == .user {
                VStack(alignment: .leading, spacing: House.Spacing.xs) {
                    if question.usedTranscript {
                        toolLine("waveform", "Used the transcript")
                    }
                    if question.usedScreen {
                        toolLine("camera.viewfinder", "Read the screen")
                    }
                }
            }
            RTIMarkdown(turn.text, style: .panel)
                .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .leading)
                .modifier(FindBlockMark(hasHit: !marks.all.isEmpty, isCurrent: marks.current != nil))
        }
    }

    private func toolLine(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: symbol)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .frame(width: House.Control.keyCap)
            Text(text)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
        }
        .frame(minHeight: House.Control.keyCap)
        .accessibilityElement(children: .combine)
    }
}
