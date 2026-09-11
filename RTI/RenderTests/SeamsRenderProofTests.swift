import AppKit
import RTICore
import SwiftUI
import XCTest

/// Package 0 ("seams") proofs: the copied house chat primitives drawn on one
/// sheet, and checks that the shared harness keeps every proof on the
/// fixture vault. PNG prefix `seams-`.
final class SeamsRenderProofTests: RenderProofTestCase {
    // MARK: - Render proofs

    func testPrimitivesSheet() throws {
        try renderBothAppearances(
            name: "seams-primitives",
            size: CGSize(width: 700, height: 760),
            view: PrimitivesSheet()
        )
    }

    func testPrimitivesSheetAtMinimumWidth() throws {
        try renderBothAppearances(
            name: "seams-primitives-minimum-width",
            size: CGSize(width: OverlayAppearanceDefaults.widthRange.lowerBound, height: 760),
            view: PrimitivesSheet()
        )
    }

    // MARK: - Seam checks

    /// The Sessions list must come from the fixture vault, never the real one.
    func testSessionsListReadsOnlyTheFixtureVault() throws {
        let root = try XCTUnwrap(FixtureVault.root).resolvingSymlinksInPath().path
        let sessions = SessionArchive.recentSessions(limit: 100)

        XCTAssertEqual(sessions.count, FixtureVault.sessions.count + 1, "five archived sessions plus one recorded meeting")
        for session in sessions {
            XCTAssertTrue(
                session.url.resolvingSymlinksInPath().path.hasPrefix(root),
                "\(session.url.path) is outside the fixture vault"
            )
        }
        XCTAssertEqual(
            sessions.compactMap(\.title).sorted(),
            ["Onboarding Scope Review with Northwind", "Pricing page teardown", "Quarterly planning sync"]
        )
    }

    /// Every settings pane has its own title and `⌘`-number, in rail order.
    func testSettingsPanesHaveUniqueTitlesAndNumbers() {
        let panes = SettingsView.SettingsTab.allCases
        XCTAssertEqual(panes.map(\.number), Array(1...panes.count))
        XCTAssertEqual(Set(panes.map(\.label)).count, panes.count)
    }
}

// MARK: - The sheet

