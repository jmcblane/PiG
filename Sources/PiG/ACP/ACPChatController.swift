import Foundation
import Combine

/// Drives one ACP chat session (one dedicated `agy acp` subprocess per active chat).
@MainActor
final class ACPChatController: ObservableObject, Identifiable, HTMLWidgetActionTarget {
    enum Event {
        case activityChanged
        case sessionBound(String)
        case metadataChanged
        case replyFinished
        case log(String)
    }

    let id: String
    let projectPath: String
    let isQuickChat: Bool
    let serverConfig: ACPServerConfig

    @Published private(set) var sessionID: String?
    @Published var title: String
    @Published var messages: [ChatMessage] = []
    @Published private(set) var isWorking = false
    @Published private(set) var isThinking = false
    @Published private(set) var isCompacting = false
    @Published var errorText: String?
    @Published var dismissedErrorToast: String?
    @Published private(set) var authRequired = false
    @Published private(set) var authMethods: [ACPAuthMethod] = []
    @Published private(set) var models: [ModelInfo] = []
    @Published private(set) var selectedModelID: String
    @Published private(set) var thinkingLevel: String
    @Published private(set) var modes: [ACPModeInfo]
    @Published private(set) var currentModeID: String
    @Published private(set) var slashCommands: [SlashCommandInfo] = []
    @Published private(set) var contextUsed: Int?
    @Published private(set) var contextWindow: Int?
    @Published private(set) var planEntries: [ACPPlanEntry] = []
    @Published private(set) var permissionPrompt: ACPPermissionPrompt?
    @Published private(set) var isProcessActive = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var capabilities = ACPAgentCapabilities()
    @Published var streamingFrameToken = 0
    @Published var bottomScrollRequest = 0
    @Published var messageScrollRequest: MessageScrollRequest?
    @Published private var visibleMessageLimit = 60

    private(set) var lastRuntimeUse = Date()
    private var client: ACPClient?
    private let eventHandler: (Event) -> Void
    private var startTask: Task<Void, Error>?
    private var activePromptTask: Task<Void, Never>?
    private var isReplayingHistory = false
    private var rawInputByToolID: [String: [String: Any]] = [:]
    private var toolMetaByID: [String: (name: String, title: String?, kind: String?)] = [:]
    private var streamingBumpScheduled = false
    private var hasReceivedReplayMessages = false

    var hasLiveWork: Bool { isWorking || permissionPrompt != nil }
    var supportsImages: Bool { capabilities.supportsImages }
    var activeModel: ModelInfo? { models.first { $0.id == selectedModelID } }

    var availableThinkingLevels: [String] {
        let levels = activeModel?.thinkingLevels ?? ["low", "medium", "high"]
        return levels.isEmpty ? ["off"] : levels
    }

    var currentMode: ACPModeInfo? {
        modes.first { $0.id == currentModeID }
    }

    var contextPercent: Double? {
        guard let used = contextUsed, let window = contextWindow, window > 0 else { return nil }
        return min(100, (Double(used) / Double(window)) * 100)
    }

    init(
        id: String = UUID().uuidString,
        sessionID: String? = nil,
        projectPath: String,
        isQuickChat: Bool = false,
        title: String = "Untitled",
        models: [ModelInfo] = [],
        selectedModelID: String = "",
        thinkingLevel: String = "high",
        modes: [ACPModeInfo] = ACPModeInfo.antigravityDefaults,
        modeID: String = ACPDefaultModePreference.modeID,
        serverConfig: ACPServerConfig = .antigravity(),
        eventHandler: @escaping (Event) -> Void = { _ in }
    ) {
        self.id = id
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.isQuickChat = isQuickChat
        self.title = title
        self.models = models
        self.selectedModelID = selectedModelID.isEmpty ? (models.first?.id ?? "") : selectedModelID
        self.thinkingLevel = thinkingLevel
        self.modes = modes.isEmpty ? ACPModeInfo.antigravityDefaults : modes
        self.currentModeID = modeID
        self.serverConfig = serverConfig
        self.eventHandler = eventHandler
    }

    deinit {
        startTask?.cancel()
        activePromptTask?.cancel()
        let owned = client
        Task { @MainActor in owned?.stop() }
    }

    func markRuntimeUsed() {
        lastRuntimeUse = Date()
    }

    // MARK: - Process & session lifecycle

