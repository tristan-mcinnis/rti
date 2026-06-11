import AppKit
import RTICore

struct UpdateInfo {
    let tag: String
    let version: SemanticVersion
    let url: URL
}

/// Lightweight update check against GitHub Releases — no Sparkle, no appcast.
/// Compares the latest published release tag to the running build and, if
/// newer, points the user at the download. For a personal signed-DMG beta this
/// is enough: testers learn a new build exists and grab the DMG.
enum UpdateChecker {
    private static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/tristan-mcinnis/rti-personal/releases/latest"
    )!
    private static let releasesPage = URL(
        string: "https://github.com/tristan-mcinnis/rti-personal/releases/latest"
    )!

    static var currentVersion: SemanticVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(SemanticVersion.init)
    }

    /// Returns info on a newer release, or nil if up to date / no releases /
    /// the network check failed (never throws — update checks are best-effort).
    static func checkForUpdate() async -> UpdateInfo? {
        guard let current = currentVersion else { return nil }
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let remote = SemanticVersion(tag),
              remote > current
        else {
            return nil
        }
        let url = (obj["html_url"] as? String).flatMap(URL.init) ?? releasesPage
        return UpdateInfo(tag: tag, version: remote, url: url)
    }

    // MARK: - User-facing

    /// Manual "Check for Updates…": always reports a result.
    @MainActor
    static func checkAndReport() {
        Task { @MainActor in
            // Local builds (installed from source by the build pipeline) are
            // ahead of any GitHub release — never offer a release "update"
            // that would actually be a downgrade.
            let alert = NSAlert()
            alert.messageText = "Locally built version"
            alert.informativeText = "RTI \(currentVersion?.description ?? "") is installed from source and is newer than any published release. Updates ship via rebuilds, not GitHub releases."
            alert.runModal()
        }
    }

    /// Quiet launch check: only interrupts if a newer build exists.
    @MainActor
    static func checkInBackground() {
        Task { @MainActor in
            if let info = await checkForUpdate() { presentUpdateAvailable(info) }
        }
    }

    @MainActor
    private static func presentUpdateAvailable(_ info: UpdateInfo) {
        let alert = NSAlert()
        alert.messageText = "Update available — RTI \(info.tag)"
        alert.informativeText = "You're running \(currentVersion?.description ?? "an older build"). Download the latest signed DMG from GitHub."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(info.url)
        }
    }
}
