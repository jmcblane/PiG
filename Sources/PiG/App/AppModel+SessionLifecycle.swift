import Foundation
import SwiftUI

extension AppModel {
    @discardableResult
    func newSession(projectPath: String, extensionPaths: [String] = [], initialMessage: String? = nil) -> SessionController {
        clearAgentSelection()
        landingDraftController?.stopRPC()
        landingDraftController = nil
        touchProject(projectPath)
        selectedProjectPath = projectPath
        composingQuickChat = false
        let controller = SessionController(
            projectPath: projectPath,
            sessionPath: nil,
            title: "Untitled",
            messages: [],
            extensionPaths: extensionPaths
        ) { [weak self] event in
            self?.handleControllerEvent(event)
        }
        controllers[controller.id] = controller
        addControllerToInbox(controller)
        selectedControllerID = controller.id
        finishedUnseenControllerIDs.remove(controller.id)
        let trustTask = projectTrustTasks[projectPath]
        Task {
            if let trustTask {
                do {
                    try await trustTask.value
                    self.projectTrustTasks.removeValue(forKey: projectPath)
                } catch {
                    controller.errorText = error.localizedDescription
                    self.reportProjectTrustFailure(path: projectPath, error: error)
                    return
                }
            }
            do {
                try await controller.ensureRPC(reloadMessages: false)
                if let initialMessage { await controller.send(initialMessage) }
            } catch {
                self.statusLine = error.localizedDescription
            }
        }
        return controller
    }

    func newQuickChat(extensionPaths: [String] = [], initialMessage: String? = nil) {
        clearAgentSelection()
        landingDraftController?.stopRPC()
        landingDraftController = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await AsyncFileSystem.createDirectory(at: PiPaths.quickChatsProject)
            } catch {
                self.statusLine = "Could not create Quick Chats directory: \(error.localizedDescription)"
                return
            }

