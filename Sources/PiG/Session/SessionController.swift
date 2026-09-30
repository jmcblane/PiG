import Foundation
import SwiftUI
import AppKit
@preconcurrency import UserNotifications

@MainActor
enum SessionKind {
    case persistent
    case quickChat
}

struct SessionRecoveryRequests {
    let getState: () async throws -> [String: Any]
    let getMessages: () async throws -> [ChatMessage]
    let loadSavedMessages: (String) async -> [ChatMessage]?
}

@MainActor
final class SessionController: ObservableObject, Identifiable {
    enum Event {
        case sessionFileChanged
        case titleChanged
        case activityChanged
        case sessionsChanged
        case showSessionTree
        case showPiUpdates(cwd: String, projectName: String, action: PiUpdateAction?)
        case showPiChangelog
        case unloadOthers(String)
        case unloadAllIdle
        case extensionUIChanged
        case log(String)
    }

    let id = UUID().uuidString
    let projectPath: String
    let kind: SessionKind
    @Published var sessionPath: String? {
        didSet {
            if sessionPath != oldValue {
                recoveryRevision &+= 1
                failedPrompt = nil
            }
        }
    }
    @Published var title: String
    @Published var messages: [ChatMessage] {
        didSet { recoveryRevision &+= 1 }
    }
    @Published var models: [ModelInfo] = []
    @Published var selectedModelID: String = ""
    @Published var isDiscoveringModels = false
    @Published var hasCompleteModelCatalog = false
    @Published var thinkingLevel: String = "medium"
    @Published var contextPercent: Double?
    @Published var contextTokens: Int?
    @Published var contextWindow: Int?
    @Published var steeringMode: String = "one-at-a-time"
    @Published var followUpMode: String = "one-at-a-time"
    @Published private(set) var queuedSteering: [String] = []
    @Published private(set) var queuedFollowUps: [String] = []
    @Published private(set) var queuedImageCount = 0
    @Published var autoCompactionEnabled = true
    @Published var pendingMessageCount = 0
    @Published var slashCommands: [SlashCommandInfo] = []
    @Published var bottomScrollRequest = 0
    @Published var streamingFrameToken = 0
    @Published var isProcessActive = false
    @Published var isAgentSettled = true
    @Published var isWorking = false
    @Published var isThinking = false
    @Published var isCompacting = false
    @Published var errorText: String? {
        didSet {
            if errorText != oldValue { dismissedErrorToast = nil }
        }
    }
    @Published var dismissedErrorToast: String?
    private var recentExtensionNotices: [String: Date] = [:]
    @Published var sessionTree: SessionTreeSnapshot?
    @Published var sessionTreeLoadState: SessionTreeLoadState = .idle
    @Published var isForking = false
    @Published var composerPrefillRequest: ComposerPrefillRequest?
    @Published private(set) var extensionUIPrompt: ExtensionUIPrompt?
    @Published private(set) var extensionUINotifications: [ExtensionUINotification] = []
    @Published private(set) var extensionUIStatuses: [String: String] = [:]
    @Published private(set) var extensionUIWidgets: [String: ExtensionUIWidget] = [:]
    @Published private(set) var extensionWindowTitle: String?
    @Published var messageScrollRequest: MessageScrollRequest?
    @Published var visibleMessageLimit = 60
    @Published var lastRuntimeUse = Date()

    struct FailedPromptSubmission {
        let id = UUID()
        var text: String
        var displayText: String
        var images: [ImageAttachment]
        var requestFollowUp: Bool
        var forceQueue: Bool
        var composerDraft: String?
    }

    @Published private(set) var failedPrompt: FailedPromptSubmission?
    @Published private(set) var isSendingPrompt = false

    func preserveFailedPromptDraft(_ draft: String) {
        failedPrompt?.composerDraft = draft
    }

    func dismissFailedPrompt() {
        guard !isSendingPrompt else { return }
        failedPrompt = nil
    }

    func retryFailedPrompt() async -> Bool {
        guard let submission = failedPrompt, !isSendingPrompt, !quickChatClosed else { return false }
        resumeRuntimeLoading()
        return await sendPrompt(
            submission.text,
            images: submission.images,
            requestFollowUp: submission.requestFollowUp,
            forceQueue: submission.forceQueue,
            composerDraft: submission.composerDraft
        )
    }

    private struct QueuedImageSubmission {
        var composerText: String
        var images: [ImageAttachment]
    }

    private var rpc: PiRPCClient?
    private var rpcStartupTask: Task<Void, Error>?
    private var rpcStartupRevision = 0
    private var runtimeLoadingSuspended = false
    private var quickChatClosed = false
    private let closedQuickChatNotice = "This quick chat is closed. Its transcript is read-only because its unsaved agent context was unloaded. Start a new quick chat to continue."
    private var streamingAccumulator: StreamingAssistantAccumulator?
    private var streamingAccumulatorNeedsSnapshot = false
    private var streamingMessageID: String?
    private var streamingTargetMessage: ChatMessage?
    private var streamingRevealScheduled = false
    private var streamingRevealGeneration = 0
    private let streamingRevealInterval: TimeInterval = 1.0 / 30.0
    private let createdAsNewSession: Bool
    private var hasExplicitModelSelection = false
    private var hasExplicitThinkingSelection = false
    private var automaticTitleGenerationStarted = false
    private var automaticTitleRequestID: UUID?
    private var automaticTitleTask: Task<Void, Never>?
    private var queuedImageSubmissions: [QueuedImageSubmission] = []
    private var extensionUIPromptQueue: [ExtensionUIPrompt] = []
    private var extensionUITimeoutTasks: [String: Task<Void, Never>] = [:]
    private var launchResources: PiLaunchResources
    @Published private(set) var chatResources: [PiResourceItem] = []
    private var launchResourcesFrozen = false
    private let recoveryRequests: SessionRecoveryRequests?
    private let eventHandler: (Event) -> Void
    private var recoveryTimerTask: Task<Void, Never>?
    private var recoveryCheckInFlight = false
    private var recoveryRevision = 0
    private var runtimeGeneration = 0

    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    static let liveUpdatesUnavailableNotice = "Live updates unavailable; work may still be running."
    private static let recoveryInterval: UInt64 = 30_000_000_000

    init(
        projectPath: String,
        sessionPath: String?,
        title: String,
        messages: [ChatMessage],
        kind: SessionKind = .persistent,
        extensionPaths: [String] = [],
        recoveryRequests: SessionRecoveryRequests? = nil,
        eventHandler: @escaping (Event) -> Void
    ) {
        self.projectPath = projectPath
        self.kind = kind
        self.sessionPath = sessionPath
        self.title = title
        self.messages = messages
        self.launchResources = PiLaunchResources(extensions: extensionPaths)
        self.recoveryRequests = recoveryRequests
        self.eventHandler = eventHandler
        self.createdAsNewSession = sessionPath == nil && messages.isEmpty
        if self.createdAsNewSession {
            self.selectedModelID = DefaultModelSchedule.effectiveModelID() ?? ""
            self.thinkingLevel = GlobalThinkingSelection.level
        }
        Task { [weak self] in await self?.loadConfiguredModels() }
    }

    // Draft additions are editable only until the first RPC startup (including failed starts).
    func setLandingResources(_ items: [PiResourceItem]) {
        guard !launchResourcesFrozen, rpcStartupTask == nil, rpc == nil else { return }
        chatResources = items
        launchResources = PiLaunchResources(items: items)
    }

