import ImageIO
import SwiftUI

/// Grid of the screen frames the local-vision lane archived with a session
/// (`<session>/frames/frame-<offset>-<kind>-<hash>.jpg`). Click a frame for
/// full size. Frames never leave the archive folder; this is a viewer only.
struct SessionFramesGallery: View {
    let directory: URL

    private struct Frame: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let caption: String
    }

    @State private var frames: [Frame] = []
    @State private var previewed: Frame?

    var body: some View {
        Group {
            if frames.isEmpty {
                Text("No screenshots were kept for this session.")
                    .font(RTIDesign.Font.meta)
                    .foregroundStyle(RTIDesign.Color.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(frames.count) frame\(frames.count == 1 ? "" : "s") captured during the session, in order.")
                        .font(RTIDesign.Font.caption)
                        .foregroundStyle(RTIDesign.Color.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 14) {
                        ForEach(frames) { frame in
                            Button {
                                previewed = frame
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    FrameThumbnail(url: frame.url)
                                    Text(frame.caption)
                                        .font(.system(size: House.TypeToken.Size.section))
                                        .foregroundStyle(RTIDesign.Color.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Click to view full size")
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: directory) { _, _ in load() }
        .sheet(item: $previewed) { frame in
            FramePreviewSheet(frame: frame.url, caption: frame.caption) {
                previewed = nil
            }
        }
    }

    private func load() {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } // offset prefix keeps session order
        frames = urls.map { Frame(url: $0, caption: Self.caption(for: $0)) }
    }

    /// "frame-00065-ambient-3f2a" → "1:05 · ambient". Falls back to filename.
    private static func caption(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        guard parts.count >= 3, parts[0] == "frame", let offset = Int(parts[1]) else { return stem }
        let stamp = "\(offset / 60):" + String(format: "%02d", offset % 60)
        return "\(stamp) · \(parts[2])"
    }
}

private struct FrameThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(RTIDesign.Color.textTertiary))
            }
        }
        .frame(height: 126)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: RTIDesign.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: RTIDesign.Radius.sm)
                .stroke(RTIDesign.Color.border, lineWidth: 1)
        )
        .task(id: url) {
            image = Self.thumbnail(for: url)
        }
    }

    private static func thumbnail(for url: URL) -> NSImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

private struct FramePreviewSheet: View {
    let frame: URL
    let caption: String
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let image = NSImage(contentsOf: frame) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 980, maxHeight: 640)
                    .clipShape(RoundedRectangle(cornerRadius: RTIDesign.Radius.sm))
            } else {
                Text("Couldn't load \(frame.lastPathComponent)")
                    .foregroundStyle(RTIDesign.Color.textSecondary)
            }
            HStack {
                Text(caption)
                    .font(.system(size: House.TypeToken.Size.meta, weight: .medium))
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([frame])
                }
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 560)
    }
}