    func ensureStarted() async throws {
        markRuntimeUsed()
        if let client, client.isRunning, sessionID != nil {
            isProcessActive = true
            return
        }
        if let startTask {
            return try await startTask.value
        }

        let task = Task<Void, Error> { @MainActor in
            defer { self.startTask = nil }
            try await self.performStart()
        }
        startTask = task
        return try await task.value
    }

    func loadExistingSessionIfNeeded() async {
        guard sessionID != nil else { return }
        if isProcessActive, !messages.isEmpty { return }
        do {
            try await ensureStarted()
        } catch {
            handleError(error)
        }
    }

    private func performStart() async throws {
        errorText = nil
        authRequired = false

        let client = ACPClient(config: serverConfig, workingDirectory: projectPath)
        client.onNotification = { [weak self] method, params in
            self?.handleNotification(method: method, params: params)
        }
        client.onRequest = { [weak self] id, method, params in
            self?.handleServerRequest(id: id, method: method, params: params)
        }
        client.onLog = { [weak self] line in
            self?.eventHandler(.log("[ACP] \(line)"))
        }
        client.onTermination = { [weak self] status in
            self?.handleTermination(status: status)
        }

        self.client = client
        try await client.start()
        isProcessActive = true

        let initResult = try await client.initialize()
        capabilities = initResult.capabilities
        authMethods = initResult.authMethods

        let mcpServers = ACPHTMLRenderBridge.mcpServersPayload()
        let includeMeta = serverConfig.isAntigravity
            && capabilities.supportsAntigravitySystemPromptAppend
            && !mcpServers.isEmpty

        if let existingSessionID = sessionID, capabilities.loadSession {
            isLoadingHistory = true
            isReplayingHistory = true
            hasReceivedReplayMessages = false
            rawInputByToolID.removeAll()
            toolMetaByID.removeAll()
            let previousMessages = messages
            messages = []
            defer {
                isReplayingHistory = false
                isLoadingHistory = false
            }
            do {
                let result = try await client.loadSession(
                    sessionID: existingSessionID,
                    cwd: projectPath,
                    mcpServers: mcpServers
                )
                finalizeReplayedMessages()
                if !hasReceivedReplayMessages && !previousMessages.isEmpty {
                    messages = previousMessages
                }
                applySessionMetadata(from: result, preserveRequestedModel: false)
                bottomScrollRequest &+= 1
            } catch {
                if !hasReceivedReplayMessages && !previousMessages.isEmpty {
                    messages = previousMessages
                }
                throw error
            }
        } else {
            let requestedModelID = selectedModelID
            let requestedThinking = thinkingLevel
            let requestedModeID = currentModeID

            let result = try await client.newSession(
                cwd: projectPath,
                mcpServers: mcpServers,
                meta: ACPHTMLRenderBridge.sessionMeta(includeHTMLRender: includeMeta)
            )
            guard let createdID = result["sessionId"] as? String, !createdID.isEmpty else {
                throw ACPClient.ACPError.invalidPayload
            }
            sessionID = createdID
            applySessionMetadata(from: result, preserveRequestedModel: false)
            eventHandler(.sessionBound(createdID))

            // Apply the model, thinking level, and mode chosen on the landing page.
            await applyInitialSelections(
                modelID: requestedModelID,
                thinking: requestedThinking,
                modeID: requestedModeID
            )
        }
    }

    private func applyInitialSelections(modelID: String, thinking: String, modeID: String) async {
        if !modelID.isEmpty, modelID != selectedModelID {
            await setModel(modelID)
        }
        if !thinking.isEmpty, thinking != thinkingLevel, availableThinkingLevels.contains(thinking) {
            await setThinkingLevel(thinking)
        }
        if !modeID.isEmpty, modeID != currentModeID, modes.contains(where: { $0.id == modeID }) {
            await setMode(modeID)
        }
    }

    func stopProcess() {
        startTask?.cancel()
        startTask = nil
        activePromptTask?.cancel()
        activePromptTask = nil
        if let prompt = permissionPrompt, let client, client.isRunning {
            try? client.respond(id: prompt.rpcRequestID, result: ["outcome": ["outcome": "cancelled"]])
        }
        permissionPrompt = nil
        client?.onNotification = nil
        client?.onRequest = nil
        client?.onTermination = nil
        client?.stop()
        client = nil
        isProcessActive = false
        if isWorking || isThinking {
            isWorking = false
            isThinking = false
            finalizeStreamingMessages(stopReason: "cancelled")
            eventHandler(.activityChanged)
        }
    }