    var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
    var isQuickChat: Bool { kind == .quickChat }
    var explicitModelSelectionID: String? { hasExplicitModelSelection ? selectedModelID : nil }
    var explicitThinkingLevel: String? { hasExplicitThinkingSelection ? thinkingLevel : nil }
    var availableThinkingLevels: [String] {
        models.first(where: { $0.id == selectedModelID })?.thinkingLevels ?? Self.thinkingLevels
    }
    var canAbort: Bool { isProcessActive && (isWorking || isThinking || isCompacting) }
    var hasRuntimeOrStartup: Bool { isProcessActive || rpcStartupTask != nil }
    var showsActivityIndicator: Bool { isWorking || isThinking || isCompacting }
    var hiddenMessageCount: Int { max(0, messages.count - visibleMessageLimit) }
    var visibleMessages: [ChatMessage] { Array(messages.suffix(visibleMessageLimit)) }

    func loadEarlierMessages() {
        visibleMessageLimit = min(messages.count, visibleMessageLimit + 100)
    }

    func loadSessionTree(force: Bool = false) async {
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
            addSystemNotice("Forked session.")
            return true
        } catch {
            errorText = error.localizedDescription
            eventHandler(.log(error.localizedDescription))
            return false
        }
    }

    func consumeComposerPrefill(_ id: UUID) {
        guard composerPrefillRequest?.id == id else { return }
        composerPrefillRequest = nil
    }

    func respondToExtensionPrompt(_ id: String, value: String) {
        completeExtensionPrompt(id, payload: ["value": value])
    }

    func respondToExtensionConfirmation(_ id: String, confirmed: Bool) {
        completeExtensionPrompt(id, payload: ["confirmed": confirmed])
    }

    func cancelExtensionPrompt(_ id: String) {
        completeExtensionPrompt(id, payload: ["cancelled": true])
    }

    func dismissExtensionNotification(_ id: String) {
        extensionUINotifications.removeAll { $0.id == id }
        eventHandler(.extensionUIChanged)
    }

    private func completeExtensionPrompt(_ id: String, payload: [String: Any]) {
        guard extensionUIPrompt?.id == id else { return }
        extensionUITimeoutTasks.removeValue(forKey: id)?.cancel()
        var response = payload
        response["type"] = "extension_ui_response"
        response["id"] = id
        try? rpc?.notify(response)
        extensionUIPrompt = nil
        showNextExtensionPrompt()
        eventHandler(.extensionUIChanged)
    }

    private func handleExtensionUIRequest(_ request: [String: Any]) {
        guard let id = request["id"] as? String,
              let method = request["method"] as? String else { return }
        let clean: (String) -> String = { $0.strippingTerminalControlSequences }
        let title = clean(request["title"] as? String ?? "Extension Request")
        let timeout = (request["timeout"] as? NSNumber).map { $0.doubleValue / 1_000 }

        switch method {
        case "select":
            enqueueExtensionPrompt(ExtensionUIPrompt(
                id: id,
                title: title,
                kind: .select((request["options"] as? [String] ?? []).map(clean)),
                initialValue: "",
                timeout: timeout
            ))
        case "confirm":
            enqueueExtensionPrompt(ExtensionUIPrompt(
                id: id,
                title: title,
                kind: .confirm(message: (request["message"] as? String).map(clean)),
                initialValue: "",
                timeout: timeout
            ))
        case "input":
            enqueueExtensionPrompt(ExtensionUIPrompt(
                id: id,
                title: title,
                kind: .input(placeholder: (request["placeholder"] as? String).map(clean)),
                initialValue: "",
                timeout: timeout
            ))
        case "editor":
            enqueueExtensionPrompt(ExtensionUIPrompt(
                id: id,
                title: title,
                kind: .editor,
                initialValue: clean(request["prefill"] as? String ?? ""),
                timeout: timeout
            ))
        case "notify":
            let kind = ExtensionUINotification.Kind(rawValue: request["notifyType"] as? String ?? "info") ?? .info
            let message = clean(request["message"] as? String ?? "")
            guard !message.isEmpty else { return }
            let signature = "\(kind.rawValue):\(message)"
            let now = Date()
            recentExtensionNotices = recentExtensionNotices.filter { now.timeIntervalSince($0.value) < 30 }
            guard recentExtensionNotices[signature] == nil,
                  !extensionUINotifications.contains(where: { $0.message == message && $0.kind == kind }) else { return }
            recentExtensionNotices[signature] = now
            extensionUINotifications.removeAll { $0.id == id }
            extensionUINotifications.append(ExtensionUINotification(id: id, message: message, kind: kind))
            // Bounded pending queue: expiry is owned by the toast UI, so
            // drop the oldest here to stop hidden items accumulating.
            if extensionUINotifications.count > ExtensionUINotification.maxPending {
                extensionUINotifications.removeFirst(extensionUINotifications.count - ExtensionUINotification.maxPending)
            }
            eventHandler(.extensionUIChanged)
            // Expiry is owned by ExtensionNotificationsView (auto-dismiss
            // toast) so hovering/keyboard focus can pause it.
        case "setStatus":
            guard let key = request["statusKey"] as? String else { return }
            if let text = request["statusText"] as? String, !text.isEmpty {
                extensionUIStatuses[key] = clean(text)
            } else {
                extensionUIStatuses.removeValue(forKey: key)
            }
            eventHandler(.extensionUIChanged)
        case "setWidget":
            guard let key = request["widgetKey"] as? String else { return }
            if let lines = request["widgetLines"] as? [String] {
                let placement = ExtensionUIWidget.Placement(rawValue: request["widgetPlacement"] as? String ?? "aboveEditor") ?? .aboveEditor
                extensionUIWidgets[key] = ExtensionUIWidget(key: key, lines: lines.map(clean), placement: placement)
            } else {
                extensionUIWidgets.removeValue(forKey: key)
            }
            eventHandler(.extensionUIChanged)
        case "setTitle":
            extensionWindowTitle = (request["title"] as? String).map(clean)?.nonEmptyTrimmed
            eventHandler(.extensionUIChanged)
        case "set_editor_text":
            composerPrefillRequest = ComposerPrefillRequest(text: clean(request["text"] as? String ?? ""))
            eventHandler(.extensionUIChanged)
        default:
            try? rpc?.notify([
                "type": "extension_ui_response",
                "id": id,
                "cancelled": true
            ])
            eventHandler(.log("Unsupported extension UI method: \(method)"))
        }
    }

    private func enqueueExtensionPrompt(_ prompt: ExtensionUIPrompt) {
        guard extensionUIPrompt?.id != prompt.id,
              !extensionUIPromptQueue.contains(where: { $0.id == prompt.id }) else { return }
        if extensionUIPrompt == nil {
            extensionUIPrompt = prompt
        } else {
            extensionUIPromptQueue.append(prompt)
        }
        if let timeout = prompt.timeout, timeout > 0 {
            extensionUITimeoutTasks[prompt.id] = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                self?.expireExtensionPrompt(prompt.id)
            }
        }
        eventHandler(.extensionUIChanged)
    }

    private func expireExtensionPrompt(_ id: String) {
        extensionUITimeoutTasks.removeValue(forKey: id)
        if extensionUIPrompt?.id == id {
            extensionUIPrompt = nil
            showNextExtensionPrompt()
        } else {
            extensionUIPromptQueue.removeAll { $0.id == id }
        }
        eventHandler(.extensionUIChanged)
    }

    private func showNextExtensionPrompt() {
        while !extensionUIPromptQueue.isEmpty {
            let next = extensionUIPromptQueue.removeFirst()
            if extensionUITimeoutTasks[next.id] != nil || next.timeout == nil {
                extensionUIPrompt = next
                return
            }
        }
    }

    private func clearExtensionUIRuntimeState() {
        for task in extensionUITimeoutTasks.values { task.cancel() }
        extensionUITimeoutTasks.removeAll()
        extensionUIPromptQueue.removeAll()
        extensionUIPrompt = nil
        extensionUIStatuses.removeAll()
        extensionUIWidgets.removeAll()
        extensionWindowTitle = nil
        eventHandler(.extensionUIChanged)
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

    @discardableResult
    func send(_ rawText: String, images: [ImageAttachment] = [], requestFollowUp: Bool = false) async -> Bool {
        let text = rawText.nonEmptyTrimmed ?? ""
        guard !text.isEmpty || !images.isEmpty else { return false }
        guard !quickChatClosed else {
            errorText = closedQuickChatNotice
            return false
        }
        lastRuntimeUse = Date()
        if !images.isEmpty, text.hasPrefix("/"), let parsed = SlashCommandParsing.split(text) {
            let name = parsed.name.lowercased()
            if name == "steer" || name == "follow-up" {
                return await sendPrompt(parsed.arguments, images: images, requestFollowUp: name == "follow-up", forceQueue: true)
            }
            if GUIBuiltinSlashCommands.named(name) != nil {
                errorText = "Images cannot be attached to the local /\(name) command. Send them with a normal prompt."
                return false
            }
            return await sendPrompt(text, images: images, requestFollowUp: requestFollowUp)
        }
        if text.hasPrefix("//") {
            return await sendPrompt(String(text.dropFirst()), images: images, requestFollowUp: requestFollowUp)
        }
        if text.hasPrefix("!!") || text.hasPrefix("!") {
            guard images.isEmpty else {
                errorText = "Images cannot be attached to shell commands. Send them with a normal prompt."
                return false
            }
            if text.hasPrefix("!!") {
                return await executeBash(String(text.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines), excludeFromContext: true)
            } else {
                return await executeBash(String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines), excludeFromContext: false)
            }
        }
        if text.hasPrefix("/") {
            if SlashCommandParsing.split(text) == nil {
                return await sendPrompt(text, images: images)
            }
            return await executeSlashCommand(text)
        }
        return await sendPrompt(text, images: images, requestFollowUp: requestFollowUp)
    }

    private func sendPrompt(
        _ rawText: String,
        images: [ImageAttachment] = [],
        requestFollowUp: Bool = false,
        forceQueue: Bool = false,
        composerDraft: String? = nil
    ) async -> Bool {
        let text = rawText.nonEmptyTrimmed ?? ""
        guard !isSendingPrompt, !text.isEmpty || !images.isEmpty else { return false }
        isSendingPrompt = true
        defer { isSendingPrompt = false }
        let isQueueing = forceQueue || showsActivityIndicator
        let prepared = PromptEnvelope.prepare(canonicalText: text, projectPath: projectPath)
        errorText = nil
        isAgentSettled = false
        bottomScrollRequest += 1
        var optimisticMessageID: String?
        var commandAttempted = false
        do {
            try await ensureRPC()
            let messageID = UUID().uuidString
            optimisticMessageID = messageID
            messages.append(ChatMessage(
                id: messageID,
                role: .user,
                text: prepared.displayText,
                canonicalText: prepared.canonicalText,
                references: prepared.references,
                images: images,
                timestamp: Date()
            ))
            let wasUntitled = title.isEmpty || title == "Untitled" || title == "Quick Chat"
            let shouldGenerateTitle = createdAsNewSession && !automaticTitleGenerationStarted && wasUntitled
            let fallbackSource = prepared.displayText.nonEmptyTrimmed ?? images.first?.name ?? prepared.references.map(\.label).joined(separator: ", ")
            let fallbackTitle = fallbackSource.oneLine(max: 70)
            if wasUntitled {
                title = fallbackTitle
                eventHandler(.titleChanged)
            }
            var command: [String: Any]
            if isQueueing {
                command = [
                    "type": requestFollowUp ? "follow_up" : "steer",
                    "message": prepared.payload
                ]
            } else {
                command = ["type": "prompt", "message": prepared.payload]
            }
            if !images.isEmpty { command["images"] = images.compactMap(\.rpcValue) }
            guard let rpc else { throw PiRPCClient.RPCError.notRunning }
            commandAttempted = true
            let response = try await rpc.command(command)
            failedPrompt = nil
            // An extension command or input handler consumed the input: no run
            // starts, so agent_settled never arrives.
            let handled = (response["data"] as? [String: Any])?["disposition"] as? String == "handled"
            if handled, !showsActivityIndicator { isAgentSettled = true }
            if isQueueing, !images.isEmpty, !handled {
                queuedImageSubmissions.append(QueuedImageSubmission(composerText: text, images: images))
                queuedImageCount = queuedImageSubmissions.reduce(0) { $0 + $1.images.count }
            }
            if shouldGenerateTitle {
                automaticTitleGenerationStarted = true
                requestAutomaticSessionTitle(for: prepared.displayText, replacing: fallbackTitle)
            }
            await refreshState()
            return true
        } catch {
            eventHandler(.log(error.localizedDescription))
            // Once a write was attempted, a lost response or connection cannot
            // prove non-delivery. Keep the optimistic message and never offer a
            // resend that could duplicate it. An explicit rejection is different.
            let wasRejected: Bool
            if let rpcError = error as? PiRPCClient.RPCError, case .commandFailed = rpcError {
                wasRejected = true
            } else {
                wasRejected = false
            }
            if commandAttempted && !wasRejected {
                failedPrompt = nil
                if isQueueing, !images.isEmpty {
                    queuedImageSubmissions.append(QueuedImageSubmission(composerText: text, images: images))
                    queuedImageCount = queuedImageSubmissions.reduce(0) { $0 + $1.images.count }
                }
                if rpc?.isRunning != true { isAgentSettled = true }
                await refreshState()
                return true
            }
            if let optimisticMessageID { messages.removeAll { $0.id == optimisticMessageID } }
            isAgentSettled = true
            failedPrompt = FailedPromptSubmission(
                text: text,
                displayText: prepared.displayText,
                images: images,
                requestFollowUp: requestFollowUp,
                forceQueue: isQueueing,
                composerDraft: composerDraft
            )
            return false
        }
    }

    private func requestAutomaticSessionTitle(for initialPrompt: String, replacing fallbackTitle: String) {
        guard SessionNamingPreference.enabled else { return }
        let mode = SessionNamingPreference.modelMode
        let modelID: String
        switch mode {
        case .apple:
            modelID = ""
        case .session:
            modelID = selectedModelID
        case .specific:
            modelID = SessionNamingPreference.modelID ?? ""
        }
        let thinkingLevel = SessionNamingPreference.thinkingLevel
        let requestID = UUID()
        automaticTitleTask?.cancel()
        automaticTitleRequestID = requestID
        automaticTitleTask = Task { [weak self] in
            let generatedTitle: String?
            if mode == .apple {
                generatedTitle = await AppleIntelligenceNaming.generateTitle(from: initialPrompt)
            } else {
                let configuredTitle = modelID.isEmpty ? nil : await SessionTitleGenerator.generate(
                    from: initialPrompt,
                    modelID: modelID,
                    thinkingLevel: thinkingLevel
                )
                if configuredTitle != nil || Task.isCancelled {
                    generatedTitle = configuredTitle
                } else {
                    generatedTitle = await AppleIntelligenceNaming.generateTitle(from: initialPrompt)
                }
            }
            guard let self, self.automaticTitleRequestID == requestID else { return }
            defer { self.automaticTitleTask = nil }
            guard !Task.isCancelled else {
                self.automaticTitleRequestID = nil
                return
            }
            guard let generatedTitle else {
                self.automaticTitleRequestID = nil
                return
            }
            await self.applyAutomaticSessionTitle(generatedTitle, replacing: fallbackTitle, requestID: requestID)
        }
    }

    private func applyAutomaticSessionTitle(_ generatedTitle: String, replacing fallbackTitle: String, requestID: UUID) async {
        guard automaticTitleRequestID == requestID else { return }
        guard title == fallbackTitle else {
            automaticTitleRequestID = nil
            return
        }
        if !isQuickChat {
            do {
                try await ensureRPC(reloadMessages: false)
                _ = try await rpc?.command(["type": "set_session_name", "name": generatedTitle])
            } catch {
                if automaticTitleRequestID == requestID { automaticTitleRequestID = nil }
                return
            }
        }
        guard automaticTitleRequestID == requestID, title == fallbackTitle else { return }
        automaticTitleRequestID = nil
        title = generatedTitle
        eventHandler(.titleChanged)
    }

    private func executeSlashCommand(_ text: String) async -> Bool {
        guard let parsed = SlashCommandParsing.split(text) else { return false }
        let name = parsed.name.lowercased()
        let args = parsed.arguments
        errorText = nil

        if GUIBuiltinSlashCommands.named(name) != nil {
            return await executeBuiltinSlashCommand(name: name, arguments: args)
        }

        if let command = slashCommands.first(where: { $0.name.caseInsensitiveCompare(parsed.name) == .orderedSame }) {
            return await sendDynamicSlashCommand(command, arguments: args, originalText: text)
        }

        do {
            try await ensureRPC()
            await refreshSlashCommands()
            if let command = slashCommands.first(where: { $0.name.caseInsensitiveCompare(parsed.name) == .orderedSame }) {
                return await sendDynamicSlashCommand(command, arguments: args, originalText: text)
            } else {
                // Unknown slash-prefixed text is a normal prompt. This keeps
                // paths, prose, and command typos from becoming hard failures.
                return await sendPrompt(text)
            }
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func sendDynamicSlashCommand(_ command: SlashCommandInfo, arguments: String, originalText: String) async -> Bool {
        guard command.source == "skill" else {
            return await sendPrompt(originalText)
        }
        let token = ComposerToken(
            kind: .skill,
            value: command.name,
            label: ComposerTokenCodec.skillDisplayName(command),
            detail: command.description.nonEmptyTrimmed,
            resourcePath: command.path
        )
        let canonical = ComposerTokenCodec.marker(for: token) + (arguments.isEmpty ? "" : " " + arguments)
        return await sendPrompt(canonical)
    }

    private static let builtinNotices: [String: String] = [
        "settings": "Settings available in the GUI: model picker, thinking picker, runtime policy, context meter. Other pi settings remain available in the terminal TUI via `/settings`.",
        "hotkeys": "**GUI Hotkeys**\n\n| Key | Action |\n|---|---|\n| `Return` | Send |\n| `Shift+Return` | New line |\n| `Tab` | Complete `/slash-command` or `@filename` |\n| `Shift+Tab` | Cycle pinned models |\n| `Cmd+1`–`Cmd+5` | Select quick models configured in Settings |\n| `/` | Slash command suggestions |\n| `!cmd` | Bash into context |\n| `!!cmd` | Hidden bash |",
        "resume": "Use the left sidebar to resume sessions. The GUI keeps sessions visible instead of opening pi's TUI `/resume` picker.",
        "scoped-models": "Scoped model selection is TUI-only. Use `/model <name>` or the toolbar model picker in PiG.",
        "trust": "PiG automatically trusts projects explicitly added or created here. Projects discovered from session history are not bulk-trusted.",
        "share": "`/share` is TUI-only. Use `/export [file.html]`, then share the exported file.",
        "login": "`/login` is interactive auth UI in terminal pi. Run `pi` in a terminal and use `/login`, or edit provider credentials in `\(PiPaths.agentDir.path)`.",
        "logout": "`/logout` is interactive auth UI in terminal pi. Run `pi` in a terminal and use `/logout`, or edit provider credentials in `\(PiPaths.agentDir.path)`."
    ]

    private func executeBuiltinSlashCommand(name: String, arguments args: String) async -> Bool {
        if let notice = Self.builtinNotices[name] {
            addSystemNotice(notice)
            return true
        }
        switch name {
        case "help", "commands":
            if name == "commands" { await refreshSlashCommands() }
            addSystemNotice(commandHelpMarkdown())
        case "abort":
            guard await abort() else { return false }
            addSystemNotice("Abort requested.")
        case "model":
            return await handleModelSlash(args)
        case "cycle-model":
            return await handleCycleModelSlash()
        case "thinking":
            return await handleThinkingSlash(args)
        case "cycle-thinking":
            return await handleCycleThinkingSlash()
        case "update":
            let action: PiUpdateAction?
            switch args.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "": action = .pi
            case "--extensions": action = .extensions
            case "--models": action = .models
            case "--all": action = .all
            case "--self", "pi", "self": action = .pi
            default:
                addSystemNotice("Usage: `/update`, `/update --extensions`, `/update --models`, or `/update --all`")
                return false
            }
            eventHandler(.showPiUpdates(cwd: projectPath, projectName: projectName, action: action))
        case "changelog":
            eventHandler(.showPiChangelog)
        case "export":
            return await handleExportSlash(args)
        case "copy":
            handleCopySlash()
        case "name":
            return await handleNameSlash(args)
        case "session":
            return await handleSessionSlash()
        case "new":
            return await handleNewSlash()
        case "compact":
            return await handleCompactSlash(args)
        case "auto-compact":
            return await handleBooleanRPCSlash(args, commandType: "set_auto_compaction", key: "enabled", label: "Auto compaction")
        case "auto-retry":
            return await handleBooleanRPCSlash(args, commandType: "set_auto_retry", key: "enabled", label: "Auto retry")
        case "steering-mode":
            return await handleModeSlash(args, commandType: "set_steering_mode", key: "mode", label: "Steering mode")
        case "follow-up-mode":
            return await handleModeSlash(args, commandType: "set_follow_up_mode", key: "mode", label: "Follow-up mode")
        case "steer":
            return await handleQueuedMessageSlash(args, type: "steer")
        case "follow-up":
            return await handleQueuedMessageSlash(args, type: "follow_up")
        case "bash":
            return await executeBash(args, excludeFromContext: false)
        case "hidden-bash":
            return await executeBash(args, excludeFromContext: true)
        case "fork":
            return await handleForkSlash(args)
        case "clone":
            return await handleCloneSlash()
        case "reload":
            return await handleReloadSlash()
        case "unload":
            return handleUnloadSlash()
        case "unload-others":
            eventHandler(.unloadOthers(id))
            addSystemNotice("Requested unload of other idle session runtimes.")
        case "unload-all-idle":
            eventHandler(.unloadAllIdle)
            addSystemNotice("Requested unload of all idle session runtimes.")
        case "refresh":
            await performRecoveryCheck(refreshMessagesWhenIdle: true)
            await refreshSlashCommands()
        case "clear-error":
            errorText = nil
            addSystemNotice("Error cleared.")
        case "tree":
            eventHandler(.showSessionTree)
        case "quit":
            NSApp.terminate(nil)
        default:
            addSystemNotice("Not implemented in PiG: `/\(name)`")
        }
        return true
    }

    private func withSlashRPC(onError: () -> Void = {}, _ body: (PiRPCClient) async throws -> Bool) async -> Bool {
        do {
            try await ensureRPC()
            guard let rpc else { throw PiRPCClient.RPCError.notRunning }
            return try await body(rpc)
        } catch {
            onError()
            errorText = error.localizedDescription
            return false
        }
    }

    private func handleModelSlash(_ args: String) async -> Bool {
        await withSlashRPC { rpc in
            if args.isEmpty {
                let current = selectedModelID.isEmpty ? "none" : selectedModelID
                let list = models.map { "- `\($0.displayName)`" }.joined(separator: "\n")
                addSystemNotice("Current model: `\(current)`\n\n\(list.isEmpty ? "No models loaded." : list)")
                return true
            }
            let needle = args.lowercased()
            let exact = models.first { model in
                [model.id, model.displayName, model.modelId, model.name].contains { $0.lowercased() == needle }
            }
            let match = exact ?? models.first { model in
                [model.id, model.displayName, model.modelId, model.name].contains { $0.lowercased().contains(needle) }
            }
            guard let model = match else {
                addSystemNotice("Model not found: `\(args)`")
                return false
            }
            selectedModelID = model.id
            _ = try await rpc.command(["type": "set_model", "provider": model.provider, "modelId": model.modelId])
            await refreshState()
            addSystemNotice("Model set: `\(model.displayName)`")
            return true
        }
    }

    private func handleCycleModelSlash() async -> Bool {
        await withSlashRPC { rpc in
            let response = try await rpc.command(["type": "cycle_model"])
            if let data = response["data"] as? [String: Any], let modelDict = data["model"] as? [String: Any], let model = ModelInfo.from(modelDict) {
                selectedModelID = model.id
                if !models.contains(model) { models.append(model) }
                addSystemNotice("Model set: `\(model.displayName)`")
            } else {
                addSystemNotice("No alternate model available.")
            }
            await refreshState()
            return true
        }
    }

    private func handleThinkingSlash(_ args: String) async -> Bool {
        let levels = availableThinkingLevels
        if args.isEmpty {
            addSystemNotice("Thinking level: `\(thinkingLevel)`\n\nLevels: `\(levels.joined(separator: "`, `"))`")
            return true
        }
        guard levels.contains(args) else {
            addSystemNotice("Unknown thinking level: `\(args)`\n\nLevels: `\(levels.joined(separator: "`, `"))`")
            return false
        }
        guard await applyThinkingLevel(args) else { return false }
        addSystemNotice("Thinking level set: `\(args)`")
        return true
    }

    private func handleCycleThinkingSlash() async -> Bool {
        await withSlashRPC { rpc in
            let response = try await rpc.command(["type": "cycle_thinking_level"])
            if let data = response["data"] as? [String: Any], let level = data["level"] as? String {
                thinkingLevel = level
                addSystemNotice("Thinking level set: `\(level)`")
            } else {
                addSystemNotice("Current model does not expose thinking levels.")
            }
            await refreshState()
            return true
        }
    }

    private func handleExportSlash(_ args: String) async -> Bool {
        await withSlashRPC { rpc in
            var command: [String: Any] = ["type": "export_html"]
            if !args.isEmpty { command["outputPath"] = args }
            let response = try await rpc.command(command)
            let path = (response["data"] as? [String: Any])?["path"] as? String ?? args
            addSystemNotice("Exported session: `\(path)`")
            return true
        }
    }

    private func handleCopySlash() {
        guard let text = messages.reversed().first(where: { $0.role == .assistant && !$0.text.isEmpty })?.text else {
            addSystemNotice("No assistant message to copy.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        addSystemNotice("Copied last assistant message.")
    }

    private func handleNameSlash(_ args: String) async -> Bool {
        guard !args.isEmpty else {
            addSystemNotice(title.isEmpty ? "Session has no name." : "Session name: `\(title)`")
            return true
        }
        return await renameSession(args)
    }

    func renameSession(_ name: String) async -> Bool {
        guard !showsActivityIndicator else {
            errorText = "Cannot rename a working session."
            return false
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        automaticTitleTask?.cancel()
        automaticTitleTask = nil
        automaticTitleRequestID = nil
        automaticTitleGenerationStarted = true
        do {
            try await ensureRPC()
            guard !showsActivityIndicator else { throw PiRPCClient.RPCError.commandFailed("Cannot rename a working session.") }
            guard let rpc else { throw PiRPCClient.RPCError.notRunning }
            _ = try await rpc.command(["type": "set_session_name", "name": name])
            title = name
            eventHandler(.titleChanged)
            addSystemNotice("Session name set: `\(name)`")
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func handleSessionSlash() async -> Bool {
        await withSlashRPC { rpc in
            let response = try await rpc.command(["type": "get_session_stats"])
            guard let data = response["data"] as? [String: Any] else { return false }
            let tokens = data["tokens"] as? [String: Any]
            let usage = data["contextUsage"] as? [String: Any]
            let lines = [
                "**Session Info**",
                "",
                "Name: `\(title)`",
                "File: `\(sessionPath ?? data["sessionFile"] as? String ?? "In-memory")`",
                "ID: `\(data["sessionId"] as? String ?? "unknown")`",
                "",
                "Messages: `\(data["totalMessages"] ?? 0)` total, `\(data["userMessages"] ?? 0)` user, `\(data["assistantMessages"] ?? 0)` assistant",
                "Tool calls: `\(data["toolCalls"] ?? 0)`",
                "Tokens: `\(tokens?["total"] ?? 0)` total (`\(tokens?["input"] ?? 0)` in, `\(tokens?["output"] ?? 0)` out)",
                "Context: `\(usage?["tokens"] ?? 0)` / `\(usage?["contextWindow"] ?? 0)` (`\(usage?["percent"] ?? 0)%`)"
            ]
            addSystemNotice(lines.joined(separator: "\n"))
            return true
        }
    }

    private func handleNewSlash() async -> Bool {
        await withSlashRPC { rpc in
            var command: [String: Any] = ["type": "new_session"]
            if let sessionPath { command["parentSession"] = sessionPath }
            let response = try await rpc.command(command)
            if let data = response["data"] as? [String: Any], data["cancelled"] as? Bool == true {
                addSystemNotice("New session cancelled by extension.")
                return false
            }
            messages.removeAll()
            sessionPath = nil
            sessionTree = nil
            sessionTreeLoadState = .idle
            title = "Untitled"
            await refreshState()
            bottomScrollRequest += 1
            addSystemNotice("New session started.")
            return true
        }
    }

    private func handleCompactSlash(_ args: String) async -> Bool {
        await withSlashRPC(onError: { isCompacting = false }) { rpc in
            isCompacting = true
            var command: [String: Any] = ["type": "compact"]
            if !args.isEmpty { command["customInstructions"] = args }
            let response = try await rpc.command(command)
            isCompacting = false
            await refreshState()
            if let data = response["data"] as? [String: Any], let summary = data["summary"] as? String {
                addSystemNotice("Compaction complete.\n\n\(summary)")
            } else {
                addSystemNotice("Compaction complete.")
            }
            return true
        }
    }

    private func handleBooleanRPCSlash(_ args: String, commandType: String, key: String, label: String) async -> Bool {
        guard let value = parseBoolean(args) else {
            addSystemNotice("Usage: `/\(commandType.replacingOccurrences(of: "set_", with: "").replacingOccurrences(of: "_", with: "-")) <on|off>`")
            return false
        }
        return await withSlashRPC { rpc in
            _ = try await rpc.command(["type": commandType, key: value])
            await refreshState()
            addSystemNotice("\(label): `\(value ? "on" : "off")`")
            return true
        }
    }

    private func handleModeSlash(_ args: String, commandType: String, key: String, label: String) async -> Bool {
        guard ["all", "one-at-a-time"].contains(args) else {
            addSystemNotice("Usage: `/\(commandType.replacingOccurrences(of: "set_", with: "").replacingOccurrences(of: "_", with: "-")) <all|one-at-a-time>`")
            return false
        }
        return await withSlashRPC { rpc in
            _ = try await rpc.command(["type": commandType, key: args])
            await refreshState()
            addSystemNotice("\(label): `\(args)`")
            return true
        }
    }

    private func handleQueuedMessageSlash(_ args: String, type: String) async -> Bool {
        guard !args.isEmpty else {
            addSystemNotice("Usage: `/\(type == "follow_up" ? "follow-up" : "steer") <message>`")
            return false
        }
        return await withSlashRPC { rpc in
            _ = try await rpc.command(["type": type, "message": args])
            messages.append(ChatMessage(role: .user, text: args, timestamp: Date()))
            bottomScrollRequest += 1
            await refreshState()
            return true
        }
    }

    private func handleForkSlash(_ args: String) async -> Bool {
        await withSlashRPC { rpc in
            let response = try await rpc.command(["type": "get_fork_messages"])
            let forkMessages = ((response["data"] as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            guard !forkMessages.isEmpty else {
                addSystemNotice("No user messages available to fork from.")
                return false
            }
            if args.isEmpty {
                let lines = forkMessages.enumerated().map { index, item in
                    let text = (item["text"] as? String ?? "").oneLine(max: 110)
                    let id = item["entryId"] as? String ?? ""
                    return "\(index + 1). `\(id)` — \(text)"
                }.joined(separator: "\n")
                addSystemNotice("Fork points:\n\n\(lines)\n\nRun `/fork <number>` or `/fork <entryId>`.")
                return true
            }
            let entryId: String?
            if let number = Int(args), forkMessages.indices.contains(number - 1) {
                entryId = forkMessages[number - 1]["entryId"] as? String
            } else {
                entryId = args
            }
            guard let entryId else { return false }
            return await forkFromTree(entryID: entryId)
        }
    }

    private func handleCloneSlash() async -> Bool {
        let shouldRefreshTree = sessionTree != nil
        return await withSlashRPC { rpc in
            let response = try await rpc.command(["type": "clone"])
            if let data = response["data"] as? [String: Any], data["cancelled"] as? Bool == true {
                addSystemNotice("Clone cancelled by extension.")
                return false
            }
            await refreshState()
            await reloadMessagesFromRPC()
            if shouldRefreshTree { await loadSessionTree(force: true) }
            addSystemNotice("Cloned session.")
            return true
        }
    }

    private func handleReloadSlash() async -> Bool {
        stopRPC()
        return await withSlashRPC { _ in
            await refreshSlashCommands()
            await reloadMessagesFromRPC()
            await refreshState()
            addSystemNotice("Reloaded RPC session, models, prompts, skills, and extension commands.")
            return true
        }
    }

    private func handleUnloadSlash() -> Bool {
        guard !showsActivityIndicator else {
            addSystemNotice("Cannot unload while the agent is working. Abort or wait for completion.")
            return false
        }
        guard isProcessActive else {
            addSystemNotice("Session runtime is already unloaded.")
            return false
        }
        stopRPC()
        addSystemNotice("Session runtime unloaded. Send a message or press Reconnect to reload it.")
        return true
    }

    private func executeBash(_ commandText: String, excludeFromContext: Bool) async -> Bool {
        guard !commandText.isEmpty else {
            addSystemNotice("Usage: `\(excludeFromContext ? "!!" : "!")<command>` or `/\(excludeFromContext ? "hidden-bash" : "bash") <command>`")
            return false
        }
        return await withSlashRPC(onError: {
            isWorking = false
            eventHandler(.activityChanged)
        }) { rpc in
            isWorking = true
            eventHandler(.activityChanged)
            let response = try await rpc.command(["type": "bash", "command": commandText, "excludeFromContext": excludeFromContext])
            isWorking = false
            eventHandler(.activityChanged)
            await refreshState()
            if let data = response["data"] as? [String: Any] {
                let output = data["output"] as? String ?? ""
                let exitCode = data["exitCode"] ?? "?"
                let failed = SessionParser.shellExitFailed(exitCode)
                var result = output
                if data["truncated"] as? Bool == true {
                    result += "\n... output truncated. Full output: \(data["fullOutputPath"] as? String ?? "")"
                }
                if failed { result += "\nExit: \(exitCode)" }
                let tool = userCommandTool(id: UUID().uuidString,
                                           command: commandText,
                                           label: excludeFromContext ? "you · hidden" : "you",
                                           result: result,
                                           status: failed ? .failed : .succeeded)
                messages.append(ChatMessage(role: .system, tools: [tool], timestamp: Date()))
                bottomScrollRequest += 1
            }
            return true
        }
    }

    private func reloadMessagesFromRPC(scrollToBottom: Bool = true) async {
        resetStreamingState()
        guard let rpc, rpc.isRunning else { return }
        guard let loaded = try? await loadRPCMessages(using: rpc) else { return }
        await MarkdownPrewarmer.warm(loaded, theme: AppThemeChoice.stored)
        guard self.rpc === rpc, !Task.isCancelled else { return }
        messages = loaded
        if scrollToBottom { bottomScrollRequest += 1 }
    }

    private func refreshSlashCommands() async {
        guard let rpc, rpc.isRunning else { return }
        if let response = try? await rpc.command(["type": "get_commands"]),
           let data = response["data"] as? [String: Any],
           let commandDicts = data["commands"] as? [[String: Any]] {
            guard self.rpc === rpc, !Task.isCancelled else { return }
            slashCommands = commandDicts.compactMap(SlashCommandInfo.fromRPC)
        }
    }

    private func commandHelpMarkdown() -> String {
        let builtin = GUIBuiltinSlashCommands.commands.map { command in
            "- `/\(command.name)` — \(command.description)"
        }.joined(separator: "\n")
        let dynamic = slashCommands.isEmpty ? "No prompt, skill, or extension commands loaded yet." : slashCommands.map { command in
            let hint = command.argumentHint.map { " \($0)" } ?? ""
            let description = command.description.isEmpty ? command.displaySource : "\(command.displaySource): \(command.description)"
            return "- `/\(command.name)`\(hint) — \(description)"
        }.joined(separator: "\n")
        return "**GUI Slash Commands**\n\n\(builtin)\n\n**Prompt Templates, Skills, Extensions**\n\n\(dynamic)\n\nUse `//text` to send a leading slash as a normal message."
    }

    private func parseBoolean(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "on", "true", "yes", "1", "enable", "enabled": return true
        case "off", "false", "no", "0", "disable", "disabled": return false
        default: return nil
        }
    }

    private func addSystemNotice(_ text: String) {
        messages.append(ChatMessage(role: .system, text: text, timestamp: Date()))
        bottomScrollRequest += 1
    }

    private func userCommandTool(id: String, command: String, label: String, result: String, status: ToolStatus) -> ToolDisplay {
        let arguments = (try? JSONSerialization.data(withJSONObject: ["command": command]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return ToolDisplay(id: id, name: "bash", arguments: arguments, result: result,
                           status: status, isError: status == .failed, userLabel: label)
    }

    private func updateUserCommandTool(messageID: String, result: String, status: ToolStatus) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              !messages[index].tools.isEmpty else { return }
        messages[index].tools[0].result = result
        messages[index].tools[0].status = status
        messages[index].tools[0].isError = status == .failed
        bottomScrollRequest += 1
    }

    func runCustomAction(_ action: CustomAction) async {
        guard !action.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let messageID = UUID().uuidString
        let tool = userCommandTool(id: messageID,
                                   command: action.command,
                                   label: action.title,
                                   result: "",
                                   status: .running)
        messages.append(ChatMessage(id: messageID, role: .system, tools: [tool], timestamp: Date()))
        bottomScrollRequest += 1

        var streamedOutput = ""
        let exitCode = await LocalShell.stream(command: action.command, in: projectPath) { [weak self] chunk in
            guard let self else { return }
            streamedOutput += chunk
            self.updateUserCommandTool(messageID: messageID, result: streamedOutput.truncatedForChatOutput, status: .running)
        }
        var result = streamedOutput.isEmpty ? "(no output)" : streamedOutput.truncatedForChatOutput
        if exitCode != 0 { result += "\nExit: \(exitCode)" }
        updateUserCommandTool(messageID: messageID, result: result, status: exitCode == 0 ? .succeeded : .failed)
    }

    func restoreQueuedMessages() async {
        guard let client = rpc, client.isRunning else { return }
        _ = await clearQueue(using: client)
    }

    func abort() async -> Bool {
        var accepted = true
        do {
            try await ensureRPC()
            guard let client = rpc else { throw PiRPCClient.RPCError.notRunning }
            accepted = await clearQueue(using: client)
            _ = try await client.command(["type": "abort"])
            _ = try? await client.command(["type": "abort_bash"])
            _ = try? await client.command(["type": "abort_retry"])
        } catch {
            errorText = error.localizedDescription
            accepted = false
        }
        resetStreamingState()
        resetIdleActivity()
        eventHandler(.activityChanged)
        return accepted
    }

    private func clearQueue(using client: PiRPCClient) async -> Bool {
        do {
            let response = try await client.command(["type": "clear_queue"])
            restoreQueuedContent(from: response)
            if rpc === client { clearQueueState() }
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private func restoreQueuedContent(from response: [String: Any]) {
        guard let data = response["data"] as? [String: Any] else { return }
        let steering = data["steering"] as? [String] ?? []
        let followUps = data["followUp"] as? [String] ?? []
        let text = (steering + followUps).joined(separator: "\n\n")
        let images = queuedImageSubmissions.flatMap(\.images)
        guard !text.isEmpty || !images.isEmpty else { return }
        composerPrefillRequest = ComposerPrefillRequest(text: text, images: images, appendsToDraft: true)
    }

    private func markQueuedImagesDelivered(in content: Any?) {
        let delivered = SessionParser.contentImages(content).compactMap(\.data)
        guard !delivered.isEmpty,
              let index = queuedImageSubmissions.firstIndex(where: { submission in
                  submission.images.compactMap(\.data) == delivered
              }) else { return }
        queuedImageSubmissions.remove(at: index)
        queuedImageCount = queuedImageSubmissions.reduce(0) { $0 + $1.images.count }
    }

    private func restoreLocalQueuedImagesIfNeeded() {
        let images = queuedImageSubmissions.flatMap(\.images)
        guard !images.isEmpty else { return }
        let text = queuedImageSubmissions.map(\.composerText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        composerPrefillRequest = ComposerPrefillRequest(text: text, images: images, appendsToDraft: true)
        errorText = "The RPC runtime stopped before queued images were delivered. Their local text and image copies were restored to the composer; Pi does not expose queued image payloads or message grouping."
    }

    private func clearQueueState() {
        queuedSteering.removeAll()
        queuedFollowUps.removeAll()
        queuedImageSubmissions.removeAll()
        queuedImageCount = 0
    }

    func refreshNewSessionDefaults() {
        guard createdAsNewSession, sessionPath == nil, messages.isEmpty, !isProcessActive else { return }
        if !hasExplicitModelSelection { selectedModelID = DefaultModelSchedule.effectiveModelID() ?? "" }
        if !hasExplicitThinkingSelection { thinkingLevel = GlobalThinkingSelection.level }
    }

    func setModel(_ id: String) {
        hasExplicitModelSelection = true
        selectedModelID = id
        guard let model = models.first(where: { $0.id == id }) else { return }
        guard isProcessActive || sessionPath != nil else { return }
        Task {
            do {
                try await ensureRPC()
                _ = try await rpc?.command(["type": "set_model", "provider": model.provider, "modelId": model.modelId])
                await refreshState()
            } catch { errorText = error.localizedDescription }
        }
    }

    func setThinkingLevel(_ level: String) {
        hasExplicitThinkingSelection = true
        thinkingLevel = level
        Task { _ = await applyThinkingLevel(level, updateSelection: false) }
    }

    private func applyThinkingLevel(_ level: String, updateSelection: Bool = true) async -> Bool {
        if updateSelection { thinkingLevel = level }
        guard isProcessActive || sessionPath != nil else { return true }
        do {
            try await ensureRPC()
            _ = try await rpc?.command(["type": "set_thinking_level", "level": level])
            await refreshState()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func ensureRPC(reloadMessages: Bool = true) async throws {
        try Task.checkCancellation()
        guard !quickChatClosed else { throw PiRPCClient.RPCError.commandFailed(closedQuickChatNotice) }
        guard !runtimeLoadingSuspended else {
            throw PiRPCClient.RPCError.commandFailed("Session runtime is unloaded. Reopen or reconnect the session to load it.")
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
        let shouldApplyNewSessionDefaults = createdAsNewSession && sessionPath == nil && messages.isEmpty
        resetStreamingState()
        clearQueueState()
        let client = PiRPCClient(projectPath: projectPath, noSession: isQuickChat, launchResources: launchResources)
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
                throw PiRPCClient.RPCError.commandFailed("Session switch cancelled")
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
                hasCompleteModelCatalog = true
            }
        }
        try checkCurrentStartup()
        isDiscoveringModels = false
        if shouldApplyNewSessionDefaults {
            do {
                guard hasCompleteModelCatalog else {
                    throw PiRPCClient.RPCError.commandFailed("Could not load available models. Retry before starting this session.")
                }
                let preferredID = hasExplicitModelSelection
                    ? selectedModelID
                    : (DefaultModelSchedule.effectiveModelID() ?? "")
                guard let model = models.first(where: { $0.id == preferredID }) else {
                    throw PiRPCClient.RPCError.commandFailed("The selected default model ‘\(preferredID)’ is unavailable or not configured. Choose a model in the composer or Settings → Models.")
                }
                _ = try await client.command(["type": "set_model", "provider": model.provider, "modelId": model.modelId])
                try checkCurrentStartup()
                selectedModelID = model.id
                if !hasExplicitThinkingSelection { thinkingLevel = GlobalThinkingSelection.level }
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

    func refreshState() async {
        guard let rpc, rpc.isRunning else { return }
        let wasActive = showsActivityIndicator
        if let stateResponse = try? await rpc.command(["type": "get_state"]),
           let data = stateResponse["data"] as? [String: Any] {
            guard self.rpc === rpc, !Task.isCancelled else { return }
            applyRecoveryMetadata(data)
            if let streaming = data["isStreaming"] as? Bool { isWorking = streaming }
            if let compacting = data["isCompacting"] as? Bool { isCompacting = compacting }
        }
        if let statsResponse = try? await rpc.command(["type": "get_session_stats"]),
           let data = statsResponse["data"] as? [String: Any],
           let usage = data["contextUsage"] as? [String: Any] {
            contextTokens = usage["tokens"] as? Int
            contextWindow = usage["contextWindow"] as? Int
            if let percent = usage["percent"] as? Double { contextPercent = percent }
            else if let percent = usage["percent"] as? Int { contextPercent = Double(percent) }
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
            if errorText == Self.liveUpdatesUnavailableNotice { errorText = nil }
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
            errorText = Self.liveUpdatesUnavailableNotice
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

    private func updateRecoveryTimer() {
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

    private func loadConfiguredModels() async {
        let configured = await ModelCatalog.configuredModelsAsync(projectPath: projectPath)
        guard models.isEmpty, !configured.isEmpty else { return }
        models = configured
        guard createdAsNewSession, selectedModelID.isEmpty else { return }
        selectedModelID = DefaultModelSchedule.effectiveModelID() ?? ""
    }

    private func resetIdleActivity() {
        isAgentSettled = true
        isWorking = false
        isThinking = false
        isCompacting = false
    }

    private func markRPCInactive() {
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

    func receiveRPCEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        // Nested calls (e.g. from codemode scripts) are reported by their parent
        // tool and never appear in the transcript.
        if type.hasPrefix("tool_execution_"), event["parentToolCallId"] != nil { return }
        recoveryRevision &+= 1
        defer { updateRecoveryTimer() }
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
            if event["success"] as? Bool == false {
                resetStreamingState()
                isWorking = false
            }
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
            if let message = agent["errorMessage"] as? String, !message.isEmpty { errorText = message }
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
            messages.append(message)
            bottomScrollRequest += 1
        }
    }

    private func clearStreamingAccumulator() {
        streamingAccumulator = nil
        streamingAccumulatorNeedsSnapshot = false
    }

    private func resetStreamingState() {
        streamingRevealGeneration += 1
        streamingRevealScheduled = false
        if let id = streamingMessageID,
           let index = messages.firstIndex(where: { $0.id == id }),
           messages[index].isStreaming {
            messages[index].isStreaming = false
            streamingFrameToken += 1
        }
        streamingMessageID = nil
        streamingTargetMessage = nil
        clearStreamingAccumulator()
    }

    private func ensureStreamingMessageExists(id: String) {
        if !messages.contains(where: { $0.id == id }) {
            messages.append(ChatMessage(id: id, role: .assistant, isStreaming: true))
            streamingFrameToken += 1
        }
    }

    private func setStreamingTarget(_ target: ChatMessage, authoritativeTools: Bool = false) {
        updateStreamingTarget(target, authoritativeTools: authoritativeTools)
        scheduleStreamingReveal()
    }

    private func updateStreamingTarget(_ target: ChatMessage, authoritativeTools: Bool = false) {
        var merged = target
        if let current = messages.first(where: { $0.id == target.id }) {
            merged.tools = authoritativeTools
                ? reconcileToolExecution(existing: current.tools, authoritative: target.tools)
                : mergeTools(existing: current.tools, incoming: target.tools)
        }
        if let previous = streamingTargetMessage, previous.id == target.id {
            merged.tools = authoritativeTools
                ? reconcileToolExecution(existing: previous.tools, authoritative: merged.tools)
                : mergeTools(existing: previous.tools, incoming: merged.tools)
        }
        streamingTargetMessage = merged
    }

    private func materializeStreamingAccumulatorSnapshot() {
        guard streamingAccumulatorNeedsSnapshot,
              let accumulator = streamingAccumulator,
              let id = streamingMessageID else { return }
        streamingAccumulatorNeedsSnapshot = false
        updateStreamingTarget(accumulator.message(id: id))
    }

    private func reconcileToolExecution(existing: [ToolDisplay], authoritative: [ToolDisplay]) -> [ToolDisplay] {
        authoritative.map { tool in
            guard let old = existing.first(where: { $0.id == tool.id }) else { return tool }
            var reconciled = tool
            if !old.result.isEmpty { reconciled.result = old.result }
            reconciled.details = old.details ?? tool.details
            if reconciled.images.isEmpty { reconciled.images = old.images }
            if old.status != .pending { reconciled.status = old.status }
            reconciled.isError = old.isError || tool.isError
            return reconciled
        }
    }

    private func scheduleStreamingReveal() {
        guard !streamingRevealScheduled else { return }
        streamingRevealScheduled = true
        streamingRevealGeneration += 1
        let generation = streamingRevealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + streamingRevealInterval) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.streamingRevealGeneration == generation else { return }
                self.streamingRevealScheduled = false
                self.runStreamingRevealFrame()
            }
        }
    }

    private func runStreamingRevealFrame() {
        materializeStreamingAccumulatorSnapshot()
        guard let target = streamingTargetMessage else { return }
        let complete = applyStreamingRevealFrame(toward: target)
        if complete {
            if !target.isStreaming {
                streamingTargetMessage = nil
                streamingMessageID = nil
            }
        } else {
            scheduleStreamingReveal()
        }
    }

    private func finishStreamingReveal(immediate: Bool) {
        streamingRevealGeneration += 1
        streamingRevealScheduled = false
        materializeStreamingAccumulatorSnapshot()
        guard let target = streamingTargetMessage else {
            if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }), messages[index].isStreaming {
                messages[index].isStreaming = false
                streamingFrameToken += 1
            }
            streamingMessageID = nil
            return
        }
        var final = target
        final.isStreaming = false
        if immediate {
            applyStreamingMessage(final)
            streamingTargetMessage = nil
            streamingMessageID = nil
        } else {
            streamingTargetMessage = final
            scheduleStreamingReveal()
        }
    }

    @discardableResult
    private func applyStreamingRevealFrame(toward target: ChatMessage) -> Bool {
        ensureStreamingMessageExists(id: target.id)
        guard let index = messages.firstIndex(where: { $0.id == target.id }) else { return true }
        let current = messages[index]
        let textPlan = streamingRevealPlan(from: current.text, to: target.text)
        let thinkingPlan = streamingRevealPlan(from: current.thinking, to: target.thinking)
        var budget = streamingRevealBudget(for: textPlan.remaining + thinkingPlan.remaining)
        let textReveal = reveal(textPlan, budget: &budget)
        let thinkingReveal = reveal(thinkingPlan, budget: &budget)
        var next = current
        next.role = target.role
        next.timestamp = target.timestamp ?? current.timestamp
        next.stopReason = target.stopReason
        next.text = textReveal.value
        next.thinking = thinkingReveal.value
        next.images = target.images
        next.tools = mergeTools(existing: current.tools, incoming: target.tools)
        let complete = textReveal.complete && thinkingReveal.complete
        next.isStreaming = target.isStreaming || !complete
        if next != current {
            messages[index] = next
            streamingFrameToken += 1
        }
        return complete
    }

    private func applyStreamingMessage(_ message: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            var updated = message
            updated.tools = mergeTools(existing: messages[index].tools, incoming: message.tools)
            messages[index] = updated
        } else {
            messages.append(message)
        }
        streamingFrameToken += 1
    }

    private func streamingRevealBudget(for remaining: Int) -> Int {
        guard remaining > 0 else { return 0 }
        return min(56, max(2, Int(ceil(Double(remaining) / 18.0))))
    }

    private struct StreamingRevealPlan {
        var base: String
        var remainder: Substring
        var remaining: Int
    }

    private func streamingRevealPlan(from current: String, to target: String) -> StreamingRevealPlan {
        var currentIndex = current.startIndex
        var targetIndex = target.startIndex
        while currentIndex < current.endIndex,
              targetIndex < target.endIndex,
              current[currentIndex] == target[targetIndex] {
            currentIndex = current.index(after: currentIndex)
            targetIndex = target.index(after: targetIndex)
        }

        if targetIndex == target.endIndex {
            return StreamingRevealPlan(base: target, remainder: target[target.endIndex...], remaining: 0)
        }
        let remainder = target[targetIndex...]
        let base = currentIndex == current.endIndex ? current : String(target[..<targetIndex])
        return StreamingRevealPlan(base: base, remainder: remainder, remaining: remainder.count)
    }

    private func reveal(_ plan: StreamingRevealPlan, budget: inout Int) -> (value: String, complete: Bool) {
        guard plan.remaining > 0 else { return (plan.base, true) }
        guard budget > 0 else { return (plan.base, false) }
        let count = revealCount(in: plan.remainder, remainderCount: plan.remaining, budget: budget)
        budget -= count
        return (plan.base + String(plan.remainder.prefix(count)), count == plan.remaining)
    }

    // Reveal whole words where possible. Revealing a fixed number of
    // characters grows the trailing word one glyph at a time, and every one
    // of those glyphs can re-wrap the line, so the paragraph jitters while it
    // streams. Falling back to the raw count keeps very long unbroken tokens
    // (URLs, base64) from stalling the reveal.
    private func revealCount(in remainder: Substring, remainderCount: Int, budget: Int) -> Int {
        let count = min(budget, remainderCount)
        guard count < remainderCount else { return remainderCount }
        let taken = remainder.prefix(count)
        guard let lastBreak = taken.lastIndex(where: { $0.isWhitespace }) else { return count }
        let trimmed = taken.distance(from: taken.startIndex, to: taken.index(after: lastBreak))
        return trimmed >= max(1, count / 4) ? trimmed : count
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

    private func mergeTools(existing: [ToolDisplay], incoming: [ToolDisplay]) -> [ToolDisplay] {
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
