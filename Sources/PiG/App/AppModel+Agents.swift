import Foundation
import AppKit
@preconcurrency import UserNotifications

struct AgentEditorRequest: Identifiable {
    let id = UUID()
    let agent: Agent
    let isNew: Bool
}

extension AppModel {
    /// Landing selection, or the identity of the ordinary thread being viewed.
    var selectedAgent: Agent? {
        if let controller = selectedController { return agent(for: controller) }
        return selectedAgentID.flatMap(agent(withID:))
    }

    func agent(withID id: String) -> Agent? { agents.first { $0.id == id } }

    func agent(forSessionPath path: String) -> Agent? {
        guard let id = agentSessionRecords[AgentSessionStore.standardizedPath(path)],
              let agent = agent(withID: id), agent.backend == .pi else { return nil }
        return agent
    }

    func agent(for controller: SessionController) -> Agent? {
        if let id = controller.agentID { return agent(withID: id) }
        return controller.sessionPath.flatMap(agent(forSessionPath:))
    }

    func selectAgent(_ agentID: String) {
        guard let agent = agent(withID: agentID) else { return }
        prepareAgentSelection()
        selectedControllerID = nil
        selectedAgentID = agentID
        selectedProjectPath = agent.backend == .pi ? agent.workingDirectory : nil
        landingDraftText = ""
        landingDraftImages = []
        if agent.backend == .pi {
            prepareLandingDraft()
            Task { [weak self] in
                let paths = self?.agentSessionRecords.filter { $0.value == agentID }.map(\.key) ?? []
                let grouped = await SessionScanner.cachedSummaries(forPaths: paths)
                guard let self else { return }
                self.agentRecentSessions[agentID] = grouped.values.flatMap { $0 }
            }
        } else {
            // A draft UUID becomes an indexed inbox chat only on submission.
            hermesLandingDraftController = makeHermesController(agent: agent, chatID: UUID().uuidString)
        }
    }

