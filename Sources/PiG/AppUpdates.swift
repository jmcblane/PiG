import AppKit
import Foundation

/// Checks GitHub for a newer PiG release. Releases are published by
/// .github/workflows/ci.yml and tagged v<VERSION>.
@MainActor
final class AppUpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let url: URL
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/jmcblane/PiG/releases/latest")!
    private static let dismissedKey = "appUpdateDismissedVersion"

    @Published private(set) var available: Release?
    @Published private var dismissedVersion = UserDefaults.standard.string(forKey: dismissedKey)
    private var isChecking = false

    /// nil when running outside an app bundle (e.g. `swift run`).
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// The available release unless the user dismissed its notice.
    var notice: Release? {
        guard let available, available.version != dismissedVersion else { return nil }
        return available
    }

    func start() {
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        guard !isChecking else { return }
        guard let currentVersion else {
            if manual { showAlert("Update checks need the bundled app", info: "Build PiG with scripts/build-app.sh to check for updates.") }
            return
        }
        isChecking = true
        defer { isChecking = false }

        let latest = await Self.fetchLatest()
        if let latest, Self.isNewer(latest.version, than: currentVersion) {
            available = latest
        } else if latest != nil {
            available = nil
        }
        guard manual else { return }

        if let available {
            let alert = NSAlert()
            alert.messageText = "PiG \(available.version) is available"
            alert.informativeText = "You have PiG \(currentVersion)."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { download() }
        } else if latest != nil {
            showAlert("PiG is up to date", info: "PiG \(currentVersion) is the latest version.")
        } else {
            showAlert("Couldn’t check for updates", info: "GitHub could not be reached. Try again later.")
        }
    }

    func download() {
        guard let available else { return }
        NSWorkspace.shared.open(available.url)
    }

    func dismiss() {
        guard let available else { return }
        dismissedVersion = available.version
        UserDefaults.standard.set(available.version, forKey: Self.dismissedKey)
    }

    private func showAlert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private struct LatestRelease: Decodable {
        let tag_name: String
        let html_url: URL
    }

    private static func fetchLatest() async -> Release? {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PiG", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(LatestRelease.self, from: data) else { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        return Release(version: version, url: release.html_url)
    }
}
