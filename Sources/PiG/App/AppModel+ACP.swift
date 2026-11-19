import Foundation
import SwiftUI
import AppKit
@preconcurrency import UserNotifications

extension AppModel {
    var selectedACPController: ACPChatController? {
        guard let selectedACPChatID else { return nil }
        return acpControllers[selectedACPChatID]
    }

    var selectedACPChatRecord: ACPChatRecord? {
        guard let selectedACPChatID else { return nil }
        return acpChats.first { $0.id == selectedACPChatID }
    }

    /// Pi models plus discovered Antigravity ACP models, used where a new chat can pick either harness.
    var selectableNewChatModels: [ModelInfo] {
        var seen = Set<String>()
        var combined: [ModelInfo] = []
        for model in sessionNamingModels where seen.insert(model.id).inserted {
            combined.append(model)
        }
        for model in antigravityModels where seen.insert(model.id).inserted {
            combined.append(model)
        }
        return combined
    }

    func loadCachedAntigravityCatalog() {
        guard let snapshot = ACPModelsCache.load() else { return }
        antigravityModels = snapshot.modelInfos
        if !snapshot.modes.isEmpty {
            antigravityModes = snapshot.modes
        }
        antigravityAgentVersion = snapshot.agentVersion
    }

    func refreshAntigravityCatalog() {
        guard !isDiscoveringAntigravityModels else { return }
        guard ACPPaths.isAntigravityInstalled else {
            antigravityModels = []
            antigravityAgentVersion = nil
            return
        }
        isDiscoveringAntigravityModels = true
        Task { [weak self] in
            defer { self?.isDiscoveringAntigravityModels = false }
            do {
                let snapshot = try await ACPCatalogProbe.discoverAntigravityCatalog()
                guard let self else { return }
                self.antigravityModels = snapshot.modelInfos
                if !snapshot.modes.isEmpty {
                    self.antigravityModes = snapshot.modes
                }
                self.antigravityAgentVersion = snapshot.agentVersion
                self.antigravityAuthRequired = false
                self.reapplyAntigravityModelsToLanding()
            } catch {
                guard let self else { return }
                if let acpError = error as? ACPClient.ACPError, acpError.isAuthRequired {
                    self.antigravityAuthRequired = true
                }
                self.statusLine = "Antigravity model discovery failed: \(error.localizedDescription)"
                NSLog("PiG: Antigravity ACP catalog probe failed: \(error.localizedDescription)")
            }
        }
    }

    func reapplyAntigravityModelsToLanding() {
        guard let landing = landingDraftController, landing.agentID == nil else { return }
        let piModels = landingModelCatalogByProject[landing.projectPath] ?? sessionNamingModels
        applyLandingModels(piModels, to: landing)
    }

    // MARK: - Chat lifecycle

    func launchACPChatFromLanding(
        text: String,
        images: [ImageAttachment],
        projectPath: String,
        isQuickChat: Bool,
        modelID: String,
        thinkingLevel: String,
        modeID: String
    ) {
        let now = Date()
        let chatID = UUID().uuidString
        let cleanTitle = text.nonEmptyTrimmed?.oneLine(max: 64) ?? (isQuickChat ? "Quick Chat" : "Untitled")
        let effectiveModelID = modelID.isEmpty ? (antigravityModels.first?.id ?? "") : modelID
        let effectiveModeID = modeID.isEmpty ? landingACPModeID : modeID

        let record = ACPChatRecord(
            id: chatID,
            sessionID: nil,
            projectPath: projectPath,
            title: cleanTitle,
            modelID: effectiveModelID,
            thinkingLevel: thinkingLevel,
            modeID: effectiveModeID,
            isQuickChat: isQuickChat,
            created: now,
            lastActivity: now
        )
        acpChats.append(record)
        persistACPChats()

        let controller = makeACPController(for: record)
        acpControllers[chatID] = controller

        clearAgentSelection()
        selectedControllerID = nil
        landingDraftController?.stopRPC()
        landingDraftController = nil
        pendingLandingModelSelection = nil
        landingDraftText = ""
        landingDraftImages = []
        composingQuickChat = false

        if !isQuickChat { touchProject(projectPath) }
        selectedProjectPath = projectPath
        selectedACPChatID = chatID
        acpUnreadChatIDs.remove(chatID)
        appendInboxID("acp:\(chatID)")

        Task { [weak self] in
            if isQuickChat {
                try? await AsyncFileSystem.createDirectory(at: PiPaths.quickChatsProject)
            }
            await controller.send(text, images: images)
            self?.enforceACPSessionUnloadPolicy()
        }
    }

