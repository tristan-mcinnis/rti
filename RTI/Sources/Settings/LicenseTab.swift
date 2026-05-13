import SwiftUI

/// Settings → License. Shows current key status, expiry, and lets the user
/// paste a replacement key (e.g. after their original one expired).
struct LicenseTab: View {
    @StateObject private var store = LicenseStore.shared
    @State private var newKey: String = ""
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Beta License").font(.system(size: 16, weight: .semibold))

            if let lic = store.current {
                statusCard(lic)
            } else {
                Label("No valid key installed.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))
            }

            Divider().padding(.vertical, 4)

            Text("Replace key").font(.system(size: 12, weight: .medium))
            TextEditor(text: $newKey)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 80)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))

            HStack {
                if let message {
                    Label(message, systemImage: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? .red : .green)
                        .font(.system(size: 11))
                }
                Spacer()
                Button("Install") { install() }
                    .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Spacer()
        }
        .padding(8)
    }

    private func statusCard(_ lic: License) -> some View {
        let df = DateFormatter()
        df.dateStyle = .medium
        let remaining = max(Int(lic.expiresAt.timeIntervalSinceNow / 86_400), 0)
        return VStack(alignment: .leading, spacing: 6) {
            row("Subject", lic.subject)
            row("Issued", df.string(from: lic.issuedDate))
            row("Expires", "\(df.string(from: lic.expiresAt))  (\(remaining) days left)")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func install() {
        do {
            let lic = try store.install(newKey)
            isError = false
            message = "Installed for \(lic.subject)."
            newKey = ""
        } catch let e as LicenseError {
            isError = true
            message = e.errorDescription
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}
