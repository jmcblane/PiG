import Foundation

extension SessionController {
    func receiveRPCEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        // Nested calls (e.g. from codemode scripts) are reported by their parent
        // tool and never appear in the transcript, except the tool a `background`
        // job runs: it outlives its parent call, so it gets its own live row.
        if type.hasPrefix("tool_execution_"), let parentID = event["parentToolCallId"] as? String {
            updateBackgroundJobRow(event, type: type, parentID: parentID)
            return
        }
        recoveryRevision &+= 1
        defer { updateRecoveryTimer() }
        switch type {
        case "agent_start", "turn_start", "agent_end", "turn_end", "agent_settled",
             "message_start", "message_update", "message_end", "queue_update",
             "tool_execution_start", "tool_execution_update", "tool_execution_end",
             "compaction_start", "compaction_end", "auto_retry_start", "auto_retry_end":
            clearRecoveredError(.liveUpdates, id: errorID)
        default:
            break
        }
        if type == "auto_retry_start" {
            // Bind recovery to this assistant error, not just matching display text.
            retryErrorID = errorSource == .assistant && event["errorMessage"] as? String == errorText
                ? errorID : nil
        }
        switch type {
        case "agent_start", "turn_start", "auto_retry_start":
            // Routine retries stay quiet: the working indicator already
            // reflects activity. A global toast per retry would spam loops.
            isAgentSettled = false
            isWorking = true
            eventHandler(.activityChanged)
        case "agent_end":
            finishStreamingReveal(immediate: false)
            clearStreamingAccumulator()
            isWorking = false
            isThinking = false
            eventHandler(.activityChanged)
            eventHandler(.sessionsChanged)
            Task { await refreshState() }
        case "turn_end":
            if let toolResults = event["toolResults"] as? [[String: Any]] {
                for result in toolResults { mergeToolResult(result) }
            }
        case "queue_update":
            queuedSteering = event["steering"] as? [String] ?? []
            queuedFollowUps = event["followUp"] as? [String] ?? []
        case "message_start":
            if let agent = event["message"] as? [String: Any], agent["role"] as? String == "assistant" {
                finishStreamingReveal(immediate: true)
                clearStreamingAccumulator()
                let id = UUID().uuidString
                streamingMessageID = id
                streamingTargetMessage = ChatMessage(id: id, role: .assistant, isStreaming: true)
                messages.append(ChatMessage(id: id, role: .assistant, isStreaming: true))
                streamingFrameToken += 1
            } else if let agent = event["message"] as? [String: Any], agent["role"] as? String == "user" {
                markQueuedImagesDelivered(in: agent["content"])
            }
        case "message_update":
            handleMessageUpdate(event)
        case "message_end":
            handleMessageEnd(event)
        case "tool_execution_start":
            upsertToolExecution(event, status: .running, result: nil, details: nil, isError: false)
            isWorking = true
            eventHandler(.activityChanged)
        case "tool_execution_update":
            if let partial = event["partialResult"] as? [String: Any] {
                upsertToolExecution(
                    event,
                    status: .running,
                    result: SessionParser.contentText(partial["content"]),
                    details: partial["details"].map(jsonString),
                    images: SessionParser.contentImages(partial["content"]),
                    isError: false
                )
            }
        case "tool_execution_end":
            let resultDict = event["result"] as? [String: Any]
            upsertToolExecution(
                event,
                status: (event["isError"] as? Bool == true) ? .failed : .succeeded,
                result: SessionParser.contentText(resultDict?["content"]),
                details: resultDict?["details"].map(jsonString),
                images: SessionParser.contentImages(resultDict?["content"]),
                isError: event["isError"] as? Bool ?? false
            )
            if let toolName = event["toolName"] as? String, ["delegate_agent", "subagent"].contains(toolName) {
                eventHandler(.sessionsChanged)
            }
        case "compaction_start":
            isAgentSettled = false
            isCompacting = true
            isWorking = true
            eventHandler(.activityChanged)
        case "compaction_end":
            isCompacting = false
            eventHandler(.activityChanged)
        case "auto_retry_end":
            if event["success"] as? Bool == true, let retryErrorID {
                clearRecoveredError(.assistant, id: retryErrorID)
            } else if event["success"] as? Bool == false {
                resetStreamingState()
                isWorking = false
            }
            retryErrorID = nil
            eventHandler(.activityChanged)
        case "agent_settled":
            finishStreamingReveal(immediate: false)
            clearStreamingAccumulator()
            resetIdleActivity()
            eventHandler(.activityChanged)
            eventHandler(.sessionsChanged)
            let shouldRefreshTree = sessionTree != nil
            Task {
                await refreshState()
                if shouldRefreshTree { await loadSessionTree(force: true) }
            }
        case "extension_error":
            errorText = event["error"] as? String
        default:
            break
        }
    }

    private func handleMessageUpdate(_ event: [String: Any]) {
        guard let assistantEvent = event["assistantMessageEvent"] as? [String: Any] else { return }
        let wasActive = showsActivityIndicator
        if streamingAccumulator == nil {
            streamingAccumulator = StreamingAssistantAccumulator()
        }
        streamingAccumulator?.apply(assistantEvent)
        streamingAccumulatorNeedsSnapshot = true
        isThinking = streamingAccumulator?.hasActiveThinking ?? false
        isWorking = true
        if wasActive != showsActivityIndicator { eventHandler(.activityChanged) }

        let id = streamingMessageID ?? UUID().uuidString
        streamingMessageID = id
        ensureStreamingMessageExists(id: id)
        scheduleStreamingReveal()
    }

    private func handleMessageEnd(_ event: [String: Any]) {
        guard let agent = event["message"] as? [String: Any], let role = agent["role"] as? String else {
            resetStreamingState()
            return
        }
        clearStreamingAccumulator()
        if role == "assistant" {
            let id = streamingMessageID ?? UUID().uuidString
            streamingMessageID = id
            ensureStreamingMessageExists(id: id)
            guard var final = (event["_pigParsedChatMessage"] as? ChatMessage)
                ?? SessionParser.chatMessage(fromAgentMessage: agent, id: id, streaming: false) else {
                resetStreamingState()
                return
            }
            final.id = id
            final.isStreaming = false
            final.completedAt = Date()
            if let message = agent["errorMessage"] as? String, !message.isEmpty {
                errorText = message
                errorSource = .assistant
            }
            // Some runtimes report retry success for any non-error stop, including aborts.
            if agent["stopReason"] as? String == "aborted" { retryErrorID = nil }
            if let index = messages.firstIndex(where: { $0.id == id }) {
                let reconciled = reconcileToolExecution(existing: messages[index].tools, authoritative: final.tools)
                if messages[index].tools != reconciled {
                    messages[index].tools = reconciled
                    streamingFrameToken += 1
                }
            }
            setStreamingTarget(final, authoritativeTools: true)
            isThinking = false
            eventHandler(.activityChanged)
        } else if role == "custom" {
            guard let message = (event["_pigParsedChatMessage"] as? ChatMessage)
                ?? SessionParser.chatMessage(fromAgentMessage: agent, streaming: false) else { return }
            if message.isBackgroundJobResult {
                // The result message now carries these jobs; drop their live state. A job
                // that ended before PiG saw its number (id 0) is dropped once finished.
                let jobIDs = Set(message.tools.compactMap { $0.backgroundJob?.id })
                backgroundJobTools = backgroundJobTools.filter { _, tool in
                    let id = tool.backgroundJob?.id ?? 0
                    return !(jobIDs.contains(id) || (id == 0 && tool.status != .running))
                }
            }
            messages.append(message)
        }
    }

    /// Tracks the tool a `background` job runs. Its events carry the `background` call
    /// as parent and keep arriving after that call and its turn have ended. The
    /// transcript shows this state on the `background` row. Deeper nested calls stay hidden.
    private func updateBackgroundJobRow(_ event: [String: Any], type: String, parentID: String) {
        guard let parent = findTool(parentID), parent.name == "background" else { return }
        // The job number is in the `background` result, which can arrive after the job starts.
        let parentDetails = parent.details
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let jobID = parentDetails?["id"] as? Int ?? 0
        var payload: [String: Any]?
        var status = ToolStatus.running
        var isError = false
        switch type {
        case "tool_execution_update":
            payload = event["partialResult"] as? [String: Any]
        case "tool_execution_end":
            payload = event["result"] as? [String: Any]
            isError = event["isError"] as? Bool ?? false
            status = isError ? .failed : .succeeded
        default:
            break
        }
        let old = backgroundJobTools[parentID]
        let images = SessionParser.contentImages(payload?["content"])
        backgroundJobTools[parentID] = ToolDisplay(
            id: parentID,
            name: event["toolName"] as? String ?? old?.name ?? "tool",
            arguments: event["args"].map(jsonString) ?? old?.arguments ?? "",
            result: payload.map { SessionParser.contentText($0["content"]) } ?? old?.result ?? "",
            details: payload?["details"].map(jsonString) ?? old?.details,
            images: images.isEmpty ? old?.images ?? [] : images,
            status: status,
            isError: isError,
            backgroundJob: BackgroundJobInfo(
                id: jobID,
                startedAt: old?.backgroundJob?.startedAt ?? Date()
            )
        )
        streamingFrameToken += 1
    }

    private func mergeToolResult(_ result: [String: Any]) {
        guard let toolId = result["toolCallId"] as? String ?? result["id"] as? String else { return }
        let name = result["toolName"] as? String ?? "tool"
        let isError = result["isError"] as? Bool ?? false
        let tool = ToolDisplay(
            id: toolId,
            name: name,
            arguments: "",
            result: SessionParser.contentText(result["content"]),
            details: result["details"].map(jsonString),
            images: SessionParser.contentImages(result["content"]),
            status: isError ? .failed : .succeeded,
            isError: isError
        )
        attachOrAppend(tool)
    }

    private func upsertToolExecution(_ event: [String: Any], status: ToolStatus, result: String?, details: String?, images: [ImageAttachment] = [], isError: Bool) {
        guard let toolId = event["toolCallId"] as? String else { return }
        let name = event["toolName"] as? String ?? "tool"
        let args = event["args"].map(jsonString) ?? ""
        var tool = ToolDisplay(id: toolId, name: name, arguments: args, result: result ?? "", details: details, images: images, status: status, isError: isError)
        if let existing = findTool(toolId) {
            if result == nil { tool.result = existing.result }
            if details == nil { tool.details = existing.details }
            if images.isEmpty { tool.images = existing.images }
        }
        attachOrAppend(tool)
    }

    private func attachOrAppend(_ tool: ToolDisplay) {
        for index in messages.indices.reversed() where messages[index].role == .assistant || messages[index].role == .system {
            if let toolIndex = messages[index].tools.firstIndex(where: { $0.id == tool.id }) {
                let old = messages[index].tools[toolIndex]
                messages[index].tools[toolIndex] = ToolDisplay(
                    id: tool.id,
                    name: tool.name.isEmpty ? old.name : tool.name,
                    arguments: tool.arguments.isEmpty ? old.arguments : tool.arguments,
                    result: tool.result.isEmpty ? old.result : tool.result,
                    details: tool.details ?? old.details,
                    images: tool.images.isEmpty ? old.images : tool.images,
                    status: tool.status,
                    isError: tool.isError
                )
                streamingFrameToken += 1
                return
            }
        }
        if let index = messages.indices.reversed().first(where: { messages[$0].role == .assistant }) {
            messages[index].tools.append(tool)
        } else {
            messages.append(ChatMessage(role: .system, tools: [tool]))
        }
        streamingFrameToken += 1
    }

    private func findTool(_ id: String) -> ToolDisplay? {
        for message in messages.reversed() {
            if let tool = message.tools.first(where: { $0.id == id }) { return tool }
        }
        return nil
    }

    func mergeTools(existing: [ToolDisplay], incoming: [ToolDisplay]) -> [ToolDisplay] {
        var merged = existing
        for tool in incoming {
            if let index = merged.firstIndex(where: { $0.id == tool.id }) {
                let old = merged[index]
                merged[index] = ToolDisplay(
                    id: tool.id,
                    name: tool.name,
                    arguments: tool.arguments.isEmpty ? old.arguments : tool.arguments,
                    result: old.result.isEmpty ? tool.result : old.result,
                    details: old.details ?? tool.details,
                    images: old.images.isEmpty ? tool.images : old.images,
                    status: old.status == .pending ? tool.status : old.status,
                    isError: old.isError || tool.isError
                )
            } else {
                merged.append(tool)
            }
        }
        return merged
    }
}
