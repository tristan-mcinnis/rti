import AppKit
import SwiftUI
import XCTest

/// The offscreen render harness every RTI render proof shares.
///
/// Every screen is hosted in an NSHostingView with no window (never ordered
/// front, never activated) and captured with `cacheDisplay(in:to:)` in both
/// `.darkAqua` and `.aqua`. The PNGs land in `/tmp/rti-render-proof/` as
/// `<name>-dark.png` and `<name>-light.png`; give each proof class its own
/// name prefix so parallel work never overwrites another class's files.
///
/// Before the first render, `prepare()` points RTI at the fixture vault
/// (`FixtureVault`), so no proof ever reads the real vault or real meetings.
///
/// Proofs assert only that a non-blank bitmap came out; the design check is
/// a person (or an agent) reading every PNG.
@MainActor
enum RenderProofHarness {
    static let outputDirectory = URL(fileURLWithPath: "/tmp/rti-render-proof", isDirectory: true)

    /// Flatten the glass, create the output folder, and install the fixture
    /// vault. Safe to call before every test.
    static func prepare() throws {
        SlateRenderMode.flattenGlass = true
        // Before any view is built: point the shared assistant controller at an
        // in-memory mode store, so a render proof can never initialize or
        // write the live modes.json / active-mode default through the header
        // or a route preview.
        LLMController.shared.useInMemoryModeStore()
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FixtureVault.install()
    }

    /// Render `view` at `size` in dark and light and write both PNGs.
    /// Returns the two file URLs, dark first.
    @discardableResult
    static func renderBothAppearances(
        name: String,
        size: CGSize,
        view: some View,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [URL] {
        var urls: [URL] = []
        for (suffix, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            let url = outputDirectory.appendingPathComponent("\(name)-\(suffix).png")
            let png = try render(view, size: size, appearance: appearanceName)
            try png.write(to: url)
            XCTAssertGreaterThan(png.count, 2_000, "\(url.lastPathComponent) looks blank", file: file, line: line)
            urls.append(url)
        }
        return urls
    }

    /// Lay the view out in a window-less NSHostingView and capture it.
    ///
    /// No NSWindow is created and no NSApplication is started, so nothing can
    /// reach the screen: the bitmap is drawn straight out of the view tree.
    /// The appearance is forced two ways at once: the view's `appearance`
    /// (which House's dynamic NSColors resolve against) and the app's own
    /// theme setting (which drives `.preferredColorScheme`).
    static func render(_ view: some View, size: CGSize, appearance name: NSAppearance.Name) throws -> Data {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        UserDefaults.standard.set(
            name == .darkAqua ? RTIAppearanceMode.dark.rawValue : RTIAppearanceMode.light.rawValue,
            forKey: OverlayAppearanceDefaults.appearanceModeKey
        )

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Two runloop turns: one for SwiftUI's first layout, one for state that
        // lands in .onAppear (tab selection, list loads).
        for _ in 0..<2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            hosting.layoutSubtreeIfNeeded()
        }

        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        return try XCTUnwrap(data)
    }
}

/// Base class for a render proof: runs `RenderProofHarness.prepare()` before
/// each test and exposes the harness as instance methods. Subclass it, one
/// class per package, with its own PNG name prefix.
@MainActor
class RenderProofTestCase: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try RenderProofHarness.prepare()
    }

    @discardableResult
    func renderBothAppearances(
        name: String,
        size: CGSize,
        view: some View,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [URL] {
        try RenderProofHarness.renderBothAppearances(name: name, size: size, view: view, file: file, line: line)
    }
}