    func recentSessions(forAgentID id: String, limit: Int = 5) -> [SessionSummary] {
        let sessions = sessionsByProject.values.flatMap { $0 } + archivedSessionsByProject.values.flatMap { $0 } + (agentRecentSessions[id] ?? [])
        return Array(Dictionary(sessions.filter { agentSessionRecords[AgentSessionStore.standardizedPath($0.filePath)] == id }
            .map { ($0.filePath, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    /// Record only persisted files; pi can allocate a path before writing its first turn.
    func syncAgentSessionRecords() {
        var changed = false
        for controller in Array(controllers.values) + [landingDraftController].compactMap({ $0 }) {
            guard let id = controller.agentID, let path = controller.sessionPath,
                  FileManager.default.fileExists(atPath: path) else { continue }
            let key = AgentSessionStore.standardizedPath(path)
            if agentSessionRecords[key] == nil {
                agentSessionRecords[key] = id
                changed = true
            }
        }
        if changed {
            do { try AgentSessionStore.save(agentSessionRecords) }
            catch { statusLine = "Could not save agent session records: \(error.localizedDescription)" }
        }
    }

    func requestNewAgent(backend: AgentBackend, fromSettings: Bool = false) {
        agentEditorInSettings = fromSettings
        agentEditorRequest = AgentEditorRequest(agent: .new(backend: backend), isNew: true)
    }

    func requestEditAgent(_ agentID: String, fromSettings: Bool = false) {
        guard let agent = agent(withID: agentID) else { return }
        agentEditorInSettings = fromSettings
        agentEditorRequest = AgentEditorRequest(agent: agent, isNew: false)
    }

    func saveAgent(_ agent: Agent, hermesAPIKey: String?) {
        if let key = hermesAPIKey, !key.isEmpty, let connection = agent.hermes {
            do { try HermesCredentials.save(key, for: connection.credentialID) }
            catch { statusLine = "Could not save Hermes credentials: \(error.localizedDescription)"; return }
        }
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent }
        else { agents.append(agent) }
        persistAgents()
        // Running threads retain their cwd/configuration until reload; new landings use edits.
        if selectedControllerID == nil, selectedAgentID == agent.id { selectAgent(agent.id) }
    }

    func removeAgent(_ agentID: String) {
        syncAgentSessionRecords()
        agents.removeAll { $0.id == agentID }
        if selectedAgentID == agentID { prepareAgentSelection() }
        // Reopening these saved sessions now uses plain controllers. Do not touch inbox/files.
        for controller in controllers.values.filter({ $0.agentID == agentID }) {
            controller.removeAgentConfiguration()
        }
        for controller in Array(hermesControllers.values).filter({ $0.agentID == agentID }) {
            controller.stop()
            hermesControllers[controller.chatID] = nil
        }
        persistAgents()
    }

    func moveAgent(_ draggedID: String, relativeTo targetID: String, after: Bool) {
        guard draggedID != targetID, let index = agents.firstIndex(where: { $0.id == draggedID }),
              agents.contains(where: { $0.id == targetID }) else { return }
        let agent = agents.remove(at: index)
        guard let target = agents.firstIndex(where: { $0.id == targetID }) else { return }
        agents.insert(agent, at: target + (after ? 1 : 0))
        persistAgents()
    }

    func clearAgentSelection() {
        selectedAgentID = nil
        selectedHermesChatID = nil
        hermesLandingDraftController?.stop()
        hermesLandingDraftController = nil
    }

    private func persistAgents() {
        do { try AgentStore.save(agents) }
        catch { statusLine = "Could not save agents: \(error.localizedDescription)" }
    }

    // MARK: Hermes threads

    func inboxHermesChat(for itemID: String) -> HermesChatRecord? {
        guard itemID.hasPrefix("hermes:") else { return nil }
        let chatID = String(itemID.dropFirst("hermes:".count))
        return hermesChats.first { $0.id == chatID }
    }

    func inboxHermesController(for itemID: String) -> HermesChatController? {
        inboxHermesChat(for: itemID).flatMap { hermesControllers[$0.id] }
    }

    func hermesAgent(for chat: HermesChatRecord) -> Agent? {
        guard let agent = agent(withID: chat.agentID), agent.backend == .hermes else { return nil }
        return agent
    }

    func recentHermesChats(forAgentID id: String, limit: Int = 5) -> [HermesChatRecord] {
        Array(hermesChats.filter { $0.agentID == id }.sorted { $0.lastActivity > $1.lastActivity }.prefix(limit))
    }

    /// Called on submission, before any network work. The index contains no remote state.
    func recordHermesSend(_ text: String, controller: HermesChatController) {
        let now = Date()
        if let index = hermesChats.firstIndex(where: { $0.id == controller.chatID }) {
            hermesChats[index].lastActivity = now
            if hermesChats[index].title == "Untitled", !controller.messages.contains(where: { $0.role == .user }) {
                hermesChats[index].title = text.oneLine(max: 120)
            }
        } else {
            hermesChats.append(HermesChatRecord(id: controller.chatID, agentID: controller.agentID,
                                               title: text.oneLine(max: 120), created: now, lastActivity: now))
        }
        persistHermesChats()
        appendInboxID("hermes:\(controller.chatID)")
    }

    private func persistHermesChats() {
        do { try HermesChatStore.save(hermesChats) }
        catch { statusLine = "Could not save Hermes chat index: \(error.localizedDescription)" }
    }

    func deleteHermesChat(_ chatID: String) {
        guard let chat = hermesChats.first(where: { $0.id == chatID }) else { return }
        guard hermesControllers[chatID]?.isWorking != true else {
            statusLine = "Cannot delete a working chat. Stop or wait for it to finish."
            return
        }
        do {
            // Detach recovery before removing its local journal. Never delete remote data.
            hermesControllers[chatID]?.stop()
            let url = HermesCache.journalURL(chatID)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            let remaining = hermesChats.filter { $0.id != chatID }
            try HermesChatStore.save(remaining)
            hermesChats = remaining
            hermesControllers[chatID] = nil
            hermesUnreadChatIDs.remove(chatID)
            removeHermesInboxItem(chatID)
            if selectedHermesChatID == chatID { prepareAgentSelection() }
            statusLine = "Removed local Hermes chat: \(chat.title). Remote data is unchanged."
        } catch {
            statusLine = "Could not delete local Hermes chat: \(error.localizedDescription)"
        }
    }

    var selectedHermesController: HermesChatController? {
        selectedHermesChatID.flatMap { hermesControllers[$0] }
    }

    @discardableResult
    func createHermesChat(agentID: String) -> HermesChatController? {
        guard let agent = agent(withID: agentID), agent.backend == .hermes else { return nil }
        let controller = makeHermesController(agent: agent, chatID: UUID().uuidString)
        hermesControllers[controller.chatID] = controller
        let now = Date()
        hermesChats.append(HermesChatRecord(id: controller.chatID, agentID: agentID, title: "Untitled", created: now, lastActivity: now))
        persistHermesChats()
        selectHermesChat(agentID: agentID, chatID: controller.chatID)
        return controller
    }

    func activateHermesLandingDraft(_ controller: HermesChatController) {
        guard hermesLandingDraftController === controller else { return }
        hermesLandingDraftController = nil
        hermesControllers[controller.chatID] = controller
        selectedHermesChatID = controller.chatID
        landingDraftText = ""
    }

    func selectHermesChat(agentID: String, chatID: String) {
        guard let chat = hermesChats.first(where: { $0.id == chatID && $0.agentID == agentID }) else { return }
        prepareAgentSelection()
        selectedControllerID = nil
        selectedAgentID = agentID
        selectedHermesChatID = chatID
        appendInboxID("hermes:\(chatID)")
        hermesUnreadChatIDs.remove(chatID)
        guard let agent = hermesAgent(for: chat) else {
            statusLine = "This Hermes chat's agent was removed. Its local data is retained, but it cannot reconnect."
            return
        }
        if hermesControllers[chatID] == nil {
            hermesControllers[chatID] = makeHermesController(agent: agent, chatID: chatID)
        }
        if let controller = hermesControllers[chatID] {
            Task { [weak self, weak controller] in
                guard let self, let controller, self.hermesControllers[chatID] === controller,
                      self.sessionInboxIDs.contains("hermes:\(chatID)"), self.hermesAgent(for: chat) != nil else { return }
                await controller.load()
            }
        }
    }

    private func makeHermesController(agent: Agent, chatID: String) -> HermesChatController {
        HermesChatController(agent: agent, chatID: chatID) { [weak self] event in
            guard let self, self.hermesControllers[chatID] != nil else { return }
            switch event {
            case .activityChanged:
                if self.hermesControllers[chatID]?.isWorking == true { self.appendInboxID("hermes:\(chatID)") }
                self.objectWillChange.send()
            case .replyFinished:
                if let index = self.hermesChats.firstIndex(where: { $0.id == chatID }) {
                    self.hermesChats[index].lastActivity = Date()
                    self.persistHermesChats()
                }
                let selected = self.selectedHermesChatID == chatID
                if !selected { self.hermesUnreadChatIDs.insert(chatID) }
                if !selected || !NSApp.isActive { self.notifyHermesFinished(agent: agent, chatID: chatID) }
                self.objectWillChange.send()
            case .log(let text): self.statusLine = text.oneLine(max: 160)
            }
        }
    }

    private func notifyHermesFinished(agent: Agent, chatID: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(agent.name) finished"
        content.body = hermesControllers[chatID]?.messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text.oneLine(max: 120) ?? "Reply ready."
        content.sound = .default
        content.userInfo = ["agentID": agent.id, "hermesChatID": chatID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "PiG.hermesFinished.\(chatID).\(UUID().uuidString)", content: content, trigger: nil))
    }

    func openNotification(_ info: [AnyHashable: Any]) async {
        if let agentID = info["agentID"] as? String, let chatID = info["hermesChatID"] as? String {
            selectHermesChat(agentID: agentID, chatID: chatID)
        } else if let path = info["sessionPath"] as? String {
            let key = AgentSessionStore.standardizedPath(path)
            if let controller = controllers.values.first(where: { $0.sessionPath.map(AgentSessionStore.standardizedPath) == key }) {
                selectController(controller)
            } else {
                let grouped = await SessionScanner.cachedSummaries(forPaths: [path])
                if let summary = grouped.values.flatMap({ $0 }).first { selectSession(summary) }
            }
        } else if let id = info["controllerID"] as? String, let controller = controllers[id] {
            selectController(controller)
        }
    }
}
