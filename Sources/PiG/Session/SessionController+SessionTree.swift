import Foundation

extension SessionController {
    func loadSessionTree(force: Bool = false) async {
        guard agentID == nil else { addSystemNotice("Agent chats do not support branching."); return }
        if !force, sessionTree != nil { return }
        sessionTreeLoadState = .loading
        do {
            try await ensureRPC(reloadMessages: false)
            guard let rpc else { throw PiRPCClient.RPCError.notRunning }
            let response = try await rpc.command(["type": "get_tree"])
            guard let data = response["data"],
                  let snapshot = await SessionParser.parseTreeResponseAsync(SessionParser.Input(value: data)) else {
                throw PiRPCClient.RPCError.invalidResponse
            }
            sessionTree = snapshot
            sessionTreeLoadState = .loaded
        } catch {
            sessionTreeLoadState = .failed(error.localizedDescription)
            eventHandler(.log(error.localizedDescription))
        }
    }

    func forkFromTree(entryID: String) async -> Bool {
        guard agentID == nil else { addSystemNotice("Agent chats do not support branching."); return false }
        guard !isForking else { return false }
        guard isAgentSettled && !showsActivityIndicator else {
            errorText = "Wait for the agent to settle before forking."
            return false
        }
        let shouldRefreshTree = sessionTree != nil
        isForking = true
        errorText = nil
        defer { isForking = false }
        do {
            try await ensureRPC()
            guard let rpc else { throw PiRPCClient.RPCError.notRunning }
            let response = try await rpc.command(["type": "fork", "entryId": entryID])
            let data = response["data"] as? [String: Any]
            if data?["cancelled"] as? Bool == true {
                addSystemNotice("Fork cancelled by extension.")
                return false
            }
            let prefill = data?["text"] as? String ?? ""
            await refreshState()
            await reloadMessagesFromRPC()
            if shouldRefreshTree { await loadSessionTree(force: true) }
            eventHandler(.sessionsChanged)
            composerPrefillRequest = ComposerPrefillRequest(text: prefill)
            addSystemNotice("Forked chat.")
            return true
        } catch {
            errorText = error.localizedDescription
            eventHandler(.log(error.localizedDescription))
            return false
        }
    }

    func forkFromMessage(id messageID: String) async {
        guard agentID == nil else { addSystemNotice("Agent chats do not support branching."); return }
        let entryID: String?
        do {
            try await ensureRPC()
            guard let rpc else { throw PiRPCClient.RPCError.notRunning }
            let response = try await rpc.command(["type": "get_fork_messages"])
            let entryIDs = (((response["data"] as? [String: Any])?["messages"] as? [[String: Any]]) ?? [])
                .compactMap { $0["entryId"] as? String }
            if entryIDs.contains(messageID) {
                entryID = messageID
            } else {
                let userIDs = messages.filter { $0.role == .user }.map(\.id)
                guard let index = userIDs.firstIndex(of: messageID) else { throw PiRPCClient.RPCError.invalidResponse }
                let fromEnd = userIDs.count - 1 - index
                entryID = entryIDs.indices.contains(entryIDs.count - 1 - fromEnd) ? entryIDs[entryIDs.count - 1 - fromEnd] : nil
            }
        } catch {
            errorText = error.localizedDescription
            return
        }
        guard let entryID else {
            errorText = "That message can't be forked."
            return
        }
        _ = await forkFromTree(entryID: entryID)
    }

    func consumeComposerPrefill(_ id: UUID) {
        guard composerPrefillRequest?.id == id else { return }
        composerPrefillRequest = nil
    }

    func revealMessage(entryID: String) async {
        if !messages.contains(where: { $0.id == entryID }) {
            await reloadMessagesFromRPC(scrollToBottom: false)
        }
        guard let index = messages.firstIndex(where: { $0.id == entryID }) else {
            errorText = "That message is not available on the current path."
            return
        }
        let requiredLimit = messages.count - index
        visibleMessageLimit = max(visibleMessageLimit, requiredLimit)
        messageScrollRequest = MessageScrollRequest(messageID: entryID)
    }

}
