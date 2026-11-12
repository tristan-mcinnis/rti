import HouseDesign
import RTICore
import SwiftUI
import UniformTypeIdentifiers

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
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            HStack {
                Text("Stimulus").font(House.TypeToken.label)
                Spacer()
                Button("Choose manifest…") { pickingManifest = true }
                    .disabled(reading || SessionCoordinator.shared.isRunning)
            }
            if reading {
                ProgressView().controlSize(.small)
            }
            if let package = store.prepared {
                DisclosureGroup("\(package.version) · \(package.items.count) items") {
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
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .accessibilityLabel("Move \(item.code) later").disabled(index + 1 == package.items.count)
                        }
                    }
                    Button(confirmed ? "Order confirmed" : "Confirm group order") {
                        store.prepared?.confirmedGroup = GuidePreparation.shared.group ?? "Session"
                        confirmed = true
                    }
                }
            }
            HStack {
                TextField("Neutral item label", text: $manual)
                Button(reference?.lastPathComponent ?? "File…") { pickingSource = true }
                TextField("Page", text: $page).frame(maxWidth: 60)
                Button("Add") {
                    var package = store.prepared ?? .init(revision: "", version: "Manual", items: [])
                    package.addManual(label: manual.trimmingCharacters(in: .whitespacesAndNewlines), file: reference, page: Int(page))
                    store.preparedProjectID = projectID
                    store.prepared = package
                    manual = ""; page = ""; reference = nil; confirmed = false
                }.disabled(manual.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        if store.mark(clear: clear, correcting: prior, at: ms) {
            correcting = nil
            seconds = ""
            store.showsControls = false
        }
    }
}
