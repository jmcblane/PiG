import Foundation
import SwiftUI

struct PiRelease: Equatable {
    let version: String
    let note: String?
}

enum PiUpdateCheckState {
    case notChecked
    case succeeded
    case failed
    case skipped
}

struct PiPackageUpdate: Identifiable, Hashable {
    let source: String
    let displayName: String
    let scope: String
    var id: String { "\(scope):\(source)" }
}

enum PiUpdateAction: String, CaseIterable, Identifiable {
    case pi
    case extensions
    case all
    case models

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pi: return "Update Pi"
        case .extensions: return "Update Extensions"
        case .all: return "Update Pi and Extensions"
        case .models: return "Refresh Model Catalogs"
        }
    }
    var arguments: [String] {
        switch self {
        case .pi: return ["update"]
        case .extensions: return ["update", "--extensions"]
        case .all: return ["update", "--all"]
        case .models: return ["update", "--models"]
        }
    }
    var command: String { "pi " + arguments.joined(separator: " ") }
    var includesPi: Bool { self == .pi || self == .all }
}

enum PiChangelogWindow {
    case main
    case settings
}

private struct PiLatestVersionResponse: Decodable {
    let version: String
    let note: String?
}

private struct PiPackageUpdateResponse: Decodable {
    let source: String
    let displayName: String
    let scope: String
}

private struct PiChangelogEntry {
    let version: String
    let markdown: String
}

private enum PiMaintenanceIO {
    static var packageRoot: URL? {
        guard let index = PiPaths.piDistIndex else { return nil }
        return index.deletingLastPathComponent().deletingLastPathComponent()
    }

