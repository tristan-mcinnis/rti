import SwiftUI

/// Top-level Settings shell. Each tab lives in its own file
/// (`KeysTab.swift`, `ModesTab.swift`, …) so changes to one section
/// don't drag the whole 1k-line monolith into review.
struct SettingsView: View {
    var onClose: (() -> Void)? = nil

    var body: some View {
        TabView {
            KeysTab()
                .tabItem { Label("Keys", systemImage: "key.fill") }
            ModesTab()
                .tabItem { Label("Modes", systemImage: "square.stack.3d.up") }
            GlossaryTab()
                .tabItem { Label("Glossary", systemImage: "character.book.closed") }
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 640, maxWidth: .infinity,
               minHeight: 460, idealHeight: 640, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if let onClose {
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .padding(8)
            }
        }
    }
}