            let projectPath = PiPaths.quickChatsProject.path
            let controller = SessionController(
                projectPath: projectPath,
                sessionPath: nil,
                title: "Quick Chat",
                messages: [],
                kind: .quickChat,
                extensionPaths: extensionPaths
            ) { [weak self] event in
                self?.handleControllerEvent(event)
            }
            self.clearAgentSelection()
            self.controllers[controller.id] = controller
            self.selectedProjectPath = projectPath
            self.composingQuickChat = false
            self.addControllerToInbox(controller)
            self.selectedControllerID = controller.id
            self.finishedUnseenControllerIDs.remove(controller.id)
            do {
                try await controller.ensureRPC(reloadMessages: false)
                if let initialMessage { await controller.send(initialMessage) }
            } catch {
                self.statusLine = error.localizedDescription
            }
        }
    }

    private func select(_ controller: SessionController) {
        clearAgentSelection()
        controller.resumeRuntimeLoading()
        touchProject(controller.projectPath)
        selectedProjectPath = controller.projectPath
        composingQuickChat = false
        addControllerToInbox(controller)
        selectedControllerID = controller.id
        finishedUnseenControllerIDs.remove(controller.id)
    }

    func selectController(_ controller: SessionController) {
        landingDraftController?.stopRPC()
        landingDraftController = nil
        select(controller)
        Task { try? await controller.ensureRPC(reloadMessages: false) }
    }

    /// Registers a controller for a saved session and loads its transcript from
    /// disk. The caller selects it; the transcript is applied only if it is
    /// still selected when parsing finishes.
    private func makeController(for summary: SessionSummary) -> SessionController {
        let owner = agent(forSessionPath: summary.filePath)
        let recorded = agentSessionRecords[AgentSessionStore.standardizedPath(summary.filePath)] != nil
        let controller = SessionController(
            projectPath: summary.projectPath,
            sessionPath: summary.filePath,
            title: summary.title,
            messages: [],
            kind: !recorded && isQuickChatsProject(summary.projectPath) ? .quickChat : .persistent,
            agentID: owner?.id,
            agentConfiguration: owner.map { agent in { [weak self] in self?.agent(withID: agent.id) } }
        ) { [weak self] event in
            self?.handleControllerEvent(event)
        }
        controllers[controller.id] = controller
        Task {
            if let parsed = await SessionParser.parseFileAsync(URL(fileURLWithPath: summary.filePath)), selectedControllerID == controller.id {
                await MarkdownPrewarmer.warm(parsed.messages, theme: selectedTheme)
                controller.messages = parsed.messages
                controller.bottomScrollRequest += 1
            }
        }
        return controller
    }

    private func prepareToOpen(_ summary: SessionSummary) {
        clearAgentSelection()
        touchProject(summary.projectPath)
        selectedProjectPath = summary.projectPath
        composingQuickChat = false
        addSessionToInbox(summary)
    }

    func selectSession(_ summary: SessionSummary) {
        landingDraftController?.stopRPC()
        landingDraftController = nil
        prepareToOpen(summary)
        if let existing = controller(forSessionPath: summary.filePath) {
            selectController(existing)
            return
        }
        let controller = makeController(for: summary)
        selectedControllerID = controller.id
        Task {
            do { try await controller.ensureRPC(reloadMessages: false) }
            catch { statusLine = error.localizedDescription }
        }
    }

    func reconnect(_ controller: SessionController) {
        select(controller)
        Task { [weak self] in
            do {
                try await controller.ensureRPC()
                self?.enforceLoadedSessionLimit()
            } catch {
                self?.statusLine = error.localizedDescription
            }
        }
    }

    func reconnectSession(_ summary: SessionSummary) {
        prepareToOpen(summary)
        reconnect(controller(forSessionPath: summary.filePath) ?? makeController(for: summary))
    }

    func unload(_ controller: SessionController) {
        if controller.isQuickChat {
            closeQuickChat(controller)
            return
        }
        guard !controller.hasLiveWork else {
            statusLine = "Cannot unload a working chat. Abort or wait for it to finish."
            return
        }
        guard controller.isProcessActive else {
            statusLine = "Chat already unloaded."
            return
        }
        controller.stopRPC()
        statusLine = "Unloaded: \(controller.title.isEmpty ? "Untitled" : controller.title)"
    }

    func closeQuickChat(_ controller: SessionController) {
        guard controller.isQuickChat else { return }
        guard !controller.hasLiveWork else {
            statusLine = "Cannot close a working quick chat. Abort or wait for it to finish."
            return
        }
        removeController(controller)
        if selectedControllerID == controller.id {
            selectedControllerID = controllers.values.sorted { $0.lastRuntimeUse > $1.lastRuntimeUse }.first?.id
            selectedProjectPath = selectedController?.projectPath
        }
        statusLine = "Closed quick chat."
    }

    func closeOtherQuickChats(keeping controller: SessionController?) {
        var count = 0
        for item in quickChatControllers where item.id != controller?.id && !item.hasLiveWork {
            removeController(item)
            count += 1
        }
        statusLine = "Closed \(count) quick chat\(count == 1 ? "" : "s")."
    }

    func closeAllQuickChats() {
        var count = 0
        for item in quickChatControllers where !item.hasLiveWork {
            removeController(item)
            count += 1
        }
        if let selectedControllerID, controllers[selectedControllerID] == nil {
            self.selectedControllerID = controllers.values.sorted { $0.lastRuntimeUse > $1.lastRuntimeUse }.first?.id
            selectedProjectPath = selectedController?.projectPath
        }
        statusLine = "Closed \(count) quick chat\(count == 1 ? "" : "s")."
    }

    func removeController(_ controller: SessionController, removeInbox: Bool = true) {
        let itemID = removeInbox ? inboxID(for: controller) : nil
        controller.stopRPC()
        controllers.removeValue(forKey: controller.id)
        if let itemID {
            sessionInboxIDs.removeAll { $0 == itemID || $0 == "controller:\(controller.id)" }
        }
        finishedUnseenControllerIDs.remove(controller.id)
        activeControllerIDs.remove(controller.id)
    }

    func unloadSession(path: String) {
        guard let controller = controller(forSessionPath: path) else {
            statusLine = "Chat is not loaded."
            return
        }
        unload(controller)
    }

}
