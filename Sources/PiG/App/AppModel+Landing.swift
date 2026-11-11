import Foundation
import SwiftUI

extension AppModel {
    func showNewChatHome(projectPath: String? = nil, quickChat: Bool = false) {
        let currentNormalProjectPath = selectedController.flatMap {
            $0.isQuickChat ? nil : $0.projectPath
        }
        let targetPath = projectPath ?? currentNormalProjectPath ?? selectedProjectPath.flatMap { path in
            isQuickChatsProject(path) ? nil : path
        } ?? projects.first?.path

        guard quickChat || targetPath != nil else {
            statusLine = "Add or select a project before starting a chat."
            return
        }
        if !quickChat, let targetPath, let trustTask = projectTrustTasks[targetPath] {
            statusLine = "Trusting project before opening it…"
            Task { [weak self] in
                do {
                    try await trustTask.value
                    guard let self, self.projectTrustTasks[targetPath] != nil else { return }
                    self.projectTrustTasks.removeValue(forKey: targetPath)
                    self.showNewChatHome(projectPath: targetPath)
                } catch {
                    self?.reportProjectTrustFailure(path: targetPath, error: error)
                }
            }
            return
        }

        clearAgentSelection()
        selectedControllerID = nil
        composingQuickChat = quickChat
        selectedProjectPath = quickChat ? PiPaths.quickChatsProject.path : targetPath
        if let targetPath, !quickChat { touchProject(targetPath) }
        prepareLandingDraft()
        newChatHomeRequestID += 1
    }

    func prepareLandingDraft() {
        guard selectedControllerID == nil, let selectedProjectPath else { return }
        let landingAgent = selectedAgentID.flatMap(agent(withID:))
        let quickChat = landingAgent == nil && (composingQuickChat || isQuickChatsProject(selectedProjectPath))
        if let existing = landingDraftController,
           existing.agentID == landingAgent?.id,
           existing.projectPath == selectedProjectPath,
           existing.isQuickChat == quickChat {
            loadLandingSlashCommands(for: existing)
            return
        }
        let previous = landingDraftController
        previous?.stopRPC()
        let controller = SessionController(
            projectPath: selectedProjectPath,
            sessionPath: nil,
            title: quickChat ? "Quick Chat" : "Untitled",
            messages: [],
            kind: quickChat ? .quickChat : .persistent,
            agentID: landingAgent?.id,
            agentConfiguration: landingAgent.map { agent in { [weak self] in self?.agent(withID: agent.id) } }
        ) { [weak self] event in
            self?.handleControllerEvent(event)
        }
        if let previous, previous.agentID == nil, landingAgent == nil {
            controller.setLandingResources(previous.chatResources)
            if let level = previous.explicitThinkingLevel { controller.setThinkingLevel(level) }
        }
        pendingLandingModelSelection = (landingAgent == nil && previous?.agentID == nil ? previous?.explicitModelSelectionID : nil).map { (controller.id, $0) }
            ?? pendingLandingModelSelection.flatMap { pending in
                // A previous transfer may still be waiting for the destination catalog.
                previous?.id == pending.controllerID ? (controller.id, pending.modelID) : nil
            }
        let initialModels = landingModelCatalogByProject[selectedProjectPath] ?? sessionNamingModels
        if !initialModels.isEmpty {
            applyLandingModels(initialModels, to: controller)
        }
        landingDraftController = controller
        loadLandingSlashCommands(for: controller)
    }

    func invalidateSlashCommandCatalog() {
        slashCommandCatalogGeneration += 1
        slashCommandCatalogByProject.removeAll()
        slashCommandCatalogLoadingPaths.removeAll()
        landingModelCatalogGeneration += 1
        landingModelCatalogByProject.removeAll()
        landingModelCatalogLoadingPaths.removeAll()
        if let landingDraftController {
            landingDraftController.slashCommands = []
            landingDraftController.hasCompleteModelCatalog = false
            loadLandingSlashCommands(for: landingDraftController)
        }
    }

    func updateLandingResources(_ items: [PiResourceItem], for controller: SessionController) {
        guard landingDraftController?.id == controller.id else { return }
        let previousIDs = controller.chatResources.map(\.id)
        controller.setLandingResources(items)
        guard controller.chatResources.map(\.id) != previousIDs else { return }
        controller.slashCommands = []
        loadLandingSlashCommands(for: controller)
    }