    static var changelogURL: URL? {
        guard let packageRoot else { return nil }
        let url = packageRoot.appendingPathComponent("CHANGELOG.md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func capturePi(arguments: [String], cwd: String) async -> (Int32, String) {
        _ = await PiEnvironment.mergedAsync()
        return await capture(executable: PiPaths.piExecutable, arguments: piArguments(arguments), cwd: cwd)
    }

    static func streamPi(
        arguments: [String],
        cwd: String,
        onChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Int32 {
        _ = await PiEnvironment.mergedAsync()
        return await stream(
            executable: PiPaths.piExecutable,
            arguments: piArguments(arguments),
            cwd: cwd,
            onChunk: onChunk
        )
    }

    private static func stream(
        executable: URL,
        arguments: [String],
        cwd: String,
        onChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Int32 {
        let environment = await PiEnvironment.mergedAsync()
        do {
            return try await ProcessRunner.stream(
                executable: executable, arguments: arguments, environment: environment,
                cwd: URL(fileURLWithPath: cwd, isDirectory: true), onChunk: onChunk
            )
        } catch {
            await MainActor.run { onChunk("\(error.localizedDescription)\n") }
            return 1
        }
    }

    static func checkPackageUpdates(cwd: String) async -> [PiPackageUpdate]? {
        guard let index = PiPaths.piDistIndex else { return nil }
        let script = """
        import { pathToFileURL } from 'node:url';
        const m = await import(pathToFileURL(process.argv[1]).href);
        const cwd = process.cwd();
        const agentDir = m.getAgentDir();
        const trusted = !m.hasTrustRequiringProjectResources(cwd) || new m.ProjectTrustStore(agentDir).get(cwd) === true;
        const settingsManager = m.SettingsManager.create(cwd, agentDir, { projectTrusted: trusted });
        const manager = new m.DefaultPackageManager({ cwd, agentDir, settingsManager });
        const updates = await manager.checkForAvailableUpdates();
        process.stdout.write('PIG_JSON:' + JSON.stringify(updates));
        """
        let result = await capture(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "--input-type=module", "--eval", script, index.path],
            cwd: cwd
        )
        guard result.0 == 0,
              let marker = result.1.range(of: "PIG_JSON:", options: .backwards),
              let data = String(result.1[marker.upperBound...]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode([PiPackageUpdateResponse].self, from: data) else { return nil }
        return decoded.map { PiPackageUpdate(source: $0.source, displayName: $0.displayName, scope: $0.scope) }
    }

    static func markChangelogSeen(version: String, cwd: String) async {
        if let index = PiPaths.piDistIndex {
            let script = """
            import { pathToFileURL } from 'node:url';
            const m = await import(pathToFileURL(process.argv[1]).href);
            const settings = m.SettingsManager.create(process.cwd(), m.getAgentDir(), { projectTrusted: false });
            settings.setLastChangelogVersion(process.argv[2]);
            await settings.flush();
            """
            let result = await capture(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["node", "--input-type=module", "--eval", script, index.path, version],
                cwd: cwd
            )
            if result.0 == 0 { return }
        }
        updateSettingsFallback(version: version)
    }

    static func changelogSettings() -> (lastVersion: String?, collapsed: Bool) {
        let url = PiPaths.agentDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, false)
        }
        return (object["lastChangelogVersion"] as? String, object["collapseChangelog"] as? Bool ?? false)
    }

    static func changelogEntries() -> [PiChangelogEntry] {
        guard let changelogURL,
              let content = try? String(contentsOf: changelogURL, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: .newlines)
        var entries: [PiChangelogEntry] = []
        var version: String?
        var collected: [String] = []
        func appendCurrent() {
            if let version, !collected.isEmpty {
                entries.append(PiChangelogEntry(version: version, markdown: collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        for line in lines {
            if line.hasPrefix("## "),
               let match = line.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                appendCurrent()
                version = String(line[match])
                collected = [line]
            } else if version != nil {
                collected.append(line)
            }
        }
        appendCurrent()
        return entries
    }

    private static func piArguments(_ arguments: [String]) -> [String] {
        PiPaths.piExecutable.path == "/usr/bin/env" ? ["pi"] + arguments : arguments
    }

    private static func capture(executable: URL, arguments: [String], cwd: String) async -> (Int32, String) {
        let environment = await PiEnvironment.mergedAsync()
        return await Task.detached(priority: .utility) {
            do {
                let result = try ProcessRunner.capture(
                    executable: executable, arguments: arguments, environment: environment,
                    cwd: URL(fileURLWithPath: cwd, isDirectory: true), mergeOutput: true
                )
                return (result.status, String(data: result.stdout, encoding: .utf8) ?? "")
            } catch {
                return (1, error.localizedDescription)
            }
        }.value
    }

    private static func updateSettingsFallback(version: String) {
        let url = PiPaths.agentDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        object["lastChangelogVersion"] = version
        guard let updated = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? updated.write(to: url, options: .atomic)
    }
}

@MainActor
final class PiMaintenanceController: ObservableObject {
    @Published private(set) var installedVersion = "—"
    @Published private(set) var latestRelease: PiRelease?
    @Published private(set) var packageUpdates: [PiPackageUpdate] = []
    @Published private(set) var releaseCheckState: PiUpdateCheckState = .notChecked
    @Published private(set) var packageCheckState: PiUpdateCheckState = .notChecked
    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published private(set) var updateOutput = ""
    @Published private(set) var updateSucceeded: Bool?
    @Published private(set) var updateAction: PiUpdateAction?
    @Published private(set) var pendingAction: PiUpdateAction?
    @Published var changelogWindow: PiChangelogWindow?
    @Published private(set) var changelogMarkdown = ""
    @Published private(set) var changelogTitle = "What’s New in Pi"
    @Published private(set) var contextPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published private(set) var contextName = "Global"
    @Published private(set) var installedUpdateNoticeVersion: String?

    private var dismissedReleaseVersion: String?
    private var dismissedPackageIDs = Set<String>()
    private var started = false
    private var checkQueued = false
    var onModelsUpdated: (() -> Void)?

    var availableRelease: PiRelease? {
        guard let latestRelease,
              isNewerVersion(latestRelease.version, than: installedVersion),
              dismissedReleaseVersion != latestRelease.version else { return nil }
        return latestRelease
    }

    var visiblePackageUpdates: [PiPackageUpdate] {
        packageUpdates.filter { !dismissedPackageIDs.contains($0.id) }
    }

    func start(cwd: String, projectName: String?) {
        guard !started else { return }
        started = true
        setContext(cwd: cwd, projectName: projectName)
        Task {
            await loadInstalledVersionAndChangelog(presentingIn: .main)
            await checkForUpdates(cwd: cwd, projectName: projectName, refreshInstalledVersion: false)
        }
    }

    func setContext(cwd: String, projectName: String?) {
        contextPath = cwd
        contextName = projectName ?? URL(fileURLWithPath: cwd).lastPathComponent
    }

    func presentUpdates(cwd: String, projectName: String?, requestedAction: PiUpdateAction? = nil) {
        setContext(cwd: cwd, projectName: projectName)
        if let requestedAction {
            requestUpdate(requestedAction)
        } else if !isUpdating {
            pendingAction = nil
        }
        SettingsTab.open(.pi)
        Task { await checkForUpdates() }
    }

    func openChangelog(showAll: Bool = true, in window: PiChangelogWindow = .main) {
        let entries = PiMaintenanceIO.changelogEntries()
        changelogTitle = "What’s New in Pi"
        changelogMarkdown = showAll
            ? entries.map(\.markdown).joined(separator: "\n\n")
            : changelogMarkdown
        if changelogMarkdown.isEmpty { changelogMarkdown = "No changelog entries found." }
        changelogWindow = window
    }

    func checkForUpdates(cwd: String? = nil, projectName: String? = nil, refreshInstalledVersion: Bool = true) async {
        if let cwd { setContext(cwd: cwd, projectName: projectName) }
        guard !isUpdating else { return }
        guard !isChecking else {
            checkQueued = true
            return
        }
        isChecking = true
        defer { isChecking = false }

        var refreshVersion = refreshInstalledVersion
        repeat {
            checkQueued = false
            if refreshVersion {
                let current = await PiMaintenanceIO.capturePi(arguments: ["--version"], cwd: contextPath)
                if current.0 == 0 {
                    let value = current.1.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { installedVersion = value }
                }
            }

            async let release = fetchLatestRelease(currentVersion: installedVersion)
            async let packages = PiMaintenanceIO.checkPackageUpdates(cwd: contextPath)
            let releaseResult = await release
            latestRelease = releaseResult.release
            releaseCheckState = releaseResult.state
            let packageResult = await packages
            packageUpdates = packageResult ?? []
            packageCheckState = packageResult == nil ? .failed : .succeeded
            dismissedPackageIDs.formIntersection(Set(packageUpdates.map(\.id)))
            refreshVersion = true
        } while checkQueued
    }

    func requestUpdate(_ action: PiUpdateAction) {
        guard !isUpdating else { return }
        dismissUpdateResult()
        pendingAction = action
    }

    func cancelPendingUpdate() {
        pendingAction = nil
    }

    func dismissUpdateResult() {
        guard !isUpdating else { return }
        updateAction = nil
        updateSucceeded = nil
        updateOutput = ""
    }

    func runConfirmedUpdate(_ action: PiUpdateAction) {
        guard !isUpdating else { return }
        isUpdating = true
        pendingAction = nil
        updateAction = action
        updateSucceeded = nil
        updateOutput = "$ \(action.command)\n\n"
        Task {
            let exitCode = await PiMaintenanceIO.streamPi(arguments: action.arguments, cwd: contextPath) { [weak self] chunk in
                self?.updateOutput += chunk.strippingTerminalControlSequences
            }
            isUpdating = false
            updateSucceeded = exitCode == 0
            if exitCode == 0 {
                if action != .models {
                    await loadInstalledVersionAndChangelog(presentingIn: action.includesPi ? .settings : nil)
                }
                await checkForUpdates()
                if action == .models {
                    updateOutput += "\nModel catalogs refreshed. Idle PiG chat runtimes are being reloaded; reload working runtimes after they settle.\n"
                    onModelsUpdated?()
                }
            } else if updateOutput.last != "\n" {
                updateOutput += "\n"
            }
        }
    }

    func dismissReleaseNotice() {
        dismissedReleaseVersion = latestRelease?.version
    }

    func dismissInstalledUpdateNotice() {
        installedUpdateNoticeVersion = nil
    }

    func dismissPackageNotice() {
        dismissedPackageIDs.formUnion(packageUpdates.map(\.id))
    }

    private func loadInstalledVersionAndChangelog(presentingIn window: PiChangelogWindow?) async {
        let result = await PiMaintenanceIO.capturePi(arguments: ["--version"], cwd: contextPath)
        guard result.0 == 0 else { return }
        let version = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { return }
        installedVersion = version

        let settings = PiMaintenanceIO.changelogSettings()
        guard let lastVersion = settings.lastVersion else {
            await PiMaintenanceIO.markChangelogSeen(version: version, cwd: contextPath)
            return
        }
        let newEntries = PiMaintenanceIO.changelogEntries().filter { isNewerVersion($0.version, than: lastVersion) }
        guard !newEntries.isEmpty else { return }
        changelogMarkdown = newEntries.map(\.markdown).joined(separator: "\n\n")
        changelogTitle = "Pi \(version)"
        await PiMaintenanceIO.markChangelogSeen(version: version, cwd: contextPath)
        guard let window else { return }
        if settings.collapsed {
            installedUpdateNoticeVersion = version
        } else {
            changelogWindow = window
        }
    }

    private func fetchLatestRelease(currentVersion: String) async -> (release: PiRelease?, state: PiUpdateCheckState) {
        let environment = await PiEnvironment.mergedAsync()
        if environment["PI_OFFLINE"] != nil || environment["PI_SKIP_VERSION_CHECK"] != nil { return (nil, .skipped) }
        guard let url = URL(string: "https://pi.dev/api/latest-version") else { return (nil, .failed) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PiG (Pi \(currentVersion))", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(PiLatestVersionResponse.self, from: data) else { return (nil, .failed) }
            return (PiRelease(version: decoded.version, note: decoded.note?.trimmingCharacters(in: .whitespacesAndNewlines)), .succeeded)
        } catch {
            return (nil, .failed)
        }
    }
}
