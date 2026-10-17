import Observation
import RTICore
import SwiftUI
import HouseDesign

/// App-level notice for global shortcuts the system refused to register
/// (usually a chord another app already owns). Fed by `HotkeyCoordinator`,
/// shown once in the overlay, dismissible. A dismissed list stays dismissed
/// across launches until the set of failed shortcuts changes.
@Observable @MainActor
final class HotkeyNoticeModel {
    static let shared = HotkeyNoticeModel()
    static let dismissedKey = "rti.hotkeyNotice.dismissedSignature"

    private(set) var failedTitles: [String] = []
    private var dismissedSignature: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissedSignature = defaults.string(forKey: Self.dismissedKey) ?? ""
    }

    @ObservationIgnored private let defaults: UserDefaults

    func update(failedTitles titles: [String]) {
        failedTitles = titles
    }

    /// The message to show, or nil when nothing failed or it was dismissed.
    var message: String? {
        HotkeyNoticeRule.message(failedTitles: failedTitles, dismissedSignature: dismissedSignature)
    }

    func dismiss() {
        dismissedSignature = HotkeyNoticeRule.signature(failedTitles)
        defaults.set(dismissedSignature, forKey: Self.dismissedKey)
    }
}

/// Non-fatal warning strip under the tabs row. Same warning tone as the
/// transcript tab's audio notices, with an optional action and dismiss.
struct OverlayNoticeBanner: View {
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(House.TypeToken.caption)
            Text(text)
                .font(House.TypeToken.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: House.Spacing.xs)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(House.TypeToken.meta)
                    .underline()
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(House.TypeToken.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .foregroundStyle(House.ColorToken.warning)
        .padding(.horizontal, House.Spacing.sm)
        .padding(.vertical, House.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(House.ColorToken.warning.opacity(0.12))
        .accessibilityElement(children: .contain)
    }
}

