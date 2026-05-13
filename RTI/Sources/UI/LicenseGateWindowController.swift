import AppKit
import SwiftUI

/// Blocking license-entry window shown at launch when no valid key is found.
/// On success it calls `onUnlocked` so `AppDelegate` can continue boot.
/// On cancel/close the app terminates — there is no way past this gate.
@MainActor
final class LicenseGateWindowController {
    static let shared = LicenseGateWindowController()
    private var window: NSWindow?
    private var onUnlocked: (@MainActor () -> Void)?

    func show(onUnlocked: @escaping @MainActor () -> Void) {
        self.onUnlocked = onUnlocked
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "RTI — Beta Access"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = NSHostingView(rootView: LicenseGateView(
            onUnlock: { [weak self] in self?.unlock() },
            onQuit: { NSApp.terminate(nil) }
        ))
        w.delegate = LicenseGateWindowDelegate.shared
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    private func unlock() {
        window?.close()
        window = nil
        onUnlocked?()
        onUnlocked = nil
    }
}

/// Closing the gate window without unlocking terminates the app — the gate
/// is mandatory.
@MainActor
private final class LicenseGateWindowDelegate: NSObject, NSWindowDelegate {
    @MainActor static let shared = LicenseGateWindowDelegate()
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if !LicenseStore.shared.isValid { NSApp.terminate(nil) }
        }
    }
}

private struct LicenseGateView: View {
    var onUnlock: () -> Void
    var onQuit: () -> Void

    @State private var key: String = ""
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enter your beta key")
                        .font(.system(size: 17, weight: .semibold))
                    Text("RTI is in private beta. Paste the key you were sent to continue.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Beta key").font(.system(size: 11, weight: .medium))
                TextEditor(text: $key)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 90)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Keys are time-limited. They typically expire 60 days after issue.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Quit") { onQuit() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(busy ? "Checking…" : "Unlock") { tryUnlock() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520, height: 360)
    }

    private func tryUnlock() {
        errorText = nil
        busy = true
        let entered = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            do {
                _ = try LicenseStore.shared.install(entered)
                busy = false
                onUnlock()
            } catch let e as LicenseError {
                busy = false
                errorText = e.errorDescription
            } catch {
                busy = false
                errorText = error.localizedDescription
            }
        }
    }
}
