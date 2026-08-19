import SwiftUI

/// Root SwiftUI content hosted by the overlay `NSPanel`: the minimal
/// overlay (header, live transcript, ask composer) plus the settings sheet
/// the gear button presents.
struct OverlayPanelView: View {
    @State private var showSettings = false

    var body: some View {
        MinimalOverlayPanel(onOpenSettings: { showSettings = true })
            .sheet(isPresented: $showSettings) {
                MinimalSettingsSheet()
            }
            .onReceive(NotificationCenter.default.publisher(for: .rtiOpenSettings)) { _ in
                showSettings = true
            }
    }
}