    // MARK: - Prompting & control

    func send(_ text: String, images: [ImageAttachment] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        guard !isWorking else { return }

        errorText = nil
        dismissedErrorToast = nil
        authRequired = false
        markRuntimeUsed()

        let prepared = PromptEnvelope.prepare(canonicalText: trimmed, projectPath: projectPath)
        let userMessage = ChatMessage(
            id: "acp-user-\(UUID().uuidString)",
            role: .user,
            text: prepared.displayText,
            canonicalText: prepared.canonicalText,
            references: prepared.references,
            images: images,
            timestamp: Date(),
            isStreaming: false
        )
        messages.append(userMessage)
        if title == "Untitled" || title.isEmpty {
            let preview = prepared.displayText.nonEmptyTrimmed ?? (images.isEmpty ? "Untitled" : "Image")
            title = preview.oneLine(max: 64)
            eventHandler(.metadataChanged)
        }
        bottomScrollRequest &+= 1

        isWorking = true
        isThinking = false
        planEntries = []
        eventHandler(.activityChanged)

        let task = Task { @MainActor in
            defer {
                self.activePromptTask = nil
                self.isWorking = false
                self.isThinking = false
                self.permissionPrompt = nil
                self.eventHandler(.activityChanged)
            }
            do {
                try await self.ensureStarted()
                guard let client = self.client, let sid = self.sessionID else {
                    throw ACPClient.ACPError.notRunning
                }

                var blocks: [[String: Any]] = []
                if !prepared.payload.isEmpty {
                    blocks.append(["type": "text", "text": prepared.payload])
                }
                for image in images {
                    if let data = image.data {
                        blocks.append([
                            "type": "image",
                            "data": data,
                            "mimeType": image.mimeType
                        ])
                    }
                }
                if blocks.isEmpty {
                    blocks.append(["type": "text", "text": trimmed])
                }

                let result = try await client.prompt(sessionID: sid, blocks: blocks)
                let stopReason = (result["stopReason"] as? String) ?? "end_turn"
                self.finalizeStreamingMessages(stopReason: stopReason == "end_turn" ? "stop" : stopReason)
                self.markRuntimeUsed()
                self.eventHandler(.replyFinished)
            } catch is CancellationError {
                self.finalizeStreamingMessages(stopReason: "cancelled")
            } catch {
                self.finalizeStreamingMessages(stopReason: "error")
                self.handleError(error)
            }
        }
        activePromptTask = task
        await task.value
    }

    @discardableResult
    func sendHTMLWidgetMessage(_ rawText: String) async -> Bool {
        guard let text = rawText.nonEmptyTrimmed, text.utf16.count <= 2000,
              !text.hasPrefix("/"), !text.hasPrefix("!") else { return false }
        await send(text, images: [])
        return true
    }

    func abort() async {
        if let prompt = permissionPrompt {
            cancelPermission(prompt)
        }
        guard let client, client.isRunning, let sid = sessionID else {
            activePromptTask?.cancel()
            return
        }
        try? client.cancel(sessionID: sid)
    }

    func respondToPermission(optionID: String) {
        guard let prompt = permissionPrompt else { return }
        permissionPrompt = nil
        eventHandler(.activityChanged)
        guard let client, client.isRunning else { return }
        do {
            try client.respond(
                id: prompt.rpcRequestID,
                result: ["outcome": ["outcome": "selected", "optionId": optionID]]
            )
        } catch {
            handleError(error)
        }
    }

    func cancelPermission(_ explicit: ACPPermissionPrompt? = nil) {
        guard let prompt = explicit ?? permissionPrompt else { return }
        if permissionPrompt?.id == prompt.id {
            permissionPrompt = nil
            eventHandler(.activityChanged)
        }
        guard let client, client.isRunning else { return }
        try? client.respond(id: prompt.rpcRequestID, result: ["outcome": ["outcome": "cancelled"]])
    }

    func setModel(_ fullModelID: String) async {
        let bareModelID = bareID(from: fullModelID)
        let normalized = fullModelID.contains("/") ? fullModelID : "\(ACPProvider.antigravity)/\(bareModelID)"
        selectedModelID = normalized
        if let model = activeModel, !model.thinkingLevels.contains(thinkingLevel), let first = model.thinkingLevels.first {
            thinkingLevel = first
        }
        eventHandler(.metadataChanged)

        guard let client, client.isRunning, let sid = sessionID else { return }
        do {
            let result = try await client.setConfigOption(sessionID: sid, configID: "model", value: bareModelID)
            applyConfigOptions(from: result["configOptions"])
        } catch {
            handleError(error)
        }
    }

