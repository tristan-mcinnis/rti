import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers
import HouseDesign

// MARK: - Setup

/// The Prepare page. Before Record it answers three questions: what kind of
/// call, which project, and (research only) which guide. Audio is one card,
/// Listening only (the microphone itself is the header's mic menu); the
/// calendar is one quiet line under the project; everything else (live aids,
/// speakers, the prep note) waits behind one "More options" disclosure that stays as the user left
/// it. Screenshots are the header's eye menu, the model is Settings.
struct SetupTabView: View {
    private enum LiveOption: Equatable, Identifiable {
        case notes
        case autoAssist

        var id: String {
            switch self {
            case .notes: "notes"
            case .autoAssist: "autoAssist"
            }
        }

        var title: String {
            switch self {
            case .notes: "Notes"
            case .autoAssist: "Auto"
            }
        }

        var detail: String {
            switch self {
            case .notes: "Capture running notes as the call develops"
            case .autoAssist: "Surface suggestions during the call"
            }
        }

        var icon: String {
            switch self {
            case .notes: "note.text"
            case .autoAssist: "sparkles"
            }
        }
    }

    /// Render proofs turn this off, so a proof never reads the Mac's real
    /// calendar (real meeting titles). The app always reads it.
    @MainActor static var readsCalendar = true

    /// Render proofs turn this on to read where the page put its text
    /// (`setupLayoutMark`). Off in the app.
    @MainActor static var reportsLayout = false

    /// The page's readable column: one centred column with even gutters.
    static let columnWidth = House.Layout.quickAIAnswerMaxWidth

    /// The call type store the page reads and sets. Shared in the app; a
    /// proof passes a memory-only one.
    private let callTypes: CallTypeStore
    private let store = MeetingContextStore.shared
    private let calendarStore = CalendarMeetingStore.shared
    private let session = SessionCoordinator.shared
    private let visibleResultLimit = 8
    // These also gate the Live page: the Notes tab and the Auto rail beside
    // the transcript, see OverlayPanelView.
    @AppStorage(NotesSettings.enabledKey) private var notesEnabled = NotesSettings.defaultEnabled
    /// Unset means Auto follows the call type; a stored value wins.
    @AppStorage(AutoAssistSettings.enabledKey) private var autoAssistStored: Bool?
    @AppStorage private var moreOptionsOpen: Bool
    @AppStorage private var researchExtrasOpen: Bool
    @State private var clients: [VaultItem] = []
    @State private var projects: [VaultItem] = []
    @State private var pickerOpen = false
    @State private var query = ""
    @State private var suppressNextQueryDisclosure = false
    @FocusState private var searchFocused: Bool

    /// `defaults` holds the disclosure state; a proof passes its own suite.
    init(callTypes: CallTypeStore = .shared, defaults: UserDefaults = .standard) {
        self.callTypes = callTypes
        _moreOptionsOpen = AppStorage(wrappedValue: false, SetupPageSettings.moreOptionsExpandedKey, store: defaults)
        _researchExtrasOpen = AppStorage(wrappedValue: false, SetupPageSettings.researchExtrasExpandedKey, store: defaults)
    }