    func selectACPChat(_ chatID: String) {
        guard let record = acpChats.first(where: { $0.id == chatID }) else { return }
        clearAgentSelection()
        selectedControllerID = nil
        landingDraftController?.stopRPC()
        landingDraftController = nil
        composingQuickChat = false
        showingSessionTree = false

        if !record.isQuickChat { touchProject(record.projectPath) }
        selectedProjectPath = record.projectPath
        selectedACPChatID = chatID
        acpUnreadChatIDs.remove(chatID)
        appendInboxID("acp:\(chatID)")

        let controller: ACPChatController
        if let existing = acpControllers[chatID] {
            controller = existing
        } else {
            controller = makeACPController(for: record)
            acpControllers[chatID] = controller
        }
        controller.markRuntimeUsed()
        Task { [weak self] in
            await controller.loadExistingSessionIfNeeded()
            self?.enforceACPSessionUnloadPolicy()
        }
    }

    func openACPSession(_ summary: ACPSessionSummary) {
        if let existing = acpChats.first(where: { $0.sessionID == summary.sessionID }) {
            selectACPChat(existing.id)
            return
        }
        let now = Date()
        let isQuick = isQuickChatsProject(summary.cwd)
        let record = ACPChatRecord(
            id: UUID().uuidString,
            sessionID: summary.sessionID,
            projectPath: summary.cwd,
            title: summary.title,
            modelID: antigravityModels.first?.id ?? "",
            thinkingLevel: defaultThinkingLevel,
            modeID: landingACPModeID,
            isQuickChat: isQuick,
            created: summary.updatedAt,
            lastActivity: max(summary.updatedAt, now)
        )
        acpChats.append(record)
        persistACPChats()
        selectACPChat(record.id)
    }

