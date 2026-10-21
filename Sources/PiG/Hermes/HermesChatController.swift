import Foundation
import Combine

struct HermesApprovalPrompt: Identifiable, Equatable {
    let id: String
    /// Human-readable context: title, reason, command.
    let title: String
}

/// Drives one Hermes chat (one remote session plus its local journal/cache).
/// `/new` is handled by AppModel creating a new controller with a new chat ID.
@MainActor
final class HermesChatController: ObservableObject, Identifiable {
    enum Event {
        /// isWorking / approval changed.
        case activityChanged
        /// A turn finished with a final reply.
        case replyFinished
        case log(String)
    }

    let id = UUID().uuidString
    let agentID: String
    /// Local UUID for this chat, independent of the agent configuration.
    let chatID: String

    @Published var messages: [ChatMessage] = [] {
        didSet { if messages != oldValue { bottomScrollRequest &+= 1 } }
    }
    @Published private(set) var isWorking = false
    /// Name of the tool the remote agent is running, if reported.
    @Published private(set) var currentTool: String?
    @Published private(set) var approval: HermesApprovalPrompt?
    @Published var errorText: String?
    /// Model IDs offered by the server (cached between launches).
    @Published private(set) var models: [String] = []
    /// nil means the server default.
    @Published private(set) var selectedModelID: String?
    @Published var bottomScrollRequest = 0
    /// Transcript paging, as in `SessionController`.
    @Published private var visibleMessageLimit = 60

    private let eventHandler: (Event) -> Void
    private let connection: HermesConnection?
    private let name: String
    private var session: HermesSession?
    private var loaded = false
    var isLoaded: Bool { loaded && !stopped }
    private var stopped = false
    private var operations: [UUID: Task<Void, Never>] = [:]

    init(agent: Agent, chatID: String, eventHandler: @escaping (Event) -> Void) {
        self.agentID = agent.id
        self.chatID = chatID
        self.selectedModelID = agent.modelID
        self.eventHandler = eventHandler
        self.connection = agent.hermes
        self.name = agent.name
        if let connection = agent.hermes { self.models = HermesCache.info(for: connection)?.models ?? [] }
    }

    deinit {
        operations.values.forEach { $0.cancel() }
        // Cancel locally without sending a remote /stop.
        let ownedSession = session
        Task { @MainActor in ownedSession?.stop() }
    }

    /// Loads the cached transcript, then reconnects and recovers any in-flight run.
    func load() async {
        guard !loaded else { return }
        loaded = true
        stopped = false
        errorText = nil
        do { messages = try HermesCache.load(chatID).messages }
        catch { report(error.localizedDescription); return }
        if let connection { models = HermesCache.info(for: connection)?.models ?? [] }
        guard let connection else {
            report("This Hermes agent has no saved connection.")
            return
        }
        do { try connection.validate() }
        catch { report(error.localizedDescription); return }

        let session = HermesSession(connection: connection, chatID: chatID)
        self.session = session
        session.onEvent = { [weak self] event in
            guard let self, !self.stopped else { return }
            switch event {
            case .history(let history, _): self.messages = history
            case .needsInput: break // onState publishes the full approval context.
            case .replyFinished: self.eventHandler(.replyFinished)
            case .notice(let text), .failed(let text): self.report(text)
            }
        }
        session.onState = { [weak self] status, tool, prompt, notice in
            guard let self, !self.stopped else { return }
            self.updateActivity(working: status != .idle, tool: tool, approval: prompt)
            if self.errorText != notice {
                self.errorText = notice
                if let notice { self.eventHandler(.log(notice)) }
            }
        }
        session.resume(name: name)
        await perform { [weak self] in
            do {
                let info = try await HermesOnboarding.check(connection)
                try Task.checkCancellation()
                guard let self, !self.stopped else { return }
                self.models = info.models
                try HermesCache.save(info, for: connection)
            } catch {
                guard !Task.isCancelled, let self, !self.stopped else { return }
                // Catalog failure does not prevent run/history recovery or discard offline models.
                self.eventHandler(.log("Hermes model refresh failed: \(error.localizedDescription)"))
            }
        }
    }

    func send(_ text: String) async {
        guard !stopped, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !loaded { await load() }
        guard !stopped, let session else { return }
        let model = selectedModelID
        await perform { await session.send(text, model: model) }
    }

    func abort() async {
        guard !stopped, let session else { return }
        await perform { await session.abort() }
    }

    func respondToApproval(allow: Bool) {
        guard !stopped, let approval else { return }
        session?.respond(approval.id, value: allow ? "Allow once" : "Deny")
    }

    /// Applies to the next admission; existing runs retain their model.
    func setModel(_ id: String?) { selectedModelID = id }

    /// Tears down streams/tunnel use for this chat. Remote work continues on the server.
    func stop() {
        stopped = true
        loaded = false
        operations.values.forEach { $0.cancel() }
        operations.removeAll()
        session?.stop()
        // Cancelled requests may finish after a later load; detach their callbacks.
        session?.onEvent = nil
        session?.onState = nil
        session = nil
        updateActivity(working: false, tool: nil, approval: nil)
        // Tunnels are shared by endpoint; app termination closes them all.
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) async {
        let id = UUID()
        let task = Task { await operation() }
        operations[id] = task
        defer { operations[id] = nil }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func updateActivity(working: Bool, tool: String?, approval prompt: HermesApprovalPrompt?) {
        let changed = isWorking != working || approval != prompt
        isWorking = working
        currentTool = tool
        approval = prompt
        if changed { eventHandler(.activityChanged) }
    }

    private func report(_ text: String) {
        errorText = text
        eventHandler(.log(text))
    }
}

/// Hermes reports final text only: no thinking, streaming frames, tools, or HTML widgets.
extension HermesChatController: ChatTranscriptSource {
    var visibleMessages: [ChatMessage] { Array(messages.suffix(visibleMessageLimit)) }
    var hiddenMessageCount: Int { max(0, messages.count - visibleMessageLimit) }
    func loadEarlierMessages() { visibleMessageLimit = min(messages.count, visibleMessageLimit + 100) }
    var isThinking: Bool { false }
    var isCompacting: Bool { false }
    var transcriptProjectPath: String? { nil }
    var streamingFrameToken: Int { 0 }
    var messageScrollRequest: MessageScrollRequest? { nil }
    var htmlActionTarget: SessionController? { nil }
}

struct HermesProbeResult: Equatable {
    var models: [String]
}

enum HermesProbe {
    /// Validates the connection fields, opens the SSH tunnel, authenticates, and discovers
    /// models without starting a model turn. `apiKey` nil means use the saved key.
    static func check(_ connection: HermesConnection, apiKey: String?) async throws -> HermesProbeResult {
        try connection.validate()
        let info = try await HermesOnboarding.check(connection, apiKey: apiKey)
        // A probe may use an unsaved key. Caching the nonsecret catalog never saves that key.
        try? HermesCache.save(info, for: connection)
        return HermesProbeResult(models: info.models)
    }
}