/// Every primitive in `HouseChatPrimitives.swift`, laid out the way the
/// thread, composer, and header will use it. Content is invented.
private struct PrimitivesSheet: View {
    private var records: [ChatEntry] { RenderFixtures.turnsWithRecords }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            liveHeader
            HouseDivider()
            titleForms
            HouseDivider()
            threadPieces
            HouseDivider()
            rows
            HStack(alignment: .top, spacing: House.Spacing.md) {
                chooser
                VStack(alignment: .leading, spacing: House.Spacing.sm) {
                    HouseChip(text: "Latest", icon: "arrow.down")
                        .raisedCard(radius: House.Radius.sm, fill: House.ColorToken.surfaceRaised)
                        .houseShadow(House.Shadow.card)
                    Button("Open Settings") {}
                        .buttonStyle(InkButtonStyle())
                    KeyCapGroup(keys: ["esc"])
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.vertical, House.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(House.ColorToken.surface)
    }

    /// Header, live form (spec section 8): rail toggle, title over a state
    /// line, one live action on the right.
    private var liveHeader: some View {
        HStack(spacing: House.Spacing.sm) {
            QuickAIGlyphButton(
                symbol: "sidebar.left",
                font: HouseChatType.glyphSmall,
                color: House.ColorToken.textSecondary,
                label: "Session list",
                help: "Show session list (⌃⌘S)",
                accessibilityValue: "Closed"
            ) {}
            HouseTitleBlock(
                title: "Onboarding Scope Review with Northwind",
                line: [
                    .status("Recording · 12:41", color: House.ColorToken.danger),
                    .button(HouseTitleButton(
                        title: "DeepSeek V4 Flash",
                        accessibilityLabel: "Model: DeepSeek V4 Flash",
                        accessibilityHint: "Change the model",
                        help: "Change model",
                        isOpen: false,
                        action: {}
                    )),
                    .button(HouseTitleButton(
                        title: "Meeting",
                        emphasised: true,
                        accessibilityLabel: "Mode: Meeting",
                        accessibilityHint: "Change the mode",
                        help: "Change mode",
                        action: {}
                    )),
                ]
            )
            Spacer(minLength: House.Spacing.xs)
            KeyHint(label: "Finish", keys: ["⌘", "⇧", "R"])
        }
        .frame(height: House.Control.composer)
    }

    /// The other two title forms: Quick AI (assistant then model) and a
    /// source line of plain text (the Sessions reader).
    private var titleForms: some View {
        HStack(alignment: .top, spacing: House.Spacing.xl) {
            HouseTitleBlock(
                title: "Quick AI",
                line: [
                    .button(HouseTitleButton(
                        title: "Researcher", emphasised: true,
                        accessibilityLabel: "Assistant: Researcher", accessibilityHint: "Change the assistant",
                        help: "Change assistant", action: {}
                    )),
                    .button(HouseTitleButton(
                        title: "DeepSeek V4 Pro",
                        accessibilityLabel: "Model: DeepSeek V4 Pro", accessibilityHint: "Change the model",
                        help: "Change model", action: {}
                    )),
                ]
            )
            HouseTitleBlock(
                title: "Pricing page teardown",
                line: [.text("Today · 15:00"), .text("16 min"), .text("Northwind app")]
            )
        }
    }

    /// Thread pieces: a status line with the thinking dots, the tool lines
    /// from a turn record, attachment kind glyphs, and a Retry hint.
    private var threadPieces: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            toolLine(text: "Searching the vault…") {
                ThinkingIndicator()
            }
            ForEach(Array((records.last?.tools ?? []).enumerated()), id: \.offset) { _, tool in
                toolLine(text: tool.text) {
                    Image(systemName: tool.kind.symbolName)
                        .font(House.TypeToken.bodySmall)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
            }
            HStack(spacing: House.Spacing.sm) {
                ForEach(Array((records.first?.attachments ?? []).enumerated()), id: \.offset) { _, ref in
                    HStack(spacing: House.Spacing.xxs) {
                        Image(systemName: ref.kind.symbolName)
                            .font(House.TypeToken.caption)
                            .foregroundStyle(House.ColorToken.textSecondary)
                        Text(ref.name)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
            HStack {
                Text("The provider is busy. Try again in a moment.")
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.danger)
                Spacer(minLength: House.Spacing.xs)
                KeyHint(label: "Retry", keys: ["⌘", "R"])
            }
            Text(records.last?.text ?? "")
                .font(House.TypeToken.body)
                .lineSpacing(HouseChatType.proseLineSpacing)
                .foregroundStyle(House.ColorToken.textPrimary)
                .frame(maxWidth: House.Layout.answerMaxWidth, alignment: .leading)
        }
    }

    private func toolLine(text: String, @ViewBuilder glyph: () -> some View) -> some View {
        HStack(spacing: House.Spacing.xs) {
            glyph()
                .frame(width: House.Control.keyCap)
            Text(text)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
        }
        .frame(minHeight: House.Control.keyCap)
    }

    /// Row highlights: selected, hovered, plain.
    private var rows: some View {
        VStack(spacing: House.Spacing.xxs) {
            row("Selected row", isSelected: true, isHovering: false)
            row("Hovered row", isSelected: false, isHovering: true)
            row("Plain row", isSelected: false, isHovering: false)
        }
        .frame(maxWidth: House.Layout.chatRail)
    }

    private func row(_ title: String, isSelected: Bool, isHovering: Bool) -> some View {
        HStack {
            Text(title)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
            Spacer(minLength: 0)
            if isSelected { KeyCap(text: "⌘1") }
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(height: House.Control.row)
        .background { RowHighlight(isSelected: isSelected, isHovering: isHovering) }
    }

    /// A floating chooser on panel glass with the two panel shadows.
    private var chooser: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SlateSectionLabel(text: "Add context")
                .padding(.horizontal, House.Spacing.xs)
            ForEach(["Attach file", "Vault file", "Read screen once"], id: \.self) { title in
                HStack {
                    Text(title)
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, House.Spacing.xs)
                .frame(height: House.Control.railRow)
                .background { RowHighlight(isSelected: title == "Vault file") }
            }
        }
        .padding(House.Spacing.xs)
        .frame(maxWidth: House.Layout.chatRail + House.Spacing.xxl)
        .panelGlass(radius: House.Radius.lg)
        .panelShadows()
    }
}
