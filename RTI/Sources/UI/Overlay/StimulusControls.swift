import HouseDesign
import RTICore
import SwiftUI
import UniformTypeIdentifiers

private struct GuideStimulusPlan: Decodable {
    struct Item: Decodable {
        let code: String
        let section: Int
    }

    let stimulus: [Item]?
}

struct StimulusPrepareControls: View {
    @Bindable private var store = SessionMarkers.shared
    @State private var pickingManifest = false
    @State private var pickingSource = false
    @State private var manual = ""
    @State private var page = ""
    @State private var reference: URL?
    @State private var loadTask: Task<Void, Never>?
    @State private var reading = false
    @State private var confirmed = false
    let projectID: String?

    var body: some View {
        HStack(alignment: .top, spacing: House.Spacing.sm) {
            Image(systemName: "photo.on.rectangle")
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textSecondary)
                .frame(width: House.Control.tile, height: House.Control.chip)
                .accessibilityHidden(true)
            content
        }
        .buttonStyle(.setupAction)
        .controlSize(.small)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            HStack(spacing: House.Spacing.xs) {
                Text("Stimulus").font(House.TypeToken.label)
                    .setupLayoutMark("text.stimulus")
                if reading {
                    ProgressView().controlSize(.small).accessibilityLabel("Reading the manifest")
                }
                Spacer(minLength: House.Spacing.xs)
                Button("Choose manifest…") { pickingManifest = true }
                    .fixedSize()
                    .disabled(reading || SessionCoordinator.shared.isRunning)
            }
            if let package = store.prepared {
                DisclosureGroup("\(package.version) · \(package.items.count) \(package.items.count == 1 ? "item" : "items")") {
                    ForEach(Array(package.items.enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Text(item.code)
                            if let page = item.page {
                                Text("p. \(page)")
                            }
                            if !item.sourceAvailable {
                                Text("Manual reference")
                            }
                            Spacer()
                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .accessibilityLabel("Move \(item.code) earlier").disabled(index == 0)
                                .help("Move earlier")
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .accessibilityLabel("Move \(item.code) later").disabled(index + 1 == package.items.count)
                                .help("Move later")
                        }
                    }
                    if let guide = GuidePreparation.shared.guide {
                        ForEach(Set(package.items.compactMap(\.moment)).sorted(), id: \.self) { moment in
                            let sectionID = package.guideSectionByMoment?[moment].map { "S" + String($0) }
                            let questions = guide.sections.first { $0.id == sectionID }?.questions ?? guide.questions
                            Picker("Moment " + moment, selection: Binding<String?>(
                                get: { store.prepared?.guideQuestionBindings?[moment] },
                                set: { qid in
                                    var bindings = store.prepared?.guideQuestionBindings ?? [:]
                                    bindings[moment] = qid
                                    store.prepared?.guideQuestionBindings = bindings
                                }
                            )) {
                                Text(sectionID.map { $0 + " · unassigned" } ?? "Unassigned").tag(String?.none)
                                ForEach(questions, id: \.qid) { q in Text(q.qid + " · " + q.en).tag(String?.some(q.qid)) }
                            }
                        }
                    }
                    Button(confirmed ? "Order confirmed" : "Confirm group order") {
                        store.prepared?.confirmedGroup = GuidePreparation.shared.group ?? "Session"
                        confirmed = true
                    }
                }
            }
            HStack(spacing: House.Spacing.xs) {
                TextField("Neutral item label", text: $manual, prompt: Text(""))
                    .setupField("Neutral item label", isEmpty: manual.isEmpty)
                    .frame(minWidth: House.Control.hero * 2)
                    .setupLayoutMark("field.stimulus")
                Button(reference?.lastPathComponent ?? "File…") { pickingSource = true }
                    .truncationMode(.middle)
                    .layoutPriority(1)
                    .help("Attach the item's source file")
                TextField("Page", text: $page, prompt: Text(""))
                    .setupField("Page", isEmpty: page.isEmpty)
                    .frame(width: House.Control.hero)
                Button("Add") {
                    var package = store.prepared ?? .init(revision: "", version: "Manual", items: [])
                    package.addManual(label: manual.trimmingCharacters(in: .whitespacesAndNewlines), file: reference, page: Int(page))
                    store.preparedProjectID = projectID
                    store.prepared = package
                    manual = ""; page = ""; reference = nil; confirmed = false
                }
                .fixedSize()
                .disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = store.lastError {
                Text(error).font(House.TypeToken.meta)
            }
            if SessionCoordinator.shared.isRunning, store.pinned != nil {
                StimulusLiveControls()
            }
        }
        .controlSize(.small)
        .fileImporter(isPresented: $pickingManifest, allowedContentTypes: [.json]) { result in
            guard case let .success(url) = result else { return }
            loadTask?.cancel()
            reading = true
            loadTask = Task {
                do {
                    let package = try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer {
                            if scoped {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        return try StimulusPackage.read(manifest: url)
                    }.value
                    guard !Task.isCancelled, !SessionCoordinator.shared.isRunning else { return }
                    store.preparedProjectID = projectID
                    store.prepared = package
                    store.lastError = nil
                    confirmed = false
                } catch {
                    if !Task.isCancelled {
                        store.lastError = error.localizedDescription
                    }
                }
                reading = false
            }
        }
        .fileImporter(isPresented: $pickingSource, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result {
                reference = url
            }
        }
        .task(id: (store.prepared?.revision ?? "") + (GuidePreparation.shared.guideURL?.path ?? "")) {
            guard !SessionCoordinator.shared.isRunning, let revision = store.prepared?.revision,
                  let guide = GuidePreparation.shared.guideURL, ["md", "markdown"].contains(guide.pathExtension.lowercased()),
                  store.prepared?.guideSourcePaths?.contains(guide.standardizedFileURL.path) == true else { return }
            do {
                let reader = ExternalTools.stimulusPlanReader
                let result = try await ScriptRunner.run(executable: ExternalTools.systemPython.path,
                                                        arguments: [reader.path, "--plan-json", guide.path], environment: [:], timeout: 30)
                let moments = try JSONDecoder().decode([GuideStimulusPlan].self, from: result).first?.stimulus ?? []
                guard !Task.isCancelled, store.prepared?.revision == revision else { return }
                store.prepared?.guideSectionByMoment = Dictionary(moments.map { ($0.code, $0.section) }, uniquingKeysWith: { first, _ in first })
            } catch {
                if !Task.isCancelled {
                    store.lastError = "Could not read the Guide stimulus plan. Bind its moments manually."
                }
            }
        }
        .onChange(of: projectID) { _, _ in
            loadTask?.cancel(); reading = false; confirmed = false; store.prepared = nil; reference = nil
        }
    }

