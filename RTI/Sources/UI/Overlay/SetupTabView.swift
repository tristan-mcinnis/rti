import AppKit
import RTICore
import SwiftUI
import UniformTypeIdentifiers
import HouseDesign

// MARK: - Setup

/// The meeting home: establish context and choose the live aids before going
/// live.
struct SetupTabView: View {
    private enum ScopeFilter: String, CaseIterable, Identifiable {
        case all
        case projects
        case clients

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .projects: "Projects"
            case .clients: "Clients"
            }
        }
    }

    private enum LiveOption: Equatable, Identifiable {
        case visualContext
        case notes
        case autoAssist

        var id: String {
            switch self {
            case .visualContext: "visualContext"
            case .notes: "notes"
            case .autoAssist: "autoAssist"
            }
        }

        var title: String {
            switch self {
            case .visualContext: "Screen context"
            case .notes: "Notes"
            case .autoAssist: "Auto"
            }
        }

        var detail: String {
            switch self {
            case .visualContext: "Read the active screen every minute; images discarded"
            case .notes: "Capture running notes as the call develops"
            case .autoAssist: "Surface suggestions during the call"
            }
        }

        var icon: String {
            switch self {
            case .visualContext: "eye"
            case .notes: "note.text"
            case .autoAssist: "sparkles"
            }
        }
    }

    /// Render proofs turn this off, so a proof never reads the Mac's real
    /// calendar (real meeting titles). The app always reads it.
    @MainActor static var readsCalendar = true

    private let store = MeetingContextStore.shared
    private let calendarStore = CalendarMeetingStore.shared
    private let session = SessionCoordinator.shared
    private let visibleResultLimit = 8
    // These also gate the live tabs (Notes / Auto), see OverlayPanelView.
    @AppStorage(NotesSettings.enabledKey) private var notesEnabled = NotesSettings.defaultEnabled
    @AppStorage(AutoAssistSettings.enabledKey) private var autoAssistEnabled = AutoAssistSettings.defaultEnabled
    @AppStorage(VisualContextSettingsDefaults.enabledKey) private var visualContextEnabled = VisualContextSettingsDefaults.defaultEnabled
    @State private var clients: [VaultItem] = []
    @State private var projects: [VaultItem] = []
    @State private var scopeFilter: ScopeFilter = .all
    @State private var pickerOpen = false
    @State private var query = ""
    @State private var suppressNextQueryDisclosure = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: House.Spacing.lg) {
                prepareHeader
                meetingFocusSection
                calendarMeetingSection
                liveCallSection
                noteEditor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            load()
            if Self.readsCalendar { calendarStore.refresh() }
        }
        .onChange(of: visualContextEnabled) { _, enabled in
            let session = SessionCoordinator.shared
            VisualContextTrail.shared.setEnabled(
                enabled,
                sessionStartedAt: session.isRunning ? session.startedAt : nil
            )
            if session.isPaused { VisualContextTrail.shared.setPaused(true) }
        }
    }

    private var prepareHeader: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            Text("Prepare the meeting")
                .font(House.TypeToken.heading)
                .foregroundStyle(House.ColorToken.textPrimary)
            Text("RTI records the meeting and improves the transcript after Finish. A client or project is optional.")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, House.Spacing.xs)
    }

    // MARK: - Meeting focus

    private var meetingFocusSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            sectionHeader("Focus", detail: "Client or project")
            if store.workstreamName != nil {
                usingBanner
            }
            picker
        }
    }

    // MARK: - Confirmed calendar meeting

    private var calendarMeetingSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            sectionHeader("Meeting", detail: "Calendar (optional)")
            settingsGroup {
                switch calendarStore.accessState {
                case .notDetermined:
                    HStack(spacing: 9) {
                        Image(systemName: "calendar")
                            .foregroundStyle(Color.overlayInkSecondary)
                        Text("Use a calendar event for the title and invitees")
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(Color.overlayInkSecondary)
                        Spacer(minLength: 6)
                        Button("Allow access") { calendarStore.requestAccess() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(10)
                case .denied:
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .foregroundStyle(RTIDesign.Color.warning)
                        Text("Calendar access is off. Enable it in System Settings to choose a meeting.")
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(Color.overlayInkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                case .available:
                    calendarPicker
                }
            }
        }
    }

    private var calendarPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let selected = store.calendarMeeting {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(RTIDesign.Color.success)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selected.title)
                            .font(.system(size: House.TypeToken.Size.meta, weight: .semibold))
                            .foregroundStyle(Color.overlayInk)
                            .lineLimit(1)
                        Text(calendarDetail(selected))
                            .font(RTIDesign.Font.micro)
                            .foregroundStyle(Color.overlayInkSecondary)
                    }
                    Spacer(minLength: 4)
                    Button { store.clearCalendarMeeting() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.overlayInkTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove calendar meeting context")
                }
                .padding(.horizontal, 10)
                .padding(.top, 9)
            } else if let suggestion = calendarStore.suggestion {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(RTIDesign.Color.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Suggested: \(suggestion.title)")
                            .font(.system(size: House.TypeToken.Size.meta, weight: .semibold))
                            .foregroundStyle(Color.overlayInk)
                            .lineLimit(1)
                        Text(calendarDetail(suggestion))
                            .font(RTIDesign.Font.micro)
                            .foregroundStyle(Color.overlayInkSecondary)
                    }
                    Spacer(minLength: 4)
                    Button("Use") { store.selectCalendarMeeting(suggestion) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.top, 9)
            } else {
                Text("No event overlaps the current time.")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
            }

            if !calendarStore.events.isEmpty {
                Menu {
                    ForEach(calendarStore.events) { event in
                        Button("\(calendarTime(event))  \(event.title)  ·  \(calendarSourceLabel(event))") {
                            store.selectCalendarMeeting(event)
                        }
                    }
                } label: {
                    Label("Choose calendar event", systemImage: "chevron.up.chevron.down")
                        .font(.system(size: House.TypeToken.Size.caption, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
        }
    }

    private func calendarDetail(_ event: CalendarMeeting) -> String {
        let count = event.attendees.count
        return "\(calendarTime(event)) · \(calendarSourceLabel(event)) · \(count == 0 ? "no invitees" : "\(count) invitee\(count == 1 ? "" : "s")")"
    }

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

    /// A group's lead-in, as the settings shell draws it: the uppercase
    /// `section` label, then a `meta` detail.
    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            SlateSectionLabel(text: title)
            if let detail {
                Text(detail)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    /// A settings-shell group: a quiet card at `Radius.lg` holding 40 pt rows.
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .slateGroupCard(cornerRadius: House.Radius.lg)
    }

    // MARK: - Combined client/project picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkSecondary)
                TextField(store.workstreamName == nil ? "Search client or project" : "Change client or project", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: House.TypeToken.Size.meta, weight: .medium))
                    .foregroundStyle(Color.overlayInk)
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
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(RTIDesign.Font.caption)
                            .foregroundStyle(Color.overlayInkTertiary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    togglePicker()
                } label: {
                    Image(systemName: pickerOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                        .foregroundStyle(Color.overlayInkSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).fill(RTIDesign.Color.chipFill))

            HStack(spacing: 8) {
                Picker("", selection: $scopeFilter) {
                    ForEach(ScopeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 194)
                .onChange(of: scopeFilter) { _, _ in
                    pickerOpen = true
                }
                if let hint = scopeHint {
                    Text(hint)
                        .font(RTIDesign.Font.micro)
                        .foregroundStyle(Color.overlayInkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }

            if pickerOpen {
                pickerList
            }
        }
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
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !visibleProjects.isEmpty {
                            pickerSection("Projects", items: visibleProjects, total: filteredProjects.count)
                        }
                        if !visibleClients.isEmpty {
                            pickerSection("Clients", items: visibleClients, total: filteredClients.count)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 178)
                if scopeFilter == .all, !query.isEmpty, !filteredProjects.isEmpty, filteredClients.isEmpty {
                    Text("Showing individual projects for “\(query)”.")
                        .font(RTIDesign.Font.micro)
                        .foregroundStyle(Color.overlayInkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).fill(RTIDesign.Color.chipFill))
        .overlay(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).stroke(RTIDesign.Color.border, lineWidth: House.hairline))
    }

    private func pickerSection(_ title: String, items: [VaultItem], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                    .foregroundStyle(Color.overlayInkSecondary)
                Spacer()
                Text("\(total)")
                    .font(.system(size: House.TypeToken.Size.micro, weight: .semibold))
                    .foregroundStyle(Color.overlayInkTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
            ForEach(items) { pickerRow($0) }
        }
    }

    private func pickerRow(_ item: VaultItem) -> some View {
        Button {
            pick(item)
            closePicker()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.isProject ? "folder" : "person.crop.circle")
                    .font(RTIDesign.Font.caption)
                    .foregroundStyle(Color.overlayInkSecondary)
                    .frame(width: 16)
                Text(item.name)
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(Color.overlayInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(item.isProject ? "Project" : "Client")
                    .font(.system(size: House.TypeToken.Size.micro, weight: .medium))
                    .foregroundStyle(Color.overlayInkTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: RTIDesign.Radius.xs)
                    .fill(store.workstreamItem == item ? RTIDesign.Color.selectionFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var usingBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: store.workstreamItem?.isProject == false ? "person.crop.circle.fill" : "folder.fill")
                .font(RTIDesign.Font.caption)
                .foregroundStyle(RTIDesign.Color.success)
                .frame(width: 16)
            Text(store.workstreamName ?? "")
                .font(.system(size: House.TypeToken.Size.caption, weight: .semibold))
                .foregroundStyle(Color.overlayInk)
                .lineLimit(1)
                .truncationMode(.middle)
            if let item = store.workstreamItem {
                Text(item.isProject ? "Project scope" : "Client note")
                    .font(.system(size: House.TypeToken.Size.micro, weight: .medium))
                    .foregroundStyle(Color.overlayInkTertiary)
            }
            Spacer(minLength: 8)
            Button { store.clearWorkstream() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(Color.overlayInkTertiary)
            }
            .buttonStyle(.plain)
            .help("Clear meeting focus")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.tile).fill(RTIDesign.Color.success.opacity(0.10)))
    }

    private var allItems: [VaultItem] {
        switch scopeFilter {
        case .all:
            projects + clients
        case .projects:
            projects
        case .clients:
            clients
        }
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
        Array(filteredProjects.prefix(scopeFilter == .all ? visibleResultLimit : visibleResultLimit + 2))
    }

    private var visibleClients: [VaultItem] {
        Array(filteredClients.prefix(scopeFilter == .all ? max(2, visibleResultLimit - visibleProjects.count) : visibleResultLimit + 2))
    }

    private var scopeHint: String? {
        switch scopeFilter {
        case .all:
            nil
        case .projects:
            "searches project files"
        case .clients:
            "uses one client note"
        }
    }

    private var emptyPickerMessage: String {
        if allItems.isEmpty {
            return "Nothing found in your vault."
        }
        if scopeFilter == .clients {
            return "No client note matches “\(query)”."
        }
        return "No match for “\(query)”."
    }

    // MARK: - Live call

    private var liveCallSection: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            sectionHeader("Live", detail: "Capture & assist")
            settingsGroup {
                liveTranscriptionRow
                settingsRowDivider
                livePanelToggle(.visualContext, $visualContextEnabled)
                settingsRowDivider
                livePanelToggle(.notes, $notesEnabled)
                settingsRowDivider
                livePanelToggle(.autoAssist, $autoAssistEnabled)
            }
        }
    }

    private var liveTranscriptionRow: some View {
        HStack(spacing: House.Spacing.sm) {
            Image(systemName: "waveform")
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textSecondary)
                .frame(width: House.Control.tile)
            VStack(alignment: .leading, spacing: 0) {
                Text("Transcription")
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                Text(captureReadiness)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: House.Spacing.sm)
            Button("Configure") {
                WindowCoordinator.shared.showSessionsControl(tab: .general)
            }
            .buttonStyle(.borderless)
            .font(.system(size: House.TypeToken.Size.caption, weight: .medium))
            .foregroundStyle(Color.overlayAccent)
        }
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.xxs)
        .frame(maxWidth: .infinity, minHeight: House.Control.row, alignment: .leading)
    }

    private var captureReadiness: String {
        let devices = session.audioDeviceNames()
        return "Mic: \(devices.input) · call audio follows: \(devices.output)"
    }

    /// The line between rows, inset to the rows' text column.
    private var settingsRowDivider: some View {
        HouseDivider()
            .padding(.leading, House.Spacing.sm + House.Control.tile + House.Spacing.sm)
    }

    private func livePanelToggle(_ option: LiveOption, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: House.Spacing.sm) {
                Image(systemName: option.icon)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .frame(width: House.Control.tile)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: HouseChatMetrics.chipGap) {
                        Text(option.title)
                            .font(House.TypeToken.label)
                            .foregroundStyle(House.ColorToken.textPrimary)
                        if option == .notes {
                            Text("Default")
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textTertiary)
                        }
                    }
                    Text(option.detail)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: House.Spacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(House.ColorToken.textPrimary)
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.xxs)
        .frame(maxWidth: .infinity, minHeight: House.Control.row, alignment: .leading)
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            sectionHeader("Prep note", detail: "Optional")
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { store.note }, set: { store.note = $0 }))
                    .font(RTIDesign.Font.meta).foregroundStyle(Color.overlayInk).scrollContentBackground(.hidden)
                    .frame(height: 64).padding(6)
                    .background(RoundedRectangle(cornerRadius: RTIDesign.Radius.row).fill(RTIDesign.Color.chipFill))
                if store.note.isEmpty {
                    Text("Anything extra for the assistant…")
                        .font(RTIDesign.Font.meta).foregroundStyle(Color.overlayInkTertiary)
                        .padding(.horizontal, 11).padding(.vertical, 13).allowsHitTesting(false)
                }
            }
        }
    }

    private func pick(_ item: VaultItem) {
        store.workstreamName = item.name
        store.workstreamContext = VaultWorkstreamStore.context(for: item)
        store.workstreamItem = item
        if !query.isEmpty {
            suppressNextQueryDisclosure = true
            query = ""
        }
    }

    private func load() {
        clients = VaultWorkstreamStore.clients()
        projects = VaultWorkstreamStore.projects()
    }
}
