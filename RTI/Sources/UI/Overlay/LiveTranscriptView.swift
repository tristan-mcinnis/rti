import RTICore
import SwiftUI

// MARK: - The list

/// The live transcript as a calm reading column: no box per speaker, one
/// quiet label per run of the same speaker, the mic wearer's runs on the
/// right in a soft bubble, everyone else as plain text on the left. Interim
/// words appear in a lighter ink where they will settle, so a final result
/// changes only the ink, not the layout.
///
/// Performance for a two-hour meeting: rows sit in a `LazyVStack`; only the
/// last run and the tail read the fast-changing interim line, so an interim
/// frame redraws those two views and nothing above them.
struct LiveTranscriptList: View {
    let rows: [LiveTranscriptPresentation.Row]
    let showTranslations: Bool

    /// Render proofs start scrolled away from the latest line to show the
    /// "Jump to latest" control; the app always starts following.
    static var startsFollowing = true

    @State private var following = LiveTranscriptList.startsFollowing
    private static let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: House.Spacing.lg) {
                    ForEach(rows) { row in
                        LiveTranscriptRun(
                            row: row,
                            showTranslation: showTranslations,
                            carriesInterim: row.id == rows.last?.id
                        )
                    }
                    LiveInterimTail(lastSpeakerId: rows.last?.speakerId) {
                        if following { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    Color.clear.frame(height: House.hairline).id(Self.bottomID)
                }
                .padding(.top, House.Spacing.xxs)
                .padding(.bottom, House.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .modifier(FollowLatestTracking(following: $following))
            .overlay(alignment: .bottom) {
                if !following {
                    JumpToLatestButton {
                        following = true
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                    .padding(.bottom, House.Spacing.sm)
                    .transition(.opacity)
                }
            }
            .onChange(of: growthKey) { _, _ in
                if following { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            // Returning to this tab re-instantiates the view at the top: jump
            // straight back to the latest line.
            .onAppear {
                if following { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
    }

    /// Changes when a run is added or the last run grows, and only then.
    private var growthKey: String {
        guard let last = rows.last else { return "" }
        return "\(rows.count)-\(last.original.count)-\(last.translation.count)"
    }
}

/// Follow the latest line until the user scrolls up; follow again once they
/// scroll back to the bottom. Content growing under a following list is not
/// a user scroll, so only scrolling the user does can stop following.
/// macOS 14 has no scroll phase API: there the list always follows.
private struct FollowLatestTracking: ViewModifier {
    @Binding var following: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.modifier(ScrollPhaseFollowTracking(following: $following))
        } else {
            content
        }
    }
}

@available(macOS 15.0, *)
private struct ScrollPhaseFollowTracking: ViewModifier {
    @Binding var following: Bool
    @State private var userScrolling = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
            }
            // nil while everything fits (and during the first, empty layout
            // pass): there is nothing to scroll, so following is left alone.
            .onScrollGeometryChange(for: Bool?.self) { geometry in
                guard geometry.contentSize.height > geometry.containerSize.height else { return nil }
                return geometry.visibleRect.maxY >= geometry.contentSize.height - House.Spacing.xl
            } action: { _, atBottom in
                guard let atBottom else { return }
                if atBottom {
                    following = true
                } else if userScrolling {
                    following = false
                }
            }
    }
}

private struct JumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: House.Spacing.xxs) {
                Image(systemName: "arrow.down")
                    .font(House.TypeToken.caption.weight(.semibold))
                Text("Jump to latest")
                    .font(House.TypeToken.meta)
            }
            .foregroundStyle(House.ColorToken.textPrimary)
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: House.Control.chip)
            .background(Capsule().fill(House.ColorToken.surfaceRaised))
            .overlay(Capsule().strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline))
            .houseShadow(House.Shadow.card)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Scroll to the latest line and keep following")
        .accessibilityLabel("Jump to latest")
    }
}

// MARK: - One run

/// One final run. The last run also shows the interim words of its speaker,
/// read here so that only this view redraws on an interim frame.
private struct LiveTranscriptRun: View {
    let row: LiveTranscriptPresentation.Row
    let showTranslation: Bool
    let carriesInterim: Bool

    var body: some View {
        TranscriptRunView(
            speakerId: row.speakerId,
            label: row.speakerLabel,
            startMs: row.startMs,
            original: row.original,
            translation: showTranslation ? row.translation : "",
            interim: interim
        )
    }

    private var interim: String {
        guard carriesInterim, let raw = SessionCoordinator.shared.interimLine else { return "" }
        return LiveTranscriptPresentation.placeInterim(
            LiveTranscriptPresentation.interimSegments(raw),
            afterSpeaker: row.speakerId
        ).inline
    }
}

/// Interim words from anyone other than the last run's speaker: each opens
/// the run it will become, in the lighter ink, below the final runs.
private struct LiveInterimTail: View {
    let lastSpeakerId: String?
    let onChange: () -> Void
    private let session = SessionCoordinator.shared
    private let names = SpeakerNameStore.shared