    private func move(_ index: Int, by delta: Int) {
        guard var package = store.prepared, package.items.indices.contains(index + delta) else { return }
        package.items.swapAt(index, index + delta)
        package.confirmedGroup = nil
        store.prepared = package
        confirmed = false
    }
}

struct StimulusLiveControls: View {
    @Bindable private var store = SessionMarkers.shared
    @State private var correcting: String?
    @State private var seconds = ""
    @State private var linkGuide = false

    var body: some View {
        if let package = store.pinned {
            let current = store.context(at: store.offset)
            HStack {
                Button("Material · " + current.materialLabel) { store.showsControls = true }
                    .accessibilityLabel("Mark shown or correct material")
                if current.revealRecorded {
                    Text("Reveal recorded").font(House.TypeToken.meta)
                }
            }
            .popover(isPresented: $store.showsControls) {
                VStack(alignment: .leading, spacing: House.Spacing.sm) {
                    Text("Material shown to the group").font(House.TypeToken.label)
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(package.items) { item in
                                Toggle(item.code, isOn: Binding(
                                    get: { store.selection.contains(item.id) },
                                    set: { on in
                                        if on {
                                            store.selection.insert(item.id)
                                        } else {
                                            store.selection.remove(item.id)
                                        }
                                    }
                                ))
                                .accessibilityHint(item.kind)
                            }
                        }
                    }.frame(maxHeight: 180)
                    let history = store.timeline.entries.filter { $0.shownCodes != nil }
                    if !history.isEmpty {
                        Picker("Change", selection: $correcting) {
                            Text("Now").tag(String?.none)
                            ForEach(history) { event in
                                Text("\(GuideExtraction.locator(event.offsetMs)) · \(event.label)").tag(String?.some(event.id))
                            }
                        }.onChange(of: correcting) { _, id in
                            guard let prior = history.first(where: { $0.id == id }) else { seconds = ""; return }
                            store.selection = Set(prior.shownItemIDs ?? [])
                            seconds = String(Double(prior.offsetMs) / 1000)
                        }
                    }
                    let linked = Set(package.items.filter { store.selection.contains($0.id) }.compactMap { item in
                        item.moment.flatMap { package.guideQuestionBindings?[$0] }
                    })
                    if correcting == nil, linked.count == 1, let qid = linked.first {
                        Toggle("Also mark " + qid, isOn: $linkGuide)
                    }
                    if correcting != nil {
                        TextField("Audio offset (seconds)", text: $seconds)
                    }
                    if let error = store.lastError {
                        Text(error).font(House.TypeToken.meta)
                    }
                    HStack {
                        Button("Clear shown") { save(clear: true) }
                        Button(correcting == nil ? "Mark shown" : "Save correction") { save(clear: false) }
                            .disabled(store.selection.isEmpty)
                    }
                }.padding(House.Spacing.md)
            }
        }
    }

    private func save(clear: Bool) {
        let prior = store.timeline.entries.first { $0.id == correcting }
        var ms: Int?
        if prior != nil {
            guard let value = Double(seconds), value.isFinite, value >= 0, value <= Double(store.offset) / 1000 else {
                store.lastError = "Enter an offset within this recording."
                return
            }
            ms = Int((value * 1000).rounded())
        }
        if store.mark(clear: clear, correcting: prior, at: ms, linkGuide: linkGuide) {
            correcting = nil
            linkGuide = false
            seconds = ""
            store.showsControls = false
        }
    }
}
