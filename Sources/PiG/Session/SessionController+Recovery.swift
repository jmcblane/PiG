import Foundation

extension SessionController {
    func fetchSessionStatistics() async throws -> SessionStatistics {
        try await ensureRPC()
        guard let rpc else { throw PiRPCClient.RPCError.notRunning }
        return try await requestSessionStatistics(using: rpc)
    }

    func requestSessionStatistics(using client: PiRPCClient) async throws -> SessionStatistics {
        let generation = runtimeGeneration
        let path = sessionPath
        let response = try await client.command(["type": "get_session_stats"])
        try Task.checkCancellation()
        guard rpc === client, runtimeGeneration == generation, sessionPath == path else {
            throw CancellationError()
        }
        guard let data = response["data"] as? [String: Any],
              data["totalMessages"] is Int || data["tokens"] is [String: Any] else {
            throw PiRPCClient.RPCError.commandFailed("Chat statistics are unavailable from this backend.")
        }
        return SessionStatistics(data)
    }

    func reloadMessagesFromRPC(scrollToBottom: Bool = true) async {
        resetStreamingState()
        guard let rpc, rpc.isRunning else { return }
        guard let loaded = try? await loadRPCMessages(using: rpc) else { return }
        await MarkdownPrewarmer.warm(loaded, theme: AppThemeChoice.stored)
        guard self.rpc === rpc, !Task.isCancelled else { return }
        messages = loaded
        if scrollToBottom { bottomScrollRequest += 1 }
    }

    func addSystemNotice(_ text: String) {
        messages.append(ChatMessage(role: .system, text: text, timestamp: Date()))
        bottomScrollRequest += 1
    }

    func clearRecoveredError(_ source: ErrorSource, id: UUID) {
        guard errorSource == source, errorID == id else { return }
        errorText = nil
    }

    func refreshState() async {
        guard let rpc, rpc.isRunning else { return }
        let recoveringErrorID = errorID
        let wasActive = showsActivityIndicator
        if let stateResponse = try? await rpc.command(["type": "get_state"]),
           let data = stateResponse["data"] as? [String: Any] {
            guard self.rpc === rpc, !Task.isCancelled else { return }
            applyRecoveryMetadata(data)
            if let streaming = data["isStreaming"] as? Bool { isWorking = streaming }
            if let compacting = data["isCompacting"] as? Bool { isCompacting = compacting }
            clearRecoveredError(.liveUpdates, id: recoveringErrorID)
        }
        if let stats = try? await requestSessionStatistics(using: rpc) {
            contextTokens = stats.contextTokens
            contextWindow = stats.contextWindow
            contextPercent = stats.contextPercent
        }
        if wasActive != showsActivityIndicator { eventHandler(.activityChanged) }
        updateRecoveryTimer()
    }

    func performRecoveryCheck(refreshMessagesWhenIdle: Bool = false) async {
        guard !recoveryCheckInFlight,
              recoveryRequests != nil || (rpc?.isRunning == true && isProcessActive) else { return }
        recoveryCheckInFlight = true
        defer { recoveryCheckInFlight = false }

        let revision = recoveryRevision
        let generation = runtimeGeneration
        let recoveringErrorID = errorID
        do {
            let state = try await requestRecoveryState()
            guard recoverySnapshotIsCurrent(revision: revision, generation: generation) else { return }

            let streaming = state["isStreaming"] as? Bool
            let compacting = state["isCompacting"] as? Bool
            let pending = state["pendingMessageCount"] as? Int
            // RPC state is authoritative; local queues may have missed their final update.
            let reportsActive = streaming == true || compacting == true || (pending ?? 0) > 0
            let reportsFinished = streaming == false && compacting == false && pending == 0
            var recoveredMessages: [ChatMessage]?

            if reportsFinished || (refreshMessagesWhenIdle && !showsActivityIndicator && !reportsActive) {
                recoveredMessages = try await requestRecoveryMessages()
                guard recoverySnapshotIsCurrent(revision: revision, generation: generation) else { return }
                if let recoveredMessages {
                    await MarkdownPrewarmer.warm(recoveredMessages, theme: AppThemeChoice.stored)
                    guard recoverySnapshotIsCurrent(revision: revision, generation: generation) else { return }
                }
            }

            let wasActive = showsActivityIndicator
            applyRecoveryMetadata(state)
            if reportsActive {
                isAgentSettled = false
                isWorking = true
                isCompacting = compacting == true
            } else if reportsFinished {
                resetStreamingState()
                clearQueueState()
                resetIdleActivity()
            }
            if let recoveredMessages {
                messages = recoveredMessages
                bottomScrollRequest += 1
            }
            clearRecoveredError(.liveUpdates, id: recoveringErrorID)
            if wasActive != showsActivityIndicator { eventHandler(.activityChanged) }
            if reportsFinished { eventHandler(.sessionsChanged) }
            updateRecoveryTimer()
        } catch {
            guard recoverySnapshotIsCurrent(revision: revision, generation: generation) else { return }
            guard let rpcError = error as? PiRPCClient.RPCError,
                  case .timedOut(let command) = rpcError,
                  command == "get_state" else {
                eventHandler(.log(error.localizedDescription))
                return
            }
            var saved: [ChatMessage]?
            if let path = sessionPath {
                saved = await requestSavedMessages(path: path)
                guard recoverySnapshotIsCurrent(revision: revision, generation: generation) else { return }
                if let saved {
                    await MarkdownPrewarmer.warm(saved, theme: AppThemeChoice.stored)
                    guard recoverySnapshotIsCurrent(revision: revision, generation: generation) else { return }
                }
            }
            // A delayed timeout must not replace a newer or unrelated error.
            if errorID == recoveringErrorID, errorText == nil || errorSource == .liveUpdates {
                errorText = Self.liveUpdatesUnavailableNotice
            }
            if let saved {
                messages = saved
                bottomScrollRequest += 1
            }
        }
    }