    func loadLandingSlashCommands(for controller: SessionController) {
        if controller.agentID != nil {
            // Use the actual saved draft runtime: custom extensions and commands must
            // match the agent launch configuration, never an unsaved catalog probe.
            guard !controller.hasCompleteModelCatalog, !controller.hasRuntimeOrStartup else { return }
            Task { [weak self, weak controller] in
                guard let self, let controller, self.landingDraftController === controller else { return }
                do { try await controller.ensureRPC(reloadMessages: false) }
                catch { controller.errorText = error.localizedDescription }
            }
            return
        }
        let projectPath = controller.projectPath
        let additions = controller.chatResources
        let commandKey = LandingCommandKey(projectPath: projectPath, resourceIDs: additions.map(\.id).sorted())
        let cachedCommands = slashCommandCatalogByProject[commandKey]
        let cachedModels = landingModelCatalogByProject[projectPath]
        if let cachedCommands { controller.slashCommands = cachedCommands }
        if let cachedModels {
            applyLandingModels(cachedModels, to: controller)
            controller.hasCompleteModelCatalog = true
        }

        let loadsCommands = cachedCommands == nil && slashCommandCatalogLoadingPaths.insert(commandKey).inserted
        let loadsModels = cachedModels == nil && landingModelCatalogLoadingPaths.insert(projectPath).inserted
        if cachedModels == nil { controller.isDiscoveringModels = true }
        guard loadsCommands || loadsModels else { return }
        let commandGeneration = slashCommandCatalogGeneration
        let modelGeneration = landingModelCatalogGeneration

        Task { [weak self] in
            let client = PiRPCClient(projectPath: projectPath, noSession: true, launchResources: PiLaunchResources(items: additions))
            var commands: [SlashCommandInfo] = []
            var discoveredModels: [ModelInfo]?
            do {
                try await client.start()
                if loadsModels,
                   let response = try? await client.command(["type": "get_available_models"]),
                   let data = response["data"] as? [String: Any],
                   let modelDicts = data["models"] as? [[String: Any]] {
                    let parsed = modelDicts.compactMap(ModelInfo.from)
                    if parsed.count == modelDicts.count {
                        // Cached unscoped; EnabledModelScope is applied fresh in
                        // applyLandingModels so scope edits never go stale here.
                        discoveredModels = parsed.sorted {
                            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                        }
                    }
                }
                if loadsCommands,
                   let response = try? await client.command(["type": "get_commands"]),
                   let data = response["data"] as? [String: Any],
                   let commandDicts = data["commands"] as? [[String: Any]] {
                    commands = commandDicts.compactMap(SlashCommandInfo.fromRPC)
                }
            } catch {
                // Seeded model and built-in command fallbacks remain usable; failed model discovery is not cached.
            }
            client.stop()

            guard let self else { return }
            let currentLanding = self.landingDraftController.flatMap {
                $0.projectPath == projectPath ? $0 : nil
            }
            if loadsCommands, self.slashCommandCatalogGeneration == commandGeneration {
                self.slashCommandCatalogLoadingPaths.remove(commandKey)
                self.slashCommandCatalogByProject[commandKey] = commands
                if currentLanding?.chatResources.map(\.id).sorted() == commandKey.resourceIDs {
                    currentLanding?.slashCommands = commands
                }
            }
            if loadsModels, self.landingModelCatalogGeneration == modelGeneration {
                self.landingModelCatalogLoadingPaths.remove(projectPath)
                if let discoveredModels {
                    self.landingModelCatalogByProject[projectPath] = discoveredModels
                    if let currentLanding {
                        self.applyLandingModels(discoveredModels, to: currentLanding)
                        currentLanding.hasCompleteModelCatalog = true
                    }
                }
                currentLanding?.isDiscoveringModels = false
            }
        }
    }

    func applyLandingModels(_ models: [ModelInfo], to controller: SessionController) {
        var scoped = EnabledModelScope.scopedModels(models, projectPath: controller.projectPath)
        if let preferredID = agent(for: controller)?.modelID,
           let preferred = models.first(where: { $0.id == preferredID }), !scoped.contains(where: { $0.id == preferredID }) {
            scoped.append(preferred)
        }
        let currentSelection = controller.selectedModelID
        controller.models = scoped
        if let pending = pendingLandingModelSelection, pending.controllerID == controller.id,
           landingModelCatalogByProject[controller.projectPath] != nil {
            pendingLandingModelSelection = nil
            if controller.explicitModelSelectionID == nil,
               scoped.contains(where: { $0.id == pending.modelID }) {
                controller.setModel(pending.modelID)
                return
            }
        }
        if !currentSelection.isEmpty { return }
        controller.selectedModelID = DefaultModelSchedule.effectiveModelID() ?? ""
    }

    func refreshLandingModelDefaults() {
        landingDraftController?.refreshNewSessionDefaults()
    }

    func activateLandingDraft(_ controller: SessionController) {
        guard landingDraftController?.id == controller.id else { return }
        clearAgentSelection()
        pendingLandingModelSelection = nil
        landingDraftText = ""
        landingDraftImages = []
        touchProject(controller.projectPath)
        controllers[controller.id] = controller
        syncAgentSessionRecords()
        addControllerToInbox(controller)
        selectedProjectPath = controller.projectPath
        selectedControllerID = controller.id
        composingQuickChat = false
        finishedUnseenControllerIDs.remove(controller.id)
        landingDraftController = nil
        reconcileControllerActivity()
    }

    /// Discard a landing draft, without stopping ordinary threads.
    func prepareAgentSelection() {
        clearAgentSelection()
        landingDraftController?.stopRPC()
        landingDraftController = nil
        composingQuickChat = false
        selectedProjectPath = nil
        showingSessionTree = false
    }

}
