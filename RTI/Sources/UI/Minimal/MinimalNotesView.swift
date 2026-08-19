import SwiftUI

/// Read-only list of the running meeting notes `NotesGenerationController`
/// generates on a timer (opt-in, Settings -> "Live analysis" -> "Generate
/// live notes"). One block per note, newest last.
struct MinimalNotesView: View {
    private let controller = NotesGenerationController.shared

    var body: some View {
        Group {
            if controller.notes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(controller.notes) { note in
                            noteBlock(note)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minHeight: 240)
    }

    private func noteBlock(_ note: GeneratedNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !note.title.isEmpty {
                Text(note.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.inkSecondary)
            }
            Text(note.content)
                .font(.system(size: 13))
                .foregroundStyle(Palette.inkPrimary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surfaceRaised)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(controller.isGenerating ? "Writing notes…" : "Nothing yet")
                .font(.system(size: 13))
                .foregroundStyle(Palette.inkFaint)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}
