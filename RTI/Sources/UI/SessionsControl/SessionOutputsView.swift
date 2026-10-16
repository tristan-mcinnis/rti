import RTICore
import SwiftUI

/// The saved-meeting output chooser.
///
/// One archived transcript in, one separate owner-only Markdown file out. It
/// never retranscribes and never touches `transcript.md` or `summary.md`; the
/// provider and the destination folder are named before Generate, and the run
/// shows wait, cancel and error states in place. Generated files then appear
/// as chips in the file row, so they read, copy and export like any archive
/// file.
struct SessionOutputsChooser: View {
    @Bindable var model: SessionsWindowModel
    @State private var hoveredRecipeID: String?
    @State private var showsCustomEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            header
            if model.isOutputAvailable {
                SlateSectionLabel(text: "Recipe")
                recipeRow
                if showsCustomEditor {
                    customEditor
                }
                destinationLine
                Text("Uses the transcript, saved session details and confirmed speaker names. Audio stays on this Mac.")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                actionRow
                if let status = model.outputStatus {
                    statusLine(status)
                }
            } else {
                Text("Output generation is unavailable in this build.")
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textTertiary)
            }
        }
        .padding(House.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved-meeting output")
    }

    private var header: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "doc.badge.plus")
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textSecondary)
                .accessibilityHidden(true)
            Text("Saved-meeting output")
                .font(House.TypeToken.heading)
                .foregroundStyle(House.ColorToken.textPrimary)
            Spacer(minLength: House.Spacing.sm)
            Text("Text, no audio")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
            QuickAIGlyphButton(
                symbol: "xmark",
                font: HouseChatType.glyphSmall,
                color: House.ColorToken.textSecondary,
                label: "Close Outputs",
                help: "Close outputs (esc)"
            ) {
                model.closeOutputChooser()
            }
        }
    }

    private var recipeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: House.Spacing.xxs) {
                ForEach(model.outputRecipes) { recipe in
                    recipeChip(recipe)
                }
                Button {
                    showsCustomEditor.toggle()
                } label: {
                    Label("Custom", systemImage: "plus")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, House.Spacing.xs)
                        .frame(height: House.Control.chip)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Write and save your own instructions")
                .accessibilityLabel("New custom output instructions")
            }
        }
    }

    private func recipeChip(_ recipe: SessionOutputRecipe) -> some View {
        let isSelected = model.outputFlow.selectedRecipeID == recipe.id
        return Button {
            model.selectOutputRecipe(id: recipe.id)
        } label: {
            Text(recipe.name)
                .font(House.TypeToken.meta)
                .foregroundStyle(isSelected ? House.ColorToken.textPrimary : House.ColorToken.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, House.Spacing.xs)
                .frame(height: House.Control.chip)
                .background {
                    RowHighlight(
                        isSelected: isSelected,
                        isHovering: hoveredRecipeID == recipe.id,
                        radius: House.Radius.pill
                    )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight($hoveredRecipeID, id: recipe.id)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var customEditor: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            TextField("Name", text: $model.customOutputDraftName)
                .textFieldStyle(.roundedBorder)
                .font(House.TypeToken.meta)
                .accessibilityLabel("Custom output name")
            TextEditor(text: $model.customOutputDraftInstruction)
                .font(House.TypeToken.bodySmall)
                .scrollContentBackground(.hidden)
                .padding(House.Spacing.xxs)
                .frame(minHeight: House.Control.hero * 2)
                .background(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .fill(House.ColorToken.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
                )
                .accessibilityLabel("Custom output instructions")
            HStack(spacing: House.Spacing.xs) {
                Button("Save custom") { model.saveCustomOutputTemplate() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(!canSaveCustomOutput)
                if !model.customOutputTemplates.isEmpty {
                    Menu("Saved (\(model.customOutputTemplates.count))") {
                        ForEach(model.customOutputTemplates) { template in
                            Button("Delete \(template.name)") {
                                model.deleteCustomOutputTemplate(id: template.id)
                            }
                        }
                    }
                    .font(House.TypeToken.meta)
                    .fixedSize()
                    .help("Saved custom instructions")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var canSaveCustomOutput: Bool {
        !model.customOutputDraftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.customOutputDraftInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var destinationLine: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "arrow.right")
                .font(House.TypeToken.caption)
                .foregroundStyle(House.ColorToken.textTertiary)
                .accessibilityHidden(true)
            Text(model.outputProviderLabel)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
            Text("→")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .accessibilityHidden(true)
            Text(model.outputDestinationLabel)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Generates with \(model.outputProviderLabel), saved to \(model.outputDestinationLabel)"
        )
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: House.Spacing.sm) {
            if model.outputFlow.isGenerating {
                Button("Cancel") { model.cancelOutput() }
                    .buttonStyle(.plain)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textSecondary)
            } else {
                Button("Generate") { model.requestGenerateOutput() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(model.selectedOutputRecipe == nil)
            }
            Spacer(minLength: 0)
        }
    }

    private func statusLine(_ status: (text: String, isRunning: Bool, tone: SessionsWindowModel.OutputTone)) -> some View {
        HStack(spacing: House.Spacing.xs) {
            if status.isRunning {
                ThinkingIndicator()
            } else {
                SlateStatusDot(color: dotColor(status.tone))
            }
            Text(status.text)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(status.tone == .error ? House.ColorToken.danger : House.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func dotColor(_ tone: SessionsWindowModel.OutputTone) -> Color {
        switch tone {
        case .neutral: House.ColorToken.textTertiary
        case .success: House.ColorToken.success
        case .error: House.ColorToken.danger
        }
    }
}
