import AppKit
import HouseDesign
import RTICore
import SwiftUI

// MARK: - Editors

struct TranscriptEditor: View {
    @Bindable var model: SessionsWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    Text("Edit transcript")
                        .font(House.TypeToken.heading)
                        .foregroundStyle(House.ColorToken.textPrimary)
                    Text("Correct text or give a turn to a named speaker. Notes stay apart from speech.")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                }
                Spacer()
                Button("Cancel") { model.isEditingTranscript = false }
                    .buttonStyle(.plain)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textSecondary)
                Button("Save") { model.saveTranscript() }
                    .buttonStyle(InkButtonStyle())
                    .disabled(model.transcriptTurns.isEmpty)
            }
            ForEach($model.transcriptTurns) { $turn in
                VStack(alignment: .leading, spacing: House.Spacing.xs) {
                    HStack(spacing: House.Spacing.xs) {
                        Text(turn.timestamp)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .monospacedDigit()
                        if turn.isNote {
                            Label("Note", systemImage: "note.text")
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textSecondary)
                        } else {
                            TextField("Speaker", text: $turn.speaker)
                                .textFieldStyle(.roundedBorder)
                                .font(House.TypeToken.meta)
                                .frame(maxWidth: House.Layout.chatRail)
                            Menu("Assign") {
                                ForEach(model.transcriptSpeakerOptions, id: \.self) { speaker in
                                    Button(speaker) { turn.speaker = speaker }
                                }
                            }
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                    TextEditor(text: $turn.text)
                        .font(House.TypeToken.bodySmall)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: House.Control.hero)
                        .padding(House.Spacing.xxs)
                        .overlay(
                            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
                        )
                }
                .padding(House.Spacing.sm)
                .raisedCard(radius: House.Radius.row)
            }
        }
    }
}

/// Name the anonymous speakers of one session. Saved only for that session.
struct SpeakerEditorSheet: View {
    @Bindable var model: SessionsWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            Text("Name speakers")
                .font(House.TypeToken.title)
                .foregroundStyle(House.ColorToken.textPrimary)
            Text(model.archivedGuideRoster == nil
                ? "Names save for this session only. They replace the anonymous labels in its transcript."
                : "Assign the original live speakers. Saving updates the guide cells for this session.")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            let labels = model.speakerLabels
            if labels.isEmpty {
                Text("No anonymous speakers in this transcript.")
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: House.Spacing.md, verticalSpacing: House.Spacing.sm) {
                    ForEach(labels, id: \.self) { label in
                        GridRow {
                            Text(label)
                                .font(House.TypeToken.label)
                                .foregroundStyle(House.ColorToken.textPrimary)
                            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                                TextField("Name", text: Binding(
                                    get: { model.speakerName(for: label) },
                                    set: { model.setSpeakerName($0, for: label) }
                                ))
                                .textFieldStyle(.roundedBorder)
                                if let roster = model.archivedGuideRoster,
                                   let raw = SpeakerLabelMapping.rawKey(forDisplayLabel: label), raw.hasPrefix("remote_") {
                                    GuideSpeakerMenu(
                                        roster: roster,
                                        assignment: model.speakerAssignments[raw] ?? GuideSpeakerAssignment(),
                                        select: { model.speakerAssignments[raw] = $0.isEmpty ? nil : $0 }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            if let error = model.speakerReadError ?? model.speakerSaveError {
                Text(error)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textPrimary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.cancelSpeakerEditor() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.saveSpeakerNames() }
                    .disabled(model.speakerReadError != nil)
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(House.Spacing.xl)
        .frame(width: House.Layout.chatRail * 2)
        .background(House.ColorToken.surface)
    }
}
