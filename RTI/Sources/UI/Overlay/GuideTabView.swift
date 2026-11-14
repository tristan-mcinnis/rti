import HouseDesign
import RTICore
import SwiftUI

struct GuideTabView: View {
    let guide: GuideDocument
    let isActive: Bool

    private let controller = GuideSessionController.shared
    @State private var showsPalette = false
    @FocusState private var readerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            OverlayTabStrip {
                overlayTabStripTitle(guide.title)
                Button(controller.isFollowing ? "Following" : "Manual") { controller.followLive() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(controller.isFollowing ? "Tracking the live question" : "Return to the live question")
                StimulusLiveControls()
                if controller.isGenerating {
                    ProgressView().controlSize(.mini)
                }
            } trailing: {
                OverlayToolbarButton(icon: "chevron.left", help: "Previous question (←)",
                                     disabled: currentIndex == 0 || currentIndex == nil) { controller.move(by: -1) }
                OverlayToolbarButton(icon: "chevron.right", help: "Next question (→)",
                                     disabled: !canAdvance) { controller.move(by: 1) }
                OverlayToolbarButton(icon: "magnifyingglass", help: "Jump to question (⌘K)") {
                    if !showsPalette { PalettePresentationTrace.begin(query: "", opening: true) }
                    showsPalette.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
                OverlayToolbarButton(icon: "arrow.clockwise", help: "Write guide notes now",
                                     disabled: controller.isGenerating || !SessionCoordinator.shared.isRunning)
                {
                    if let sessionID = SessionCoordinator.shared.currentSessionId {
                        Task { _ = await controller.generateLive(sessionId: sessionID, explicit: true) }
                    }
                }
            }
            if let error = controller.lastError {
                Text(error).font(House.TypeToken.meta).foregroundStyle(House.ColorToken.textSecondary)
            }
            GuideReadingView(
                guide: guide, currentID: controller.currentQuestionID, cells: controller.extraction?.cells ?? [],
                elapsed: { controller.elapsed(in: $0, at: $1) }, jump: { controller.jump(to: $0) },
                furthestIndex: controller.furthestIndex, visit: { controller.visitNumber(for: $0, at: $1) },
                isActive: isActive
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
                    onRun: { command in
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

/// The position and clock stay visible while the moderator browses other questions.
struct GuideReadingView: View {
    let guide: GuideDocument
    let currentID: String?
    let cells: [GuideCell]
    let elapsed: (String, Date) -> TimeInterval
    let jump: (String) -> Void
    var furthestIndex = 0
    var visit: (String, Int) -> Int = { _, _ in 1 }
    /// False while the Guide is hidden behind another view: the section
    /// clock then stops ticking.
    var isActive = true
    @State private var expandedSections: Set<String> = []
    @State private var expandedQuestions: Set<String> = []

    var body: some View {
        let questions = guide.questions
        let position = questions.firstIndex { $0.qid == currentID } ?? 0
        let reached = min(questions.count, max(position, furthestIndex) + 1)
        let order = Dictionary(uniqueKeysWithValues: questions.enumerated().map { ($0.element.qid, $0.offset) })
        let byID = Dictionary(uniqueKeysWithValues: cells.map { ($0.qid, $0) })
        let currentSection = guide.sections.first { $0.questions.contains { $0.qid == currentID } }
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            if let section = currentSection {
                tracker(section, reached: reached, total: questions.count, cells: byID)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: House.Spacing.xs) {
                        ForEach(guide.sections, id: \.id) { section in
                            let expanded = expandedSections.contains(section.id)
                            Button {
                                if expanded { expandedSections.remove(section.id) } else { expandedSections.insert(section.id) }
                            } label: {
                                HStack(spacing: House.Spacing.xs) {
                                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    Text(section.title).lineLimit(1)
                                    Spacer()
                                    let states = section.questions.map { question in
                                        status(byID[question.qid], passed: (order[question.qid] ?? 0) < reached - 1)
                                    }
                                    // Counts in words, not coloured dots (2026-11-14 review:
                                    // the dots had no legend).
                                    Text(GuideSectionSummary.text(states))
                                        .monospacedDigit()
                                        .foregroundStyle(House.ColorToken.textTertiary)
                                }
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textSecondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                            ForEach(section.questions, id: \.qid) { question in
                                let index = order[question.qid] ?? 0
                                if expanded || (position...position + 2).contains(index) {
                                    questionCard(question, section: section, cell: byID[question.qid],
                                                 passed: index < reached - 1, current: question.qid == currentID)
                                        .id(question.qid)
                                }
                            }
                        }
                    }
                    .padding(.vertical, House.Spacing.xxs)
                }
                .onChange(of: currentID) { _, id in
                    if let id { scroll.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    private func tracker(_ section: GuideDocument.Section, reached: Int, total: Int, cells: [String: GuideCell]) -> some View {
        let ordinal = (section.questions.firstIndex { $0.qid == currentID } ?? 0) + 1
        let mustAsk = section.questions.filter(\.mustAsk)
        return VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                Text(section.title).font(House.TypeToken.heading).lineLimit(1)
                Spacer(minLength: House.Spacing.xs)
                // Ticks only while the Guide shows: the view stays mounted
                // behind other views (2026-11-14).
                TimelineView(.periodic(from: .now, by: isActive ? 1 : 3600)) { clock in
                    let seconds = max(0, Int(elapsed(section.id, clock.date)))
                    let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
                    if let plan = section.minutes {
                        let over = seconds > plan * 60
                        HStack(spacing: House.Spacing.xxs) {
                            if over { SlateStatusDot(color: House.ColorToken.danger) }
                            Text("\(time) / \(plan) min\(over ? " · over" : "")").font(House.TypeToken.meta).monospacedDigit()
                        }.accessibilityElement(children: .combine)
                    } else {
                        Text("\(time) elapsed").font(House.TypeToken.meta).monospacedDigit()
                    }
                }
            }
            Text("Question \(ordinal) of \(section.questions.count) · \(reached) of \(total) reached")
                .font(House.TypeToken.meta).foregroundStyle(House.ColorToken.textSecondary)
            ProgressView(value: Double(reached), total: Double(max(1, total)))
                .accessibilityLabel("Overall guide progress")
            if !mustAsk.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: House.Spacing.xs) {
                        Text("Must ask").font(House.TypeToken.meta)
                        ForEach(mustAsk, id: \.qid) { q in
                            let covered = cells[q.qid]?.coverage == "Answered"
                            Button { jump(q.qid) } label: {
                                HStack(spacing: House.Spacing.xxs) {
                                    Image(systemName: covered ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(covered ? House.ColorToken.success : House.ColorToken.textTertiary)
                                    Text(q.qid)
                                }
                                .font(House.TypeToken.meta)
                                .padding(.horizontal, House.Spacing.xs)
                                .background(House.ColorToken.chipFill, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(q.qid), \(covered ? "covered" : "still to ask")")
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }
        .padding(.bottom, House.Spacing.xs)
    }

    private func status(_ cell: GuideCell?, passed: Bool) -> String {
        cell?.displayCoverage(passed: passed) ?? (passed ? "Skipped" : "Pending")
    }

    private func questionCard(_ question: GuideDocument.Question, section: GuideDocument.Section, cell: GuideCell?,
                              passed: Bool, current: Bool) -> some View {
        let expanded = expandedQuestions.contains(question.qid)
        let quotes = cell?.orderedQuotes ?? []
        return VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            HStack(spacing: House.Spacing.xs) {
                Button { jump(question.qid) } label: {
                    HStack {
                        Text(question.qid).font(House.TypeToken.code)
                        Text(guide.header(for: question, in: section)).font(House.TypeToken.label)
                        Spacer()
                        Text(status(cell, passed: passed)).font(House.TypeToken.meta)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityHint("Select this question manually")
                Button {
                    if expanded { expandedQuestions.remove(question.qid) } else { expandedQuestions.insert(question.qid) }
                } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Show compact question" : "Expand question and evidence")
            }
            if !question.en.isEmpty { Text(question.en).font(current ? House.TypeToken.heading : House.TypeToken.bodySmall).lineLimit(current || expanded ? nil : 1) }
            if (current || expanded) && !question.zh.isEmpty { Text(question.zh).font(House.TypeToken.bodySmall) }
            if current || expanded {
                ForEach(question.probes.indices, id: \.self) { index in
                    let probe = question.probes[index]
                    Text([probe.en, probe.zh].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(House.TypeToken.meta).foregroundStyle(House.ColorToken.textSecondary)
                }
                ForEach(expanded ? quotes : Array(quotes.suffix(3)), id: \.turnID) { quote in
                    let visitNumber = visit(question.qid, quote.offsetMs)
                    let revisit = visitNumber > 1 ? " · Visit " + String(visitNumber) : ""
                    Text("\(quote.locator) · \(quote.speakerLabel)\(revisit)  \(quote.original)")
                        .font(House.TypeToken.bodySmall).textSelection(.enabled)
                }
                if expanded, let cell, !cell.summary.isEmpty { Text(cell.summary).font(House.TypeToken.bodySmall) }
                if let tally = cell?.tally { Text(tally).font(House.TypeToken.meta) }
            }
        }
        .padding(current ? House.Spacing.sm : House.Spacing.xs)
        .slateRaisedTile(current)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// A section's question states as one quiet line: "9 answered · 1 thin · 8 to ask".
enum GuideSectionSummary {
    static let words = [("Answered", "answered"), ("Lightly covered", "thin"), ("Skipped", "skipped"), ("Pending", "to ask")]

    static func text(_ states: [String]) -> String {
        words.compactMap { state, word in
            let count = states.filter { $0 == state }.count
            return count > 0 ? "\(count) \(word)" : nil
        }.joined(separator: " · ")
    }
}