    func setThinkingLevel(_ level: String) async {
        thinkingLevel = level
        eventHandler(.metadataChanged)
        guard let client, client.isRunning, let sid = sessionID else { return }
        do {
            let result = try await client.setConfigOption(sessionID: sid, configID: "thought_level", value: level)
            applyConfigOptions(from: result["configOptions"])
        } catch {
            handleError(error)
        }
    }

    func setMode(_ modeID: String) async {
        currentModeID = modeID
        eventHandler(.metadataChanged)
        guard let client, client.isRunning, let sid = sessionID else { return }
        do {
            let result = try await client.setConfigOption(sessionID: sid, configID: "mode", value: modeID)
            applyConfigOptions(from: result["configOptions"])
        } catch {
            // Fall back to standard ACP `session/set_mode` for non-configOption servers.
            do {
                _ = try await client.setMode(sessionID: sid, modeID: modeID)
            } catch {
                handleError(error)
            }
        }
    }

    // MARK: - ACP JSON-RPC handlers

    private func handleNotification(method: String, params: [String: Any]) {
        guard method == "session/update" else { return }
        if let sid = params["sessionId"] as? String, let current = sessionID, sid != current {
            return
        }
        guard let update = params["update"] as? [String: Any] else { return }
        handleSessionUpdate(update, isReplaying: isReplayingHistory)
    }