    private func requestRecoveryState() async throws -> [String: Any] {
        if let recoveryRequests { return try await recoveryRequests.getState() }
        guard let rpc, rpc.isRunning else { throw PiRPCClient.RPCError.notRunning }
        let response = try await rpc.command(["type": "get_state"])
        guard let data = response["data"] as? [String: Any] else { throw PiRPCClient.RPCError.invalidResponse }
        return data
    }

    private func requestRecoveryMessages() async throws -> [ChatMessage] {
        if let recoveryRequests { return try await recoveryRequests.getMessages() }
        guard let rpc, rpc.isRunning else { throw PiRPCClient.RPCError.notRunning }
        return try await loadRPCMessages(using: rpc)
    }

    private func loadRPCMessages(using rpc: PiRPCClient) async throws -> [ChatMessage] {
        if let response = try? await rpc.command(["type": "get_entries"]),
           let data = response["data"],
           let loaded = await SessionParser.parseEntriesResponseAsync(SessionParser.Input(value: data)) {
            return loaded
        }
        let response = try await rpc.command(["type": "get_messages"])
        guard let data = response["data"] else { throw PiRPCClient.RPCError.invalidResponse }
        return await SessionParser.parseMessagesResponseAsync(SessionParser.Input(value: data))
    }

    private func requestSavedMessages(path: String) async -> [ChatMessage]? {
        if let recoveryRequests { return await recoveryRequests.loadSavedMessages(path) }
        return await SessionParser.parseFileAsync(URL(fileURLWithPath: path))?.messages
    }

    private func recoverySnapshotIsCurrent(revision: Int, generation: Int) -> Bool {
        recoveryRevision == revision && runtimeGeneration == generation
            && (recoveryRequests != nil || (rpc?.isRunning == true && isProcessActive))
    }

    private func applyRecoveryMetadata(_ data: [String: Any]) {
        if let file = data["sessionFile"] as? String, file != sessionPath {
            sessionPath = file
            sessionTree = nil
            sessionTreeLoadState = .idle
            eventHandler(.sessionFileChanged)
        }
        if let name = data["sessionName"] as? String, !name.isEmpty, name != title {
            title = name
            eventHandler(.titleChanged)
        }
        if let level = data["thinkingLevel"] as? String { thinkingLevel = level }
        if let steering = data["steeringMode"] as? String { steeringMode = steering }
        if let followUp = data["followUpMode"] as? String { followUpMode = followUp }
        if let autoCompact = data["autoCompactionEnabled"] as? Bool { autoCompactionEnabled = autoCompact }
        if let pending = data["pendingMessageCount"] as? Int { pendingMessageCount = pending }
        if let model = data["model"] as? [String: Any], let info = ModelInfo.from(model) {
            if !models.contains(info) { models.append(info) }
            selectedModelID = info.id
        }
    }

    func updateRecoveryTimer() {
        let shouldRun = isProcessActive && showsActivityIndicator && rpc?.isRunning == true
        guard shouldRun else {
            recoveryTimerTask?.cancel()
            recoveryTimerTask = nil
            return
        }
        guard recoveryTimerTask == nil else { return }
        recoveryTimerTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: Self.recoveryInterval) }
            catch { return }
            guard let self else { return }
            self.recoveryTimerTask = nil
            await self.performRecoveryCheck()
            self.updateRecoveryTimer()
        }
    }

}
