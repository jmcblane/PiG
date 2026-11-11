import Foundation

extension SessionController {
    /// Removing an agent keeps the live thread and saved transcript as a plain session.
    func removeAgentConfiguration() {
        agentID = nil
        agentConfiguration = nil
        launchResources = PiLaunchResources(items: chatResources)
    }

    // Draft additions are editable only until the first RPC startup (including failed starts).
    func setLandingResources(_ items: [PiResourceItem]) {
        guard !launchResourcesFrozen, rpcStartupTask == nil, rpc == nil else { return }
        chatResources = items
        launchResources = PiLaunchResources(items: items)
    }

    func stopRPC() {
        recoveryRevision &+= 1
        runtimeGeneration &+= 1
        recoveryTimerTask?.cancel()
        recoveryTimerTask = nil
        rpcStartupRevision &+= 1
        let startupTask = rpcStartupTask
        rpcStartupTask = nil
        startupTask?.cancel()
        resetStreamingState()
        backgroundJobTools.removeAll()
        rpc?.stop()
        rpc = nil
        markRPCInactive()
    }

    func suspendRuntime() {
        if isQuickChat {
            quickChatClosed = true
            errorText = closedQuickChatNotice
        }
        runtimeLoadingSuspended = true
        automaticTitleTask?.cancel()
        automaticTitleTask = nil
        automaticTitleRequestID = nil
        stopRPC()
    }

    func resumeRuntimeLoading() {
        guard !quickChatClosed else {
            errorText = closedQuickChatNotice
            return
        }
        runtimeLoadingSuspended = false
    }

    func reloadRuntime() async throws {
        guard !isQuickChat else { throw PiRPCClient.RPCError.commandFailed("Quick chat runtimes are not reloadable") }
        guard !showsActivityIndicator else { throw PiRPCClient.RPCError.commandFailed("Cannot reload while the agent is working") }
        let shouldRefreshTree = sessionTree != nil
        stopRPC()
        try await ensureRPC()
        await refreshSlashCommands()
        await reloadMessagesFromRPC()
        await refreshState()
        if shouldRefreshTree { await loadSessionTree(force: true) }
    }

    func ensureRPC(reloadMessages: Bool = true) async throws {
        try Task.checkCancellation()
        guard !quickChatClosed else { throw PiRPCClient.RPCError.commandFailed(closedQuickChatNotice) }
        guard !runtimeLoadingSuspended else {
            throw PiRPCClient.RPCError.commandFailed("Chat runtime is unloaded. Reopen or reconnect the chat to load it.")
        }
        lastRuntimeUse = Date()
        if let rpcStartupTask {
            try await rpcStartupTask.value
            try Task.checkCancellation()
            return
        }
        if rpc?.isRunning == true { return }

        launchResourcesFrozen = true
        rpcStartupRevision &+= 1
        let revision = rpcStartupRevision
        let startupTask = Task { @MainActor in
            try await self.startRPC(reloadMessages: reloadMessages)
        }
        rpcStartupTask = startupTask
        do {
            try await startupTask.value
            if rpcStartupRevision == revision { rpcStartupTask = nil }
        } catch {
            if rpcStartupRevision == revision { rpcStartupTask = nil }
            throw error
        }
    }