    /// Internal so unit tests can drive ACP `session/update` notifications directly.
    func handleSessionUpdate(_ update: [String: Any], isReplaying: Bool = false) {
        guard let kind = update["sessionUpdate"] as? String else { return }

        switch kind {
        case "user_message_chunk":
            if isReplaying { hasReceivedReplayMessages = true }
            appendUserChunk(content: update["content"] as? [String: Any])

        case "agent_thought_chunk":
            if isReplaying { hasReceivedReplayMessages = true }
            if let text = extractText(from: update["content"]) {
                let idx = ensureAssistantMessage(forTool: false, isReplaying: isReplaying)
                messages[idx].thinking += text
                if !isReplaying {
                    isThinking = true
                    scheduleStreamingBump()
                }
            }

        case "agent_message_chunk":
            if isReplaying { hasReceivedReplayMessages = true }
            let idx = ensureAssistantMessage(forTool: false, isReplaying: isReplaying)
            if let content = update["content"] as? [String: Any] {
                let type = content["type"] as? String
                if type == "text", let text = content["text"] as? String {
                    messages[idx].text += text
                } else if type == "image", let data = content["data"] as? String {
                    let mime = content["mimeType"] as? String ?? "image/png"
                    messages[idx].images.append(ImageAttachment(name: "Image", mimeType: mime, data: data))
                }
            }
            if !isReplaying {
                isThinking = false
                scheduleStreamingBump()
            }

        case "tool_call", "tool_call_update":
            if isReplaying { hasReceivedReplayMessages = true }
            handleToolCallUpdate(update, isReplaying: isReplaying)

        case "plan":
            let entries = (update["entries"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item -> ACPPlanEntry? in
                guard let content = item["content"] as? String else { return nil }
                return ACPPlanEntry(
                    id: "\(index)-\(content.prefix(24))",
                    content: content,
                    status: item["status"] as? String ?? "pending",
                    priority: item["priority"] as? String
                )
            }
            planEntries = entries

        case "available_commands_update":
            let rawCommands = update["availableCommands"] as? [[String: Any]] ?? []
            slashCommands = rawCommands.compactMap { item -> SlashCommandInfo? in
                guard let name = item["name"] as? String, !name.isEmpty else { return nil }
                let inputDict = item["input"] as? [String: Any]
                return SlashCommandInfo(
                    name: name,
                    description: item["description"] as? String ?? "",
                    source: "acp",
                    location: nil,
                    path: nil,
                    argumentHint: inputDict?["hint"] as? String
                )
            }

        case "current_mode_update":
            if let modeID = update["currentModeId"] as? String, !modeID.isEmpty {
                currentModeID = modeID
                eventHandler(.metadataChanged)
            }

        case "config_option_update":
            applyConfigOptions(from: update["configOptions"])

        case "usage_update":
            if let used = update["used"] as? Int { contextUsed = used }
            if let size = update["size"] as? Int { contextWindow = size }

        case "session_info_update":
            if let newTitle = (update["title"] as? String)?.nonEmptyTrimmed {
                title = newTitle
                eventHandler(.metadataChanged)
            }

        default:
            break
        }
    }

    func handleServerRequest(id: ACPJSONID, method: String, params: [String: Any]) {
        guard method == "session/request_permission" else {
            try? client?.respondError(id: id, code: -32601, message: "Unsupported client method: \(method)")
            return
        }

        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let toolCallID = toolCall["toolCallId"] as? String ?? UUID().uuidString
        let rawTitle = (toolCall["title"] as? String)?.nonEmptyTrimmed ?? "Tool action"
        let kind = toolCall["kind"] as? String
        let rawInput = toolCall["rawInput"] as? [String: Any]

        let options = (params["options"] as? [[String: Any]] ?? []).compactMap { item -> ACPPermissionOption? in
            guard let optionId = item["optionId"] as? String,
                  let name = item["name"] as? String else { return nil }
            return ACPPermissionOption(
                optionId: optionId,
                name: name,
                kind: item["kind"] as? String ?? "allow_once"
            )
        }

        // Auto-approve ONLY our own stateless `pig` `html_render` MCP widget tool.
        if isHTMLRenderToolCall(toolCall: toolCall, toolCallID: toolCallID, title: rawTitle, rawInput: rawInput),
           let allowOption = options.first(where: { $0.kind == "allow_once" || $0.kind == "allow_always" }) {
            try? client?.respond(
                id: id,
                result: ["outcome": ["outcome": "selected", "optionId": allowOption.optionId]]
            )
            return
        }

        var detailParts: [String] = []
        if let rawInput, !rawInput.isEmpty {
            if let cmd = rawInput["command"] as? String {
                detailParts.append(cmd)
            } else if let path = (rawInput["path"] as? String) ?? (rawInput["file_path"] as? String) {
                detailParts.append(path)
            } else {
                detailParts.append(jsonString(rawInput))
            }
        }
        let detail = detailParts.joined(separator: "\n").nonEmptyTrimmed

        permissionPrompt = ACPPermissionPrompt(
            id: UUID().uuidString,
            rpcRequestID: id,
            toolCallID: toolCallID,
            title: rawTitle,
            detail: detail,
            kind: kind,
            options: options
        )
        eventHandler(.activityChanged)
    }

    // MARK: - Message & tool assembly helpers

    private func appendUserChunk(content: [String: Any]?) {
        guard let content else { return }
        let type = content["type"] as? String
        let shouldStartNew = messages.last?.role != .user

        if shouldStartNew {
            messages.append(ChatMessage(
                id: "acp-replay-user-\(messages.count)-\(UUID().uuidString.prefix(8))",
                role: .user,
                text: "",
                timestamp: Date(),
                isStreaming: false
            ))
        }
        let idx = messages.count - 1
        if type == "text", let text = content["text"] as? String {
            messages[idx].text += text
            if let parsed = PromptEnvelope.parse(messages[idx].text) {
                messages[idx].text = parsed.text
                messages[idx].canonicalText = parsed.canonicalText
                messages[idx].references = parsed.references
            }
        } else if type == "image", let data = content["data"] as? String {
            let mime = content["mimeType"] as? String ?? "image/png"
            messages[idx].images.append(ImageAttachment(name: "Image", mimeType: mime, data: data))
        }
    }

    private func ensureAssistantMessage(forTool: Bool, isReplaying: Bool) -> Int {
        if let lastIndex = messages.indices.last, messages[lastIndex].role == .assistant {
            if !forTool && !messages[lastIndex].tools.isEmpty {
                // Start a fresh assistant message after tool calls so intermediate narration +
                // tools fold cleanly into ToolActivityView while the final reply sits below.
                messages[lastIndex].isStreaming = false
                if messages[lastIndex].stopReason == nil {
                    messages[lastIndex].stopReason = "toolUse"
                }
            } else {
                return lastIndex
            }
        }
        let message = ChatMessage(
            id: "acp-assistant-\(messages.count)-\(UUID().uuidString.prefix(8))",
            role: .assistant,
            text: "",
            timestamp: Date(),
            isStreaming: !isReplaying
        )
        messages.append(message)
        return messages.count - 1
    }

    private func handleToolCallUpdate(_ update: [String: Any], isReplaying: Bool) {
        guard let toolCallID = update["toolCallId"] as? String, !toolCallID.isEmpty else { return }

        if let rawInput = update["rawInput"] as? [String: Any], !rawInput.isEmpty {
            rawInputByToolID[toolCallID] = rawInput
        }
        let cachedInput = rawInputByToolID[toolCallID]

        let rawTitle = (update["title"] as? String)?.nonEmptyTrimmed
        let rawKind = (update["kind"] as? String)?.nonEmptyTrimmed
        let metaName = extractToolName(from: update)

        let existingMeta = toolMetaByID[toolCallID]
        let resolvedTitle = rawTitle ?? existingMeta?.title
        let resolvedKind = rawKind ?? existingMeta?.kind
        let rawName = metaName ?? existingMeta?.name ?? resolvedKind ?? "tool"

        let isHTML = isHTMLRenderToolCall(
            toolCall: update,
            toolCallID: toolCallID,
            title: resolvedTitle,
            rawInput: cachedInput
        )
        let normalizedName = isHTML ? "html_render" : rawName
        toolMetaByID[toolCallID] = (name: normalizedName, title: resolvedTitle, kind: resolvedKind)

        let status = mapToolStatus(update["status"] as? String)
        let isError = (status == .failed)
        let argumentsText = cachedInput.map { jsonString($0) } ?? ""
        let (resultText, resultImages) = extractToolOutput(from: update)

        var details: String?
        if isHTML, status == .succeeded, !isError {
            details = ACPHTMLRenderBridge.pigHTMLDetailsJSON(
                rawInput: cachedInput,
                outputText: resultText,
                fallbackSeed: toolCallID
            )
        }

        // Look up existing tool in any assistant message of the current turn.
        if let location = findToolLocation(toolCallID: toolCallID) {
            var existing = messages[location.messageIndex].tools[location.toolIndex]
            existing.name = normalizedName
            if !argumentsText.isEmpty { existing.arguments = argumentsText }
            if !resultText.isEmpty { existing.result = resultText }
            if let details { existing.details = details }
            if !resultImages.isEmpty { existing.images = resultImages }
            existing.status = status
            existing.isError = existing.isError || isError
            if let resolvedTitle { existing.acpTitle = resolvedTitle }
            if let resolvedKind { existing.acpKind = resolvedKind }
            messages[location.messageIndex].tools[location.toolIndex] = existing
        } else {
            let msgIndex = ensureAssistantMessage(forTool: true, isReplaying: isReplaying)
            let tool = ToolDisplay(
                id: toolCallID,
                name: normalizedName,
                arguments: argumentsText,
                result: resultText,
                details: details,
                images: resultImages,
                status: status,
                isError: isError,
                acpTitle: isHTML ? nil : resolvedTitle,
                acpKind: isHTML ? nil : resolvedKind
            )
            messages[msgIndex].tools.append(tool)
        }

        if !isReplaying {
            isThinking = false
            scheduleStreamingBump()
        }
    }

    private func findToolLocation(toolCallID: String) -> (messageIndex: Int, toolIndex: Int)? {
        for mIdx in messages.indices.reversed() {
            if messages[mIdx].role == .user { break }
            if let tIdx = messages[mIdx].tools.firstIndex(where: { $0.id == toolCallID }) {
                return (mIdx, tIdx)
            }
        }
        return nil
    }

    private func extractToolName(from update: [String: Any]) -> String? {
        if let meta = update["_meta"] as? [String: Any] {
            if let toolName = (meta["toolName"] as? String)?.nonEmptyTrimmed { return toolName }
            if let cc = meta["claudeCode"] as? [String: Any],
               let toolName = (cc["toolName"] as? String)?.nonEmptyTrimmed { return toolName }
            if let agy = meta["antigravity"] as? [String: Any],
               let toolName = (agy["toolName"] as? String)?.nonEmptyTrimmed { return toolName }
        }
        if let name = (update["name"] as? String)?.nonEmptyTrimmed { return name }
        return nil
    }

    private func isHTMLRenderToolCall(
        toolCall: [String: Any],
        toolCallID: String,
        title: String?,
        rawInput: [String: Any]?
    ) -> Bool {
        if let metaName = extractToolName(from: toolCall), ACPHTMLRenderBridge.isHTMLRenderToolName(metaName) {
            return true
        }
        if let cached = toolMetaByID[toolCallID], ACPHTMLRenderBridge.isHTMLRenderToolName(cached.name) {
            return true
        }
        if let title {
            let lower = title.lowercased()
            if ACPHTMLRenderBridge.isHTMLRenderToolName(lower) || lower.contains("html_render") {
                return true
            }
        }
        if let rawInput, rawInput["html"] is String,
           (title?.lowercased().contains("pig") == true || title?.lowercased().contains("html") == true) {
            return true
        }
        return false
    }

    private func mapToolStatus(_ raw: String?) -> ToolStatus {
        switch raw?.lowercased() {
        case "pending": return .pending
        case "in_progress", "running": return .running
        case "completed", "succeeded": return .succeeded
        case "failed", "error", "cancelled": return .failed
        default: return .running
        }
    }

    private func extractText(from raw: Any?) -> String? {
        guard let dict = raw as? [String: Any] else { return nil }
        if dict["type"] as? String == "text" { return dict["text"] as? String }
        return dict["text"] as? String
    }

    private func extractToolOutput(from update: [String: Any]) -> (String, [ImageAttachment]) {
        var textParts: [String] = []
        var images: [ImageAttachment] = []

        if let contentList = update["content"] as? [[String: Any]] {
            for item in contentList {
                let type = item["type"] as? String
                if type == "content", let inner = item["content"] as? [String: Any] {
                    let innerType = inner["type"] as? String
                    if innerType == "text", let text = inner["text"] as? String, !text.isEmpty {
                        textParts.append(text)
                    } else if innerType == "image", let data = inner["data"] as? String {
                        let mime = inner["mimeType"] as? String ?? "image/png"
                        images.append(ImageAttachment(name: "Image", mimeType: mime, data: data))
                    }
                } else if type == "diff", let path = item["path"] as? String {
                    let oldText = item["oldText"] as? String ?? ""
                    let newText = item["newText"] as? String ?? ""
                    textParts.append(formatDiffSummary(path: path, oldText: oldText, newText: newText))
                } else if type == "text", let text = item["text"] as? String, !text.isEmpty {
                    textParts.append(text)
                }
            }
        }

        if textParts.isEmpty, let rawOutput = update["rawOutput"] {
            if let str = rawOutput as? String, !str.isEmpty {
                textParts.append(str)
            } else if let dict = rawOutput as? [String: Any] {
                if let content = dict["content"] as? [[String: Any]] {
                    for block in content {
                        if let text = block["text"] as? String, !text.isEmpty {
                            textParts.append(text)
                        }
                    }
                }
                if textParts.isEmpty {
                    textParts.append(jsonString(dict))
                }
            } else if let array = rawOutput as? [Any], !array.isEmpty {
                textParts.append(jsonString(array))
            }
        }

        return (textParts.joined(separator: "\n"), images)
    }

    private func formatDiffSummary(path: String, oldText: String, newText: String) -> String {
        let shortPath = ToolDisplay.displayPath(path, projectPath: projectPath)
        if oldText.isEmpty {
            return "Created \(shortPath)\n\n\(newText)"
        }
        return "Edited \(shortPath)\n--- before\n\(oldText)\n+++ after\n\(newText)"
    }

    private func finalizeStreamingMessages(stopReason: String) {
        let now = Date()
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
            messages[index].completedAt = now
            if messages[index].stopReason == nil {
                messages[index].stopReason = stopReason
            }
        }
        if let lastAssistant = messages.indices.last(where: { messages[$0].role == .assistant }) {
            messages[lastAssistant].isStreaming = false
            if messages[lastAssistant].completedAt == nil {
                messages[lastAssistant].completedAt = now
            }
            if messages[lastAssistant].stopReason == nil || messages[lastAssistant].stopReason == "toolUse" {
                messages[lastAssistant].stopReason = stopReason
            }
        }
        streamingFrameToken &+= 1
    }

