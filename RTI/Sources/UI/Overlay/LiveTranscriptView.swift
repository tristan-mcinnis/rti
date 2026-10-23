import AppKit
import RTICore
import SwiftUI
import HouseDesign

// MARK: - The list

/// The live transcript as a calm reading column: no box per speaker, one
/// quiet label per run of the same speaker, the mic wearer's runs on the
/// right in a soft bubble, everyone else as plain text on the left. Interim
/// words appear in lighter ink in their speaker's current run.
///
/// The Core projection shares its frozen history and replaces only its live
/// tail. Stable row IDs and revisions let the lazy list skip unchanged runs.
struct LiveTranscriptList: View, Equatable {
    let rows: LiveTranscriptPresentation.LiveRows
    let revision: Int
    var isActive = true
    var sessionID: String?

    /// Render proofs start scrolled away from the latest line to show the
    /// "Jump to latest" control; the app always starts following.
    static var startsFollowing = true

    @State private var following = LiveTranscriptList.startsFollowing
    @State private var readingAnchor: LiveTranscriptPresentation.RunID?

    private struct FollowUpdate: Equatable {
        let revision: Int
        let isActive: Bool
        let sessionID: String?
    }

    private var followUpdate: FollowUpdate {
        FollowUpdate(revision: revision, isActive: isActive, sessionID: sessionID)
    }

    /// The owner advances the revision whenever it replaces the snapshot.
    /// Raw arrivals while hidden therefore skip even the historical ID diff.
    nonisolated static func == (lhs: LiveTranscriptList, rhs: LiveTranscriptList) -> Bool {
        lhs.revision == rhs.revision && lhs.isActive == rhs.isActive && lhs.sessionID == rhs.sessionID
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: House.Spacing.lg) {
                    ForEach(rows) { row in
                        TranscriptRunView(row: row)
                            .equatable()
                    }
                }
                .scrollTargetLayout()
                .padding(.top, House.Spacing.xxs)
                .padding(.bottom, House.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TranscriptScrollTracking(following: $following, isActive: isActive))
            }
            .scrollContentBackground(.hidden)
            .scrollPosition(id: $readingAnchor)
            .accessibilityIdentifier("rti-live-transcript")
            .overlay(alignment: .bottom) {
                if !following {
                    JumpToLatestButton {
                        following = true
                        scrollToLatest(proxy)
                    }
                    .padding(.bottom, House.Spacing.sm)
                    .transition(.opacity)
                }
            }
            // Activation, a new session and a new snapshot can arrive in one
            // frame. Resolve their follow policy once before issuing a scroll.
            .onChange(of: followUpdate, initial: true) { previous, current in
                if previous.sessionID != current.sessionID {
                    following = true
                    readingAnchor = nil
                }
                if current.isActive, following { scrollToLatest(proxy) }
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

/// Observe the existing SwiftUI scroll view through its AppKit seam. This
/// keeps user scroll intent distinct from content growth on macOS 14 too.
private struct TranscriptScrollTracking: NSViewRepresentable {
    @Binding var following: Bool
    let isActive: Bool

    func makeNSView(context: Context) -> TranscriptScrollTrackingView {
        TranscriptScrollTrackingView()
    }

    func updateNSView(_ view: TranscriptScrollTrackingView, context: Context) {
        view.isActive = isActive
        view.onFollowingChange = { value in
            if following != value { following = value }
        }
        view.connectIfNeeded()
    }

    static func dismantleNSView(_ view: TranscriptScrollTrackingView, coordinator: ()) {
        view.disconnect()
    }
}

private final class TranscriptScrollTrackingView: NSView {
    var isActive = true
    var onFollowingChange: ((Bool) -> Void)?
    private weak var scrollView: NSScrollView?
    private var userScrolling = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { disconnect() } else { connectIfNeeded() }
    }

    override func layout() {
        super.layout()
        connectIfNeeded()
    }

    func connectIfNeeded() {
        guard let enclosing = enclosingScrollView, enclosing !== scrollView else { return }
        disconnect()
        scrollView = enclosing
        enclosing.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        // AppKit posts these on the main thread during native scrolling.
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: enclosing.contentView)
        center.addObserver(self, selector: #selector(scrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: enclosing)
        center.addObserver(self, selector: #selector(scrollChanged), name: NSScrollView.didLiveScrollNotification, object: enclosing)
        center.addObserver(self, selector: #selector(scrollEnded), name: NSScrollView.didEndLiveScrollNotification, object: enclosing)
    }

    func disconnect() {
        NotificationCenter.default.removeObserver(self)
        scrollView = nil
        userScrolling = false
    }

    @objc private func scrollStarted(_ notification: Notification) { userScrolling = true }

    @objc private func scrollChanged(_ notification: Notification) { reportScroll(userDriven: true) }

    @objc private func scrollEnded(_ notification: Notification) {
        reportScroll(userDriven: true)
        userScrolling = false
    }

    @objc private func boundsChanged(_ notification: Notification) {
        reportScroll(userDriven: userScrolling)
    }

    private func reportScroll(userDriven: Bool) {
        guard isActive, userDriven, let scrollView, let document = scrollView.documentView else { return }
        let visible = scrollView.documentVisibleRect
        guard visible.height > 0 else { return }
        let atBottom = document.isFlipped
            ? visible.maxY >= document.bounds.maxY - House.Spacing.xl
            : visible.minY <= document.bounds.minY + House.Spacing.xl
        onFollowingChange?(atBottom)
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
        .accessibilityIdentifier("rti-transcript-jump-latest")
    }
}

// MARK: - One run

/// The run itself. Others: a small muted label line (speaker dot, name,
/// time), then plain text capped at the reading width. The mic wearer: the
/// same label line on the right over a soft `chipFill` bubble, as the house
/// thread draws the user's turns. A note: a glyph label and secondary ink.
private struct TranscriptRunView: View, Equatable {
    let row: LiveTranscriptPresentation.LiveRow

    private var isSelf: Bool { row.isSelf }
    private var isNote: Bool { row.isNote }

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
                if !row.speakerId.isEmpty { header }
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
                Text(row.speakerLabel)
                    .font(House.TypeToken.meta.weight(.medium))
                    .foregroundStyle(House.ColorToken.textSecondary)
            } else {
                if !isSelf {
                    SlateStatusDot(color: SpeakerLabels.chipColor(for: row.speakerId))
                }
                SpeakerNameControl(speakerId: row.speakerId, label: row.speakerLabel)
            }
            if let startMs = row.startMs {
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
            // Boundaries come from all visible words. Marking a span final
            // changes only its ink; it cannot introduce a paragraph break.
            VStack(alignment: .leading, spacing: House.Spacing.sm) {
                ForEach(row.paragraphs) { paragraph in
                    TranscriptParagraphView(paragraph: paragraph, isNote: isNote)
                        .equatable()
                }
            }
            if !row.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(row.translation.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(House.TypeToken.bodySmall)
                    .italic()
                    .lineSpacing(RTIDesign.Font.bodySmallLineSpacing)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TranscriptParagraphView: View, Equatable {
    let paragraph: LiveTranscriptPresentation.Paragraph
    let isNote: Bool

    private var finalInk: Color {
        isNote ? House.ColorToken.textSecondary : House.ColorToken.textPrimary
    }

    var body: some View {
        paragraph.spans.reduce(Text("")) { text, span in
            text + Text(span.text).foregroundStyle(span.isFinal ? finalInk : House.ColorToken.textTertiary)
        }
        .font(House.TypeToken.bodySmall)
        .lineSpacing(RTIDesign.Font.bodySmallLineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
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