    func unloadACPChat(_ chatID: String) {
        guard let controller = acpControllers[chatID] else {
            statusLine = "Chat is not loaded."
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
        controller.stopProcess()
        statusLine = "Unloaded: \(controller.title.isEmpty ? "Untitled" : controller.title)"
    }

    func deleteACPChat(_ chatID: String) {
        if let controller = acpControllers[chatID] {
            guard !controller.hasLiveWork else {
                statusLine = "Cannot remove a working chat. Stop it first."
                return
            }
            controller.stopProcess()
            acpControllers.removeValue(forKey: chatID)
        }
        acpChats.removeAll { $0.id == chatID }
        persistACPChats()
        removeACPInboxItem(chatID)
        acpUnreadChatIDs.remove(chatID)
        if selectedACPChatID == chatID {
            selectedACPChatID = nil
            newChatHomeRequestID += 1
        }
    }

    func removeACPInboxItem(_ chatID: String) {
        let itemID = "acp:\(chatID)"
        sessionInboxIDs.removeAll { $0 == itemID }
        if inboxDismissalUndo?.items.contains(where: { $0.id == itemID }) == true {
            inboxDismissalUndo = nil
        }
    }

    // MARK: - Inbox & session queries

    func inboxACPChat(for itemID: String) -> ACPChatRecord? {
        guard itemID.hasPrefix("acp:") else { return nil }
        let chatID = String(itemID.dropFirst("acp:".count))
        return acpChats.first { $0.id == chatID }
    }

    func inboxACPController(for itemID: String) -> ACPChatController? {
        inboxACPChat(for: itemID).flatMap { acpControllers[$0.id] }
    }

    func refreshACPSessions(forProjectPath path: String) {
        guard ACPPaths.isAntigravityInstalled else { return }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard acpSessionLoadingPaths.insert(standardized).inserted else { return }
        Task { [weak self] in
            defer { self?.acpSessionLoadingPaths.remove(standardized) }
            do {
                let sessions = try await ACPCatalogProbe.listSessions(cwd: standardized)
                guard let self else { return }
                self.acpSessionsByProject[standardized] = sessions
            } catch {
                NSLog("PiG: Antigravity session/list failed for \(standardized): \(error.localizedDescription)")
            }
        }
    }

    func recentACPSessions(forProjectPath path: String, limit: Int = 5) -> [ACPSessionSummary] {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var bySessionID: [String: ACPSessionSummary] = [:]
        for summary in acpSessionsByProject[standardized] ?? [] {
            bySessionID[summary.sessionID] = summary
        }
        for record in acpChats where record.standardizedProjectPath == standardized {
            if let sid = record.sessionID, bySessionID[sid] == nil {
                bySessionID[sid] = ACPSessionSummary(
                    sessionID: sid,
                    cwd: record.projectPath,
                    title: record.title,
                    updatedAt: record.lastActivity
                )
            }
        }
        return Array(bySessionID.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    // MARK: - Idle unload policy

    func unloadOtherACPSessions(keepingID: String?) -> Int {
        var count = 0
        for (id, controller) in acpControllers where id != keepingID && controller.isProcessActive && !controller.hasLiveWork {
            controller.stopProcess()
            count += 1
        }
        return count
    }

    func unloadAllIdleACPSessions(includeSelected: Bool) -> Int {
        var count = 0
        for (id, controller) in acpControllers where controller.isProcessActive && !controller.hasLiveWork {
            if !includeSelected, id == selectedACPChatID { continue }
            controller.stopProcess()
            count += 1
        }
        return count
    }

    func enforceACPSessionUnloadPolicy() {
        guard sessionRuntimePolicy == .hybrid else { return }
        let now = Date()
        let candidates = acpControllers.values.filter { controller in
            controller.isProcessActive
                && !controller.isQuickChat
                && !controller.hasLiveWork
                && !acpUnreadChatIDs.contains(controller.id)
                && controller.id != selectedACPChatID
        }
        for controller in candidates where now.timeIntervalSince(controller.lastRuntimeUse) >= idleUnloadInterval {
            controller.stopProcess()
        }
        let stillActive = candidates.filter(\.isProcessActive).sorted { $0.lastRuntimeUse < $1.lastRuntimeUse }
        let overflow = stillActive.count - maxLoadedIdleSessions
        if overflow > 0 {
            for controller in stillActive.prefix(overflow) {
                controller.stopProcess()
            }
        }
    }

    // MARK: - Auth onboarding

    func openAntigravityLoginInTerminal() {
        guard ACPPaths.isAntigravityInstalled else {
            statusLine = "Antigravity CLI (`agy`) was not found. Install Antigravity or set its path in Settings."
            return
        }
        let exe = ACPPaths.antigravityExecutable.path
        let escaped = exe.replacingOccurrences(of: "'", with: "'\\''")
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("pig-agy-login.command")
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        do {
            try "#!/bin/zsh -l\n'\(escaped)' acp --login\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            statusLine = "Could not prepare login script: \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            Task { @MainActor in
                self?.statusLine = error.map { "Could not open Terminal for login: \($0.localizedDescription)" }
                    ?? "Opened Terminal for `agy acp --login`. Click Refresh Models after signing in."
            }
        }
    }

    // MARK: - Internal helpers

    private func makeACPController(for record: ACPChatRecord) -> ACPChatController {
        let controller = ACPChatController(
            id: record.id,
            sessionID: record.sessionID,
            projectPath: record.projectPath,
            isQuickChat: record.isQuickChat,
            title: record.title,
            models: antigravityModels,
            selectedModelID: record.modelID,
            thinkingLevel: record.thinkingLevel,
            modes: antigravityModes,
            modeID: record.modeID
        ) { [weak self] event in
            guard let self, let current = self.acpControllers[record.id] else { return }
            self.handleACPEvent(event, controller: current)
        }
        return controller
    }

    private func handleACPEvent(_ event: ACPChatController.Event, controller: ACPChatController) {
        switch event {
        case .sessionBound(let sid):
            if let index = acpChats.firstIndex(where: { $0.id == controller.id }) {
                acpChats[index].sessionID = sid
                acpChats[index].lastActivity = Date()
                persistACPChats()
            }
            objectWillChange.send()

        case .metadataChanged:
            if let index = acpChats.firstIndex(where: { $0.id == controller.id }) {
                acpChats[index].title = controller.title
                if !controller.selectedModelID.isEmpty {
                    acpChats[index].modelID = controller.selectedModelID
                }
                acpChats[index].thinkingLevel = controller.thinkingLevel
                acpChats[index].modeID = controller.currentModeID
                acpChats[index].lastActivity = Date()
                persistACPChats()
            }
            objectWillChange.send()

        case .activityChanged:
            if let index = acpChats.firstIndex(where: { $0.id == controller.id }) {
                acpChats[index].lastActivity = Date()
            }
            objectWillChange.send()

        case .replyFinished:
            if let index = acpChats.firstIndex(where: { $0.id == controller.id }) {
                acpChats[index].lastActivity = Date()
                persistACPChats()
            }
            if selectedACPChatID != controller.id || !NSApp.isActive {
                acpUnreadChatIDs.insert(controller.id)
                notifyACPFinished(chatID: controller.id)
            }
            objectWillChange.send()

        case .log(let message):
            NSLog("PiG ACP: \(message)")
        }
    }

    private func notifyACPFinished(chatID: String) {
        guard notificationsEnabled, let controller = acpControllers[chatID] else { return }
        let content = UNMutableNotificationContent()
        content.title = "Antigravity finished"
        content.subtitle = controller.isQuickChat ? "Quick Chat" : URL(fileURLWithPath: controller.projectPath).lastPathComponent
        content.body = controller.title.isEmpty || controller.title == "Untitled"
            ? "A background Antigravity chat completed."
            : "\(controller.title) completed."
        content.sound = .default
        content.userInfo = ["acpChatID": chatID]
        let request = UNNotificationRequest(
            identifier: "PiG.acpFinished.\(chatID).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func persistACPChats() {
        do { try ACPChatStore.save(acpChats) }
        catch { statusLine = "Could not save Antigravity chat index: \(error.localizedDescription)" }
    }
}