    private func finalizeReplayedMessages() {
        for index in messages.indices where messages[index].role == .assistant {
            messages[index].isStreaming = false
            if messages[index].stopReason == nil {
                let hasFollowingAssistantBeforeUser = (index + 1 < messages.count) && messages[index + 1].role == .assistant
                messages[index].stopReason = hasFollowingAssistantBeforeUser ? "toolUse" : "stop"
            }
        }
        streamingFrameToken &+= 1
    }

    private func applySessionMetadata(from result: [String: Any], preserveRequestedModel: Bool) {
        let configOptions = ACPModelCatalogParser.parseConfigOptions(result["configOptions"])
        let parsedModels = ACPModelCatalogParser.parseModels(from: result, configOptions: configOptions)
        let parsedModes = ACPModelCatalogParser.parseModes(from: result, configOptions: configOptions)

        if !parsedModels.models.isEmpty {
            models = parsedModels.models
        }
        if !preserveRequestedModel {
            if let current = parsedModels.currentModelID, !current.isEmpty {
                selectedModelID = current
            } else if selectedModelID.isEmpty, let first = models.first {
                selectedModelID = first.id
            }
            if let thought = parsedModels.currentThinkingLevel, !thought.isEmpty {
                thinkingLevel = thought
            }
        }
        if !parsedModes.modes.isEmpty {
            modes = parsedModes.modes
        }
        if !preserveRequestedModel, !parsedModes.currentModeID.isEmpty {
            currentModeID = parsedModes.currentModeID
        }
        eventHandler(.metadataChanged)
    }

