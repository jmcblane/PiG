import Foundation
import SwiftUI
import AppKit

extension AppModel {
    func unloadOtherSessions(keeping controller: SessionController?) {
        var count = 0
        for item in controllers.values where item.id != controller?.id && item.isProcessActive && !item.hasLiveWork {
            item.stopRPC()
            count += 1
        }
        statusLine = "Unloaded \(count) idle chat\(count == 1 ? "" : "s")."
    }

    func unloadAllIdleSessions(includeSelected: Bool = true) {
        var count = 0
        for item in controllers.values where item.isProcessActive && !item.hasLiveWork {
            if !includeSelected, item.id == selectedControllerID { continue }
            item.stopRPC()
            count += 1
        }
        statusLine = "Unloaded \(count) idle chat\(count == 1 ? "" : "s")."
    }

    var canReloadCurrentSessionRuntime: Bool {
        guard let selectedController else { return false }
        return canReloadSessionRuntime(selectedController)
    }

    var canReloadAnyIdleSessionRuntime: Bool {
        controllers.values.contains { isIdlePersistentRuntime($0) }
    }

    private func isIdlePersistentRuntime(_ controller: SessionController) -> Bool {
        !controller.isQuickChat && controller.isProcessActive && !controller.hasLiveWork
    }

    func canReloadSessionRuntime(_ controller: SessionController?) -> Bool {
        guard let controller else { return false }
        return isIdlePersistentRuntime(controller)
    }

    func controller(forSessionPath path: String) -> SessionController? {
        controllers.values.first { $0.sessionPath == path }
    }

    func loadedController(forSessionPath path: String) -> SessionController? {
        controllers.values.first { $0.sessionPath == path && $0.isProcessActive }
    }

    func reloadCurrentSessionRuntime() {
        guard canReloadCurrentSessionRuntime, let selectedController else { return }
        reloadSessionRuntime(selectedController)
    }

    func reloadSessionRuntime(_ controller: SessionController) {
        guard canReloadSessionRuntime(controller) else {
            statusLine = "Cannot reload this chat runtime."
            return
        }
        Task { [weak self, weak controller] in
            guard let self, let controller else { return }
            do {
                try await controller.reloadRuntime()
                self.statusLine = "Reloaded: \(controller.title.isEmpty ? "Untitled" : controller.title)"
            } catch {
                self.statusLine = error.localizedDescription
            }
        }
    }

    func reloadSessionRuntime(path: String) {
        guard let controller = loadedController(forSessionPath: path) else {
            statusLine = "Chat runtime is not loaded."
            return
        }
        reloadSessionRuntime(controller)
    }

    func reloadAllIdleSessionRuntimes() {
        let candidates = controllers.values.filter { isIdlePersistentRuntime($0) }
        let skipped = controllers.values.filter { !$0.isQuickChat && $0.isProcessActive && $0.hasLiveWork }.count
        guard !candidates.isEmpty else {
            statusLine = skipped > 0 ? "No idle chat runtimes to reload; \(skipped) working." : "No loaded chat runtimes to reload."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var reloaded = 0
            for controller in candidates {
                do {
                    try await controller.reloadRuntime()
                    reloaded += 1
                } catch {
                    self.statusLine = error.localizedDescription
                }
            }
            self.statusLine = "Reloaded \(reloaded) idle chat runtime\(reloaded == 1 ? "" : "s")\(skipped > 0 ? "; skipped \(skipped) working" : "")."
        }
    }

    func refreshModelsAfterCatalogUpdate() async {
        landingModelCatalogGeneration += 1
        landingModelCatalogByProject.removeAll()
        landingModelCatalogLoadingPaths.removeAll()
        if let landingDraftController {
            landingDraftController.hasCompleteModelCatalog = false
            loadLandingSlashCommands(for: landingDraftController)
        }
        await loadSessionNamingModels()

        let candidates = controllers.values.filter { isIdlePersistentRuntime($0) }
        let working = controllers.values.filter { !$0.isQuickChat && $0.isProcessActive && $0.hasLiveWork }.count
        guard !candidates.isEmpty else {
            statusLine = working > 0
                ? "Model catalogs refreshed. Reload working chat runtimes after they settle to load new models."
                : "Model catalogs refreshed. New models will load when chat runtimes reconnect."
            return
        }

        var reloaded = 0
        var failed = 0
        for controller in candidates {
            do {
                try await controller.reloadRuntime()
                reloaded += 1
            } catch {
                failed += 1
            }
        }
        var status = "Model catalogs refreshed; reloaded \(reloaded) idle chat runtime\(reloaded == 1 ? "" : "s")."
        if working > 0 { status += " Reload \(working) working runtime\(working == 1 ? "" : "s") after they settle." }
        if failed > 0 { status += " \(failed) runtime\(failed == 1 ? "" : "s") could not be reloaded." }
        statusLine = status
    }

    func activeController(forSessionPath path: String) -> SessionController? {
        controllers.values.first { $0.sessionPath == path && $0.showsActivityIndicator }
    }