    private func startRPC(reloadMessages: Bool) async throws {
        try Task.checkCancellation()
        guard !runtimeLoadingSuspended else { throw PiRPCClient.RPCError.notRunning }
        recoveryRevision &+= 1
        runtimeGeneration &+= 1
        recoveryTimerTask?.cancel()
        recoveryTimerTask = nil
        // pi allocates a path before the first turn writes it. An unloaded empty
        // agent chat must create another fresh session, not switch to a missing file.
        if agentID != nil, let path = sessionPath, !FileManager.default.fileExists(atPath: path) { sessionPath = nil }
        let emptyChat = messages.isEmpty || (agentID != nil && messages.allSatisfy { $0.role == .system })
        let shouldApplyNewSessionDefaults = (createdAsNewSession || agentID != nil) && sessionPath == nil && emptyChat
        resetStreamingState()
        clearQueueState()
        if let agent = agentConfiguration?() {
            try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
            launchResources = PiLaunchResources(agent: agent)
        }
        let resources = try PiGBundledExtensions.addingTo(launchResources)
        let client = PiRPCClient(projectPath: projectPath, noSession: isQuickChat, launchResources: resources)
        client.onEvent = { [weak self, weak client] event in
            guard let self, self.rpc === client else { return }
            self.receiveRPCEvent(event)
        }
        client.onExtensionUIRequest = { [weak self, weak client] request in
            guard let self, self.rpc === client else { return }
            self.handleExtensionUIRequest(request)
        }
        client.onLog = { [weak self] log in self?.eventHandler(.log(log)) }
        client.onTermination = { [weak self, weak client] in
            guard let self, self.rpc === client else { return }
            self.markRPCInactive()
        }
        rpc = client
        func checkCurrentStartup() throws {
            try Task.checkCancellation()
            guard rpc === client, !runtimeLoadingSuspended else { throw PiRPCClient.RPCError.notRunning }
        }
        do {
            try await client.start()
            try Task.checkCancellation()
            guard !runtimeLoadingSuspended, rpc === client else {
                client.stop()
                throw PiRPCClient.RPCError.notRunning
            }
        } catch {
            client.stop()
            if rpc === client { rpc = nil }
            throw error
        }
        isProcessActive = true
        eventHandler(.activityChanged)

        if let sessionPath {
            let switchResponse = try await client.command(["type": "switch_session", "sessionPath": sessionPath])
            try checkCurrentStartup()
            if let data = switchResponse["data"] as? [String: Any], data["cancelled"] as? Bool == true {
                throw PiRPCClient.RPCError.commandFailed("Chat switch cancelled")
            }
            if reloadMessages {
                await reloadMessagesFromRPC()
            }
        }

        try checkCurrentStartup()
        isDiscoveringModels = true
        hasCompleteModelCatalog = false
        if let modelResponse = try? await client.command(["type": "get_available_models"]),
           let data = modelResponse["data"] as? [String: Any],
           let modelDicts = data["models"] as? [[String: Any]] {
            try checkCurrentStartup()
            let parsedModels = modelDicts.compactMap(ModelInfo.from)
            if parsedModels.count == modelDicts.count {
                let sorted = parsedModels.sorted { $0.displayName < $1.displayName }
                models = EnabledModelScope.scopedModels(sorted, projectPath: projectPath)
                if let preferredID = agentConfiguration?()?.modelID,
                   let preferred = sorted.first(where: { $0.id == preferredID }), !models.contains(where: { $0.id == preferredID }) {
                    models.append(preferred)
                }
                hasCompleteModelCatalog = true
            }
        }
        try checkCurrentStartup()
        isDiscoveringModels = false
        if shouldApplyNewSessionDefaults {
            do {
                guard hasCompleteModelCatalog else {
                    throw PiRPCClient.RPCError.commandFailed("Could not load available models. Retry before starting this chat.")
                }
                let preferredID = hasExplicitModelSelection
                    ? selectedModelID
                    : (agentConfiguration?()?.modelID ?? DefaultModelSchedule.effectiveModelID() ?? "")
                guard let model = models.first(where: { $0.id == preferredID }) else {
                    throw PiRPCClient.RPCError.commandFailed("The selected default model ‘\(preferredID)’ is unavailable or not configured. Choose a model in the composer or Settings → Models.")
                }
                _ = try await client.command(["type": "set_model", "provider": model.provider, "modelId": model.modelId])
                try checkCurrentStartup()
                selectedModelID = model.id
                if !hasExplicitThinkingSelection { thinkingLevel = agentConfiguration?()?.thinking ?? GlobalThinkingSelection.level }
                _ = try await client.command(["type": "set_thinking_level", "level": thinkingLevel])
            } catch {
                if rpc === client { stopRPC() }
                throw error
            }
        }
        try checkCurrentStartup()
        await refreshState()
        try checkCurrentStartup()
        await refreshSlashCommands()
        try checkCurrentStartup()
    }

    func resetIdleActivity() {
        isAgentSettled = true
        isWorking = false
        isThinking = false
        isCompacting = false
    }

    private func markRPCInactive() {
        retryErrorID = nil
        recoveryRevision &+= 1
        runtimeGeneration &+= 1
        recoveryTimerTask?.cancel()
        recoveryTimerTask = nil
        resetStreamingState()
        restoreLocalQueuedImagesIfNeeded()
        clearQueueState()
        clearExtensionUIRuntimeState()
        isProcessActive = false
        isDiscoveringModels = false
        resetIdleActivity()
        eventHandler(.activityChanged)
    }

}