    private func applyConfigOptions(from raw: Any?) {
        let configOptions = ACPModelCatalogParser.parseConfigOptions(raw)
        guard !configOptions.isEmpty else { return }

        if let modelConfig = configOptions.first(where: { $0.category == "model" || $0.id == "model" }),
           !modelConfig.currentValue.isEmpty {
            selectedModelID = "\(ACPProvider.antigravity)/\(modelConfig.currentValue)"
        }
        if let thoughtConfig = configOptions.first(where: { $0.category == "thought_level" || $0.id == "thought_level" }) {
            if !thoughtConfig.currentValue.isEmpty {
                thinkingLevel = thoughtConfig.currentValue
            }
            let updatedLevels = thoughtConfig.options.map(\.value)
            if !updatedLevels.isEmpty, let idx = models.firstIndex(where: { $0.id == selectedModelID }) {
                var updated = models[idx]
                updated = ModelInfo(
                    id: updated.id,
                    provider: updated.provider,
                    modelId: updated.modelId,
                    name: updated.name,
                    reasoning: updatedLevels.contains { $0 != "off" },
                    thinkingLevels: updatedLevels,
                    contextWindow: updated.contextWindow
                )
                models[idx] = updated
            }
        }
        if let modeConfig = configOptions.first(where: { $0.category == "mode" || $0.id == "mode" }) {
            if !modeConfig.options.isEmpty {
                modes = modeConfig.options.map { ACPModeInfo(id: $0.value, name: $0.name, description: $0.description) }
            }
            if !modeConfig.currentValue.isEmpty {
                currentModeID = modeConfig.currentValue
            }
        }
        eventHandler(.metadataChanged)
    }