    private var isResearch: Bool { callTypes.active == .research }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: House.Spacing.xl) {
                Text("Prepare")
                    .font(House.TypeToken.heading)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                section("Call type") { callTypePicker.setupLayoutMark("edge.callType") }
                section("Project") { projectSection }
                if isResearch {
                    section("Guide") { guideSection }
                }
                // Audio, live aids, speakers and the prep note fold into
                // More options; its line says what runs (2026-11-14 review).
                moreOptions
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .setupLayoutMark("page")
            .coordinateSpace(name: SetupGrid.space)
            .padding(.top, House.Spacing.xs)
            .padding(.bottom, House.Spacing.xl)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            load()
            if Self.readsCalendar { calendarStore.refreshIfStale() }
        }
    }

    // MARK: - Layout grammar

    /// One section: the uppercase `section` label, `xs`, then its controls.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            SlateSectionLabel(text: title)
                .setupLayoutMark("edge.section.\(title)")
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A settings-shell group: a quiet card at `Radius.lg` holding 40 pt rows.
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slateGroupCard(cornerRadius: House.Radius.lg)
    }

    /// The line between rows, inset to the rows' text column.
    private var settingsRowDivider: some View {
        HouseDivider()
            .padding(.leading, SetupGrid.textColumn)
    }

    /// A row glyph in the fixed tile column, so every row's text starts on
    /// the same line whatever the symbol width.
    private func rowGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(House.TypeToken.label)
            .foregroundStyle(House.ColorToken.textSecondary)
            .frame(width: House.Control.tile)
    }

    /// A row's title over its one-line detail.
    private func rowText(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
            if let detail {
                Text(detail)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func rowFrame(_ row: some View) -> some View {
        row
            .padding(.horizontal, House.Spacing.sm)
            .padding(.vertical, House.Spacing.xxs)
            .frame(maxWidth: .infinity, minHeight: House.Control.row, alignment: .leading)
    }

    /// A quiet line under a card, on the card's text column.
    private func footnote(_ text: String, mark: String) -> some View {
        Text(text)
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .setupLayoutMark(mark)
            .padding(.leading, SetupGrid.textColumn)
            .padding(.trailing, House.Spacing.sm)
    }

    /// A row with an ink switch on the right.
    private func toggleRow(icon: String, title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        rowFrame(
            Toggle(isOn: isOn) {
                HStack(spacing: House.Spacing.sm) {
                    rowGlyph(icon)
                    rowText(title, detail: detail)
                    Spacer(minLength: House.Spacing.sm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(House.ColorToken.textPrimary)
        )
    }

    // MARK: - Call type

    private var callTypePicker: some View {
        Picker("Call type", selection: Binding(
            get: { callTypes.active },
            set: { CommandBuilder.switchCallType(to: $0, callTypes: callTypes, llm: .shared) }
        )) {
            ForEach(CallType.allCases) { Text($0.name).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - Project

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            if let item = store.workstreamItem, !pickerOpen {
                selectedProject(item)
            } else {
                searchField
            }
            if pickerOpen {
                pickerList
            }
            calendarLine
        }
    }

    private func selectedProject(_ item: VaultItem) -> some View {
        HStack(spacing: House.Spacing.sm) {
            rowGlyph(item.isProject ? "folder.fill" : "person.crop.circle.fill")
            HStack(spacing: House.Spacing.xs) {
                Text(item.name)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .setupLayoutMark("text.project")
                Text(item.isProject ? "Project" : "Client")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
            }
            Spacer(minLength: House.Spacing.xs)
            HStack(spacing: House.Spacing.xs) {
                Button("Change…") { openPicker() }
                    .help("Choose another client or project")
                Button("Remove") { store.clearWorkstream() }
                    .help("Clear the project")
                    .accessibilityLabel("Clear the project")
            }
            .buttonStyle(.setupAction)
            .fixedSize()
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(minHeight: House.Control.row)
        .slateGroupCard(cornerRadius: House.Radius.lg)
    }

    private var searchField: some View {
        HStack(spacing: House.Spacing.sm) {
            rowGlyph("magnifyingglass")
            TextField("Search clients and projects", text: $query, prompt: Text(""))
                .textFieldStyle(.plain)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
                .setupPlaceholder("Search clients and projects", shown: query.isEmpty, font: House.TypeToken.label)
                .focused($searchFocused)
                .onTapGesture { openPicker() }
                .onChange(of: query) { _, _ in
                    if suppressNextQueryDisclosure {
                        suppressNextQueryDisclosure = false
                    } else {
                        pickerOpen = true
                    }
                }
                .onSubmit {
                    if let first = filteredItems.first {
                        pick(first)
                        closePicker()
                    }
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            Button { togglePicker() } label: {
                Image(systemName: pickerOpen ? "chevron.up" : "chevron.down")
                    .font(House.TypeToken.micro)
                    .foregroundStyle(House.ColorToken.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pickerOpen ? "Hide results" : "Show clients and projects")
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(minHeight: House.Control.row)
        .slateGroupCard(cornerRadius: House.Radius.lg)
    }

    private func openPicker() {
        pickerOpen = true
        searchFocused = true
    }

    private func closePicker() {
        pickerOpen = false
        searchFocused = false
    }

    private func togglePicker() {
        pickerOpen ? closePicker() : openPicker()
    }

    private var pickerList: some View {
        VStack(spacing: 0) {
            if filteredItems.isEmpty {
                Text(emptyPickerMessage)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(House.Spacing.sm)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !visibleProjects.isEmpty {
                            pickerGroup("Projects", items: visibleProjects, total: filteredProjects.count)
                        }
                        if !visibleClients.isEmpty {
                            pickerGroup("Clients", items: visibleClients, total: filteredClients.count)
                        }
                    }
                    .padding(.vertical, House.Spacing.xxs)
                }
                .frame(maxHeight: House.Control.row * 5)
            }
        }
        .slateGroupCard(cornerRadius: House.Radius.md)
    }

    private func pickerGroup(_ title: String, items: [VaultItem], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: House.Spacing.xs) {
                SlateSectionLabel(text: title)
                Spacer()
                Text("\(total)")
                    .font(House.TypeToken.micro)
                    .foregroundStyle(House.ColorToken.textTertiary)
            }
            .padding(.horizontal, House.Spacing.sm)
            .padding(.top, House.Spacing.xs)
            .padding(.bottom, House.Spacing.xxs)
            ForEach(items) { pickerRow($0) }
        }
    }

    private func pickerRow(_ item: VaultItem) -> some View {
        Button {
            pick(item)
            closePicker()
        } label: {
            HStack(spacing: House.Spacing.sm) {
                rowGlyph(item.isProject ? "folder" : "person.crop.circle")
                Text(item.name)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: House.Spacing.xs)
            }
            .padding(.horizontal, House.Spacing.sm)
            .frame(minHeight: House.Control.compact)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: House.Radius.xs)
                    .fill(store.workstreamItem == item ? House.ColorToken.selectionFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var allItems: [VaultItem] {
        projects + clients
    }

    private var filteredItems: [VaultItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allItems }
        return allItems.filter { $0.name.lowercased().contains(q) }
    }

    private var filteredProjects: [VaultItem] {
        filteredItems.filter(\.isProject)
    }

    private var filteredClients: [VaultItem] {
        filteredItems.filter { !$0.isProject }
    }

    private var visibleProjects: [VaultItem] {
        Array(filteredProjects.prefix(visibleResultLimit))
    }

    private var visibleClients: [VaultItem] {
        Array(filteredClients.prefix(max(2, visibleResultLimit - visibleProjects.count)))
    }

    private var emptyPickerMessage: String {
        allItems.isEmpty ? "Nothing found in your vault." : "No match for “\(query)”."
    }

    /// The calendar, the one control for it on the page: the chosen event
    /// (Change, Remove), else the one overlapping now (Use event, and Other
    /// when there are more), else a chooser over the next 12 hours, else
    /// nothing. Access is asked for here too.
    @ViewBuilder
    private var calendarLine: some View {
        if let selected = store.calendarMeeting {
            calendarLineRow(icon: "calendar.badge.checkmark", text: "Meeting: \(selected.title) · \(calendarTime(selected))") {
                HStack(spacing: House.Spacing.xs) {
                    if calendarStore.events.contains(where: { $0.id != selected.id }) {
                        calendarEventMenu("Change…", excluding: selected)
                    }
                    Button("Remove") { store.clearCalendarMeeting() }
                        .help("Remove calendar meeting context")
                        .accessibilityLabel("Remove calendar meeting context")
                }
            }
        } else {
            switch calendarStore.accessState {
            case .notDetermined:
                calendarLineRow(icon: "calendar", text: "Calendar: use an event for the title and invitees") {
                    Button("Allow access") { calendarStore.requestAccess() }
                }
            case .denied:
                calendarLineRow(icon: "calendar.badge.exclamationmark", text: "Calendar access is off in System Settings") {
                    EmptyView()
                }
            case .available:
                if let suggestion = calendarStore.suggestion {
                    calendarLineRow(icon: "calendar", text: "Now: \(suggestion.title) · \(calendarTime(suggestion))") {
                        HStack(spacing: House.Spacing.xs) {
                            if calendarStore.events.contains(where: { $0.id != suggestion.id }) {
                                calendarEventMenu("Other", excluding: suggestion)
                            }
                            Button("Use event") { store.selectCalendarMeeting(suggestion) }
                                .help("Use this event for the title and invitees")
                        }
                    }
                } else if !calendarStore.events.isEmpty {
                    let count = calendarStore.events.count
                    calendarLineRow(icon: "calendar", text: "\(count) calendar \(count == 1 ? "event" : "events") in the next 12 hours") {
                        calendarEventMenu("Choose event", excluding: nil)
                    }
                }
            }
        }
    }

    /// The events of the next 12 hours, as a quiet menu beside the line.
    private func calendarEventMenu(_ title: String, excluding: CalendarMeeting?) -> some View {
        Menu(title) {
            ForEach(calendarStore.events.filter { $0.id != excluding?.id }) { event in
                Button("\(calendarTime(event))  \(event.title)  ·  \(calendarSourceLabel(event))") {
                    store.selectCalendarMeeting(event)
                }
            }
        }
        // A button-styled menu, so it takes the same `.setupAction` look as
        // the Remove beside it (2026-11-14: a plain "Change" next to a boxed
        // "Remove").
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title == "Choose event" ? "Choose a calendar event" : "\(title) calendar event")
    }

    /// A quiet line under the project card: glyph in the glyph column, text
    /// on the text column, its action chip on the right like a card row's.
    private func calendarLineRow(icon: String, text: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: House.Spacing.sm) {
            rowGlyph(icon)
            Text(text)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .setupLayoutMark("text.calendarLine")
            Spacer(minLength: House.Spacing.xs)
            action()
                .buttonStyle(.setupAction)
                .fixedSize()
        }
        .padding(.horizontal, House.Spacing.sm)
    }

    // MARK: - Guide (research)

    private var guideSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            GuidePrepareControls(project: store.workstreamItem)
                .id(store.workstreamItem?.id)
                .slateGroupCard(cornerRadius: House.Radius.lg)
            SetupDisclosure(title: "Codebook and stimulus", detail: researchExtrasSummary, isExpanded: $researchExtrasOpen) {
                VStack(alignment: .leading, spacing: House.Spacing.sm) {
                    ResearchCodebookPreparation()
                    HouseDivider()
                        .padding(.leading, SetupGrid.textIndent)
                    StimulusPrepareControls(projectID: store.workstreamItem?.url.path)
                }
                .padding(House.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .slateGroupCard(cornerRadius: House.Radius.lg)
            }
        }
    }

    private var researchExtrasSummary: String {
        let seeds = ResearchCodebookController.shared.seedText
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let items = SessionMarkers.shared.prepared?.items.count ?? 0
        return Self.researchExtrasSummary(seeds: seeds, stimulusItems: items)
    }

    /// The collapsed "Codebook and stimulus" line: what is set, else what it
    /// holds.
    static func researchExtrasSummary(seeds: Int, stimulusItems: Int) -> String {
        var parts: [String] = []
        if seeds > 0 { parts.append("\(seeds) \(seeds == 1 ? "word" : "words") to watch") }
        if stimulusItems > 0 { parts.append("\(stimulusItems) stimulus \(stimulusItems == 1 ? "item" : "items")") }
        return parts.isEmpty ? "Optional" : parts.joined(separator: " · ")
    }

    // MARK: - Audio

    /// Before a call the switch shows the one-call preset. During a call it
    /// shows whether this call is listening only; turning it off unmutes, and
    /// the preset cannot be turned on mid-call (use the mic button to mute).
    private static var listeningOnlyToggleIsOn: Bool {
        let session = SessionCoordinator.shared
        return session.mic.isLive ? session.isListeningOnly : session.listeningOnlyPreset
    }

    private static func setListeningOnlyToggle(_ enabled: Bool) {
        let session = SessionCoordinator.shared
        if session.mic.isLive {
            if !enabled, session.isListeningOnly { session.unmuteMic() }
        } else {
            session.setListeningOnlyPreset(enabled)
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            settingsGroup {
                toggleRow(icon: "mic.slash", title: "Listening only", detail: "Record the call with your mic muted",
                          isOn: Binding(get: { Self.listeningOnlyToggleIsOn }, set: { Self.setListeningOnlyToggle($0) }))
                    .help("Record call audio with your microphone muted.")
            }
        }
    }

    private var guideNotesOn: Bool {
        GuideSessionController.shared.isActive || (isResearch && GuidePreparation.shared.guide != nil)
    }

    private var liveStatusLine: String {
        let callType = callTypes.active
        return Self.liveStatusLine(notes: notesEnabled,
                                   auto: AutoAssistSettings.runs(on: callType)
                                       ? AutoAssistSettings.isActive(for: callType, stored: autoAssistStored) : nil,
                                   guideNotes: guideNotesOn)
    }

    /// The one quiet line under Audio: which live aids run. `auto` is nil
    /// when Auto never runs on the call type.
    static func liveStatusLine(notes: Bool, auto: Bool?, guideNotes: Bool) -> String {
        var parts = ["Notes \(notes ? "on" : "off")"]
        if let auto { parts.append("Auto \(auto ? "on" : "off")") }
        if guideNotes { parts.append("Guide notes on") }
        return parts.joined(separator: " · ")
    }

    // MARK: - More options

    private var moreOptions: some View {
        SetupDisclosure(title: "More options", detail: liveStatusLine,
                        isExpanded: $moreOptionsOpen)
        {
            VStack(alignment: .leading, spacing: House.Spacing.xl) {
                section("Audio") { audioSection }
                section("Live aids") { liveAidsGroup }
                section("Speakers") { speakerGroup.disabled(session.phase == .finishing) }
                section("Prep note") { noteEditor }
            }
        }
    }

    private var liveAidsGroup: some View {
        settingsGroup {
            toggleRow(icon: LiveOption.notes.icon, title: LiveOption.notes.title, detail: LiveOption.notes.detail, isOn: $notesEnabled)
            settingsRowDivider
            toggleRow(icon: LiveOption.autoAssist.icon, title: LiveOption.autoAssist.title, detail: autoAssistDetail,
                      isOn: Binding(
                          get: { AutoAssistSettings.isActive(for: callTypes.active, stored: autoAssistStored) },
                          set: { autoAssistStored = $0 }
                      ))
                .disabled(!AutoAssistSettings.runs(on: callTypes.active))
            if guideNotesOn {
                settingsRowDivider
                rowFrame(
                    HStack(spacing: House.Spacing.sm) {
                        rowGlyph("list.bullet.rectangle")
                        rowText("Guide notes", detail: "Respondent answers filed by question")
                        Spacer(minLength: House.Spacing.sm)
                        Text("On")
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textSecondary)
                    }
                )
            }
        }
    }

    /// Until the user flips the switch, Auto follows the call type, and the
    /// row says so.
    private var autoAssistDetail: String {
        let callType = callTypes.active
        guard AutoAssistSettings.runs(on: callType) else { return "Auto does not run on this call type" }
        guard autoAssistStored == nil else { return LiveOption.autoAssist.detail }
        return "Auto on for this call type"
    }

    private var speakerGroup: some View {
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: House.Spacing.xs) {
            settingsGroup {
                toggleRow(icon: "person.2.wave.2", title: "Live speaker guesses", detail: "Numbered speakers; often flip in groups",
                          isOn: $session.speakerPolicy.liveLabelsEnabled)
                settingsRowDivider
                toggleRow(icon: "person.text.rectangle", title: "Speaker labels after the call", detail: "On the upgraded transcript",
                          isOn: $session.speakerPolicy.labelsEnabled)
                settingsRowDivider
                rowFrame(
                    HStack(spacing: House.Spacing.sm) {
                        rowGlyph("person.3")
                        rowText("Speakers in the room", detail: nil)
                        Spacer(minLength: House.Spacing.sm)
                        Stepper(session.speakerPolicy.expectedCount.map(String.init) ?? "Unknown") {
                            let count = session.speakerPolicy.expectedCount ?? 0
                            if count < Int.max { session.speakerPolicy.expectedCount = count + 1 }
                        } onDecrement: {
                            let count = session.speakerPolicy.expectedCount ?? 0
                            session.speakerPolicy.expectedCount = count > 1 ? count - 1 : nil
                        }
                        .font(House.TypeToken.meta)
                        .fixedSize()
                    }
                )
            }
            footnote("Live rows say Me or Them. The transcript after the call names each speaker; a count helps.",
                     mark: "text.speakers")
        }
    }

    // MARK: - Calendar

    private func calendarTime(_ event: CalendarMeeting) -> String {
        Self.calendarTimeFormatter.string(from: event.startDate)
    }

    private func calendarSourceLabel(_ event: CalendarMeeting) -> String {
        let labels = [event.calendarSource, event.calendarName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return labels.isEmpty ? "Calendar" : labels.joined(separator: " / ")
    }

    private static let calendarTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    // MARK: - Prep note

    private var noteEditor: some View {
        SetupTextEditor(text: Binding(get: { store.note }, set: { store.note = $0 }),
                        placeholder: "Anything extra for the assistant…", accessibilityLabel: "Prep note")
    }

    private func pick(_ item: VaultItem) {
        store.selectWorkstream(item)
        if !query.isEmpty {
            suppressNextQueryDisclosure = true
            query = ""
        }
    }

    /// The client and project lists walk the vault on disk, so they load off
    /// the main actor (2026-11-14: each visit to Prepare stalled the window).
    private func load() {
        Task {
            let lists = await Task.detached(priority: .userInitiated) {
                (VaultWorkstreamStore.clients(), VaultWorkstreamStore.projects())
            }.value
            clients = lists.0
            projects = lists.1
        }
    }
}

/// A disclosure that keeps its content on the page's own leading edge (the
/// system DisclosureGroup indents it): a chevron, a `label` title and a
/// `meta` summary of what it holds.
struct SetupDisclosure<Content: View>: View {
    let title: String
    var detail: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: House.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(House.TypeToken.micro.weight(.semibold))
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: House.Control.tile)
                    Text(title)
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .setupLayoutMark("title.\(title)")
                    if let detail {
                        Text(detail)
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, SetupGrid.glyphInset)
                .frame(minHeight: House.Control.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(detail ?? "")
            if isExpanded {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
