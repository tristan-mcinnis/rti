import ImageIO
import SwiftUI

/// Grid of the screen frames archived with a session
/// (`<session>/frames/frame-<offset>-<kind>-<hash>.jpg`): the ambient local
/// vision trail when that lane is on, plus every screenshot the user asked
/// for. Click a frame for full size. Frames never leave the archive folder;
/// this is a viewer only.
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
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: House.Spacing.xs) {
                    Text("\(frames.count) frame\(frames.count == 1 ? "" : "s") from the session, in order.")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: House.Layout.chatRail), spacing: House.Spacing.sm)],
                        spacing: House.Spacing.md
                    ) {
                        ForEach(frames) { frame in
                            Button {
                                previewed = frame
                            } label: {
                                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                                    FrameThumbnail(url: frame.url)
                                    Text(frame.caption)
                                        .font(House.TypeToken.caption)
                                        .foregroundStyle(House.ColorToken.textSecondary)
                                        .monospacedDigit()
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

    /// Thumbnails share one screen-shaped frame (16:10), whatever the capture.
    static let aspect: CGFloat = 16.0 / 10.0

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(House.ColorToken.tileFill)
                    .overlay(Image(systemName: "photo").foregroundStyle(House.ColorToken.textTertiary))
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(Self.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
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
        VStack(spacing: House.Spacing.sm) {
            if let image = NSImage(contentsOf: frame) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: House.Layout.chatWidth, maxHeight: House.Layout.chatHeight)
                    .clipShape(RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous))
            } else {
                Text("Couldn't load \(frame.lastPathComponent)")
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
            }
            HStack {
                Text(caption)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([frame])
                }
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(House.Spacing.lg)
        .frame(minWidth: House.Layout.chatMinWidth - House.Layout.chatRail)
        .background(House.ColorToken.surface)
    }
}