    func activeController(forProjectPath path: String) -> SessionController? {
        controllers.values.first { $0.projectPath == path && $0.showsActivityIndicator }
    }

    func finishedUnseen(_ controller: SessionController) -> Bool {
        finishedUnseenControllerIDs.contains(controller.id)
    }

    func finishedUnseen(forSessionPath path: String) -> Bool {
        controllers.values.contains { $0.sessionPath == path && finishedUnseenControllerIDs.contains($0.id) }
    }

    func shutdown() {
        usageLimitTask?.cancel()
        usageLimitTask = nil
        sessionUnloadTask?.cancel()
        sessionUnloadTask = nil
        for controller in controllers.values {
            controller.stopRPC()
        }
        landingDraftController?.stopRPC()
        hermesLandingDraftController?.stop()
        for controller in hermesControllers.values { controller.stop() }
    }

    func startSessionUnloadPolling() {
        sessionUnloadTask?.cancel()
        sessionUnloadTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                self?.enforceSessionUnloadPolicy()
            }
        }
    }

    private func enforceSessionUnloadPolicy() {
        guard sessionRuntimePolicy == .hybrid else { return }
        let now = Date()
        for controller in unloadCandidates(includeSelected: false) where now.timeIntervalSince(controller.lastRuntimeUse) >= idleUnloadInterval {
            controller.stopRPC()
        }
        enforceLoadedSessionLimit()
    }

    func enforceLoadedSessionLimit() {
        guard sessionRuntimePolicy == .hybrid else { return }
        let candidates = unloadCandidates(includeSelected: false).sorted { $0.lastRuntimeUse < $1.lastRuntimeUse }
        let overflow = candidates.count - maxLoadedIdleSessions
        guard overflow > 0 else { return }
        for controller in candidates.prefix(overflow) {
            controller.stopRPC()
        }
    }

    private func unloadCandidates(includeSelected: Bool) -> [SessionController] {
        controllers.values.filter { controller in
            controller.isProcessActive &&
            !controller.isQuickChat &&
            !controller.hasLiveWork &&
            !finishedUnseenControllerIDs.contains(controller.id) &&
            (includeSelected || controller.id != selectedControllerID)
        }
    }

    func isQuickChatsProject(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path == PiPaths.quickChatsProject.standardizedFileURL.path
    }

    func syncOpenControllerTitles(from grouped: [String: [SessionSummary]]) {
        let summariesByPath = Dictionary(uniqueKeysWithValues: grouped.values.flatMap { $0 }.map { ($0.filePath, $0) })
        for controller in controllers.values {
            guard let sessionPath = controller.sessionPath,
                  let summary = summariesByPath[sessionPath],
                  summary.title != controller.title,
                  summary.named || controller.title.isEmpty || controller.title == "Untitled" else { continue }
            controller.title = summary.title
        }
    }

    /// Shared event sink for ordinary and agent pi controllers.
    func handleControllerEvent(_ event: SessionController.Event) {
        syncAgentSessionRecords()
        switch event {
        case .sessionFileChanged:
            for controller in controllers.values { syncControllerInboxID(controller) }
            refreshSessions()
        case .titleChanged:
            refreshSessions()
        case .activityChanged:
            reconcileControllerActivity()
            // Sidebar sections derive attention/loaded state from controller
            // properties this model does not publish itself.
            objectWillChange.send()
        case .sessionsChanged:
            refreshSessions()
        case .showSessionTree:
            showingSessionTree = true
        case .showPiUpdates(let cwd, let projectName, let action):
            piMaintenance.presentUpdates(cwd: cwd, projectName: projectName, requestedAction: action)
        case .showPiChangelog:
            piMaintenance.openChangelog()
        case .unloadOthers(let controllerID):
            unloadOtherSessions(keeping: controllers[controllerID])
        case .unloadAllIdle:
            unloadAllIdleSessions()
        case .extensionUIChanged:
            objectWillChange.send()
        case .log(let message):
            if !message.isEmpty { statusLine = message.oneLine(max: 160) }
        }
    }

    func reconcileControllerActivity() {
        let activeControllers = controllers.values.filter(\.showsActivityIndicator)
        for controller in activeControllers { addControllerToInbox(controller) }
        let currentActiveIDs = Set(activeControllers.map(\.id))
        let finishedIDs = activeControllerIDs.subtracting(currentActiveIDs)
        let backgroundFinishedIDs: Set<String>
        if let selectedControllerID {
            backgroundFinishedIDs = finishedIDs.filter { $0 != selectedControllerID }
        } else {
            backgroundFinishedIDs = finishedIDs
        }
        finishedUnseenControllerIDs.formUnion(backgroundFinishedIDs)
        let notificationIDs = NSApp.isActive ? backgroundFinishedIDs : finishedIDs
        for controllerID in notificationIDs {
            notifyAgentFinished(controllerID: controllerID)
        }
        activeControllerIDs = currentActiveIDs
    }

}
