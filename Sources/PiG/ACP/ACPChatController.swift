import Foundation
import Combine

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
    @Published var draft = ""
    @Published var draftImages: [ImageAttachment] = []
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
    @Published private var permissionPrompts: [ACPPermissionPrompt] = []
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
    @Published private var isStarting = false
    private var startTask: Task<Void, Error>? {
        didSet { isStarting = startTask != nil }
    }
    private var startGeneration = 0
    private var isSessionReady = false
    private var settingsTask: Task<Void, Never>?
    private(set) var pendingSelections: ACPSelections
    private var rejectedModeError: Error?
    private var modeConfigID: String?
    private var activePromptTask: Task<Void, Never>?
    private var isCancellingPrompt = false
    private var promptID: UUID?
    private var promptQueued = false
    private var promptCancelTask: Task<Void, Never>?
    private var replayUpdates: [[String: Any]]?
    private var rawInputByToolID: [String: [String: Any]] = [:]
    private var toolMetaByID: [String: (name: String, title: String?, kind: String?)] = [:]
    private var streamingBumpScheduled = false

    var permissionPrompt: ACPPermissionPrompt? { permissionPrompts.first }
    var hasLiveWork: Bool { isWorking || permissionPrompt != nil }
    var canAbort: Bool { isWorking || isStarting }
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
        pendingSelections: ACPSelections? = nil,
        serverConfig: ACPServerConfig = .antigravity(),
        eventHandler: @escaping (Event) -> Void = { _ in }
    ) {
        self.id = id
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.isQuickChat = isQuickChat
        self.title = title
        self.models = models
        let initialModelID = selectedModelID.isEmpty ? (models.first?.id ?? "") : selectedModelID
        self.selectedModelID = initialModelID
        self.thinkingLevel = thinkingLevel
        self.modes = modes.isEmpty ? ACPModeInfo.antigravityDefaults : modes
        self.currentModeID = modeID
        self.pendingSelections = pendingSelections ?? (sessionID == nil
            ? ACPSelections(modelID: initialModelID.nonEmptyTrimmed,
                            thinkingLevel: thinkingLevel.nonEmptyTrimmed, modeID: modeID.nonEmptyTrimmed)
            : ACPSelections())
        self.serverConfig = serverConfig
        self.eventHandler = eventHandler
    }

    deinit {
        startTask?.cancel()
        activePromptTask?.cancel()
        settingsTask?.cancel()
        promptCancelTask?.cancel()
        let owned = client
        Task { @MainActor in owned?.stop() }
    }

    func markRuntimeUsed() {
        lastRuntimeUse = Date()
    }

    // MARK: - Process & session lifecycle

    private func startIfNeeded() -> Task<Void, Error>? {
        markRuntimeUsed()
        if let startTask { return startTask }
        if isSessionReady, client?.isRunning == true { return nil }

        startGeneration &+= 1
        let task = Task<Void, Error> { @MainActor in
            defer { if !Task.isCancelled { self.startTask = nil } }
            do {
                try await self.performStart()
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
        startTask = task
        return task
    }

    func loadExistingSessionIfNeeded() async {
        guard sessionID != nil else { return }
        await connect()
    }

    func retryLogin() async {
        guard !hasLiveWork else { return }
        if isSessionReady { stopProcess() }
        dismissedErrorToast = nil
        await connect(keepLoginAvailable: true)
    }

    private func connect(keepLoginAvailable: Bool = false) async {
        let task = startIfNeeded()
        let generation = startGeneration
        do {
            try await task?.value
            guard !Task.isCancelled, startGeneration == generation else { return }
            await applyPendingSelections()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, startGeneration == generation else { return }
            if keepLoginAvailable { authRequired = true }
            handleError(error)
        }
    }

    private func performStart() async throws {
        try Task.checkCancellation()
        disconnectClient()
        if isQuickChat {
            try await AsyncFileSystem.createDirectory(at: URL(fileURLWithPath: projectPath, isDirectory: true))
            try Task.checkCancellation()
        }

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
        defer {
            if self.client === client, !isSessionReady { disconnectClient() }
        }
        try await client.start()
        try Task.checkCancellation()
        isProcessActive = true

        let initResult = try await client.initialize()
        try Task.checkCancellation()
        capabilities = initResult.capabilities
        authMethods = initResult.authMethods

        let mcpServers = ACPHTMLRenderBridge.mcpServersPayload(projectPath: projectPath)
        let includeMeta = serverConfig.isAntigravity
            && capabilities.supportsAntigravitySystemPromptAppend
            && !mcpServers.isEmpty

        if let existingSessionID = sessionID {
            guard capabilities.loadSession else { throw ACPClient.ACPError.sessionLoadUnsupported }
            isLoadingHistory = true
            replayUpdates = []
            let result = try await client.loadSession(
                sessionID: existingSessionID,
                cwd: projectPath,
                mcpServers: mcpServers
            )
            try Task.checkCancellation()
            guard client.isRunning else { throw ACPClient.ACPError.notRunning }
            var hasReplayMessages = false
            let updates = (replayUpdates ?? []).filter { update in
                let valid: Bool
                switch update["sessionUpdate"] as? String {
                case "user_message_chunk", "agent_message_chunk":
                    guard let content = update["content"] as? [String: Any] else { return false }
                    switch content["type"] as? String {
                    case "text": valid = content["text"] is String
                    case "image": valid = content["data"] is String
                    default: return false
                    }
                case "agent_thought_chunk": valid = extractText(from: update["content"]) != nil
                case "tool_call", "tool_call_update": valid = (update["toolCallId"] as? String)?.isEmpty == false
                default: return true
                }
                hasReplayMessages = hasReplayMessages || valid
                return valid
            }
            replayUpdates = nil
            if hasReplayMessages {
                messages = []
                rawInputByToolID.removeAll()
                toolMetaByID.removeAll()
            }
            for update in updates { handleSessionUpdate(update, isReplaying: true) }
            if hasReplayMessages { finalizeReplayedMessages() }
            applySessionMetadata(from: result)
            isLoadingHistory = false
            bottomScrollRequest &+= 1
        } else {
            let result = try await client.newSession(
                cwd: projectPath,
                mcpServers: mcpServers,
                meta: ACPHTMLRenderBridge.sessionMeta(includePiGTools: includeMeta)
            )
            try Task.checkCancellation()
            guard client.isRunning else { throw ACPClient.ACPError.notRunning }
            guard let createdID = result["sessionId"] as? String, !createdID.isEmpty else {
                throw ACPClient.ACPError.invalidPayload
            }
            sessionID = createdID
            applySessionMetadata(from: result)
            eventHandler(.sessionBound(createdID))
        }
        isSessionReady = true
        if authRequired { errorText = nil }
        authRequired = false
    }

    private typealias LiveSession = (client: ACPClient, id: String)

    private func disconnectClient() {
        settingsTask?.cancel()
        settingsTask = nil
        rejectedModeError = nil
        cancelPendingPermissions()
        client?.onNotification = nil
        client?.onRequest = nil
        client?.onTermination = nil
        client?.stop()
        client = nil
        isSessionReady = false
        isProcessActive = false
        replayUpdates = nil
        isLoadingHistory = false
    }

    func stopProcess() {
        startGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        activePromptTask?.cancel()
        if promptQueued { finalizeStreamingMessages(stopReason: "cancelled") }
        disconnectClient()
        if promptID != nil { finishPrompt() }
    }

    // MARK: - Prompting & control

    func sendDraft(_ submittedDraft: String, images submittedImages: [ImageAttachment], normalizedText: String? = nil) async {
        await send(normalizedText ?? submittedDraft, images: submittedImages) {
            if self.draft == submittedDraft { self.draft = "" }
            let submittedIDs = Set(submittedImages.map(\.id))
            self.draftImages.removeAll { submittedIDs.contains($0.id) }
        }
    }

    @discardableResult
    func send(_ text: String, images: [ImageAttachment] = [], onQueued: @escaping () -> Void = {}) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, promptID == nil else { return false }

        errorText = nil
        dismissedErrorToast = nil
        markRuntimeUsed()

        let prepared = PromptEnvelope.prepare(canonicalText: trimmed, projectPath: projectPath)
        let id = UUID()
        promptID = id
        isWorking = true
        isThinking = false
        planEntries = []
        eventHandler(.activityChanged)

        var queued = false
        let task = Task { @MainActor in
            defer { if self.promptID == id { self.finishPrompt() } }
            do {
                try await self.startIfNeeded()?.value
                try Task.checkCancellation()
                await self.applyPendingSelections(retryRejectedMode: true)
                try Task.checkCancellation()
                try self.checkRequestedMode()
                guard let client = self.client, let sid = self.sessionID else {
                    throw ACPClient.ACPError.notRunning
                }

                var blocks: [[String: Any]] = []
                if !prepared.payload.isEmpty {
                    blocks.append(["type": "text", "text": prepared.payload])
                }
                for image in images {
                    if let data = image.data {
                        blocks.append(["type": "image", "data": data, "mimeType": image.mimeType])
                    }
                }
                if blocks.isEmpty { blocks.append(["type": "text", "text": trimmed]) }

                let result = try await client.prompt(sessionID: sid, blocks: blocks, beforeQueue: {
                    try self.checkRequestedMode()
                }, onQueued: {
                    queued = true
                    self.promptQueued = true
                    self.messages.append(ChatMessage(
                        id: "acp-user-\(id.uuidString)", role: .user, text: prepared.displayText,
                        canonicalText: prepared.canonicalText, references: prepared.references,
                        images: images, timestamp: Date(), isStreaming: false
                    ))
                    if self.title == "Untitled" || self.title.isEmpty {
                        let preview = prepared.displayText.nonEmptyTrimmed ?? (images.isEmpty ? "Untitled" : "Image")
                        self.title = preview.oneLine(max: 64)
                        self.eventHandler(.metadataChanged)
                    }
                    self.bottomScrollRequest &+= 1
                    onQueued()
                })
                guard self.promptID == id else { return }
                let stopReason = (result["stopReason"] as? String) ?? "end_turn"
                guard stopReason != "cancelled", !self.isCancellingPrompt else { throw CancellationError() }
                self.finalizeStreamingMessages(stopReason: stopReason == "end_turn" ? "stop" : stopReason)
                self.markRuntimeUsed()
                self.eventHandler(.replyFinished)
            } catch {
                guard self.promptID == id else { return }
                if error is CancellationError || Task.isCancelled || self.isCancellingPrompt {
                    if queued { self.finalizeStreamingMessages(stopReason: "cancelled") }
                } else {
                    if queued { self.finalizeStreamingMessages(stopReason: "error") }
                    self.handleError(error)
                }
            }
        }
        activePromptTask = task
        await task.value
        return queued
    }

    @discardableResult
    func sendHTMLWidgetMessage(_ rawText: String) async -> Bool {
        guard let text = rawText.nonEmptyTrimmed, text.utf16.count <= 2000,
              !text.hasPrefix("/"), !text.hasPrefix("!") else { return false }
        return await send(text)
    }

    func abort() {
        guard let id = promptID else {
            if startTask != nil { stopProcess() }
            return
        }
        guard !isCancellingPrompt else { return }
        guard promptQueued else {
            if isSessionReady {
                activePromptTask?.cancel()
                finishPrompt()
            } else {
                stopProcess()
            }
            return
        }
        isCancellingPrompt = true
        cancelPendingPermissions()
        guard let client, let sid = sessionID else { stopProcess(); return }
        do {
            try client.cancel(sessionID: sid)
        } catch {
            stopProcess()
            return
        }
        promptCancelTask = Task { @MainActor [weak self, weak client] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, let client, self.client === client, self.promptID == id else { return }
            self.stopProcess()
        }
    }

    private func finishPrompt() {
        promptCancelTask?.cancel()
        promptCancelTask = nil
        activePromptTask = nil
        promptID = nil
        promptQueued = false
        isCancellingPrompt = false
        isWorking = false
        isThinking = false
        cancelPendingPermissions()
        eventHandler(.activityChanged)
    }

    func respondToPermission(promptID: String, optionID: String) {
        guard let prompt = permissionPrompt, prompt.id == promptID,
              prompt.options.contains(where: { $0.optionId == optionID }) else { return }
        permissionPrompts.removeFirst()
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

    func cancelPermission(promptID: String) {
        guard let prompt = permissionPrompt, prompt.id == promptID else { return }
        permissionPrompts.removeFirst()
        sendPermissionCancellation(id: prompt.rpcRequestID)
        eventHandler(.activityChanged)
    }

    private func cancelPendingPermissions() {
        guard !permissionPrompts.isEmpty else { return }
        for prompt in permissionPrompts { sendPermissionCancellation(id: prompt.rpcRequestID) }
        permissionPrompts.removeAll()
        eventHandler(.activityChanged)
    }

    private func sendPermissionCancellation(id: ACPJSONID) {
        try? client?.respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
    }

    func setModel(_ fullModelID: String) async {
        pendingSelections.modelID = fullModelID.contains("/") ? fullModelID : "\(ACPProvider.antigravity)/\(fullModelID)"
        eventHandler(.metadataChanged)
        await applyPendingSelections()
    }

    func setThinkingLevel(_ level: String) async {
        pendingSelections.thinkingLevel = level
        eventHandler(.metadataChanged)
        await applyPendingSelections()
    }

    func setMode(_ modeID: String) async {
        pendingSelections.modeID = modeID
        if rejectedModeError?.localizedDescription == errorText { errorText = nil }
        rejectedModeError = nil
        eventHandler(.metadataChanged)
        await applyPendingSelections()
    }

    private func applyPendingSelections(retryRejectedMode: Bool = false) async {
        if retryRejectedMode { rejectedModeError = nil }
        if let settingsTask { return await settingsTask.value }
        guard isSessionReady, let client, client.isRunning, let sessionID else { return }
        let task = Task { @MainActor in
            defer { if !Task.isCancelled { self.settingsTask = nil } }
            let session = (client: client, id: sessionID)
            while !Task.isCancelled {
                if let model = self.pendingSelections.modelID {
                    await self.applySelection(\.modelID, value: model) {
                        if self.selectedModelID != model {
                            try await self.applyConfig("model", value: self.bareID(from: model), session: session)
                        }
                        guard self.selectedModelID == model else {
                            throw ACPClient.ACPError.settingUnconfirmed("model", model)
                        }
                    }
                } else if let level = self.pendingSelections.thinkingLevel {
                    await self.applySelection(\.thinkingLevel, value: level) {
                        if self.thinkingLevel != level {
                            try await self.applyConfig("thought_level", value: level, session: session)
                        }
                        guard self.thinkingLevel == level else {
                            throw ACPClient.ACPError.settingUnconfirmed("thinking level", level)
                        }
                    }
                } else if let mode = self.pendingSelections.modeID, self.rejectedModeError == nil {
                    await self.applySelection(\.modeID, value: mode) {
                        try await self.applyMode(mode, session: session)
                    }
                } else {
                    return
                }
            }
        }
        settingsTask = task
        await task.value
    }

    private func applySelection(_ setting: WritableKeyPath<ACPSelections, String?>, value: String, apply: () async throws -> Void) async {
        do {
            try await apply()
            guard !Task.isCancelled, pendingSelections[keyPath: setting] == value else { return }
            pendingSelections[keyPath: setting] = nil
        } catch {
            guard !Task.isCancelled, pendingSelections[keyPath: setting] == value else { return }
            if setting == \.modeID { rejectedModeError = error }
            else { pendingSelections[keyPath: setting] = nil }
            dismissedErrorToast = nil
            handleError(error)
        }
        eventHandler(.metadataChanged)
    }

    private func applyConfig(_ id: String, value: String, session: LiveSession) async throws {
        let result = try await session.client.setConfigOption(sessionID: session.id, configID: id, value: value)
        try Task.checkCancellation()
        applyConfigOptions(from: result["configOptions"])
    }

    private func applyMode(_ mode: String, session: LiveSession) async throws {
        guard currentModeID != mode else { return }
        guard modes.contains(where: { $0.id == mode }) else {
            throw ACPClient.ACPError.modeUnavailable(mode)
        }
        if let modeConfigID {
            do {
                try await applyConfig(modeConfigID, value: mode, session: session)
                guard currentModeID == mode else { throw ACPClient.ACPError.settingUnconfirmed("permission mode", mode) }
                return
            } catch ACPClient.ACPError.rpcError(code: -32601, message: _) {
                try Task.checkCancellation()
            }
        }
        _ = try await session.client.setMode(sessionID: session.id, modeID: mode)
        try Task.checkCancellation()
        currentModeID = mode
    }

    private func checkRequestedMode() throws {
        if let mode = pendingSelections.modeID {
            throw rejectedModeError ?? ACPClient.ACPError.settingUnconfirmed("permission mode", mode)
        }
    }

    // MARK: - ACP JSON-RPC handlers

    private func handleNotification(method: String, params: [String: Any]) {
        guard method == "session/update" else { return }
        if let sid = params["sessionId"] as? String, let current = sessionID, sid != current {
            return
        }
        guard let update = params["update"] as? [String: Any] else { return }
        if replayUpdates != nil {
            replayUpdates?.append(update)
        } else {
            handleSessionUpdate(update)
        }
    }

    /// Internal so unit tests can drive ACP `session/update` notifications directly.
    func handleSessionUpdate(_ update: [String: Any], isReplaying: Bool = false) {
        guard let kind = update["sessionUpdate"] as? String else { return }

        switch kind {
        case "user_message_chunk":
            appendUserChunk(content: update["content"] as? [String: Any])

        case "agent_thought_chunk":
            if let text = extractText(from: update["content"]) {
                let idx = ensureAssistantMessage(forTool: false, isReplaying: isReplaying)
                messages[idx].thinking += text
                if !isReplaying {
                    isThinking = true
                    scheduleStreamingBump()
                }
            }

        case "agent_message_chunk":
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

        if isCancellingPrompt {
            sendPermissionCancellation(id: id)
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

        permissionPrompts.append(ACPPermissionPrompt(
            id: UUID().uuidString,
            rpcRequestID: id,
            toolCallID: toolCallID,
            title: rawTitle,
            detail: detail,
            kind: kind,
            options: options
        ))
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
        let isPiSubagent = !isHTML && (
            existingMeta?.name == "subagent"
                || [metaName, resolvedTitle].contains { $0.map(ACPHTMLRenderBridge.isPiSubagentToolName) == true }
        )
        let normalizedName = isHTML ? "html_render" : isPiSubagent ? "subagent" : rawName
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
            if isPiSubagent {
                existing.acpTitle = nil
                existing.acpKind = nil
            } else {
                if let resolvedTitle { existing.acpTitle = resolvedTitle }
                if let resolvedKind { existing.acpKind = resolvedKind }
            }
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
                acpTitle: isHTML || isPiSubagent ? nil : resolvedTitle,
                acpKind: isHTML || isPiSubagent ? nil : resolvedKind
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
        if let lastAssistant = messages.indices.last(where: { messages[$0].role == .assistant }),
           messages.indices.last(where: { messages[$0].role == .user }).map({ $0 < lastAssistant }) ?? true {
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

    private func applySessionMetadata(from result: [String: Any]) {
        let configOptions = ACPModelCatalogParser.parseConfigOptions(result["configOptions"])
        let parsedModels = ACPModelCatalogParser.parseModels(from: result, configOptions: configOptions)
        let parsedModes = ACPModelCatalogParser.parseModes(from: result, configOptions: configOptions)
        if !parsedModels.models.isEmpty { models = parsedModels.models }
        selectedModelID = parsedModels.currentModelID ?? ""
        thinkingLevel = parsedModels.currentThinkingLevel ?? ""
        modes = parsedModes.modes
        currentModeID = parsedModes.currentModeID
        modeConfigID = configOptions.first { $0.category == "mode" || $0.id == "mode" }?.id
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
            modeConfigID = modeConfig.id
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
        isSessionReady = false
        isProcessActive = false
        cancelPendingPermissions()
        if promptQueued, !isCancellingPrompt, status != 0 {
            errorText = "Antigravity ACP process exited unexpectedly (status \(status))."
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