    var body: some View {
        let segments = trailing
        VStack(alignment: .leading, spacing: House.Spacing.lg) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                TranscriptRunView(
                    speakerId: segment.speakerId,
                    label: LiveTranscriptPresentation.label(for: segment.speakerId, names: names.names),
                    startMs: nil,
                    original: "",
                    translation: "",
                    interim: segment.text
                )
            }
        }
        .onChange(of: session.interimLine) { _, _ in onChange() }
    }

    private var trailing: [LiveTranscriptPresentation.InterimSegment] {
        guard let raw = session.interimLine else { return [] }
        return LiveTranscriptPresentation.placeInterim(
            LiveTranscriptPresentation.interimSegments(raw),
            afterSpeaker: lastSpeakerId
        ).trailing
    }
}

/// The run itself. Others: a small muted label line (speaker dot, name,
/// time), then plain text capped at the reading width. The mic wearer: the
/// same label line on the right over a soft `chipFill` bubble, as the house
/// thread draws the user's turns. A note: a glyph label and secondary ink.
private struct TranscriptRunView: View {
    let speakerId: String
    let label: String
    let startMs: Int?
    let original: String
    let translation: String
    let interim: String

    private var isSelf: Bool { speakerId == "self" }
    private var isNote: Bool { speakerId == "note" }

    var body: some View {
        if isSelf {
            VStack(alignment: .trailing, spacing: House.Spacing.xxs) {
                header
                bubble
            }
            .padding(.leading, House.Spacing.xxxxl)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                // Interim text the pipeline did not attribute has no label.
                if !speakerId.isEmpty { header }
                texts
                    .answerWidth()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: House.Spacing.xs) {
            if isNote {
                Image(systemName: "note.text")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .accessibilityHidden(true)
                Text(label)
                    .font(House.TypeToken.meta.weight(.medium))
                    .foregroundStyle(House.ColorToken.textSecondary)
            } else {
                if !isSelf {
                    SlateStatusDot(color: SpeakerLabels.chipColor(for: speakerId))
                }
                SpeakerNameControl(speakerId: speakerId, label: label)
            }
            if let startMs {
                Text(TimeFormat.elapsedMs(startMs))
                    .font(House.TypeToken.caption)
                    .monospacedDigit()
                    .foregroundStyle(House.ColorToken.textTertiary)
            }
        }
        .frame(minHeight: House.Control.keyCap)
    }

    private var bubble: some View {
        texts
            .padding(.horizontal, House.Spacing.sm)
            .padding(.vertical, House.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.pill, style: .continuous)
                    .fill(House.ColorToken.chipFill)
            )
            .frame(maxWidth: RTIDesign.Layout.answerMaxWidth, alignment: .trailing)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            spoken
                .font(House.TypeToken.bodySmall)
                .lineSpacing(RTIDesign.Font.bodySmallLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(translation.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(House.TypeToken.bodySmall)
                    .italic()
                    .lineSpacing(RTIDesign.Font.bodySmallLineSpacing)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Final words in full ink, interim words after them in tertiary ink:
    /// one `Text`, so a final result recolours words in place.
    private var spoken: Text {
        let final = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let settling = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalInk = isNote ? House.ColorToken.textSecondary : House.ColorToken.textPrimary
        var text = Text(final).foregroundStyle(finalInk)
        if !settling.isEmpty {
            text = text + Text((final.isEmpty ? "" : " ") + settling).foregroundStyle(House.ColorToken.textTertiary)
        }
        return text
    }

    private var accessibilityText: String {
        let final = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let settling = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = [final, settling].filter { !$0.isEmpty }.joined(separator: " ")
        return "\(label): \(spoken)"
    }
}

// MARK: - Speaker name

/// The speaker's name as small muted text. Click to name the speaker: with a
/// confirmed calendar meeting, a menu offers its invitees first; otherwise
/// (or from "Type a name…") an inline field takes the name. Return commits to
/// `SpeakerNameStore`, so the live view and the archive both use it; Escape
/// cancels.
private struct SpeakerNameControl: View {
    let speakerId: String
    let label: String

    private let names = SpeakerNameStore.shared
    private let meeting = MeetingContextStore.shared
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if editing {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(House.TypeToken.meta.weight(.medium))
                .foregroundStyle(House.ColorToken.textPrimary)
                .frame(width: House.Layout.chatRail - House.Spacing.xxxl)
                .focused($fieldFocused)
                .onSubmit {
                    names.rename(speakerId, to: draft)
                    editing = false
                }
                .onExitCommand { editing = false }
                .onAppear { fieldFocused = true }
        } else {
            let choices = LiveTranscriptPresentation.nameChoices(
                attendees: meeting.calendarMeeting?.attendees ?? [],
                names: names.names,
                for: speakerId
            )
            if choices.isEmpty {
                Button(action: startEditing) { nameText }
                    .buttonStyle(.plain)
                    .help("Click to name this speaker")
            } else {
                Menu {
                    ForEach(choices, id: \.self) { name in
                        Button(name) { names.rename(speakerId, to: name) }
                    }
                    Divider()
                    Button("Type a name…", action: startEditing)
                    if names.name(for: speakerId) != nil {
                        Button("Clear name") { names.rename(speakerId, to: "") }
                    }
                } label: {
                    nameText
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Name this speaker from the meeting's invitees")
            }
        }
    }

    private var nameText: some View {
        Text(label)
            .font(House.TypeToken.meta.weight(.medium))
            .foregroundStyle(House.ColorToken.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: House.Layout.chatRail, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
    }

    private func startEditing() {
        draft = names.name(for: speakerId) ?? ""
        editing = true
    }
}