    private func handleTermination(status: Int32) {
        isProcessActive = false
        permissionPrompt = nil
        if isWorking {
            isWorking = false
            isThinking = false
            finalizeStreamingMessages(stopReason: "error")
            if status != 0 {
                errorText = "Antigravity ACP process exited unexpectedly (status \(status))."
            }
            eventHandler(.activityChanged)
        }
    }

    private func handleError(_ error: Error) {
        if let acpError = error as? ACPClient.ACPError, acpError.isAuthRequired {
            authRequired = true
        }
        let message = error.localizedDescription
        errorText = message
        eventHandler(.log("[ACP] \(message)"))
    }

    private func bareID(from fullID: String) -> String {
        if let slash = fullID.firstIndex(of: "/") {
            return String(fullID[fullID.index(after: slash)...])
        }
        return fullID
    }

    private func scheduleStreamingBump() {
        guard !streamingBumpScheduled else { return }
        streamingBumpScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self else { return }
            self.streamingBumpScheduled = false
            self.streamingFrameToken &+= 1
        }
    }
}

extension ACPChatController: ChatTranscriptSource {
    var visibleMessages: [ChatMessage] { Array(messages.suffix(visibleMessageLimit)) }
    var hiddenMessageCount: Int { max(0, messages.count - visibleMessageLimit) }
    func loadEarlierMessages() { visibleMessageLimit = min(messages.count, visibleMessageLimit + 100) }

    var trailingActivityText: String? {
        if isLoadingHistory { return "Loading conversation" }
        if permissionPrompt != nil { return "Waiting for permission" }
        return nil
    }

    var transcriptProjectPath: String? { projectPath }

    func scrollToMessage(_ messageID: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        visibleMessageLimit = max(visibleMessageLimit, messages.count - index)
        messageScrollRequest = MessageScrollRequest(messageID: messageID)
    }

    var htmlActionTarget: (any HTMLWidgetActionTarget)? { self }
}
