import HouseDesign
import RTICore
import SwiftUI

struct GuideTabView: View {
    let guide: GuideDocument
    let isActive: Bool

    private let controller = GuideSessionController.shared
    @State private var showsPalette = false
    @State private var query = ""
    @FocusState private var readerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            OverlayTabStrip {
                overlayTabStripTitle(guide.title)
                if controller.isGenerating {
                    ProgressView().controlSize(.mini)
                }
            } trailing: {
                OverlayToolbarButton(icon: "chevron.left", help: "Previous question (←)",
                                     disabled: currentIndex == 0 || currentIndex == nil) { controller.move(by: -1) }
                OverlayToolbarButton(icon: "chevron.right", help: "Next question (→)",
                                     disabled: !canAdvance) { controller.move(by: 1) }
                OverlayToolbarButton(icon: "magnifyingglass", help: "Jump to question (⌘K)") {
                    query = ""
                    showsPalette.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                OverlayToolbarButton(icon: "arrow.clockwise", help: "Write guide notes now",
                                     disabled: controller.isGenerating || !SessionCoordinator.shared.isRunning)
                {
                    if let sessionID = SessionCoordinator.shared.currentSessionId {
                        Task { _ = await NotesGenerationController.shared.generate(sessionId: sessionID) }
                    }
                }
            }
            if let error = controller.lastError {
                Text(error).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.textSecondary)
            }
            GuideReadingView(
                guide: guide, currentID: controller.currentQuestionID, cells: controller.extraction?.cells ?? [],
                elapsed: { controller.elapsed(in: $0, at: $1) }, jump: { controller.jump(to: $0) }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusable()
        .focusEffectDisabled()
        .focused($readerFocused)
        .onChange(of: isActive && !showsPalette, initial: true) { _, focus in
            readerFocused = focus
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { event in
            guard isActive, !showsPalette, event.modifiers.isEmpty else { return .ignored }
            controller.move(by: event.key == .rightArrow ? 1 : -1)
            return .handled
        }
        .overlay(alignment: .topTrailing) {
            if showsPalette {
                CommandPaletteView(
                    query: $query, onRun: { command in
                        showsPalette = false
                        command.perform()
                    }, onClose: { showsPalette = false },
                    leadingCommands: CommandBuilder.guideCommands(), maxVisibleRows: 4
                )
                .frame(maxWidth: HouseChatMetrics.paletteWidth)
                .panelGlass(radius: House.Radius.lg)
                .panelShadows()
                .padding(House.Spacing.xs)
            }
        }
    }

    private var currentIndex: Int? {
        guide.questions.firstIndex { $0.qid == controller.currentQuestionID }
    }

    private var canAdvance: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < guide.questions.count
    }
}

/// The ordered guide and its captured evidence; timers update only their own labels.
struct GuideReadingView: View {
    let guide: GuideDocument
    let currentID: String?
    let cells: [GuideCell]
    let elapsed: (String, Date) -> TimeInterval
    let jump: (String) -> Void

    var body: some View {
        let byQuestion = Dictionary(uniqueKeysWithValues: cells.map { ($0.qid, $0) })
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: House.Spacing.xs) {
                    ForEach(guide.sections, id: \.id) { section in
                        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                            Text(section.title)
                                .font(House.TypeToken.heading)
                                .foregroundStyle(House.ColorToken.textPrimary)
                            Spacer(minLength: House.Spacing.xs)
                            if let planned = section.minutes {
                                TimelineView(.periodic(from: .now, by: 1)) { clock in
                                    let seconds = max(0, Int(elapsed(section.id, clock.date)))
                                    Text(String(format: "%d:%02d / %d min", seconds / 60, seconds % 60, planned))
                                        .font(House.TypeToken.meta).monospacedDigit()
                                        .foregroundStyle(House.ColorToken.textSecondary)
                                        .accessibilityLabel("\(seconds / 60) minutes elapsed of \(planned) planned")
                                }
                            }
                        }
                        .padding(.top, House.Spacing.xs)
                        ForEach(section.questions, id: \.qid) { question in
                            questionRow(question, cell: byQuestion[question.qid]).id(question.qid)
                        }
                    }
                }
            }
            .onChange(of: currentID, initial: true) { _, id in
                if let id {
                    scroll.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func questionRow(_ question: GuideDocument.Question, cell: GuideCell?) -> some View {
        let active = question.qid == currentID
        let answered = cell?.coverage == "Answered"
        return VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            Button { jump(question.qid) } label: {
                HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                    if question.mustAsk {
                        Image(systemName: answered ? "checkmark.square" : "square")
                            .accessibilityLabel(answered ? "Must ask, answered" : "Must ask, outstanding")
                    }
                    VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                        HStack(spacing: House.Spacing.xs) {
                            Text(question.qid).font(House.TypeToken.code)
                            if active {
                                Text("Current").font(House.TypeToken.label)
                            }
                            if let cell, cell.coverage != "Not covered" {
                                Text(cell.coverage).font(House.TypeToken.meta)
                            }
                        }
                        .foregroundStyle(House.ColorToken.textSecondary)
                        if !question.en.isEmpty {
                            Text(question.en).font(House.TypeToken.label)
                        }
                        if !question.zh.isEmpty {
                            Text(question.zh).font(House.TypeToken.bodySmall)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Set as current question")
            .accessibilityAddTraits(active ? .isSelected : [])
            if active {
                ForEach(question.probes.indices, id: \.self) { index in
                    let probe = question.probes[index]
                    Text([probe.en, probe.zh].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
            }
            if let cell, cell.coverage != "Not covered" {
                if !cell.summary.isEmpty {
                    Text(cell.summary).font(House.TypeToken.bodySmall)
                }
                ForEach(cell.quotes.indices, id: \.self) { index in
                    let quote = cell.quotes[index]
                    Text("\(quote.locator) · \(quote.participant)  \(quote.original)")
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .textSelection(.enabled)
                }
                if let tally = cell.tally {
                    Text(tally).font(House.TypeToken.label)
                }
            }
        }
        .foregroundStyle(House.ColorToken.textPrimary)
        .padding(House.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .slateRaisedTile(active)
    }
}
